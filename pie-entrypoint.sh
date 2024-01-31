#!/bin/bash
set -e

echoerr () { echo "$@" 1>&2; }

php_envset () {
  echoerr "PIE_PHP_VERSION: ${PIE_PHP_VERSION:=8.3}"
  echoerr "PIE_PHPPOOLS_INCLUDE_DIRS: ${PIE_PHPPOOLS_INCLUDE_DIRS:=/etc/php/${PIE_PHP_VERSION}/fpm/pool.d:/etc/opt/pie/php${PIE_PHP_VERSION}/fpm/pool.d}"
  echoerr "PIE_PHPPOOLS_STATUSURLS_FILE: ${PIE_PHPPOOLS_STATUSURLS_FILE:=/run/php-fpm.d/status-urls.txt}"
  echoerr "PIE_PHPPOOLS_LOG_DIR: ${PIE_PHPPOOLS_LOG_DIR:=/var/log/php-fpm}"

  echoerr "LIGHTTPD_ADMIN_SUBNET: ${LIGHTTPD_ADMIN_SUBNET:=10.0.0.0/8}"

  echoerr "PHP_MEMORY_LIMIT: ${PHP_MEMORY_LIMIT:=64M}"
  echoerr "PHP_POST_MAX_SIZE: ${PHP_POST_MAX_SIZE:=30M}"
  echoerr "PHP_UPLOAD_MAX_FILESIZE: ${PHP_UPLOAD_MAX_FILESIZE:=25M}"
  echoerr "PHP_MAX_FILE_UPLOADS: ${PHP_MAX_FILE_UPLOADS:=20}"
  echoerr "PHP_MAX_EXECUTION_TIME: ${PHP_MAX_EXECUTION_TIME:=120}"
  echoerr "PHP_DATE_TIMEZONE: ${PHP_DATE_TIMEZONE:=America/Chicago}"
  echoerr "PHP_LOGGING: ${PHP_LOGGING}"
  echoerr "PHP_XDEBUG: ${PHP_XDEBUG:=off}"

  echoerr "PHP_SESSION_SAVE_HANDLER: ${PHP_SESSION_SAVE_HANDLER:=files}"
  echoerr "PHP_SESSION_SAVE_PATH: ${PHP_SESSION_SAVE_PATH:=/tmp}"

  echoerr "PHP_OPCACHE_MEMORY_CONSUMPTION: ${PHP_OPCACHE_MEMORY_CONSUMPTION:=64}"
  echoerr "PHP_OPCACHE_REVALIDATE_FREQ: ${PHP_OPCACHE_REVALIDATE_FREQ:=2}"
  echoerr "PHP_OPCACHE_INTERNED_STRINGS_BUFFER: ${PHP_OPCACHE_INTERNED_STRINGS_BUFFER:=4}"
  echoerr "PHP_OPCACHE_MAX_ACCELERATED_FILES: ${PHP_OPCACHE_MAX_ACCELERATED_FILES:=2000}"
  echoerr "PHP_REALPATH_CACHE_SIZE: ${PHP_REALPATH_CACHE_SIZE:=16k}"
  echoerr "PHP_REALPATH_CACHE_TTL: ${PHP_REALPATH_CACHE_TTL:=120}"

  echoerr "PHP_FCGI_MAX_REQUESTS: ${PHP_FCGI_MAX_REQUESTS:=0}"
  echoerr "PHP_FCGI_MAX_CHILDREN (provided): ${PHP_FCGI_MAX_CHILDREN:=0}"

  export PIE_PHP_VERSION PIE_PHPPOOLS_INCLUDE_DIRS PIE_PHPPOOLS_STATUSURLS_FILE PIE_PHPPOOLS_LOG_DIR
  export LIGHTTPD_ADMIN_SUBNET
  export PHP_MEMORY_LIMIT PHP_POST_MAX_SIZE PHP_UPLOAD_MAX_FILESIZE PHP_MAX_FILE_UPLOADS PHP_MAX_EXECUTION_TIME PHP_DATE_TIMEZONE PHP_LOGGING PHP_XDEBUG
  export PHP_SESSION_SAVE_HANDLER PHP_SESSION_SAVE_PATH
  export PHP_OPCACHE_MEMORY_CONSUMPTION PHP_OPCACHE_REVALIDATE_FREQ PHP_OPCACHE_INTERNED_STRINGS_BUFFER PHP_OPCACHE_MAX_ACCELERATED_FILES PHP_REALPATH_CACHE_SIZE PHP_REALPATH_CACHE_TTL
  export PHP_FCGI_MAX_REQUESTS

  if (( PHP_FCGI_MAX_CHILDREN <= 0 )); then
    # Attempt to set ServerLimit and MaxRequestWorkers based on the amount of
    # memory in the container. This will never use less than 16 servers, and
    # never more than 2000. If no memory limits are specified, then it will
    # use free space
    exp_memory_size=${PIE_EXP_MEMORY_SIZE:-64}
    res_memory_size=${PIE_RES_MEMORY_SIZE:-50}

    ram_limit=0
    if [[ -f "/sys/fs/cgroup/memory/memory.limit_in_bytes" ]]; then
      ram_limit=$(</sys/fs/cgroup/memory/memory.limit_in_bytes)
      if [[ "$ram_limit" = "9223372036854771712" ]]; then
        ram_limit=0
      else
        ram_limit=$(echo "$ram_limit" | awk '{ print int( $1 / 1048576 ) }')
      fi
    fi
    (( ram_limit <= 0 )) && ram_limit=$(free -m | awk '/^Mem:/ { print $4 + $6 + $7 }')

    echoerr "exp_memory_size: $exp_memory_size MB"
    echoerr "res_memory_size: $res_memory_size MB"
    echoerr "ram_limit: $ram_limit MB"

    PHP_FCGI_MAX_CHILDREN=5

    if (( ram_limit > 0 )); then
      PHP_FCGI_MAX_CHILDREN=$( \
        echo "$exp_memory_size $res_memory_size $ram_limit" \
        | awk '{ print int( ($3 - $2) / $1 ) }' \
      )
      if (( PHP_FCGI_MAX_CHILDREN < 5 )); then
        PHP_FCGI_MAX_CHILDREN=5
      elif (( PHP_FCGI_MAX_CHILDREN > 512 )); then
        PHP_FCGI_MAX_CHILDREN=512
      fi
    fi

    echoerr "PHP_FCGI_MAX_CHILDREN (calculated): $PHP_FCGI_MAX_CHILDREN"
  fi

  export PHP_FCGI_MAX_CHILDREN

  # Read configuration variable file if it is present
  if [[ -f /etc/default/php${PIE_PHP_VERSION}-fpm ]]; then
    . /etc/default/php${PIE_PHP_VERSION}-fpm
  fi

  PHP_CONF_PIDFILE=$(sed -n 's/^pid\s*=\s*//p' /etc/php/${PIE_PHP_VERSION}/fpm/php-fpm.conf)
  PHP_PIDFILE=${PHP_CONF_PIDFILE:-/run/php-fpm.pid}
}

