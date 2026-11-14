FROM composer:2 AS composer

FROM php:8.4-fpm-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        unzip \
        libicu-dev \
        libpq-dev \
        libzip-dev \
        supervisor \
    && docker-php-ext-install -j"$(nproc)" pdo_pgsql intl bcmath zip pcntl opcache \
    && apt-get purge -y --auto-remove \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer /usr/bin/composer /usr/bin/composer

COPY docker/php/php.ini /usr/local/etc/php/conf.d/zz-studyroom.ini
COPY docker/php/supervisord.conf /etc/supervisor/conf.d/studyroom.conf

ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_MEMORY_LIMIT=-1

WORKDIR /var/www/html

EXPOSE 9000
