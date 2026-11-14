#!/usr/bin/env bash
# Smoke-тест API StudyRoom: авторизация, комнаты, чат, стрим.
set -uo pipefail

# Порты берём из .env, чтобы тест не зависел от домена и настроек хоста.
APP_PORT="${APP_PORT:-$(grep -E '^APP_PORT=' .env 2>/dev/null | head -1 | cut -d= -f2)}"
APP_PORT="${APP_PORT:-8080}"
LIVEKIT_HTTP_PORT="${LIVEKIT_HTTP_PORT:-$(grep -E '^LIVEKIT_HTTP_PORT=' .env 2>/dev/null | head -1 | cut -d= -f2)}"
LIVEKIT_HTTP_PORT="${LIVEKIT_HTTP_PORT:-7880}"
API="${API:-http://localhost:${APP_PORT}/api/v1}"
BASE_URL="${BASE_URL:-http://localhost:${APP_PORT}}"
PASS=0
FAIL=0
SUFFIX="$$-$(date +%s)"
EMAIL_T="teacher-${SUFFIX}@example.com"
EMAIL_S="student-${SUFFIX}@example.com"

jqn() { node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);const v=$1;console.log(v===undefined?'':typeof v==='object'?JSON.stringify(v):v)}catch(e){console.log('')}})"; }

# Ждём, пока контейнер поднимется и прогонит миграции.
echo "==> Ждём готовность API..."
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$API/rooms" || true)
  if [ "$code" = "401" ]; then
    echo "==> API готов."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "==> API не поднялся." >&2
    exit 1
  fi
  sleep 3
done

check() {
  local name="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  OK   $name"
    PASS=$((PASS+1))
  else
    echo "  FAIL $name (expected '$expected', got '$actual')"
    FAIL=$((FAIL+1))
  fi
}

echo "== 1. Регистрация =="
REG=$(curl -s -X POST "$API/auth/register" -H "Content-Type: application/json" \
  -d "{\"name\":\"Teacher\",\"email\":\"${EMAIL_T}\",\"password\":\"secret12345\"}")
TOKEN=$(echo "$REG" | jqn "j.token")
check "token выдан" "$([ -n "$TOKEN" ] && echo yes || echo no)" "yes"
check "пользователь создан" "$(echo "$REG" | jqn "j.user.name")" "Teacher"

echo "== 2. Вход =="
LOGIN=$(curl -s -X POST "$API/auth/login" -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL_T}\",\"password\":\"secret12345\"}")
TOKEN=$(echo "$LOGIN" | jqn "j.token")
check "логин выдаёт токен" "$([ -n "$TOKEN" ] && echo yes || echo no)" "yes"

BAD=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/auth/login" \
  -H "Content-Type: application/json" -d "{\"email\":\"${EMAIL_T}\",\"password\":\"wrong\"}")
check "неверный пароль -> 422" "$BAD" "422"

AUTH="Authorization: Bearer $TOKEN"

echo "== 3. Комнаты =="
ROOM=$(curl -s -X POST "$API/rooms" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"name":"Math 101","description":"Linear algebra"}')
ROOM_ID=$(echo "$ROOM" | jqn "j.data.id")
check "комната создана" "$(echo "$ROOM" | jqn "j.data.name")" "Math 101"
check "владелец назначен" "$(echo "$ROOM" | jqn "j.data.owner.email")" "$EMAIL_T"

LIST=$(curl -s "$API/rooms" -H "$AUTH")
check "комната в списке" "$(echo "$LIST" | jqn "j.data.find(r=>r.name==='Math 101')?'yes':'no'")" "yes"

SEARCH=$(curl -s "$API/rooms?search=Math" -H "$AUTH")
check "поиск находит комнату" "$(echo "$SEARCH" | jqn "j.data.find(r=>r.name==='Math 101')?'yes':'no'")" "yes"

