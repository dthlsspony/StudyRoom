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

## Деплой

Скрипт `deploy/deploy.sh` закрывает весь цикл: генерация недостающих секретов →
бэкап → обновление образов → деплой → проверка → **автоматический откат** при ошибке.

```bash
bash deploy/deploy.sh                # деплой с проверками
bash deploy/deploy.sh --skip-pull    # не обновлять базовые образы (postgres, livekit)
bash deploy/deploy.sh --skip-git     # не делать git pull
bash deploy/deploy.sh --full         # плюс полный смоук-тест API
bash deploy/deploy.sh --dry-run      # показать план, ничего не меняя
bash deploy/deploy.sh --simulate-failure   # проверить, что откат работает
```

Что происходит по шагам:

1. **Префлайт** — наличие docker и docker compose, `.env`, проверка обязательных переменных
   и **свободных портов**: если порт, который Docker собирается опубликовать,
   уже занят на хосте (например, 5432 занят вашим Postgres), скрипт останавливается
   до изменений и прямо называет переменную, которую нужно поменять.
   Порты, занятые нашими же контейнерами, заняты законно и игнорируются.
2. **Секреты** — скрипт находит и заменяет не только пустые значения, но и
   **заглушки**: `devkey`, `devsecret…`, `change_me`, `changeme`, `studyroomappkey`,
   `studyroomappsecret`, `studyroom`, `postgres`, `secret`, `password` и подобные.
   Значит, если в вашем `.env` остались дефолтные значения из `.env.example`,
   они будут заменены автоматически — править `.env` вручную не нужно.
   Уже настоящие секреты не трогаются: скрипт идемпотентен.
   Пароль БД меняется по-настоящему: `ALTER USER` в Postgres **и** в `.env`
   одновременно, иначе приложение перестало бы подключаться.
   Ключ Reverb дублируется в `VITE_REVERB_KEY` — фронтенд пересобирается под него,
   а сами значения LiveKit и Reverb дополнительно синхронизируются в `backend/.env`.
3. **Бэкап** — дамп БД (`pg_dump -Fc`) в `deploy/backups/<метка>/` и сохранение
   текущих образов по ID, чтобы вернуть именно прежнюю сборку.
4. **Обновление** — `git pull --ff-only` (если рабочее дерево чистое),
   `docker compose pull` для postgres и livekit, сборка образов приложения.
   Если реестр недоступен, сборка повторяется на локальном кэше образов.
5. **Деплой** — `docker compose up -d`, ожидание готовности БД и ответа `/up`.
6. **Проверка** — все контейнеры запущены, БД отвечает и видит таблицы,
   `/up` отвечает, API возвращает 401 без токена, LiveKit отвечает,
   WebSocket чата даёт `101 Switching Protocols`. Опционально — полный смоук-тест.
   Кратковременные 502/503 после перезапуска пережидаются повторами.
7. **Откат** — при любой ошибке: `.env` и `backend/.env` возвращаются к состоянию
   до деплоя, образы возвращаются к прежним по ID, контейнеры пересоздаются на них,
   база восстанавливается из дампа, а сменённый пароль БД возвращается в Postgres.
   В вывод попадает причина сбоя и путь к логу.

Дампы хранятся в `deploy/backups/` (последние 5), логи — в `deploy/logs/`.

### Автоматические обновления

Юниты для systemd в `deploy/`:

```bash
sudo cp deploy/studyroom-deploy.service /etc/systemd/system/
sudo cp deploy/studyroom-deploy.timer  /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now studyroom-deploy.timer
```

Таймер запускает деплой каждую ночь в 4:12; если машина была выключена —
догонит при следующем включении (`Persistent=true`). Аналог для cron:

```cron
17 4 * * * cd /opt/studyroom && /usr/bin/bash deploy/deploy.sh --skip-git >> deploy/logs/cron.log 2>&1
```

Уведомление о результате можно прикрутить к journal:

```bash
# уведомление об успехе
SuccessExitStatus=0
OnSuccess=mail -s "StudyRoom: деплой успешен" admin@example.com
# об ошибке — сам скрипт печатает причину в stdout
OnFailure=mail -s "StudyRoom: деплой провален, выполнен откат" admin@example.com
```

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

### Участники и модерация

