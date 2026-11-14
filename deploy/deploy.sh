#!/usr/bin/env bash
#
# Деплой StudyRoom: обновление, проверка и автоматический откат.
#
#   bash deploy/deploy.sh              # обновить, собрать, задеплоить, проверить
#   bash deploy/deploy.sh --skip-pull # без обновления базовых образов
#   bash deploy/deploy.sh --skip-git  # без git pull
#   bash deploy/deploy.sh --full      # полный смоук-тест API (создаёт тестовые данные)
#   bash deploy/deploy.sh --dry-run   # только показать, что будет сделано
#
# Порядок работы:
#   1. префлайт (docker, .env, занятые порты);
#   2. генерация недостающих секретов (пароль БД, ключи LiveKit и Reverb, APP_KEY);
#   3. бэкап: дамп БД + метки текущих образов для отката;
#   4. обновление: git pull (если чистое рабочее дерево) + docker pull + build;
#   5. деплой: docker compose up -d + ожидание готовности;
#   6. проверка: контейнеры, БД, health-endpoint, API, LiveKit, WebSocket чата;
#   7. при любой ошибке — откат на прошлую версию (образы + дамп БД) с выводом причины.
#
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$ROOT/deploy/backups/$TS"
LOG_DIR="$ROOT/deploy/logs"
LOG_FILE="$LOG_DIR/deploy-$TS.log"
ROLLBACK_TAG="rollback-$TS"

SKIP_PULL=0
SKIP_GIT=0
FULL_TEST=0
DRY_RUN=0
SIMULATE_FAILURE=0

for arg in "$@"; do
    case "$arg" in
        --skip-pull) SKIP_PULL=1 ;;
        --skip-git)  SKIP_GIT=1 ;;
        --full)      FULL_TEST=1 ;;
        --dry-run)   DRY_RUN=1 ;;
        --simulate-failure) SIMULATE_FAILURE=1 ;;
        -h|--help)   sed -n '2,23p' "$0"; exit 0 ;;
        *) echo "Неизвестный аргумент: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "$LOG_DIR" "$ROOT/deploy/backups"
exec > >(tee -a "$LOG_FILE") 2>&1

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_info=$'\033[36m'; c_off=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_info" "$*" "$c_off"; }
ok()   { printf '%s  ✓ %s%s\n' "$c_ok" "$*" "$c_off"; }
warn() { printf '%s  ! %s%s\n' "$c_warn" "$*" "$c_off"; }
fail() { printf '%s  ✗ %s%s\n' "$c_err" "$*" "$c_off"; }

LAST_ERROR=""
DEPLOY_STARTED=0
BACKUP_DUMP=""
BACKUP_ENV=""
PREV_IMAGES=()

# ---------------------------------------------------------------------------
# Обработка ошибки: откат + понятное сообщение
# ---------------------------------------------------------------------------
handle_failure() {
    local code="${1:-1}"
    local reason="${2:-неизвестная ошибка}"

    trap - ERR
    LAST_ERROR="$reason"

    fail "Деплой не удался: $reason"

    # .env восстанавливаем всегда: секреты могли смениться до падения
    if [ -n "$BACKUP_ENV" ] && [ -f "$BACKUP_ENV" ]; then
        cp "$BACKUP_ENV" .env
    fi

    if [ "$DEPLOY_STARTED" -eq 1 ]; then
        rollback
    fi

    printf '\n%s══════════════════════════════════════════════════════════════%s\n' "$c_err" "$c_off"
    printf '%s  ДЕПЛОЙ ПРОВАЛЕН — ВЕРСИЯ ОТКАТИЛАСЬ%s\n' "$c_err" "$c_off"
    printf '  Причина: %s\n' "$reason"
    printf '  Лог:     %s\n' "$LOG_FILE"
    [ -n "$BACKUP_DUMP" ] && printf '  Дамп БД: %s\n' "$BACKUP_DUMP"
    printf '%s══════════════════════════════════════════════════════════════%s\n\n' "$c_err" "$c_off"
    exit "$code"
}

trap 'handle_failure 1 "ошибка в строке $LINENO"' ERR

