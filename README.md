# StudyRoom — база веб-приложения

Учебные комнаты с чатом и видеоэфиром. Backend — только API (авторизация, комнаты, чат, создание стриминга), frontend — React SPA, стриминг — LiveKit.

| Слой | Технологии |
|---|---|
| Backend | Laravel 13 (PHP 8.4), Sanctum (Bearer-токены), Reverb (WebSocket), LiveKit Server API |
| Frontend | React 19, TypeScript, Vite 8, react-router 7, livekit-client 2, laravel-echo 2 |
| БД | PostgreSQL 17 |
| Стриминг | LiveKit Server 1.13 (WebRTC) |
| Инфраструктура | Docker Compose: php-fpm + nginx + supervisor, node, postgres, livekit |

Всё запускается и работает только в Docker — на хост не ставится ничего (ни Composer, ни PHP-расширений, ни psql).

---

## Быстрый старт

```bash
cp .env.example .env      # при необходимости поменяйте ключи
docker compose up -d --build
```

Дальше:

| Что | Адрес |
|---|---|
| Приложение (dev, Vite) | http://localhost:5173 |
| Собранный фронтенд (nginx) | http://localhost:8080 |
| API | http://localhost:8080/api/v1 |
| Reverb (WebSocket чата) | ws://localhost:8081 |
| LiveKit | ws://localhost:7880 |
| PostgreSQL | localhost:5432 |

Миграции выполняются автоматически при старте контейнера `app`.

Проверка, что всё живо:

```bash
bash docker/smoke-test.sh      # 29 проверок API: auth, комнаты, чат, LiveKit, вебхуки
```

### Что где крутится

| Сервис | Роль |
|---|---|
| `app` | php-fpm + queue worker + `reverb:start` + `schedule:work` (supervisor) |
| `web` | nginx: проксирует `/api/*` на php-fpm, раздаёт собранный фронтенд |
| `frontend` | Vite dev server с проксированием `/api` на `web` |
| `db` | PostgreSQL 17 |
| `livekit` | LiveKit Server; вебхуки уходят на `http://web/api/v1/livekit/webhook` |

### Частые команды

```bash
docker compose logs -f app          # логи backend (Laravel пишет в stderr)
docker compose exec app php artisan migrate
docker compose exec app php artisan db:seed
docker compose exec frontend npm run build     # сборка фронтенда в frontend/dist
docker compose down -v               # полный сброс вместе с данными
```

---

## Структура

```
.
├── docker-compose.yml
├── .env / .env.example              # общие переменные окружения (compose)
├── docker/
│   ├── php/{Dockerfile,entrypoint.sh,php.ini,supervisord.conf}
│   ├── nginx/{Dockerfile,default.conf}
│   ├── node/Dockerfile
│   ├── livekit/entrypoint.sh        # рендерит livekit.yaml из переменных окружения
│   └── smoke-test.sh
├── backend/                         # Laravel 13, API-only
│   ├── app/Http/Controllers/Api/V1/ # Auth, Room, Message, Stream, LiveKitWebhook
│   ├── app/Services/LiveKit/        # выдача JWT-токенов, Twirp-клиент RoomService
│   ├── app/Events/                  # MessageCreated, ParticipantPresence
│   ├── app/Http/Middleware/ForceJsonResponse.php
│   ├── routes/{api.php,channels.php}
│   ├── config/livekit.php
│   └── database/migrations/         # rooms, room_user, messages, streams
└── frontend/                        # React + TS + Vite
    └── src/
        ├── lib/{api.ts,echo.ts}
        ├── context/AuthContext.tsx
        ├── pages/{LoginPage,RegisterPage,RoomsPage,RoomPage}.tsx
        └── components/{ChatPanel,VideoStage}.tsx
```

---

## API

Базовый префикс — `/api/v1`. Все защищённые маршруты требуют заголовок
`Authorization: Bearer <token>` (personal access token Sanctum). Ошибки — JSON,
ответы обёрнуты в `data` (стандартная обёртка Laravel Resource).

### Авторизация

| Метод | Путь | Описание |
|---|---|---|
| POST | `/auth/register` | `{name, email, password}` → `{token, user}` |
| POST | `/auth/login` | `{email, password}` → `{token, user}` |
| POST | `/auth/logout` | отзывает текущий токен |
| GET | `/auth/me` | текущий пользователь |

### Комнаты