| Метод | Путь | Описание |
|---|---|---|
| GET | `/rooms/{id}/participants` | участники эфира: имя, статус микрофона и камеры, показ экрана, метка заглушения |
| POST | `/rooms/{id}/participants/{identity}/mute` | ведущий заглушает микрофон участника |
| POST | `/rooms/{id}/participants/{identity}/unmute` | ведущий разрешает микрофон |

Заглушение сделано на стороне LiveKit: в правах участника выставляется
`canPublish = false`, поэтому включить микрофон сам он не сможет, даже если
попробует. Дополнительно ведущий помечает участника в `metadata`
(`{"muted": true}`) — клиент участника по этому событию сам выключает микрофон.
Ответить взаимностью нельзя: эндпоинты модерации доступны только владельцу
комнаты, а ведущего заглушить нельзя вовсе (403).

### Стриминг (LiveKit)

Эфир умеет демонстрацию экрана: ведущий включает показ, и он виден всем
участникам отдельной плиткой. Окно ведущего показывается отдельно от окон
участников — участники собраны в общей сетке под ним.

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

## Развёртывание на домене

Пример: приложение на `study-room.quietroom.name`, LiveKit — на отдельном
поддомене `livekit.quietroom.name`.

Отдельный поддомен для LiveKit обязателен: клиент подключается к
`<host>/rtc/v1` от корня домена, поэтому разделить его с API по путям нельзя.

### Что поменять в `.env`

| Переменная | Значение | Почему |
|---|---|---|
| `APP_ENV` | `production` | режим приложения |
| `APP_DEBUG` | `false` | не показывать детали ошибок наружу |
| `APP_URL` | `https://study-room.quietroom.name` | генерация URL, ссылки в письмах |
| `APP_KEY` | оставить текущий или сгенерировать новый | при смене все токены сгорят |
| `LIVEKIT_URL` | `wss://livekit.quietroom.name` | адрес LiveKit для **браузера** |
| `LIVEKIT_API_URL` | `http://livekit:7880` | адрес LiveKit для **backend** (внутренняя сеть) |
| `LIVEKIT_NODE_IP` | пусто | на сервере с публичным IP LiveKit определит его сам (STUN) |
| `APP_PORT` | `8082` | хостовый порт контейнера `web` — на него смотрит Caddy |
| `DB_PUBLISHED_PORT` | `5433` | хостовый порт БД; **поставьте свободный**, если на сервере уже есть свой Postgres (внутри Docker БД всегда на 5432) |
| `LIVEKIT_HTTP_PORT` | `7882` | хостовый порт сигналинга LiveKit — на него смотрит Caddy |
| `LIVEKIT_UDP_PORT` | `7882` | хостовый порт медиа (UDP) — его LiveKit объявляет в кандидатах |
| `LIVEKIT_TCP_PORT` | `7881` | ICE поверх TCP, запасной транспорт |
| `VITE_REVERB_HOST` | `study-room.quietroom.name` | адрес Reverb для **браузера** |
| `VITE_REVERB_PORT` | `443` | |
| `VITE_REVERB_SCHEME` | `https` | |
| `VITE_REVERB_KEY` | значение `REVERB_APP_KEY` | ключ Reverb |
| `VITE_API_URL` | `` (пусто) | API на том же домене — относительные запросы |

Что **не** меняется:

- `REVERB_HOST` / `REVERB_PORT` / `REVERB_SCHEME` — это как **backend** ходит
  в Reverb: он живёт в контейнере `app` рядом с ним, поэтому остаётся
  `localhost` / `8081` / `http`. Браузер ходит в Reverb через домен — за это
  отвечают `VITE_REVERB_*`.
- `LIVEKIT_API_URL`, `DB_*` — внутренняя сеть Docker, домен там не нужен.
- `CORS_ALLOWED_ORIGINS` в текущем виде ни на что не влияет: переменную не читает
  ни одна конфигурация (`config/cors.php` не создан, а дефолтный из фреймворка
  содержит `allowed_origins => ['*']`). Если фронт и API на одном домене, CORS и не
  нужен; если разнести — опубликуйте `config/cors.php` через
  `php artisan vendor:publish --tag=cors` и задайте origins там.

### Обратный прокси

Готовые конфиги: `deploy/Caddyfile.example` (Caddy) и `deploy/nginx.conf.example` (nginx).
Оба терминируют TLS и передают:

- `study-room.quietroom.name` → контейнер `web` (порт 8080): фронтенд, `/api/*`
  и WebSocket чата `/app/{REVERB_APP_KEY}`;
- `livekit.quietroom.name` → контейнер `livekit` (порт 7880): сигналинг LiveKit.

С Caddy всё почти сводится к двум блокам — сертификаты Let's Encrypt он выпускает
и обновляет сам, WebSocket-апгрейд обрабатывает из коробки:

```caddyfile
study-room.quietroom.name {
    reverse_proxy 127.0.0.1:8082
}

livekit.quietroom.name {
    reverse_proxy 127.0.0.1:7882
}
```

Медиа WebRTC идёт мимо прокси напрямую, поэтому в firewall должен быть открыт
**7882/udp** (`LIVEKIT_UDP_PORT`) — именно этот порт LiveKit объявляет в
ICE-кандидатах, и он же публикуется Docker'ом. Порт 7881/tcp (ICE поверх TCP)
нужен как запасной транспорт.

Приложение за прокси доверие к `X-Forwarded-For` включено в
`bootstrap/app.php` (`trustProxies`), иначе Laravel видел бы IP прокси, а не
клиента. Ограничение частоты запросов — 120 в минуту на пользователя
(для анонимных — на IP).

### Порядок запуска на сервере

```bash
cp .env.example .env
# заполнить .env по таблице выше, сгенерировать APP_KEY:
docker compose run --rm app php artisan key:generate --force
# пересобрать фронтенд: VITE_* попадают в бандл на этапе сборки
docker compose exec frontend npm run build
docker compose up -d --build
```

После смены `VITE_REVERB_*` фронтенд нужно пересобрать заново — эти значения
впечатываются в бандл, а не читаются в рантайме.

### LiveKit за доменом

`LIVEKIT_NODE_IP` на сервере с публичным IP оставляйте пустым: LiveKit сам
определит внешний адрес через STUN и объявит его в ICE-кандидатах. Значение
нужно только если сервер стоит за NAT и наружу пробрасывается один порт — тогда
указывайте IP, доступный браузеру, и публикуйте тот же порт в Docker.

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

### Если что-то не работает

Частые причины, проверенные на боевом развёртывании:

- **Чат не обновляется в реальном времени.** Проверьте `docker compose exec app env | grep BROADCAST` —
  в окружении контейнера должен быть `BROADCAST_CONNECTION=reverb`. Если переменная
  не передана, Laravel берёт дефолт `"null"` — это `NullBroadcaster`, у которого
  `auth()` возвращает пустоту: подписка на приватный канал отдаёт 200 с пустым
  телом, браузер не вступает в канал `rooms.{id}`, и события о сообщениях не
  приходят. Тот же симптом даёт пустой `REVERB_APP_SECRET` в окружении.
- **Браузер подключается к `ws://localhost` вместо домена.** `VITE_REVERB_*`
  впечатываются в бандл при сборке, поэтому после правки `.env` фронтенд нужно
  пересобрать (`./deploy.sh` делает это сам) и убедиться, что домен есть в
  бандле: `grep -c "study-room.quietroom.name" frontend/dist/assets/*.js`.
- **Страница открывается старой или пустой.** `index.html` отдаётся с `no-cache`,
  а файлы в `/assets` — с `immutable` (в имени хэш). После деплоя сделайте
  жёсткую перезагрузку (Ctrl+Shift+R), если вкладка была открыта до него.
- **Видно 404 вместо сайта.** Домен смотрит не туда: сверьте цели в Caddyfile с
  портами из `.env` — приложение на `APP_PORT`, сигналинг LiveKit на
  `LIVEKIT_HTTP_PORT`. Деплой предупредит о расхождении.
- **В наушниках слышно свой микрофон.** Локальный аудиотрек приглушается в
  `VideoStage`; если слышно чужой голос как свой — в комнате открыта та же
  комната в двух вкладках (каждая вкладка — отдельный участник), либо включено
  «Прослушивание микрофона» в Windows.

### Демонстрация экрана и доступ к устройствам

В grant токена LiveKit передаётся `canPublishSources` — белый список
источников: `CAMERA`, `MICROPHONE`, `SCREEN_SHARE`, `SCREEN_SHARE_AUDIO`.
Значения — **имена элементов protobuf-enum** `TrackSource`; в нижнем регистре
сервер токен не принимает и отклоняет подключение.

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