die() { handle_failure 1 "$*"; }

# ---------------------------------------------------------------------------
# Работа с .env
# ---------------------------------------------------------------------------
env_get() {
    local key="$1" default="${2:-}"
    local value
    value="$(grep -E "^${key}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
    [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$default"
}

env_set() {
    local key="$1" value="$2"
    if grep -qE "^${key}=" .env 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}

random_hex() {
    local len="${1:-48}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$((len / 2))"
    else
        LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | dd bs=1 count="$len" 2>/dev/null || true
    fi
}

db_user()  { env_get DB_USERNAME studyroom; }
db_name()  { env_get DB_DATABASE studyroom; }
app_port() { env_get APP_PORT 8080; }
lk_port()  { env_get LIVEKIT_HTTP_PORT 7880; }

# HTTP-код с повторами: сразу после перезапуска контейнеров соединение может
# кратковременно отваливаться (502/503/504), пока поднимается php-fpm.
# Это не повод откатывать деплой — ждём и пробуем ещё раз.
http_code() {
    local url="$1" tries="${2:-12}" code="" i
    for i in $(seq 1 "$tries"); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true)"
        case "$code" in
            ''|000|502|503|504) sleep 3 ;;
            *) printf '%s' "$code"; return 0 ;;
        esac
    done
    printf '%s' "${code:-000}"
}

# WebSocket-апгрейд с повторами
ws_code() {
    local url="$1" tries="${2:-12}" code="" i
    for i in $(seq 1 "$tries"); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
            -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' -H 'Sec-WebSocket-Version: 13' \
            "$url" 2>/dev/null || true)"
        case "$code" in
            ''|000|502|503|504) sleep 3 ;;
            *) printf '%s' "$code"; return 0 ;;
        esac
    done
    printf '%s' "${code:-000}"
}

# ===========================================================================
# 1. Префлайт
# ===========================================================================
preflight() {
    step "Префлайт"

    command -v docker >/dev/null 2>&1 || die "docker не найден в PATH"
    docker compose version >/dev/null 2>&1 || die "не найден плагин docker compose (v2)"

    if [ ! -f .env ]; then
        cp .env.example .env
        ok "создан .env из .env.example"
    fi

    # Копия .env делается до генерации секретов, чтобы их можно было вернуть
    mkdir -p "$BACKUP_DIR"
    BACKUP_ENV="$BACKUP_DIR/.env"
    cp .env "$BACKUP_ENV"
    ok ".env сохранён для отката"

    local missing=()
    for key in APP_PORT DB_DATABASE DB_USERNAME DB_PASSWORD LIVEKIT_API_KEY LIVEKIT_API_SECRET \
               REVERB_APP_ID REVERB_APP_KEY REVERB_APP_SECRET; do
        [ -n "$(env_get "$key")" ] || missing+=("$key")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        warn "не заданы переменные: ${missing[*]} — будут сгенерированы"
    fi

    ok "окружение готово"
}

