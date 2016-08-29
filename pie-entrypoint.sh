#!/bin/bash
set -e

echoerr () { echo "$@" 1>&2; }

if [[ "$1" == "php-pie" ]]; then
  shift

  # Attempt to set ServerLimit and MaxRequestWorkers based on the amount of
  # memory in the container. This will never use less than 16 servers, and
  # never more than 2000. If no memory limits are specified, then it will
  # use free space
  exp_memory_size=${PIE_EXP_MEMORY_SIZE:-50}
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
  (( ram_limit <= 0 )) && ram_limit=$(free -m | awk '/^Mem:/ { print $4 }')

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

  echoerr "PHP_FCGI_MAX_CHILDREN: $PHP_FCGI_MAX_CHILDREN"

  export PHP_FCGI_MAX_CHILDREN

  (
    # Start lighttpd to get PHP-FPM ping healthchecks
    if [[ -f /etc/default/lighttpd ]]; then
      . /etc/default/lighttpd
    fi

    LIGHTTPD_CONF_PIDFILE=$(sed -n 's/^\s*server\.pid-file\s*=\s*"(.+)"$/$1/p' /etc/lighttpd/lighttpd.conf)
    LIGHTTPD_PIDFILE=${LIGHTTPD_CONF_PIDFILE:-/run/lighttpd.pid}

    rm -f "$LIGHTTPD_PIDFILE"

    lighttpd -f /etc/lighttpd/lighttpd.conf
  )

  # Read configuration variable file if it is present
  if [[ -f /etc/default/php5-fpm ]]; then
  	. /etc/default/php5-fpm
  fi

  PHP_CONF_PIDFILE=$(sed -n 's/^pid\s*=\s*//p' /etc/php5/fpm/php-fpm.conf)
  PHP_PIDFILE=${PHP_CONF_PIDFILE:-/run/php5-fpm.pid}

  rm -f "$PHP_PIDFILE"

  #pie-sitegen.pl 1>&2
  exec php5-fpm --nodaemonize --force-stderr --fpm-config /etc/php5/fpm/php-fpm.conf "$@"
else
  exec "$@"
fi