| Метод | Путь | Описание |
|---|---|---|
| GET | `/rooms?search=` | список комнат (20 на страницу), поиск по имени |
| POST | `/rooms` | `{name, description?, is_private?, capacity?}` |
| GET | `/rooms/{id}` | одна комната |
| PATCH | `/rooms/{id}` | изменить (только владелец) |
| DELETE | `/rooms/{id}` | удалить (только владелец) |
| POST | `/rooms/{id}/join` | вступить |
| POST | `/rooms/{id}/leave` | выйти |

Приватная комната видна только владельцу и участникам.

### Чат

| Метод | Путь | Описание |
|---|---|---|
| GET | `/rooms/{id}/messages` | последние 100 сообщений |
| POST | `/rooms/{id}/messages` | `{body}` → сообщение сохраняется и рассылается в канал `rooms.{id}` |

Живое обновление — Reverb (приватный канал `rooms.{id}`, событие `.message.created`).
Авторизация канала — `/api/broadcasting/auth`, middleware `auth:sanctum`.

### Стриминг (LiveKit)

| Метод | Путь | Описание |
|---|---|---|
| GET | `/rooms/{id}/stream` | токен участника и `ws_url` (если эфир идёт) |
| POST | `/rooms/{id}/stream` | запустить эфир (только владелец): создаёт комнату LiveKit |
| DELETE | `/rooms/{id}/stream` | остановить эфир (только владелец) |
| POST | `/livekit/webhook` | вебхуки LiveKit (подпись, а не токен) |

Ответ `GET/POST /rooms/{id}/stream`:

```json
{
  "token": "eyJhbGciOiJIUzI1NiIs...",
  "ws_url": "ws://localhost:7880",
  "room_name": "studyroom-12",
  "identity": "10",
  "stream_id": 7,
  "is_live": true
}
```

---

## Как устроена интеграция с LiveKit

Официального PHP SDK у LiveKit нет, поэтому backend реализует их же протокол:

**Токен участника** — JWT (HS256, секрет `LIVEKIT_API_SECRET`, не короче 32 символов):

```json
{
  "iss": "<API key>",
  "sub": "<user id>",
  "nbf": 1730000000,
  "exp": 1730003600,
  "jti": "<uuid>",
  "name": "Имя пользователя",
  "video": {
    "room": "studyroom-12",
    "roomJoin": true,
    "canPublish": true,
    "canSubscribe": true,
    "canPublishData": true
  }
}
```

**Управление комнатами** — Twirp RPC: `POST /twirp/livekit.RoomService/{CreateRoom,DeleteRoom,ListRooms}`
с `Authorization: Bearer <service token>` (см. `backend/app/Services/LiveKit/LiveKitService.php`).

**Вебхуки** — LiveKit подписывает тело запроса JWT-токеном: в claims лежит `sha256` =
`base64(sha256(raw body))`. Backend проверяет issuer, срок жизни и контрольную сумму,
иначе отвечает 401 (`LiveKitWebhookController`). Обрабатываются `room_started`,
`room_finished`, `participant_joined`, `participant_left`.

### Когда эфир заканчивается

Эфир завершается в трёх случаях:

- владелец нажал «Остановить эфир»;
- ведущий закрыл вкладку или потерял связь — LiveKit присылает `participant_left`,
  backend сверяет, что ушёл именно тот, кто запустил эфир, закрывает запись в БД,
  удаляет комнату LiveKit и рассылает событие `stream.ended`;
- комната LiveKit опустела (вебхук потерялся) — backend сам закрывает эфир при
  следующем обращении к `GET /rooms/{id}/stream`.

Открытые клиенты узнают об окончании эфира по событию `stream.ended` в приватном
канале `rooms.{id}` и обновляют страницу без перезагрузки. Обнаружение ухода
занимает 15–20 секунд — столько нужно LiveKit, чтобы зафиксировать обрыв связи.

---

## Особенности окружения

- **Хост остаётся чистым.** `composer`, PHP-расширения и psql живут только в контейнерах.
- **`vendor/` и `node_modules/` — в именованных volume'ах**, а не на хосте: так быстрее
  и не засоряется рабочая папка. `composer install` выполняется при старте контейнера.
- **Windows + bind mount:** файловые события внутрь контейнера не доходят, поэтому HMR
  не срабатывает — после правки фронтенда нужен `docker compose restart frontend`.
  Laravel в этом режиме перечитывает файлы сам (opcache `validate_timestamps=1`).
- **Права на `storage/`** решаются в entrypoint (`chown www-data`): каталоги с хоста
  приходят с правами root.
- **API всегда отвечает JSON** — middleware `ForceJsonResponse` подставляет
  `Accept: application/json`, иначе middleware авторизации пытается редиректить
  на несуществующий `route('login')`.
