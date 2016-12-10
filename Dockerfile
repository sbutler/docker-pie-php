FROM sbutler/pie-base

ARG PHP_MODULES="\
  php7.0-mcrypt \
  php7.0-mysqlnd \
  php7.0-pspell aspell-en \
  php7.0-tidy \
  php7.0-xmlrpc \
  php7.0-xsl \
  php7.0-gd \
  php7.0-ldap \
  php7.0-ssh2 \
  php7.0-memcached \
  "

ARG PHP_POOL_UID_MIN=9000
ARG PHP_POOL_UID_MAX=9100

COPY dotdeb.gpg /tmp

RUN set -xe \
    && echo "deb http://packages.dotdeb.org jessie all" >> /etc/apt/sources.list.d/dotdeb.org.list \
    && echo "deb-src http://packages.dotdeb.org jessie all" >> /etc/apt/sources.list.d/dotdeb.org.list \
    && apt-key add /tmp/dotdeb.gpg && rm /tmp/dotdeb.gpg \
    && apt-get update && apt-get install -y \
        lighttpd \
        ssmtp \
        php7.0-fpm \
        $PHP_MODULES \
        --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

COPY etc/ /etc
COPY opt/ /opt
COPY pie-entrypoint.sh /usr/local/bin/

RUN set -xe \
    && mkdir /var/empty \
    && mkdir /run/php7.0-fpm.sock.d && chmod 0755 /run/php7.0-fpm.sock.d \
    && rm /etc/php/7.0/fpm/pool.d/www.conf \
    && useradd -N -r -g users -s /usr/sbin/nologin -u 8000 pie-agent \
    && for pool_idx in $(seq $PHP_POOL_UID_MIN $PHP_POOL_UID_MAX); do \
        useradd -N -r -g users -s /usr/sbin/nologin -u $pool_idx pie-pool${pool_idx}; \
       done \
    && lighttpd-enable-mod fastcgi \
    && lighttpd-enable-mod pie-agent

ENV PIE_EXP_MEMORY_SIZE 64
ENV PIE_RES_MEMORY_SIZE 50

ENV LIGHTTPD_ADMIN_SUBNET   10.0.0.0/8

ENV PHP_MEMORY_LIMIT        64M
ENV PHP_POST_MAX_SIZE       30M
ENV PHP_UPLOAD_MAX_FILESIZE 25M
ENV PHP_MAX_FILE_UPLOADS    20
ENV PHP_MAX_EXECUTION_TIME  120
ENV PHP_DATE_TIMEZONE       "America/Chicago"

VOLUME /etc/opt/pie/php7.0/fpm
VOLUME /etc/ssmtp
VOLUME /var/www

EXPOSE 9000-10000
EXPOSE 8008

ENTRYPOINT ["/usr/local/bin/pie-entrypoint.sh"]
CMD ["php-pie"]
