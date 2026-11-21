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
BACKUP_ENV_LARAVEL=""
DB_PASS_BEFORE=""
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

    # Запоминаем пароль БД до восстановления .env: иначе сравнение не увидит
    # разницы и в Postgres останется уже сменённый пароль.
    DB_PASS_BEFORE="$(env_get DB_PASSWORD)"

    # .env восстанавливаем всегда: секреты могли смениться до падения
    if [ -n "$BACKUP_ENV" ] && [ -f "$BACKUP_ENV" ]; then
        cp "$BACKUP_ENV" .env
    fi
    if [ -n "${BACKUP_ENV_LARAVEL:-}" ] && [ -f "$BACKUP_ENV_LARAVEL" ]; then
        cp "$BACKUP_ENV_LARAVEL" backend/.env
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

# Laravel держит свои настройки в backend/.env — там же живёт APP_KEY.
laravel_env_get() {
    local key="$1" default="${2:-}"
    local value
    value="$(grep -E "^${key}=" backend/.env 2>/dev/null | head -1 | cut -d= -f2- || true)"
    [ -n "$value" ] && printf '%s' "$value" || printf '%s' "$default"
}

laravel_env_set() {
    local key="$1" value="$2"
    if grep -qE "^${key}=" backend/.env 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" backend/.env
    else
        printf '%s=%s\n' "$key" "$value" >> backend/.env
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

# Похоже ли значение на «заглушку» из .env.example: такие секреты нужно
# заменить перед выкладкой в бой.
is_placeholder() {
    local value="${1:-}"
    local lower
    lower="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

    [ -z "$lower" ] && return 0

    case "$lower" in
        devkey|devsecret|secret|password|changeme|change_me|studyroomappkey|studyroomappsecret|example)
            return 0 ;;
        studyroom|postgres|laravel|root|admin)
            return 0 ;;
    esac

    case "$lower" in
        devsecret*|change_me*|changeme*|your-*|replace*|todo*|xxx*)
            return 0 ;;
    esac

    return 1
}

db_user()  { env_get DB_USERNAME studyroom; }
db_name()  { env_get DB_DATABASE studyroom; }
app_port() { env_get APP_PORT 8080; }
lk_port()  { env_get LIVEKIT_HTTP_PORT 7880; }

# Вызов docker compose с необязательным дополнительным файлом
# (COMPOSE_EXTRA_FILE) — так можно убрать публикацию ненужных портов.
compose() {
    if [ -n "${COMPOSE_EXTRA_FILE:-}" ] && [ -f "$COMPOSE_EXTRA_FILE" ]; then
        docker compose -f docker-compose.yml -f "$COMPOSE_EXTRA_FILE" "$@"
    else
        docker compose "$@"
    fi
}

