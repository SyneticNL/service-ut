FROM debian:stretch-slim

ARG PHP_DEV
ARG PHP_DEBUG

ARG WODBY_USER_ID=1000
ARG WODBY_GROUP_ID=1000

# prevent Debian's PHP packages from being installed
# https://github.com/docker-library/php/pull/542
RUN set -eux; \
  { \
    echo 'Package: php*'; \
    echo 'Pin: release *'; \
    echo 'Pin-Priority: -1'; \
  } > /etc/apt/preferences.d/no-debian-php

# dependencies required for running "phpize"
# (see persistent deps below)
ENV PHPIZE_DEPS \
    autoconf \
    dpkg-dev \
    file \
    g++ \
    gcc \
    libc-dev \
    make \
    pkg-config \
    re2c

# persistent / runtime deps
RUN apt-get update && apt-get install -y \
    $PHPIZE_DEPS \
    ca-certificates \
    curl \
    xz-utils \
  --no-install-recommends && rm -r /var/lib/apt/lists/*

ENV PHP_INI_DIR /usr/local/etc/php
RUN mkdir -p $PHP_INI_DIR/conf.d

ENV PHP_EXTRA_CONFIGURE_ARGS --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data --disable-cgi

# Apply stack smash protection to functions using local buffers and alloca()
# Make PHP's main executable position-independent (improves ASLR security mechanism, and has no performance impact on x86_64)
# Enable optimization (-O2)
# Enable linker optimization (this sorts the hash buckets to improve cache locality, and is non-default)
# Adds GNU HASH segments to generated executables (this is used if present, and is much faster than sysv hash; in this configuration, sysv hash is also generated)
# https://github.com/docker-library/php/issues/272
ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -Wl,--hash-style=both -pie"

ENV GPG_KEYS A917B1ECDA84AEC2B568FED6F50ABC807BD5DCD0 528995BFEDFBA7191D46839EF9BA0ADA31CBD89E 1729F83938DA44E27BA0F4D3DBDB397470D12172

ENV PHP_VERSION 7.1.25
ENV PHP_URL="https://secure.php.net/get/php-7.1.25.tar.xz/from/this/mirror" PHP_ASC_URL="https://secure.php.net/get/php-7.1.25.tar.xz.asc/from/this/mirror"
ENV PHP_SHA256="0fd8dad1903cd0b2d615a1fe4209f99e53b7292403c8ffa1919c0f4dd1eada88" PHP_MD5=""

RUN set -xe; \
  apt-get update; \
  apt-get install -y --no-install-recommends wget dirmngr gnupg; \
  rm -rf /var/lib/apt/lists/*; \
  \
  mkdir -p /usr/src; \
  cd /usr/src; \
  \
  wget -O php.tar.xz "$PHP_URL"; \
  \
  if [ -n "$PHP_SHA256" ]; then \
    echo "$PHP_SHA256 *php.tar.xz" | sha256sum -c -; \
  fi; \
  if [ -n "$PHP_MD5" ]; then \
    echo "$PHP_MD5 *php.tar.xz" | md5sum -c -; \
  fi; \
  apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false

COPY docker-php-source /usr/local/bin/

RUN set -eux; \
  \
  savedAptMark="$(apt-mark showmanual)"; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libedit-dev \
    libsqlite3-dev \
    libssl-dev \
    libxml2-dev \
    zlib1g-dev \
    ${PHP_EXTRA_BUILD_DEPS:-} \
  ; \
  rm -rf /var/lib/apt/lists/*; \
  \
  export \
    CFLAGS="$PHP_CFLAGS" \
    CPPFLAGS="$PHP_CPPFLAGS" \
    LDFLAGS="$PHP_LDFLAGS" \
  ; \
  docker-php-source extract; \
  cd /usr/src/php; \
  gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
  debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
# https://bugs.php.net/bug.php?id=74125
  if [ ! -d /usr/include/curl ]; then \
    ln -sT "/usr/include/$debMultiarch/curl" /usr/local/include/curl; \
  fi; \
  ./configure \
    --build="$gnuArch" \
    --with-config-file-path="$PHP_INI_DIR" \
    --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
    \
# make sure invalid --configure-flags are fatal errors intead of just warnings
    --enable-option-checking=fatal \
    \
# https://github.com/docker-library/php/issues/439
    --with-mhash \
    \
# --enable-ftp is included here because ftp_ssl_connect() needs ftp to be compiled statically (see https://github.com/docker-library/php/issues/236)
    --enable-ftp \
# --enable-mbstring is included here because otherwise there's no way to get pecl to use it properly (see https://github.com/docker-library/php/issues/195)
    --enable-mbstring \
# --enable-mysqlnd is included here because it's harder to compile after the fact than extensions are (since it's a plugin for several extensions, not an extension in itself)
    --enable-mysqlnd \
    \
    --with-curl \
    --with-libedit \
    --with-openssl \
    --with-zlib \
    \
# bundled pcre does not support JIT on s390x
# https://manpages.debian.org/stretch/libpcre3-dev/pcrejit.3.en.html#AVAILABILITY_OF_JIT_SUPPORT
    $(test "$gnuArch" = 's390x-linux-gnu' && echo '--without-pcre-jit') \
    --with-libdir="lib/$debMultiarch" \
    \
    ${PHP_EXTRA_CONFIGURE_ARGS:-} \
  ; \
  make -j "$(nproc)"; \
  make install; \
  find /usr/local/bin /usr/local/sbin -type f -executable -exec strip --strip-all '{}' + || true; \
  make clean; \
  \
# https://github.com/docker-library/php/issues/692 (copy default example "php.ini" files somewhere easily discoverable)
  cp -v php.ini-* "$PHP_INI_DIR/"; \
  \
  cd /; \
  docker-php-source delete; \
  \
  apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
  \
  php --version; \
  \
# https://github.com/docker-library/php/issues/443
  pecl update-channels; \
  rm -rf /tmp/pear ~/.pearrc

COPY docker-php-ext-* docker-php-entrypoint /usr/local/bin/

ENTRYPOINT ["docker-php-entrypoint"]

WORKDIR /var/www/html

RUN set -ex \
  && cd /usr/local/etc \
  && if [ -d php-fpm.d ]; then \
    # for some reason, upstream's php-fpm.conf.default has "include=NONE/etc/php-fpm.d/*.conf"
    sed 's!=NONE/!=!g' php-fpm.conf.default | tee php-fpm.conf > /dev/null; \
    cp php-fpm.d/www.conf.default php-fpm.d/www.conf; \
  else \
    # PHP 5.x doesn't use "include=" by default, so we'll create our own simple config that mimics PHP 7+ for consistency
    mkdir php-fpm.d; \
    cp php-fpm.conf.default php-fpm.d/www.conf; \
    { \
      echo '[global]'; \
      echo 'include=etc/php-fpm.d/*.conf'; \
    } | tee php-fpm.conf; \
  fi \
  && { \
    echo '[global]'; \
    echo 'error_log = /proc/self/fd/2'; \
    echo; \
    echo '[www]'; \
    echo '; if we send this to /proc/self/fd/1, it never appears'; \
    echo 'access.log = /proc/self/fd/2'; \
    echo; \
    echo 'clear_env = no'; \
    echo; \
    echo '; Ensure worker stdout and stderr are sent to the main error log.'; \
    echo 'catch_workers_output = yes'; \
  } | tee php-fpm.d/docker.conf \
  && { \
    echo '[global]'; \
    echo 'daemonize = no'; \
    echo; \
    echo '[www]'; \
    echo 'listen = 9000'; \
  } | tee php-fpm.d/zz-docker.conf

### Wodby PHP specific starts here. ###

ENV PHP_DEV="${PHP_DEV}" \
    PHP_DEBUG="${PHP_DEBUG}" \
    SSHD_PERMIT_USER_ENV="yes" \
    PHP_PRESTISSIMO_VER="0.3" \
    WALTER_VER="1.3.0" \
    \
    EXT_AMQP_VER="1.9.3" \
    EXT_APCU_VER="5.1.11" \
    EXT_AST_VER="0.1.6" \
    EXT_DS_VER="1.2.4" \
    EXT_GEOIP_VER="1.1.1" \
    EXT_GRPC_VER="1.10.0" \
    EXT_IGBINARY_VER="2.0.5" \
    EXT_IMAGICK_VER="3.4.3" \
    EXT_MEMCACHED_VER="3.0.4" \
    EXT_MONGODB_VER="1.4.0" \
    EXT_OAUTH_VER="2.0.2" \
    EXT_REDIS_VER="3.1.6" \
    EXT_TIDEWAYS_XHPROF_VER="4.1.6" \
    EXT_XDEBUG_VER="2.6.0" \
    EXT_YAML_VER="2.0.2" \
    \
    PHP72_EXT_MCRYPT_VER="1.0.1" \
    \
    C_CLIENT_VER="2007f-r7" \
    FREETYPE_VER="2.8.1-r3" \
    GEOIP_VER="1.6.11-r0" \
    GMP_VER="6.1.2-r1" \
    ICU_LIBS_VER="59.1-r1" \
    IMAGEMAGICK_VER="7.0.7.11-r1" \
    JPEGOPTIM_VER="1.4.4-r0" \
    LIBBZ2_VER="1.0.6-r6" \
    LIBJPEG_TURBO_VER="1.5.2-r0" \
    LIBLDAP_VER="2.4.45-r3" \
    LIBLTDL_VER="2.4.6-r4" \
    LIBMEMCACHED_LIBS_VER="1.0.18-r2" \
    LIBMCRYPT_VER="2.5.8-r7" \
    LIBPNG_VER="1.6.34-r1" \
    LIBXSLT_VER="1.1.31-r0" \
    MARIADB_CLIENT_VER="10.1.32-r0" \
    POSTGRESQL_CLIENT_VER="10.4-r0" \
    RABBITMQ_C_VER="0.8.0-r3" \
    TIDYHTML_VER="5.4.0-r0" \
    YAML_VER="0.1.7-r0";

ENV APP_ROOT="/var/www/html" \
    CONF_DIR="/var/www/conf" \
    FILES_DIR="/mnt/files"

ENV PATH="${PATH}:/home/wodby/.composer/vendor/bin:${APP_ROOT}/vendor/bin" \
    SSHD_HOST_KEYS_DIR="/etc/ssh" \
    ENV="/home/wodby/.shrc" \
    \
    GIT_USER_EMAIL="wodby@example.com" \
    GIT_USER_NAME="wodby"

RUN set -xe; \
    \
    # Delete existing user/group if uid/gid occupied.
    existing_group=$(getent group "${WODBY_GROUP_ID}" | cut -d: -f1); \
    if [[ -n "${existing_group}" ]]; then delgroup "${existing_group}"; fi; \
    existing_user=$(getent passwd "${WODBY_USER_ID}" | cut -d: -f1); \
    if [[ -n "${existing_user}" ]]; then deluser "${existing_user}"; fi; \
    \

  groupadd -g "${WODBY_GROUP_ID}" wodby; \
  useradd -u "${WODBY_USER_ID}" -m -d /home/wodby/ -s /bin/bash -g sudo wodby; \
  adduser wodby www-data; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    autoconf \
    cmake \
    findutils \
    build-essential \
    libicu-dev \
    git \
    libpng-dev \
    imagemagick \
    libmagickwand-dev \
    libkf5imap-dev \
    jpegoptim \
    less \
    libbz2-dev \
    libjpeg-dev \
    libc-client-dev \
    libkrb5-dev \
    libgmp-dev \
    libldap2-dev \
    libltdl-dev \
    libmemcached-dev \
    libmcrypt-dev \
    libtool \
    libxslt1-dev \
    libtidy-dev \
    libgeoip-dev \
    make \
    mariadb-client \
    nano \
    openssh-server \
    openssh-client \
    patch \
    librabbitmq-dev \
    unixodbc-dev \
    rsync \
    sudo \
    sendmail \
    tig \
    tmux \
    libyaml-dev \
    libfreetype6-dev \
    unzip \
    libpcre3-dev \
    vim; \
  sed -i '/^wodby/s/!/*/' /etc/shadow; \
    docker-php-ext-install \
        bcmath \
        bz2 \
        calendar \
        exif \
        gmp \
        intl \
        ldap \
        mysqli \
        opcache \
        pcntl \
        pdo_mysql \
        soap \
        sockets \
        tidy \
        xmlrpc \
        xsl \
        zip; \
    \
    # GD
    docker-php-ext-configure gd \
        --with-gd \
        --with-freetype-dir=/usr/include/ \
        --with-png-dir=/usr/include/ \
        --with-jpeg-dir=/usr/include/; \
      NPROC=$(getconf _NPROCESSORS_ONLN); \
      docker-php-ext-install "-j${NPROC}" gd; \
    \
    # PECL extensions
    pecl config-set php_ini "${PHP_INI_DIR}/php.ini"; \
    \
    pecl install \
        "amqp-${EXT_AMQP_VER}" \
        "apcu-${EXT_APCU_VER}" \
        "ast-${EXT_AST_VER}" \
        "ds-${EXT_DS_VER}" \
        "geoip-${EXT_GEOIP_VER}" \
        "grpc-${EXT_GRPC_VER}" \
        "igbinary-${EXT_IGBINARY_VER}" \
        "imagick-${EXT_IMAGICK_VER}" \
        "memcached-${EXT_MEMCACHED_VER}" \
        "mongodb-${EXT_MONGODB_VER}" \
        "oauth-${EXT_OAUTH_VER}" \
        "redis-${EXT_REDIS_VER}" \
        "xdebug-${EXT_XDEBUG_VER}" \
        "sqlsrv" \
        "pdo_sqlsrv" \
        "yaml-${EXT_YAML_VER}"; \
    \
    docker-php-ext-enable \
        amqp \
        apcu \
        ast \
        ds \
        igbinary \
        imagick \
        geoip \
        grpc \
        memcached \
        mongodb \
        oauth \
        sqlsrv \
        pdo_sqlsrv \
        redis \
        xdebug \
        yaml; \
    \
    # Uploadprogress
    mkdir -p /usr/src/php/ext/uploadprogress; \
    up_url="https://github.com/wodby/pecl-php-uploadprogress/archive/latest.tar.gz"; \
    wget -qO- "${up_url}" | tar xz --strip-components=1 -C /usr/src/php/ext/uploadprogress; \
    docker-php-ext-install uploadprogress; \
    \
    # Tideways xhprof
    mkdir -p /usr/src/php/ext/xhprof; \
    xhprof_url="https://github.com/tideways/php-xhprof-extension/archive/v${EXT_TIDEWAYS_XHPROF_VER}.tar.gz"; \
    wget -qO- "${xhprof_url}" | tar xz --strip-components=1 -C /usr/src/php/ext/xhprof; \
    docker-php-ext-install xhprof; \
    \
    # Install composer
    wget -qO- https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer; \
    \
    # Plugin for parallel install
    composer global require "hirak/prestissimo:^${PHP_PRESTISSIMO_VER}"; \
    \
    # Install Walter
    walter_url="https://github.com/walter-cd/walter/releases/download/v${WALTER_VER}/walter_${WALTER_VER}_linux_amd64.tar.gz"; \
    wget -qO- "${walter_url}" | tar xz -C /tmp/; \
    mv /tmp/walter_linux_amd64/walter /usr/local/bin; \
    \
    { \
        echo 'export PS1="\u@${WODBY_APP_NAME:-php}.${WODBY_ENVIRONMENT_NAME:-container}:\w $ "'; \
        # Make sure PATH is the same for ssh sessions.
        echo "export PATH=${PATH}"; \
    } | tee /home/wodby/.shrc; \
    \
    # Make sure bash uses the same settings as ash.
    cp /home/wodby/.shrc /home/wodby/.bashrc; \
    cp /home/wodby/.shrc /home/wodby/.bash_profile; \
    \
    # Configure sudoers
    { \
        echo 'Defaults env_keep += "APP_ROOT FILES_DIR"' ; \
        \
        if [[ -n "${PHP_DEV}" ]]; then \
            echo 'wodby ALL=(root) NOPASSWD:SETENV:ALL'; \
        else \
            echo -n 'wodby ALL=(root) NOPASSWD:SETENV: ' ; \
            echo -n '/usr/local/bin/files_chmod, ' ; \
            echo -n '/usr/local/bin/files_chown, ' ; \
            echo -n '/usr/local/bin/files_sync, ' ; \
            echo -n '/usr/local/bin/gen_ssh_keys, ' ; \
            echo -n '/usr/local/bin/init_container, ' ; \
            echo -n '/usr/local/bin/migrate, ' ; \
            echo -n '/usr/local/sbin/php-fpm, ' ; \
            echo -n '/usr/local/bin/go, ' ; \
            echo -n '/usr/sbin/sshd, ' ; \
            echo '/usr/sbin/crond' ; \
        fi; \
    } | tee /etc/sudoers.d/wodby; \
    \
    # Create required directories and fix permissions
    mkdir -p \
        "${APP_ROOT}" \
        "${CONF_DIR}" \
        "${FILES_DIR}/public" \
        "${FILES_DIR}/private" \
        "${FILES_DIR}/xdebug/traces" \
        "${FILES_DIR}/xdebug/profiler" \
        /home/wodby/.ssh \
        /home/www-data/.ssh; \
    \
    chmod -R 775 "${FILES_DIR}"; \
    chown -R www-data:www-data "${FILES_DIR}" /home/www-data/.ssh; \
    chown -R wodby:wodby \
        "${APP_ROOT}" \
        "${CONF_DIR}" \
        "${PHP_INI_DIR}/conf.d" \
        /usr/local/etc/php-fpm.d/ \
        /home/wodby/; \
    \
    # SSHD
    touch /etc/ssh/sshd_config; \
    chown wodby: /etc/ssh/sshd_config; \
    \
    # Cleanup
    composer clear-cache; \
    docker-php-source delete; \
    pecl clear-cache; \
    \
    rm -rf \
        /usr/src/php/ext/ast \
        /usr/src/php/ext/uploadprogress \
        /usr/include/php \
        /usr/lib/php/build \
        /tmp/* \
        /root/.composer; \
    \
    if [[ -z "${PHP_DEV}" ]]; then \
        rm -rf /usr/src/php.tar.xz; \
    fi

WORKDIR ${APP_ROOT}

RUN set -xe; \
  curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add -; \
  curl https://packages.microsoft.com/config/debian/9/prod.list > /etc/apt/sources.list.d/mssql-release.list; \
  apt-get install -y apt-transport-https; \
  apt-get update; \
  ACCEPT_EULA=Y apt-get install -y msodbcsql17; \
  ACCEPT_EULA=Y apt-get install -y mssql-tools; \
  echo 'export PATH="$PATH:/opt/mssql-tools/bin"' >> ~/.shrc; \
  export PATH="$PATH:/opt/mssql-tools/bin"; \
  cp /home/wodby/.shrc /home/wodby/.bashrc; \
  cp /home/wodby/.shrc /home/wodby/.bash_profile;

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y locales

RUN sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    update-locale LANG=en_US.UTF-8

ENV LANG en_US.UTF-8

RUN set -eux; \
    apt-get install -y --no-install-recommends golang; \
    { \
      echo 'export GOPATH=/home/wodby'; \
    } | tee /home/wodby/.shrc; \
    cp /home/wodby/.shrc /home/wodby/.bashrc; \
    cp /home/wodby/.shrc /home/wodby/.bash_profile; \
    export GOPATH=/home/wodby; \
    go get github.com/tsg/gotpl; \
    go install github.com/tsg/gotpl;

EXPOSE 9000

COPY templates /etc/gotpl/
COPY docker-entrypoint.sh /
#COPY docker-lucius-sendmail.sh /
COPY bin /usr/local/bin/

#ENTRYPOINT ["/docker-entrypoint.sh"]
#ENTRYPOINT ["/docker-lucius-sendmail.sh"]
CMD ["sudo", "php-fpm"]

RUN set -ex; \
    apt-get install -y --no-install-recommends \
    ssmtp \
    mailutils;

RUN echo "hostname=uva_php" > /etc/ssmtp/ssmtp.conf
RUN echo "root=support@lucius.digital" >> /etc/ssmtp/ssmtp.conf
RUN echo "mailhub=mailhog:1025" >> /etc/ssmtp/ssmtp.conf
# The above 'mailhog' is the name you used for the link command
# in your docker-compose file or docker link command.
# Docker automatically adds that name in the hosts file
# of the container you're linking Mailhog to.

# Fully qualified domain name configuration for sendmail on localhost.
# Without this sendmail will not work.
# This must match the value for 'hostname' field that you set in ssmtp.conf.
RUN echo "localhost uva_php" >> /etc/hosts

RUN curl -Lsf 'https://storage.googleapis.com/golang/go1.8.3.linux-amd64.tar.gz' | tar -C '/usr/local' -xvzf -
ENV PATH /usr/local/go/bin:$PATH
RUN go get github.com/mailhog/mhsendmail
RUN cp /root/go/bin/mhsendmail /usr/bin/mhsendmail
RUN echo 'sendmail_path = /usr/bin/mhsendmail --smtp-addr mailhog:1025' > /usr/local/etc/php/php.ini

RUN set -ex; \
    \
    composer global require drush/drush:^8.0; \
    \
    # Drush launcher
    drush_launcher_url="https://github.com/drush-ops/drush-launcher/releases/download/0.6.0/drush.phar"; \
    wget -O drush.phar "${drush_launcher_url}"; \
    chmod +x drush.phar; \
    sudo mv drush.phar /usr/local/bin/drush; \
    \
    # Drush extensions
    mkdir -p /home/wodby/.drush; \
    drush_patchfile_url="https://bitbucket.org/davereid/drush-patchfile.git"; \
    git clone "${drush_patchfile_url}" /home/wodby/.drush/drush-patchfile; \
    drush_rr_url="https://ftp.drupal.org/files/projects/registry_rebuild-7.x-2.5.tar.gz"; \
    wget -qO- "${drush_rr_url}" | tar zx -C /home/wodby/.drush; \
    \
    # Drupal console
    console_url="https://github.com/hechoendrupal/drupal-console-launcher/releases/download/1.8.0/drupal.phar"; \
    curl "${console_url}" -L -o drupal.phar; \
    sudo mv drupal.phar /usr/local/bin/drupal; \
    chmod +x /usr/local/bin/drupal; \
    mkdir -p "${FILES_DIR}/config"; \
    chown www-data:www-data "${FILES_DIR}/config"; \
    chmod 775 "${FILES_DIR}/config"; \
    \
    # Clean up
    composer clear-cache;

USER wodby

COPY init /docker-entrypoint-init.d/