SEARCH2=$(curl -s "$API/rooms?search=Physics" -H "$AUTH")
check "поиск без совпадений" "$(echo "$SEARCH2" | jqn "j.data.length")" "0"

NOAUTH=$(curl -s -o /dev/null -w "%{http_code}" "$API/rooms")
check "без токена -> 401" "$NOAUTH" "401"

echo "== 4. Чат =="
MSG=$(curl -s -X POST "$API/rooms/$ROOM_ID/messages" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"body":"Hello everyone"}')
MSG_ID=$(echo "$MSG" | jqn "j.data.id")
check "сообщение создано" "$(echo "$MSG" | jqn "j.data.body")" "Hello everyone"
check "автор сообщения" "$(echo "$MSG" | jqn "j.data.user.email")" "$EMAIL_T"

HIST=$(curl -s "$API/rooms/$ROOM_ID/messages" -H "$AUTH")
check "история сообщений" "$(echo "$HIST" | jqn "j.data.length")" "1"

echo "== 5. Стриминг (LiveKit) =="
ACCESS=$(curl -s "$API/rooms/$ROOM_ID/stream" -H "$AUTH")
check "эфир не запущен" "$(echo "$ACCESS" | jqn "j.is_live")" "false"

START=$(curl -s -X POST "$API/rooms/$ROOM_ID/stream" -H "$AUTH")
check "эфир запущен" "$(echo "$START" | jqn "j.is_live")" "true"
LK_TOKEN=$(echo "$START" | jqn "j.token")
check "LiveKit-токен выдан" "${LK_TOKEN:0:3}" "eyJ"
check "адрес LiveKit" "$(echo "$START" | jqn "j.ws_url")" "ws://localhost:${LIVEKIT_HTTP_PORT:-7880}"
check "имя комнаты LiveKit" "$(echo "$START" | jqn "j.room_name")" "studyroom-$ROOM_ID"

ACCESS2=$(curl -s "$API/rooms/$ROOM_ID/stream" -H "$AUTH")
check "токен участника выдаётся" "$(echo "$ACCESS2" | jqn "j.is_live")" "true"

ROOM_STATE=$(curl -s "$API/rooms/$ROOM_ID" -H "$AUTH")
check "комната помечена как живая" "$(echo "$ROOM_STATE" | jqn "j.data.is_live")" "true"

echo "== 6. Комнаты LiveKit =="
LK_TOKEN_SVC=$(docker compose exec -T app php artisan tinker --execute \
  "echo \App\Services\LiveKit\LiveKitService::fromConfig()->createServiceToken();" 2>/dev/null | tail -1)
LKROOMS=$(curl -s "http://localhost:${LIVEKIT_HTTP_PORT:-7880}/twirp/livekit.RoomService/ListRooms" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $LK_TOKEN_SVC" -d '{}')
check "комната создана в LiveKit" \
  "$(echo "$LKROOMS" | jqn "j.rooms.find(r=>r.name==='studyroom-$ROOM_ID')?'yes':'no'")" "yes"

echo "== 6b. Ведущий закрыл вкладку =="
ME=$(curl -s "$API/auth/me" -H "$AUTH")
OWNER_ID=$(echo "$ME" | jqn "j.data.id")
LEFT_BODY="{\"event\":\"participant_left\",\"room\":{\"name\":\"studyroom-${ROOM_ID}\"},\"participant\":{\"identity\":\"${OWNER_ID}\"},\"createdAt\":$(date +%s)}"
LEFT_TOKEN=$(docker compose exec -T app php artisan tinker --execute \
  "\$body = '${LEFT_BODY}'; \$claims = ['iss' => config('livekit.api_key'), 'nbf' => time()-5, 'exp' => time()+300, 'sha256' => base64_encode(hash('sha256', \$body, true))]; echo \Firebase\JWT\JWT::encode(\$claims, config('livekit.api_secret'), 'HS256');" 2>/dev/null | tail -1)
LEFT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/livekit/webhook" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $LEFT_TOKEN" -d "$LEFT_BODY")
check "вебхук participant_left принят" "$LEFT_CODE" "200"