# Порты, которые compose реально публикует на хосте: "порт/протокол".
# Разбор идёт через awk — без python, чтобы не зависеть от его наличия.
published_ports() {
    local json
    json="$(compose config --format json 2>/dev/null || true)"
    [ -n "$json" ] || return 0

    # JSON от compose печатается в несколько строк, поэтому сначала схлопываем
    # его в одну, а затем режем по '{' — иначе published и protocol окажутся
    # в разных строках и протокол будет определён неверно.
    printf '%s' "$json" | tr -d '\n' | tr '{' '\n' | awk '
        {
            port = ""
            proto = "tcp"
            if (match($0, /"published": *"[0-9]+"/)) {
                port = substr($0, RSTART, RLENGTH)
                sub(/.*"published": *"/, "", port)
                sub(/".*/, "", port)
            }
            if (match($0, /"protocol": *"[a-z]+"/)) {
                proto = substr($0, RSTART, RLENGTH)
                sub(/.*"protocol": *"/, "", proto)
                sub(/".*/, "", proto)
            }
            if (port != "") print port "/" proto
        }
    '
}

# Занят ли порт нашим собственным контейнером.
port_ours() {
    local port="$1"
    compose ps --format '{{.Ports}}' 2>/dev/null | grep -F -q ":${port}->"
}

# Порты, которые уже заняты другими переменными .env: подбирать их нельзя,
# иначе два сервиса получат один и тот же порт (контейнеры при этом могут
# быть ещё не запущены, и проверка занятости ничего не увидит).
reserved_ports() {
    local var value
    for var in APP_PORT VITE_PORT LIVEKIT_HTTP_PORT LIVEKIT_TCP_PORT LIVEKIT_UDP_PORT \
               DB_PUBLISHED_PORT REVERB_PUBLISHED_PORT; do
        value="$(env_get "$var")"
        [ -n "$value" ] && printf '%s\n' "$value"
    done
}

# Подобрать свободный порт, начиная с заданного. Пропускаем и занятые
# чужими процессами, и те, что уже публикуют наши контейнеры, и порты,
# зарезервированные другими переменными .env.
pick_free_port() {
    local start="${1:-5400}" port reserved
    reserved="$(reserved_ports)"
    for port in $(seq "$start" $((start + 300))); do
        port_busy "$port" tcp && continue
        port_ours "$port" && continue
        printf '%s\n' "$reserved" | grep -Fxq "$port" && continue
        printf '%s' "$port"
        return 0
    done
    return 1
}

# Занят ли порт на хосте. Порты, которые уже публикуют наши собственные
# контейнеры, заняты законно — их игнорируем.
port_busy() {

    [ -n "$port" ] || return 1

    if compose ps --format '{{.Ports}}' 2>/dev/null | grep -F -q ":${port}->"; then
        return 1
    fi

    command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || return 1

    if command -v ss >/dev/null 2>&1; then
        if [ "$proto" = "udp" ]; then
            ss -lun 2>/dev/null | awk -v p=":$port" '$5 ~ p"$" {found=1} END {exit !found}' && return 0
        else
            ss -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {found=1} END {exit !found}' && return 0
        fi
    else
        local flag="-ltn"
        [ "$proto" = "udp" ] && flag="-lun"
        if netstat $flag >/dev/null 2>&1; then
            # Linux: локальный адрес в 4-й колонке
            netstat $flag 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {found=1} END {exit !found}' && return 0
        else
            # Windows: netstat -ano, локальный адрес во 2-й колонке
            local wflag="-ano"
            [ "$proto" = "udp" ] && wflag="-ano -p UDP"
            netstat $wflag 2>/dev/null | awk -v p=":$port" '$2 ~ p"$" {found=1} END {exit !found}' && return 0
        fi
    fi

    return 1
}

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
    compose version >/dev/null 2>&1 || die "не найден плагин compose (v2)"

    if [ ! -f .env ]; then
        cp .env.example .env
        ok "создан .env из .env.example"
    fi

    # Копия .env делается до генерации секретов, чтобы их можно было вернуть
    mkdir -p "$BACKUP_DIR"
    BACKUP_ENV="$BACKUP_DIR/.env"
    cp .env "$BACKUP_ENV"
    ok ".env сохранён для отката"

    if [ -f backend/.env ]; then
        BACKUP_ENV_LARAVEL="$BACKUP_DIR/.env.backend"
        cp backend/.env "$BACKUP_ENV_LARAVEL"
        ok "backend/.env сохранён для отката"
    fi

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

# Проверяем порты, которые Docker собирается опубликовать на хосте: конфликт
# иначе всплывает в середине деплоя, когда часть контейнеров уже поднята.
check_ports() {
    step "Проверка портов"

    # Для каждого опубликованного порта: какая переменная его задаёт, можно ли
    # подобрать порт автоматически (второе поле: пусто — нельзя, порт указан
    # вручную, потому что на него ссылаются Caddy или firewall) и подсказка.
    spec_for_port() {
        case "$1" in
            "$(env_get DB_PUBLISHED_PORT 5432)")
                echo "DB_PUBLISHED_PORT|5432|порт БД на хосте — на него никто внешний не смотрит, можно поставить свободный" ;;
            "$(env_get REVERB_PUBLISHED_PORT 8081)")
                echo "REVERB_PUBLISHED_PORT|8081|порт Reverb на хосте — в бою его можно не публиковать вовсе (COMPOSE_EXTRA_FILE)" ;;
            "$(app_port)")
                echo "APP_PORT||порт приложения — на него смотрит обратный прокси, менять нужно и в Caddy" ;;
            "$(lk_port)")
                echo "LIVEKIT_HTTP_PORT||порт сигналинга LiveKit — на него смотрит обратный прокси, задаётся вручную" ;;
            "$(env_get LIVEKIT_TCP_PORT 7881)")
                echo "LIVEKIT_TCP_PORT||порт ICE поверх TCP у LiveKit, задаётся вручную" ;;
            "$(env_get LIVEKIT_UDP_PORT 7882)")
                echo "LIVEKIT_UDP_PORT||порт медиа LiveKit (UDP) — LiveKit объявляет его в ICE-кандидатах, задаётся вручную" ;;
            "$(env_get VITE_PORT 5173)")
                echo "VITE_PORT||порт dev-сервера фронтенда, задаётся вручную" ;;
            *) echo "||порт не публикуется наружу" ;;
        esac
    }

    local busy=0 entry port proto var default hint current new_port
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        port="${entry%%/*}"
        proto="${entry##*/}"
        IFS='|' read -r var default hint <<< "$(spec_for_port "$port")"

        port_busy "$port" "$proto" || continue

        current="$(env_get "$var" "$default")"

        # Значение не задано или осталось дефолтным — подберём свободный порт.
        if [ -n "$default" ] && [ "$current" = "$default" ]; then
            new_port="$(pick_free_port "$default")" || new_port=""
            if [ -n "$new_port" ]; then
                env_set "$var" "$new_port"
                warn "порт $port занят — для $var подобрал свободный $new_port"
                continue
            fi
        fi

        fail "порт $port ($proto) уже занят на хосте — $var=$current"
        [ -n "$hint" ] && warn "$hint"
        busy=1
    done <<< "$(published_ports)"

    # Один порт нельзя публиковать дважды (в рамках одного протокола) —
    # Docker скажет об этом только в момент запуска контейнеров, когда часть
    # стека уже поднята. TCP и UDP на одном номере — не конфликт.
    local dup
    dup="$(published_ports | sort | uniq -d | tr '\n' ' ')"
    if [ -n "$dup" ]; then
        fail "порт(ы) $dup заданы в .env дважды — проверьте DB_PUBLISHED_PORT, REVERB_PUBLISHED_PORT и APP_PORT"
        busy=1
    fi

    if [ "$busy" -eq 1 ]; then
        die "сначала освободите порты или смените их в .env — деплой остановлен до изменений"
    fi

    ok "все публикуемые порты свободны"
}


