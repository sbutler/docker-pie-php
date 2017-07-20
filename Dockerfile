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
FROM sbutler/pie-base

ARG HTTPD_UID=8001
ARG HTTPD_GID=8001

ARG PHP_MODULES="\
  php7.1-bcmath \
  php7.1-bz2 \
  php7.1-curl \
  php7.1-dba \
  php7.1-gd \
  php7.1-igbinary \
  php7.1-intl \
  php7.1-ldap \
  php7.1-mbstring \
  php7.1-mcrypt \
  php7.1-memcached \
  php7.1-mysqlnd \
  php7.1-oauth \
  php7.1-odbc \
  php7.1-pgsql \
  php7.1-pspell aspell-en \
  php7.1-redis \
  php7.1-soap \
  php7.1-sqlite \
  php7.1-ssh2 \
  php7.1-tidy \
  php7.1-xml \
  php7.1-xmlrpc \
  php7.1-xsl \
  php7.1-zip \
  "

ARG PHP_POOL_UID_MIN=9000
ARG PHP_POOL_UID_MAX=9100

COPY sury-php.gpg /tmp

RUN set -xe \
    && apt-get update && apt-get install -y \
        apt-transport-https \
        ca-certificates \
        --no-install-recommends \
    && echo "deb https://packages.sury.org/php/ jessie main" >> /etc/apt/sources.list.d/sury-php.list \
    && echo "deb-src https://packages.sury.org/php/ jessie main" >> /etc/apt/sources.list.d/sury-php.list \
    && apt-key add /tmp/sury-php.gpg && rm /tmp/sury-php.gpg \
    && apt-get update && apt-get install -y \
        lighttpd \
        ssmtp \
        php7.1-fpm \
        $PHP_MODULES \
        --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

COPY etc/ /etc
COPY opt/ /opt
COPY pie-entrypoint.sh /usr/local/bin/

RUN set -xe \
    && groupadd -r -g $HTTPD_GID pie-www-data \
    && useradd -N -r -g pie-www-data -s /usr/sbin/nologin -u $HTTPD_UID pie-www-data \
    && mkdir /var/empty \
    && mkdir /run/php7.1-fpm.sock.d && chmod 0755 /run/php7.1-fpm.sock.d \
    && rm /etc/php/7.1/fpm/pool.d/www.conf \
    && useradd -N -r -g users -s /usr/sbin/nologin -u 8000 pie-agent \
    && for pool_idx in $(seq $PHP_POOL_UID_MIN $PHP_POOL_UID_MAX); do \
        useradd -N -r -g users -s /usr/sbin/nologin -u $pool_idx pie-pool${pool_idx}; \
        mkdir /tmp/php.pie-pool${pool_idx}; \
        chown pie-pool${pool_idx}:users /tmp/php.pie-pool${pool_idx}; \
        chmod u=rwx,g=,o= /tmp/php.pie-pool${pool_idx}; \
       done \
    && lighttpd-enable-mod fastcgi \
    && lighttpd-enable-mod pie-agent

ENV PIE_EXP_MEMORY_SIZE 64
ENV PIE_RES_MEMORY_SIZE 50

ENV LIGHTTPD_ADMIN_SUBNET   10.0.0.0/8

# Basic request variables
ENV PHP_MEMORY_LIMIT        64M
ENV PHP_POST_MAX_SIZE       30M
ENV PHP_UPLOAD_MAX_FILESIZE 25M
ENV PHP_MAX_FILE_UPLOADS    20
ENV PHP_MAX_EXECUTION_TIME  120
ENV PHP_DATE_TIMEZONE       "America/Chicago"

# Performance tuning nobs
ENV PHP_OPCACHE_MEMORY_CONSUMPTION      64
ENV PHP_OPCACHE_REVALIDATE_FREQ         2
ENV PHP_OPCACHE_INTERNED_STRINGS_BUFFER 4
ENV PHP_OPCACHE_MAX_ACCELERATED_FILES   2000
ENV PHP_REALPATH_CACHE_SIZE             16k
ENV PHP_REALPATH_CACHE_TTL              120

# FPM settings
ENV PHP_FCGI_MAX_REQUESTS   0

VOLUME /etc/opt/pie/php7.1/fpm
VOLUME /etc/ssmtp
VOLUME /var/www

EXPOSE 9000-10000
EXPOSE 8008

ENTRYPOINT ["/usr/local/bin/pie-entrypoint.sh"]
CMD ["php-pie"]