ROOM_AFTER_LEFT=$(curl -s "$API/rooms/$ROOM_ID" -H "$AUTH")
check "эфир завершён после ухода ведущего" "$(echo "$ROOM_AFTER_LEFT" | jqn "j.data.is_live")" "false"

LKROOMS2=$(curl -s "http://localhost:${LIVEKIT_HTTP_PORT:-7880}/twirp/livekit.RoomService/ListRooms" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $LK_TOKEN_SVC" -d '{}')
check "комната LiveKit удалена" \
  "$(echo "$LKROOMS2" | jqn "j.rooms.find(r=>r.name==='studyroom-$ROOM_ID')?'yes':'no'")" "no"

# Возобновляем эфир, чтобы проверить его остановку вручную
curl -s -o /dev/null -X POST "$API/rooms/$ROOM_ID/stream" -H "$AUTH"

echo "== 7. Остановка эфира =="
STOP=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$API/rooms/$ROOM_ID/stream" -H "$AUTH")
check "эфир остановлен" "$STOP" "200"
ROOM_STATE2=$(curl -s "$API/rooms/$ROOM_ID" -H "$AUTH")
check "комната больше не живая" "$(echo "$ROOM_STATE2" | jqn "j.data.is_live")" "false"

echo "== 8. Доступ по ролям =="
OTHER=$(curl -s -X POST "$API/auth/register" -H "Content-Type: application/json" \
  -d "{\"name\":\"Student\",\"email\":\"${EMAIL_S}\",\"password\":\"secret12345\"}")
OTHER_TOKEN=$(echo "$OTHER" | jqn "j.token")
STREAM_OTHER=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API/rooms/$ROOM_ID/stream" \
  -H "Authorization: Bearer $OTHER_TOKEN")
check "чужой не может запустить эфир" "$STREAM_OTHER" "403"
DEL_OTHER=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$API/rooms/$ROOM_ID" \
  -H "Authorization: Bearer $OTHER_TOKEN")
check "чужой не может удалить комнату" "$DEL_OTHER" "403"

echo "== 9. Broadcasting (Reverb) =="
BAUTH=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/broadcasting/auth" \
  -H "$AUTH" -H "Content-Type: application/x-www-form-urlencoded" \
  -d "channel_name=rooms.${ROOM_ID}&socket_id=123.456")
check "авторизация приватного канала" "$BAUTH" "200"

BAUTH_NO=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/broadcasting/auth" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "channel_name=rooms.${ROOM_ID}&socket_id=123.456")
check "без токена канал не авторизуется" "$BAUTH_NO" "401"

echo "== 10. Вебхуки LiveKit =="
HOOK_BODY="{\"event\":\"room_started\",\"room\":{\"name\":\"studyroom-${ROOM_ID}\"},\"createdAt\":$(date +%s)}"
HOOK_TOKEN=$(docker compose exec -T app php artisan tinker --execute \
  "\$body = '${HOOK_BODY}'; \$claims = ['iss' => config('livekit.api_key'), 'nbf' => time()-5, 'exp' => time()+300, 'sha256' => base64_encode(hash('sha256', \$body, true))]; echo \Firebase\JWT\JWT::encode(\$claims, config('livekit.api_secret'), 'HS256');" 2>/dev/null | tail -1)

HOOK_OK=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/livekit/webhook" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $HOOK_TOKEN" -d "$HOOK_BODY")
check "подписанный вебхук принят" "$HOOK_OK" "200"

HOOK_BAD=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/livekit/webhook" \
  -H "Content-Type: application/json" -H "Authorization: Bearer bad.token.value" -d "$HOOK_BODY")
check "неподписанный вебхук отклонён" "$HOOK_BAD" "401"

echo
echo "Итог: успешно $PASS, провалено $FAIL"
[ "$FAIL" -eq 0 ]
