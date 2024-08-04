ARG PHP_PACKAGES="php8.2 composer php8.2-common php8.2-pgsql php8.2-redis php8.2-mbstring\
        php8.2-simplexml php8.2-bcmath php8.2-gd php8.2-curl php8.2-zip\
        php8.2-imagick php8.2-bz2 php8.2-gmp php8.2-intl php8.2-soap php8.2-xsl"

FROM node:20-alpine AS javascript-builder
WORKDIR /app

ADD client/package.json client/package-lock.json ./
RUN npm install

ADD client /app/
RUN cp .env.docker .env
RUN npm run build

# syntax=docker/dockerfile:1.3-labs
FROM --platform=linux/amd64 ubuntu:24.04 AS php-dependency-installer

ARG PHP_PACKAGES

RUN apt-get update \
    && apt-get install -y software-properties-common \
    && add-apt-repository ppa:ondrej/php \
    && apt-get update \
    && apt-get install -y $PHP_PACKAGES composer

WORKDIR /app
ADD composer.json composer.lock artisan ./

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

RUN php artisan package:discover --ansi

FROM --platform=linux/amd64 ubuntu:24.04

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]

WORKDIR /app

ARG PHP_PACKAGES

RUN apt-get update \
    && apt-get install -y \
        supervisor nginx sudo redis \
        $PHP_PACKAGES php8.2-fpm wget \
    && apt-get clean

RUN useradd nuxt && mkdir ~nuxt && chown nuxt ~nuxt
RUN wget -qO- https://raw.githubusercontent.com/creationix/nvm/v0.39.3/install.sh | sudo -u nuxt bash
RUN sudo -u nuxt bash -c ". ~nuxt/.nvm/nvm.sh && nvm install --no-progress 20"

ADD docker/postgres-wrapper.sh docker/php-fpm-wrapper.sh docker/redis-wrapper.sh docker/nuxt-wrapper.sh docker/generate-api-secret.sh /usr/local/bin/
ADD docker/php-fpm.conf /etc/php/8.2/fpm/pool.d/
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
    && echo "daemon off;" >> /etc/nginx/nginx.conf \
    && echo "daemonize no" >> /etc/redis/redis.conf \
    && echo "appendonly yes" >> /etc/redis/redis.conf \
    && echo "dir /persist/redis/data" >> /etc/redis/redis.conf

EXPOSE 80