# ===========================================================================
# 2. Секреты
# ===========================================================================
ensure_secrets() {
    step "Секреты"

    local changed=0

    # Пароль БД: у живого контейнера Postgres пароль задаётся при инициализации
    # тома, поэтому менять его после первого запуска нельзя.
    local container volume_name db_initialized=0
    container="$(docker compose ps -q db 2>/dev/null || true)"
    if [ -n "$container" ]; then
        volume_name="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$container" 2>/dev/null || true)"
        [ -n "$volume_name" ] && db_initialized=1
    fi

    if [ -z "$(env_get DB_PASSWORD)" ]; then
        if [ "$db_initialized" -eq 1 ]; then
            env_set DB_PASSWORD "$(env_get DB_PASSWORD studyroom)"
            warn "БД уже инициализирована, а DB_PASSWORD в .env отсутствует — пароль оставлен как есть"
        else
            env_set DB_PASSWORD "$(random_hex 32)"
            ok "сгенерирован пароль БД"
        fi
        changed=1
    fi

    if [ -z "$(env_get LIVEKIT_API_KEY)" ] || [ "$(env_get LIVEKIT_API_KEY)" = "devkey" ]; then
        env_set LIVEKIT_API_KEY "srk_$(random_hex 16)"
        ok "сгенерирован ключ LiveKit"
        changed=1
    fi
    if [ -z "$(env_get LIVEKIT_API_SECRET)" ] || [ "$(env_get LIVEKIT_API_SECRET)" = "devsecret_change_me_0123456789abcdefghij" ]; then
        env_set LIVEKIT_API_SECRET "$(random_hex 48)"
        ok "сгенерирован секрет LiveKit"
        changed=1
    fi

    if [ -z "$(env_get REVERB_APP_KEY)" ] || [ "$(env_get REVERB_APP_KEY)" = "studyroomappkey" ]; then
        env_set REVERB_APP_KEY "srk_$(random_hex 16)"
        ok "сгенерирован ключ Reverb"
        changed=1
    fi
    if [ -z "$(env_get REVERB_APP_SECRET)" ] || [ "$(env_get REVERB_APP_SECRET)" = "studyroomappsecret" ]; then
        env_set REVERB_APP_SECRET "$(random_hex 48)"
        ok "сгенерирован секрет Reverb"
        changed=1
    fi

    # Ключ Reverb дублируется во фронтенд: он впечатывается в бандл
    if [ "$changed" -eq 1 ]; then
        env_set VITE_REVERB_KEY "$(env_get REVERB_APP_KEY)"
        env_set VITE_REVERB_HOST "$(env_get VITE_REVERB_HOST localhost)"
        env_set VITE_REVERB_PORT "$(env_get VITE_REVERB_PORT 8081)"
        env_set VITE_REVERB_SCHEME "$(env_get VITE_REVERB_SCHEME http)"
    fi

    # APP_KEY должен соответствовать Laravel — генерируем его контейнером
    if [ -z "$(env_get APP_KEY)" ]; then
        if docker compose ps --status running --services 2>/dev/null | grep -qx app; then
            docker compose exec -T app php artisan key:generate --force --no-interaction >/dev/null
            ok "сгенерирован APP_KEY"
        else
            env_set APP_KEY "base64:$(random_hex 48)"
            ok "сгенерирован APP_KEY (контейнер не запущен)"
        fi
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        ok ".env обновлён — фронтенд будет пересобран с новым VITE_REVERB_KEY"
    else
        ok "секреты на месте, менять нечего"
    fi
}

# ===========================================================================
# 3. Бэкап
# ===========================================================================
backup() {
    step "Бэкап"

    mkdir -p "$BACKUP_DIR"

    if docker compose ps --status running --services 2>/dev/null | grep -qx db; then
        if docker compose exec -T db pg_dump -U "$(db_user)" -d "$(db_name)" -Fc > "$BACKUP_DIR/db.dump" 2>/dev/null \
            && [ -s "$BACKUP_DIR/db.dump" ]; then
            BACKUP_DUMP="$BACKUP_DIR/db.dump"
            ok "дамп БД сохранён ($(du -h "$BACKUP_DUMP" | cut -f1))"
        else
            warn "не удалось сделать дамп БД — откат данных будет невозможен"
        fi
    else
        warn "контейнер БД не запущен — дамп не сделан"
    fi

    # Образы: запоминаем имя и ID, чтобы вернуть именно прежнюю сборку.
    local images img img_id marker
    images="$(docker compose config --images 2>/dev/null | sort -u || true)"
    for img in $images; do
        if img_id="$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null)" && [ -n "$img_id" ]; then
            # Метка с безопасным именем: у образа может уже быть свой тег.
            marker="studyroom-rollback/$(echo "$img" | tr '/:' '--'):$TS"
            docker tag "$img_id" "$marker" 2>/dev/null || true
            PREV_IMAGES+=("$img $img_id")
        fi
    done
    if [ "${#PREV_IMAGES[@]}" -gt 0 ]; then
        ok "образы сохранены для отката: $(printf '%s ' ${PREV_IMAGES[@]})"
    else
        warn "нет локальных образов — откат образов невозможен (первый деплой)"
    fi
}

