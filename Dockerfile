ARG PHP_PACKAGES="php8.3 composer php8.3-common php8.3-pgsql php8.3-redis php8.3-mbstring\
        php8.3-simplexml php8.3-bcmath php8.3-gd php8.3-curl php8.3-zip\
        php8.3-imagick php8.3-bz2 php8.3-gmp php8.3-int php8.3-pcov php8.3-soap php8.3-xsl"

FROM node:20-alpine AS javascript-builder
WORKDIR /app

# It's best to add as few files as possible before running the build commands
# as they will be re-run everytime one of those files changes.
#
# It's possible to run npm install with only the package.json and package-lock.json file.

ADD client/package.json client/package-lock.json ./
RUN npm install

ADD client /app/
RUN cp .env.docker .env
RUN npm run build

# syntax=docker/dockerfile:1.3-labs
FROM --platform=linux/amd64 ubuntu:24.04 AS php-dependency-installer

ARG PHP_PACKAGES

RUN apt-get update \
    && apt-get install -y $PHP_PACKAGES composer

WORKDIR /app
ADD composer.json composer.lock artisan ./

# NOTE: The project would build more reliably if all php files were added before running
# composer install.  This would though introduce a dependency which would cause every
# dependency to be re-installed each time any php file is edited.  It may be necessary in
# future to remove this 'optimisation' by moving the `RUN composer install` line after all
# the following ADD commands.

# Running artisan requires the full php app to be installed so we need to remove the
# post-autoload command from the composer file if we want to run composer without
# adding a dependency to all the php files.
RUN sed 's_@php artisan package:discover_/bin/true_;' -i composer.json
ADD app/helpers.php /app/app/helpers.php
RUN composer install --ignore-platform-req=php

ADD app /app/app
ADD bootstrap /app/bootstrap
ADD config /app/config
ADD database /app/database
ADD public public
ADD routes routes
ADD tests tests

# Manually run the command we deleted from composer.json earlier
RUN php artisan package:discover --ansi


FROM --platform=linux/amd64 ubuntu:24.04

# supervisord is a process manager which will be responsible for managing the
# various server processes.  These are configured in docker/supervisord.conf
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]

WORKDIR /app

ARG PHP_PACKAGES

# Instalar wget y software-properties-common para añadir repositorios
RUN apt-get update && apt-get install -y wget gnupg software-properties-common

# Añadir el repositorio de PostgreSQL
RUN echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" | tee /etc/apt/sources.list.d/pgdg.list

# Importar la clave del repositorio
RUN wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -

RUN apt-get update \
    && apt-get install -y \
        supervisor nginx sudo postgresql-15 redis\
        $PHP_PACKAGES php8.3-fpm php8.3-curl wget\
    && apt-get clean

RUN useradd nuxt && mkdir ~nuxt && chown nuxt ~nuxt
RUN wget -qO- https://raw.githubusercontent.com/creationix/nvm/v0.39.3/install.sh | sudo -u nuxt bash
RUN sudo -u nuxt bash -c ". ~nuxt/.nvm/nvm.sh && nvm install --no-progress 20"

ADD docker/postgres-wrapper.sh docker/php-fpm-wrapper.sh docker/redis-wrapper.sh docker/nuxt-wrapper.sh docker/generate-api-secret.sh /usr/local/bin/
ADD docker/php-fpm.conf /etc/php/8.3/fpm/pool.d/
ADD docker/nginx.conf /etc/nginx/sites-enabled/default
ADD docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

ADD . .
ADD .env.docker .env
ADD client/.env.docker client/.env

COPY --from=javascript-builder /app/.output/ ./nuxt/
RUN cp -r nuxt/public .
COPY --from=php-dependency-installer /app/vendor/ ./vendor/

RUN chmod a+x /usr/local/bin/*.sh /app/artisan \
    && ln -s /app/artisan /usr/local/bin/artisan \
    && useradd opnform \
    && echo "daemon off;" >> /etc/nginx/nginx.conf\
    && echo "daemonize no" >> /etc/redis/redis.conf\
    && echo "appendonly yes" >> /etc/redis/redis.conf\
    && echo "dir /persist/redis/data" >> /etc/redis/redis.conf


EXPOSE 80