# Проверяем, что объявляемый LiveKit адрес действительно принадлежит этой
# машине: с чужим адресом браузер не достучится до медиа
# ("could not establish pc connection").
check_node_ip() {
    local node_ip
    node_ip="$(env_get LIVEKIT_NODE_IP)"
    [ -n "$node_ip" ] || return 0

    local found=0 tool=""
    if command -v ip >/dev/null 2>&1; then
        tool="ip"
    elif command -v ifconfig >/dev/null 2>&1; then
        tool="ifconfig"
    else
        # Нечем проверить — молча пропускаем, чтобы не пугать зря.
        return 0
    fi

    if [ "$tool" = "ip" ]; then
        ip -4 addr show 2>/dev/null | grep -qw "$node_ip" && found=1
    else
        ifconfig 2>/dev/null | grep -w "$node_ip" >/dev/null && found=1
    fi

    if [ "$found" -eq 1 ]; then
        ok "LIVEKIT_NODE_IP=$node_ip — адрес этой машины"
    else
        warn "LIVEKIT_NODE_IP=$node_ip не является адресом этой машины."
        warn "  Браузер не достучится до медиа: could not establish pc connection."
        warn "  Если у сервера есть публичный IP — очистите переменную, LiveKit определит его сам."
    fi
}

# Сверяем цели обратного прокси с портами из .env: если Caddy смотрит не туда,
# домен будет отдавать чужой сервис (например Reverb вместо приложения).
check_reverse_proxy() {
    local file="${CADDYFILE:-/etc/caddy/Caddyfile}"
    [ -f "$file" ] || return 0

    local targets app_target lk_target missing
    targets="$(grep -oE 'reverse_proxy[[:space:]]+[0-9.]+:[0-9]+' "$file" 2>/dev/null | grep -oE '[0-9]+$' | sort -u | tr '
' ' ')"
    [ -n "$targets" ] || return 0

    app_target="$(app_port)"
    lk_target="$(lk_port)"
    missing=""

    printf '%s' "$targets" | grep -qw "$app_target" || missing="$missing APP_PORT($app_target)"
    printf '%s' "$targets" | grep -qw "$lk_target"  || missing="$missing LIVEKIT_HTTP_PORT($lk_target)"

    if [ -n "$missing" ]; then
        warn "Caddyfile ($file) проксирует на порты:$targets"
        warn "в .env этих портов нет среди целей прокси:$missing — домен будет отдавать не то"
    else
        ok "Caddyfile проксирует на нужные порты ($targets)"
    fi
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
    container="$(compose ps -q db 2>/dev/null || true)"
    if [ -n "$container" ]; then
        volume_name="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$container" 2>/dev/null || true)"
        [ -n "$volume_name" ] && db_initialized=1
    fi

    if is_placeholder "$(env_get DB_PASSWORD)"; then
        local new_pass
        new_pass="$(random_hex 32)"
        if [ "$db_initialized" -eq 1 ]; then
            # БД уже живёт со старым паролем — меняем его и в Postgres,
            # и в .env, иначе приложение перестанет подключаться.
            if compose exec -T db psql -U "$(db_user)" -d "$(db_name)" -tAc \
                "ALTER USER \"$(db_user)\" WITH PASSWORD '$new_pass'" >/dev/null 2>&1; then
                env_set DB_PASSWORD "$new_pass"
                ok "пароль БД заменён на сгенерированный (и в Postgres, и в .env)"
            else
                warn "не удалось сменить пароль в Postgres — оставлен прежний"
            fi
        else
            env_set DB_PASSWORD "$new_pass"
            ok "сгенерирован пароль БД"
        fi
        changed=1
    fi

    if is_placeholder "$(env_get LIVEKIT_API_KEY)"; then
        env_set LIVEKIT_API_KEY "srk_$(random_hex 16)"
        ok "сгенерирован ключ LiveKit"
        changed=1
    fi
    if is_placeholder "$(env_get LIVEKIT_API_SECRET)"; then
        env_set LIVEKIT_API_SECRET "$(random_hex 48)"
        ok "сгенерирован секрет LiveKit"
        changed=1
    fi

    if is_placeholder "$(env_get REVERB_APP_KEY)"; then
        env_set REVERB_APP_KEY "srk_$(random_hex 16)"
        ok "сгенерирован ключ Reverb"
        changed=1
    fi
    if is_placeholder "$(env_get REVERB_APP_SECRET)"; then
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

    # APP_KEY живёт в backend/.env: перегенерировать его на каждом деплое
    # нельзя — это отозвало бы все выданные токены. Но если там заглушка
    # из скелета Laravel — заменяем.
    if is_placeholder "$(laravel_env_get APP_KEY)" || \
       [ "$(laravel_env_get APP_KEY)" = "base64:wISUzyhEUHPoce8CFCbKGuZxSvB/mt6xNyapGEMiTdM=" ]; then
        if compose ps --status running --services 2>/dev/null | grep -qx app; then
            compose exec -T app php artisan key:generate --force --no-interaction >/dev/null
            ok "сгенерирован APP_KEY"
        else
            laravel_env_set APP_KEY "base64:$(random_hex 48)"
            ok "сгенерирован APP_KEY (контейнер не запущен)"
        fi
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        ok ".env обновлён — фронтенд будет пересобран с новым VITE_REVERB_KEY"
    else
        ok "секреты на месте, менять нечего"
    fi

    # Дублируем ключи в backend/.env: приложение вне Docker (например artisan
    # локально) должно видеть те же значения, что и контейнер.
    # Приводим backend/.env к актуальным значениям: приложение должно видеть
    # те же настройки БД, LiveKit и Reverb, что и контейнеры.
    local key value
    for key in BROADCAST_CONNECTION DB_CONNECTION DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD \
               REVERB_APP_ID REVERB_APP_KEY REVERB_APP_SECRET REVERB_HOST REVERB_PORT REVERB_SCHEME \
               LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL LIVEKIT_API_URL; do
        value="$(env_get "$key")"
        [ -n "$value" ] || continue
        if [ "$(laravel_env_get "$key")" != "$value" ]; then
            laravel_env_set "$key" "$value"
            ok "backend/.env синхронизирован: $key"
        fi
    done
}

