#!/bin/sh
set -eu

API_KEY="${LIVEKIT_API_KEY:-devkey}"
API_SECRET="${LIVEKIT_API_SECRET:-devsecret}"
WEBHOOK_URL="${LIVEKIT_WEBHOOK_URL:-http://web/api/v1/livekit/webhook}"
NODE_IP="${LIVEKIT_NODE_IP:-}"
UDP_PORT="${LIVEKIT_UDP_PORT:-7882}"
TCP_PORT="${LIVEKIT_TCP_PORT:-7881}"

if [ -n "$NODE_IP" ]; then
    # node_ip — адрес, который сервер объявляет в ICE-кандидатах. Без него
    # LiveKit отдаёт IP контейнера (172.x), до которого из браузера не достучаться.
    RTC_BLOCK="  udp_port: ${UDP_PORT}
  tcp_port: ${TCP_PORT}
  use_external_ip: false
  node_ip: ${NODE_IP}"
else
    echo "==> ВНИМАНИЕ: LIVEKIT_NODE_IP не задан. Браузер не сможет установить" >&2
    echo "    WebRTC-соединение с контейнера (нужен IP хоста, доступный браузеру)." >&2
    RTC_BLOCK="  udp_port: ${UDP_PORT}
  tcp_port: ${TCP_PORT}
  use_external_ip: true"
fi

cat > /tmp/livekit.yaml <<EOF
port: 7880
log_level: info
rtc:
${RTC_BLOCK}
keys:
  ${API_KEY}: ${API_SECRET}
webhook:
  api_key: ${API_KEY}
  urls:
    - ${WEBHOOK_URL}
EOF

echo "==> Конфигурация LiveKit:"
cat /tmp/livekit.yaml

echo "==> Запуск LiveKit на :7880 (медиа: UDP ${UDP_PORT}, вебхук: ${WEBHOOK_URL})"
exec /livekit-server --config /tmp/livekit.yaml
