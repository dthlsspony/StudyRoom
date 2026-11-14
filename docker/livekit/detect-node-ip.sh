#!/usr/bin/env bash
# Печатает IP этой машины в локальной сети.
#
# Его нужно указать в .env как LIVEKIT_NODE_IP: LiveKit объявляет этот адрес
# в ICE-кандидатах, иначе сервер отдаёт IP контейнера, до которого браузер
# не может достучаться.
#
# Использование:
#   bash docker/livekit/detect-node-ip.sh
set -u

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        ipconfig | grep -i "IPv4" | grep -v "127.0.0.1" | awk '{print $NF}' | tr -d '\r' | head -1
        ;;
    Darwin)
        ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null
        ;;
    *)
        ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
        ;;
esac