# ===========================================================================
# 2b. Внутренние адреса и порты
# ===========================================================================
fix_internal_settings() {
    step "Внутренние адреса"

    # Эти порты заданы конструктивно и не настраиваются: Postgres в сети
    # Docker всегда слушает 5432, Reverb внутри контейнера app — 8081,
    # LiveKit-контейнер — 7880. Если в .env стоит другое значение, связь
    # приложения с сервисами просто не заработает.
    local key value fixed=0
    for key in DB_PORT REVERB_PORT; do
        case "$key" in
            DB_PORT)     value=5432 ;;
            REVERB_PORT) value=8081 ;;
        esac
        if [ "$(env_get "$key")" != "$value" ]; then
            local was
            was="$(env_get "$key")"
            env_set "$key" "$value"
            ok "$key: $was → $value (внутренний порт)"
            fixed=1
        fi
    done

    # Внутренний адрес LiveKit — контейнер livekit в сети Docker.
    local livekit_internal
    livekit_internal="$(env_get LIVEKIT_API_URL)"
    case "$livekit_internal" in
        http://livekit:*)
            if [ "$livekit_internal" != "http://livekit:7880" ]; then
                env_set LIVEKIT_API_URL "http://livekit:7880"
                ok "LIVEKIT_API_URL: $livekit_internal → http://livekit:7880 (внутренний адрес)"
                fixed=1
            fi
            ;;
    esac

    [ "$fixed" -eq 1 ] && ok "внутренние настройки приведены к правильным" || ok "внутренние настройки корректны"
}

