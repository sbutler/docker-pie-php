#!/bin/bash
# Copyright (c) 2017 University of Illinois Board of Trustees
# All rights reserved.
#
# Developed by:         Technology Services
#                       University of Illinois at Urbana-Champaign
#                       https://techservices.illinois.edu/
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# with the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
#      * Redistributions of source code must retain the above copyright notice,
#        this list of conditions and the following disclaimers.
#      * Redistributions in binary form must reproduce the above copyright notice,
#        this list of conditions and the following disclaimers in the
#        documentation and/or other materials provided with the distribution.
#      * Neither the names of Technology Services, University of Illinois at
#        Urbana-Champaign, nor the names of its contributors may be used to
#        endorse or promote products derived from this Software without specific
#        prior written permission.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# CONTRIBUTORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS WITH
# THE SOFTWARE.
set -e

echoerr () { echo "$@" 1>&2; }

php_envset () {
  echoerr "LIGHTTPD_ADMIN_SUBNET: ${LIGHTTPD_ADMIN_SUBNET:=10.0.0.0/8}"

  echoerr "PHP_MEMORY_LIMIT: ${PHP_MEMORY_LIMIT:=64M}"
  echoerr "PHP_POST_MAX_SIZE: ${PHP_POST_MAX_SIZE:=30M}"
  echoerr "PHP_UPLOAD_MAX_FILESIZE: ${PHP_UPLOAD_MAX_FILESIZE:=25M}"
  echoerr "PHP_MAX_FILE_UPLOADS: ${PHP_MAX_FILE_UPLOADS:=20}"
  echoerr "PHP_MAX_EXECUTION_TIME: ${PHP_MAX_EXECUTION_TIME:=120}"
  echoerr "PHP_DATE_TIMEZONE: ${PHP_DATE_TIMEZONE:=America/Chicago}"

  echoerr "PHP_OPCACHE_MEMORY_CONSUMPTION: ${PHP_OPCACHE_MEMORY_CONSUMPTION:=64}"
  echoerr "PHP_OPCACHE_REVALIDATE_FREQ: ${PHP_OPCACHE_REVALIDATE_FREQ:=2}"
  echoerr "PHP_OPCACHE_INTERNED_STRINGS_BUFFER: ${PHP_OPCACHE_INTERNED_STRINGS_BUFFER:=4}"
  echoerr "PHP_OPCACHE_MAX_ACCELERATED_FILES: ${PHP_OPCACHE_MAX_ACCELERATED_FILES:=2000}"
  echoerr "PHP_REALPATH_CACHE_SIZE: ${PHP_REALPATH_CACHE_SIZE:=16k}"
  echoerr "PHP_REALPATH_CACHE_TTL: ${PHP_REALPATH_CACHE_TTL:=120}"

  echoerr "PHP_FCGI_MAX_REQUESTS: ${PHP_FCGI_MAX_REQUESTS:=0}"

  export PHP_MEMORY_LIMIT PHP_POST_MAX_SIZE PHP_UPLOAD_MAX_FILESIZE PHP_MAX_FILE_UPLOADS PHP_MAX_EXECUTION_TIME PHP_DATE_TIMEZONE
  export PHP_OPCACHE_MEMORY_CONSUMPTION PHP_OPCACHE_REVALIDATE_FREQ PHP_OPCACHE_INTERNED_STRINGS_BUFFER PHP_OPCACHE_MAX_ACCELERATED_FILES PHP_REALPATH_CACHE_SIZE PHP_REALPATH_CACHE_TTL
  export PHP_FCGI_MAX_REQUESTS

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

  # Read configuration variable file if it is present
  if [[ -f /etc/default/php7.1-fpm ]]; then
    . /etc/default/php7.1-fpm
  fi

  PHP_CONF_PIDFILE=$(sed -n 's/^pid\s*=\s*//p' /etc/php/7.1/fpm/php-fpm.conf)
  PHP_PIDFILE=${PHP_CONF_PIDFILE:-/run/php7.1-fpm.pid}
}

if [[ "$1" == "php-pie" ]]; then
  shift

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

  php_envset

  rm -f "$PHP_PIDFILE"
  exec php-fpm7.1 --nodaemonize --force-stderr --fpm-config /etc/php/7.1/fpm/php-fpm.conf "$@"
elif [[ "$1" == "php"* ]]; then
  php_envset

  exec "$@"
else
  exec "$@"
fi