# ===========================================================================
# 4. Обновление и сборка
# ===========================================================================
update() {
    if [ "$SKIP_GIT" -eq 0 ] && [ -d .git ]; then
        step "Обновление кода"
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            warn "в рабочем дереве есть изменения — git pull пропущен"
        else
            git pull --ff-only || warn "git pull не удался (продолжаем с текущей версии)"
        fi
    fi

    if [ "$SKIP_PULL" -eq 0 ]; then
        step "Обновление базовых образов"
        docker compose pull --quiet --ignore-buildable db livekit || warn "pull базовых образов не удался"
    fi

    step "Сборка образов"
    if ! docker compose build --pull app web frontend; then
        # Реестр недоступен или сеть моргнула — собираем на локальном кэше.
        warn "сборка с обновлением базовых образов не удалась, пробуем без него"
        docker compose build app web frontend || die "сборка образов не удалась"
    fi
    ok "образы собраны"
}

# ===========================================================================
# 5. Деплой
# ===========================================================================
deploy() {
    step "Деплой"

    docker compose up -d --remove-orphans
    DEPLOY_STARTED=1
    ok "контейнеры запущены"

    # Ждём готовности БД
    local waited=0
    until docker compose exec -T db pg_isready -U "$(db_user)" -d "$(db_name)" >/dev/null 2>&1; do
        waited=$((waited + 5))
        [ "$waited" -gt 180 ] && die "БД не поднялась за 3 минуты"
        sleep 5
    done
    ok "БД готова"

    # Ждём API: в контейнере идут composer install и миграции
    waited=0
    until curl -fsS --max-time 5 "http://127.0.0.1:$(app_port)/up" >/dev/null 2>&1; do
        waited=$((waited + 5))
        [ "$waited" -gt 300 ] && die "API не отвечает на /up дольше 5 минут"
        sleep 5
    done
    ok "API отвечает"
}

# ===========================================================================
# 6. Проверка
# ===========================================================================
verify() {
    step "Проверка"

    local services svc code
    services="$(docker compose config --services 2>/dev/null || true)"
    for svc in $services; do
        if ! docker compose ps --status running --services 2>/dev/null | grep -qx "$svc"; then
            die "контейнер $svc не запущен"
        fi
    done
    ok "все контейнеры запущены: $(echo $services | tr '\n' ' ')"

    docker compose exec -T db pg_isready -U "$(db_user)" -d "$(db_name)" >/dev/null \
        || die "Postgres не отвечает"

    local tables
    tables="$(docker compose exec -T db psql -U "$(db_user)" -d "$(db_name)" -tAc \
        "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$tables" in
        ''|*[!0-9]*) die "БД недоступна из приложения" ;;
    esac
    ok "БД отвечает (таблиц: $tables)"

    curl -fsS --max-time 10 "http://127.0.0.1:$(app_port)/up" >/dev/null \
        || die "health-endpoint /up не отвечает"
    ok "health-endpoint в порядке"

    code="$(http_code "http://127.0.0.1:$(app_port)/api/v1/rooms")"
    [ "$code" = "401" ] || die "API вернул $code вместо 401"
    ok "API работает (401 без токена)"

    code="$(http_code "http://127.0.0.1:$(lk_port)/")"
    [ "$code" = "200" ] || die "LiveKit вернул $code вместо 200"
    ok "LiveKit отвечает"

    code="$(ws_code "http://127.0.0.1:$(app_port)/app/$(env_get REVERB_APP_KEY)")"
    [ "$code" = "101" ] || die "WebSocket чата не поднялся (код $code)"
    ok "WebSocket чата отвечает (101)"

    if [ "$FULL_TEST" -eq 1 ]; then
        step "Полный смоук-тест API"
        bash docker/smoke-test.sh || die "смоук-тест API не пройден"
        ok "смоук-тест пройден"
    fi

    # Проверка самого механизма отката: гасим проверку и ждём откат.
    if [ "$SIMULATE_FAILURE" -eq 1 ]; then
        step "Имитация сбоя (проверка отката)"
        die "имитация сбоя: --simulate-failure"
    fi

    ok "все проверки пройдены"
}