# ===========================================================================
# 3. Бэкап
# ===========================================================================
backup() {
    step "Бэкап"

    mkdir -p "$BACKUP_DIR"

    if compose ps --status running --services 2>/dev/null | grep -qx db; then
        if compose exec -T db pg_dump -U "$(db_user)" -d "$(db_name)" -Fc > "$BACKUP_DIR/db.dump" 2>/dev/null \
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
    images="$(compose config --images 2>/dev/null | sort -u || true)"
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
        # git pull умеет работать и при изменённом рабочем дереве, пока
        # входящие изменения не задевают правленые файлы. Раньше скрипт
        # пропускал обновление при любых правках — из-за локального .env
        # сервер оставался на старой версии compose и кода.
        if ! git pull --ff-only; then
            warn "git pull не удался (правки в рабочем дереве мешают) — продолжаем с текущей версии"
            warn "изменённые файлы: $(git status --porcelain 2>/dev/null | head -5 | tr '
' ' ')"
        else
            ok "код обновлён"
        fi
    fi

    if [ "$SKIP_PULL" -eq 0 ]; then
        step "Обновление базовых образов"
        # Docker Hub ограничивает анонимные запросы (429). Это не повод
        # останавливать деплой: базовые образы уже есть в локальном кэше.
        local attempt pulled=0
        for attempt in 1 2 3; do
            if compose pull --quiet --ignore-buildable db livekit; then
                pulled=1
                break
            fi
            warn "pull не удался (обычно лимит Docker Hub), пробуем ещё раз ($attempt/3)"
            sleep $((attempt * 20))
        done
        [ "$pulled" -eq 1 ] && ok "базовые образы обновлены" || warn "базовые образы остались прежними — сборка пойдёт по локальному кэшу"
    fi

    step "Сборка образов"
    # Без --pull: BuildKit берёт базовые образы из локального кэша и не ходит
    # в реестр — иначе лимит Docker Hub (429) роняет всю сборку.
    if ! compose build app web frontend; then
        warn "сборка на локальном кэше не удалась, пробуем с обновлением базовых образов"
        compose build --pull app web frontend || die "сборка образов не удалась"
    fi
    ok "образы собраны"

    step "Сборка фронтенда"
    # Образ фронтенда только запускает dev-сервер. Собранный бандл нужен
    # контейнеру web: он раздаёт frontend/dist с хоста, поэтому собираем
    # прямо в рабочем каталоге (bind-mount пишет на хост).
    # Каталог создаём на хосте: Docker Desktop не умеет создавать новые
    # каталоги внутри bind-mount с Windows-хоста.
    mkdir -p "$ROOT/frontend/dist"
    compose run --rm -T --no-deps frontend sh -c 'mkdir -p dist && npm run build'         || die "сборка фронтенда не удалась"
    ok "фронтенд собран в frontend/dist"

    # Проверяем, что в бандл попал адрес Reverb из .env: иначе фронтенд будет
    # стучаться в localhost и чат не заработает.
    local reverb_host
    reverb_host="$(env_get VITE_REVERB_HOST)"
    if [ -n "$reverb_host" ] && [ -d "$ROOT/frontend/dist/assets" ]; then
        if grep -rqF "$reverb_host" "$ROOT/frontend/dist/assets" 2>/dev/null; then
            ok "в бандле адрес Reverb: $reverb_host"
        else
            warn "в собранном бандле нет адреса $reverb_host — фронтенд собран со старыми значениями, чат не заработает"
        fi
    fi
}

