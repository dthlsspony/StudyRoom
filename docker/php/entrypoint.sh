#!/bin/bash
set -euo pipefail

cd /var/www/html

# Каталоги с хоста монтируются с правами root — отдаём их процессу php-fpm.
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true

echo "==> Waiting for database..."
for i in $(seq 1 60); do
    if php -r '
        $host = getenv("DB_HOST") ?: "db";
        $port = getenv("DB_PORT") ?: "5432";
        $db   = getenv("DB_DATABASE") ?: "studyroom";
        $user = getenv("DB_USERNAME") ?: "studyroom";
        $pass = getenv("DB_PASSWORD") ?: "";
        try {
            new PDO("pgsql:host={$host};port={$port};dbname={$db}", $user, $pass, [PDO::ATTR_TIMEOUT => 3]);
            exit(0);
        } catch (Throwable $e) {
            exit(1);
        }
    ' 2>/dev/null; then
        echo "==> Database is up."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "==> Database is not reachable, aborting." >&2
        exit 1
    fi
    sleep 2
done

if [ ! -f .env ]; then
    echo "==> .env not found, copying .env.example"
    cp .env.example .env
fi

if ! grep -qE '^APP_KEY=.+' .env; then
    echo "==> Generating APP_KEY..."
    php artisan key:generate --force --no-interaction
fi

echo "==> Installing composer dependencies..."
composer install --no-interaction --prefer-dist --no-progress --optimize-autoloader

if [ "${AUTO_MIGRATE:-true}" = "true" ]; then
    echo "==> Running migrations..."
    php artisan migrate --force --no-interaction
fi

if [ "${AUTO_SEED:-false}" = "true" ]; then
    echo "==> Seeding database..."
    php artisan db:seed --force --no-interaction
fi

echo "==> Starting supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
