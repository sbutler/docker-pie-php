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
FROM sbutler/pie-base:latest-ubuntu18.04

ARG HTTPD_UID=8001
ARG HTTPD_GID=8001
ENV PIE_PHP_VERSION 7.1

ARG PHP_MODULES="\
  php${PIE_PHP_VERSION}-bcmath \
  php${PIE_PHP_VERSION}-bz2 \
  php${PIE_PHP_VERSION}-curl \
  php${PIE_PHP_VERSION}-dba \
  php${PIE_PHP_VERSION}-gd \
  php${PIE_PHP_VERSION}-igbinary \
  php${PIE_PHP_VERSION}-intl \
  php${PIE_PHP_VERSION}-ldap \
  php${PIE_PHP_VERSION}-mbstring \
  php${PIE_PHP_VERSION}-mcrypt \
  php${PIE_PHP_VERSION}-memcached \
  php${PIE_PHP_VERSION}-mysqlnd \
  php${PIE_PHP_VERSION}-oauth \
  php${PIE_PHP_VERSION}-odbc \
  php${PIE_PHP_VERSION}-pgsql \
  php${PIE_PHP_VERSION}-pspell aspell-en \
  php${PIE_PHP_VERSION}-redis \
  php${PIE_PHP_VERSION}-soap \
  php${PIE_PHP_VERSION}-sqlite3 \
  php${PIE_PHP_VERSION}-ssh2 \
  php${PIE_PHP_VERSION}-tidy \
  php${PIE_PHP_VERSION}-xml \
  php${PIE_PHP_VERSION}-xmlrpc \
  php${PIE_PHP_VERSION}-xsl \
  php${PIE_PHP_VERSION}-zip \
  "

ARG PHP_POOL_UID_MIN=9000
ARG PHP_POOL_UID_MAX=9100

RUN set -xe \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get update && apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        software-properties-common \
    && add-apt-repository ppa:ondrej/php \
    && apt-get update && apt-get install -y --no-install-recommends \
        curl \
        lighttpd libconfig-tiny-perl \
        psmisc \
        python3 python3-pip python3-botocore python3-jmespath python3-requests \
        ssmtp \
        php${PIE_PHP_VERSION}-fpm \
        $PHP_MODULES \
    && rm /etc/php/${PIE_PHP_VERSION}/fpm/pool.d/www.conf \
    && rm -rf /var/lib/apt/lists/*

COPY etc/ /etc
COPY opt/ /opt
COPY pie-entrypoint.sh /usr/local/bin/
COPY pie-loginit.pl /usr/local/bin/

COPY pie-aws-metrics.py /usr/local/bin/
RUN pip3 install --no-cache-dir boto3

RUN groupadd -r -g $HTTPD_GID pie-www-data
RUN useradd -N -r -g pie-www-data -s /usr/sbin/nologin -u $HTTPD_UID pie-www-data
RUN mkdir /var/empty
RUN mkdir /run/php${PIE_PHP_VERSION}-fpm.sock.d && chmod 0755 /run/php${PIE_PHP_VERSION}-fpm.sock.d
RUN mkdir /run/php${PIE_PHP_VERSION}-fpm.d && chmod 0755 /run/php${PIE_PHP_VERSION}-fpm.d
RUN mkdir /var/log/php${PIE_PHP_VERSION}-fpm && chmod 0755 /var/log/php${PIE_PHP_VERSION}-fpm
RUN useradd -N -r -g users -s /usr/sbin/nologin -u 8000 pie-agent
RUN set -xe; for pool_idx in $(seq $PHP_POOL_UID_MIN $PHP_POOL_UID_MAX); do \
        useradd -N -r -g users -s /usr/sbin/nologin -u $pool_idx pie-pool${pool_idx}; \
        mkdir /tmp/php.pie-pool${pool_idx}; \
        chown pie-pool${pool_idx}:users /tmp/php.pie-pool${pool_idx}; \
        chmod u=rwx,g=,o= /tmp/php.pie-pool${pool_idx}; \
    done
RUN lighttpd-enable-mod fastcgi
RUN lighttpd-enable-mod pie-agent

COPY pie-dynamodb-sessions/ /usr/local/share/pie-dynamodb-sessions/

RUN set -xe \
    && cd /usr/local/bin \
    && curl --location --fail https://getcomposer.org/installer | php \
    && cd /usr/local/share/pie-dynamodb-sessions \
    && COMPOSER_ALLOW_SUPERUSER=1 composer.phar install --no-interaction --no-ansi --no-progress --optimize-autoloader

ENV PIE_EXP_MEMORY_SIZE=64 \
    PIE_RES_MEMORY_SIZE=50 \
    PIE_PHPPOOLS_INCLUDE_DIRS="/etc/php/${PIE_PHP_VERSION}/fpm/pool.d:/etc/opt/pie/php${PIE_PHP_VERSION}/fpm/pool.d" \
    PIE_PHPPOOLS_STATUSURLS_FILE="/run/php${PIE_PHP_VERSION}-fpm.d/status-urls.txt" \
    PIE_PHPPOOLS_LOG_DIR="/var/log/php${PIE_PHP_VERSION}-fpm"

ENV LIGHTTPD_ADMIN_SUBNET=10.0.0.0/8

# Basic request variables
ENV PHP_MEMORY_LIMIT=64M \
    PHP_POST_MAX_SIZE=30M \
    PHP_UPLOAD_MAX_FILESIZE=25M \
    PHP_MAX_FILE_UPLOADS=20 \
    PHP_MAX_EXECUTION_TIME=120 \
    PHP_DATE_TIMEZONE="America/Chicago" \
    PHP_LOGGING=""

# Performance tuning nobs
ENV PHP_OPCACHE_MEMORY_CONSUMPTION=64 \
    PHP_OPCACHE_REVALIDATE_FREQ=2 \
    PHP_OPCACHE_INTERNED_STRINGS_BUFFER=4 \
    PHP_OPCACHE_MAX_ACCELERATED_FILES=2000 \
    PHP_REALPATH_CACHE_SIZE=16k \
    PHP_REALPATH_CACHE_TTL=120

# FPM settings
ENV PHP_FCGI_MAX_REQUESTS=0

VOLUME /etc/opt/pie/php${PIE_PHP_VERSION}/fpm
VOLUME /run/php${PIE_PHP_VERSION}-fpm.sock.d /run/php${PIE_PHP_VERSION}-fpm.d
VOLUME /var/log/php${PIE_PHP_VERSION}-fpm

EXPOSE 9000-10000
EXPOSE 8008

ENTRYPOINT ["/usr/local/bin/pie-entrypoint.sh"]
CMD ["php-pie"]