- **Отказ камеры ≠ отказ подключения.** Если браузер не дал доступ к устройствам,
  подключение к LiveKit остаётся, а в сцене появляется предупреждение с кнопками
  «Включить микрофон/камеру» для повторной попытки.
- **Состояние эфира сверяется с LiveKit.** Перед выдачей токена backend проверяет,
  что комната в LiveKit действительно есть; если она закрылась (таймаут пустой
  комнаты или пропущенный вебхук), эфир помечается завершённым, а не «зависшим».

### Видеосвязь и Docker

WebRTC требует, чтобы браузер и сервер LiveKit «достучались» друг до друга по
UDP. В Docker на Windows/Mac это требует двух вещей, иначе соединение падает с
`could not establish pc connection`:

1. **LiveKit объявляет адрес, доступный браузеру.** Контейнер по умолчанию
   отдаёт свой внутренний IP (`172.x`), до которого из браузера не достучаться.
   За это отвечает `LIVEKIT_NODE_IP` — IP вашей машины в локальной сети
   (например `192.168.0.106`). Браузер идёт по нему на опубликованный порт 7882.
   Если сеть сменилась (новый DHCP-адрес) — обновите значение:

   ```bash
   sed -i "s/^LIVEKIT_NODE_IP=.*/LIVEKIT_NODE_IP=$(bash docker/livekit/detect-node-ip.sh)/" .env
   docker compose up -d --force-recreate livekit
   ```

2. **Медиа-порт один и опубликован.** Docker пробрасывает конкретные порты, поэтому
   в конфиге LiveKit задан `udp_port: 7882` (тот же, что в `docker-compose.yml`),
   а диапазон `port_range_start/end` не используется — иначе сервер отдаст
   кандидаты на случайных портах, которые наружу не проброшены.

Отдельная частая причина «не подключается»: Chromium (в т.ч. Яндекс.Браузер)
скрывает локальный IP клиента за mDNS-именем, и сервер в контейнере не может его
разрешить. Настройка `node_ip` снимает эту зависимость — браузер сам инициирует
проверки на адрес сервера.

Для доступа извне (с телефона, из другой сети) понадобится TURN-сервер —
в этом проекте он не настроен.

### Камера и микрофон

- `http://localhost` — **защищённый контекст**, поэтому `getUserMedia` работает
  без HTTPS-сертификата. Если открыть приложение по IP-адресу (например,
  `http://192.168.1.10:8080`), браузер сочтёт страницу небезопасной и заблокирует
  камеру — нужен HTTPS или доступ именно через `localhost`.
- Браузер спрашивает разрешение **один раз на сайт**. Если доступ был запрещён,
  повторного запроса не будет: его надо разрешить вручную (значок камеры в адресной
  строке → «Разрешить») и перезагрузить страницу.
- При старте эфира камеру автоматически включает владелец комнаты; участники
  включают её кнопками «Включить микрофон/камеру» — браузер спросит разрешение при
  первом нажатии.
- Если что-то из этого не сработало, сцена эфира покажет, что именно: браузер не
  даёт доступ на этой странице, доступ заблокирован в настройках или камера просто
  выключена.

### Переменные окружения

Основные (полный список — в `.env.example`):

| Переменная | Назначение |
|---|---|
| `DB_*` | подключение к PostgreSQL |
| `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | ключи LiveKit (секрет ≥ 32 символов) |
| `LIVEKIT_URL` | адрес LiveKit для браузера (`ws://localhost:7880`) |
| `LIVEKIT_API_URL` | адрес LiveKit для backend (`http://livekit:7880`) |
| `LIVEKIT_NODE_IP` | IP этой машины в локальной сети — LiveKit объявляет его в ICE-кандидатах |
| `LIVEKIT_UDP_PORT` | UDP-порт для медиа, должен совпадать с опубликованным портом (7882) |
| `REVERB_*` | параметры Reverb |
| `VITE_REVERB_*` | те же значения для фронтенда (Vite) |

При смене `LIVEKIT_API_SECRET` нужно пересоздать контейнер LiveKit
(`docker compose up -d --force-recreate livekit`), иначе подписи токенов не совпадут.

---

## Что можно добавить дальше

- запись эфиров (Egress) и их просмотр;
- файлы в комнате (загрузка/раздача);
- роли в комнате (модератор/наблюдатель) и расширение `RoomPolicy`;
- запись сообщений в отдельную таблицу истории с пагинацией;
- E2E-тесты API на PHPUnit.