# ===========================================================================
# 7. Откат
# ===========================================================================
rollback() {
    printf '\n%s==> Откат на предыдущую версию%s\n' "$c_warn" "$c_off"

    if [ -n "$BACKUP_ENV" ] && [ -f "$BACKUP_ENV" ]; then
        cp "$BACKUP_ENV" .env
        ok ".env восстановлен"
    fi

    # Возвращаем прежние образы по сохранённым ID
    local pair img img_id restored=0
    for pair in ${PREV_IMAGES[@]+"${PREV_IMAGES[@]}"}; do
        img="${pair%% *}"
        img_id="${pair##* }"
        [ -n "$img" ] && [ -n "$img_id" ] || continue
        if docker tag "$img_id" "$img" 2>/dev/null; then
            restored=1
        fi
    done
    if [ "$restored" -eq 1 ]; then
        ok "образы возвращены к предыдущей версии"
    else
        warn "образы вернуть не удалось"
    fi

    docker compose up -d --no-build --force-recreate --remove-orphans \
        || warn "не удалось пересоздать контейнеры на старых образах"
    ok "контейнеры пересозданы на предыдущей версии"

    if [ -n "$BACKUP_DUMP" ] && [ -s "$BACKUP_DUMP" ]; then
        if docker compose exec -T db pg_restore -U "$(db_user)" -d "$(db_name)" --clean --if-exists \
            < "$BACKUP_DUMP" >/dev/null 2>&1; then
            ok "база восстановлена из дампа"
        else
            warn "не удалось восстановить базу из дампа ($BACKUP_DUMP)"
        fi
    fi

    # Убираем метки отката
    for pair in ${PREV_IMAGES[@]+"${PREV_IMAGES[@]}"}; do
        img="${pair%% *}"
        docker rmi "studyroom-rollback/$(echo "$img" | tr '/:' '--'):$TS" >/dev/null 2>&1 || true
    done

    ok "откат завершён"
}

# ===========================================================================
# Запуск
# ===========================================================================
main() {
    printf '%s╔══════════════════════════════════════════════════════════╗%s\n' "$c_info" "$c_off"
    printf '%s║  StudyRoom — деплой %s║%s\n' "$c_info" "$c_off"
    printf '%s╚══════════════════════════════════════════════════════════╝%s\n' "$c_info" "$c_off"
    printf '  время: %s\n  лог:   %s\n' "$TS" "$LOG_FILE"

    if [ "$DRY_RUN" -eq 1 ]; then
        step "Пробный запуск (ничего не меняем)"
        preflight
        step "Будет сделано"
        echo "  • сгенерированы недостающие секреты в .env"
        echo "  • дамп БД: deploy/backups/$TS/db.dump"
        echo "  • docker compose pull + build + up -d"
        echo "  • проверки: контейнеры, БД, /up, API, LiveKit, WebSocket чата"
        echo "  • при ошибке — откат образов и БД"
        return 0
    fi

    preflight
    ensure_secrets
    backup
    update
    deploy
    verify

    for pair in ${PREV_IMAGES[@]+"${PREV_IMAGES[@]}"}; do
        img="${pair%% *}"
        docker rmi "studyroom-rollback/$(echo "$img" | tr '/:' '--'):$TS" >/dev/null 2>&1 || true
    done

    ls -1dt "$ROOT"/deploy/backups/*/ 2>/dev/null | tail -n +6 | while read -r old; do
        rm -rf "$old"
    done

    printf '\n%s══════════════════════════════════════════════════════════════%s\n' "$c_ok" "$c_off"
    printf '%s  ДЕПЛОЙ УСПЕШЕН%s\n' "$c_ok" "$c_off"
    printf '  Бэкап БД: %s\n' "${BACKUP_DUMP:-не делался}"
    printf '  Лог: %s\n' "$LOG_FILE"
    printf '%s══════════════════════════════════════════════════════════════%s\n\n' "$c_ok" "$c_off"
}

main "$@"
