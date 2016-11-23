FROM sbutler/pie-base

ARG PHP_MODULES="\
  php5-mcrypt \
  php5-mysqlnd \
  php5-pspell aspell-en \
  php5-tidy \
  php5-xmlrpc \
  php5-xsl \
  php5-gd \
  php5-ldap \
  php5-ssh2 \
  php5-memcached \
  "

RUN set -xe \
    && apt-get update && apt-get install -y \
        lighttpd \
        ssmtp \
        php5-fpm \
        $PHP_MODULES \
        --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

COPY etc/ /etc
COPY opt/ /opt
COPY pie-entrypoint.sh /usr/local/bin/

RUN set -xe \
    && mkdir /var/empty \
    && mkdir /run/php5-fpm.sock.d && chmod 0755 /run/php5-fpm.sock.d \
    && rm /etc/php5/fpm/pool.d/www.conf \
    && useradd -N -r -g users -s /usr/sbin/nologin -u 8000 pie-agent \
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

VOLUME /etc/opt/pie/php5/fpm
VOLUME /etc/ssmtp
VOLUME /var/www

EXPOSE 9000-10000
EXPOSE 8008

ENTRYPOINT ["/usr/local/bin/pie-entrypoint.sh"]
CMD ["php-pie"]