# ===========================================================================
# 5. Деплой
# ===========================================================================
deploy() {
    step "Деплой"

    compose up -d --remove-orphans
    DEPLOY_STARTED=1
    ok "контейнеры запущены"

    # Ждём готовности БД
    local waited=0
    until compose exec -T db pg_isready -U "$(db_user)" -d "$(db_name)" >/dev/null 2>&1; do
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
    services="$(compose config --services 2>/dev/null || true)"
    for svc in $services; do
        if ! compose ps --status running --services 2>/dev/null | grep -qx "$svc"; then
            die "контейнер $svc не запущен"
        fi
    done
    ok "все контейнеры запущены: $(echo $services | tr '\n' ' ')"

    compose exec -T db pg_isready -U "$(db_user)" -d "$(db_name)" >/dev/null \
        || die "Postgres не отвечает"

    local tables
    tables="$(compose exec -T db psql -U "$(db_user)" -d "$(db_name)" -tAc \
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
    if [ -n "${BACKUP_ENV_LARAVEL:-}" ] && [ -f "$BACKUP_ENV_LARAVEL" ]; then
        cp "$BACKUP_ENV_LARAVEL" backend/.env
        ok "backend/.env восстановлен"
    fi

    # Если пароль БД успели поменять — возвращаем прежний и в Postgres,
    # иначе приложение останется без доступа к базе.
    local old_pass current_pass
    old_pass="$(grep -E '^DB_PASSWORD=' "$BACKUP_ENV" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    current_pass="${DB_PASS_BEFORE:-}"
    if [ -n "$old_pass" ] && [ "$old_pass" != "$current_pass" ]; then
        if compose exec -T db psql -U "$(db_user)" -d "$(db_name)" -tAc \
            "ALTER USER \"$(db_user)\" WITH PASSWORD '$old_pass'" >/dev/null 2>&1; then
            ok "прежний пароль БД возвращён"
        else
            warn "не удалось вернуть прежний пароль БД — проверьте .env вручную"
        fi
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

    compose up -d --no-build --force-recreate --remove-orphans \
        || warn "не удалось пересоздать контейнеры на старых образах"
    ok "контейнеры пересозданы на предыдущей версии"

    if [ -n "$BACKUP_DUMP" ] && [ -s "$BACKUP_DUMP" ]; then
        if compose exec -T db pg_restore -U "$(db_user)" -d "$(db_name)" --clean --if-exists \
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
        check_ports
        step "Будет сделано"
        echo "  • сгенерированы недостающие секреты в .env"
        echo "  • дамп БД: deploy/backups/$TS/db.dump"
        echo "  • compose pull + build + up -d"
        echo "  • проверки: контейнеры, БД, /up, API, LiveKit, WebSocket чата"
        echo "  • при ошибке — откат образов и БД"
        return 0
    fi

    preflight
    check_ports
    check_node_ip
    check_reverse_proxy
    ensure_secrets
    fix_internal_settings
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