if [[ "$1" == "php-pie" ]]; then
  shift
  php_envset
  pie-loginit.pl
  if [[ -n $PHP_XDEBUG && $PHP_XDEBUG != off ]]; then
    phpenmod -s fpm xdebug
  fi

  (
    # Start lighttpd to get PHP-FPM ping healthchecks
    if [[ -f /etc/default/lighttpd ]]; then
      . /etc/default/lighttpd
    fi

    LIGHTTPD_CONF_PIDFILE=$(sed -n 's/^\s*server\.pid-file\s*=\s*"(.+)"$/$1/p' /etc/lighttpd/lighttpd.conf)
    LIGHTTPD_PIDFILE=${LIGHTTPD_CONF_PIDFILE:-/run/lighttpd.pid}

    rm -f "$LIGHTTPD_PIDFILE"
    setsid lighttpd-angel -D -f /etc/lighttpd/lighttpd.conf &
  )
  if [[ -n $PHP_AWS_METRICS_LOGGROUP_NAME ]]; then
      set +e
      setsid pie-aws-metrics.py 1>&2 &
      set -e
  fi

  rm -f "$PHP_PIDFILE"
  exec php-fpm${PIE_PHP_VERSION} --nodaemonize --force-stderr --fpm-config /etc/php/${PIE_PHP_VERSION}/fpm/php-fpm.conf "$@"
elif [[ "$1" == "php"* ]]; then
  php_envset
  pie-loginit.pl
  if [[ -n $PHP_XDEBUG && $PHP_XDEBUG != off ]]; then
    phpenmod -s fpm xdebug
  fi

  exec "$@"
elif [[ "$1" == "lighttpd"* || "$1" == "pie-aws-metrics.py" ]]; then
  php_envset

  exec "$@"
else
  exec "$@"
fi
