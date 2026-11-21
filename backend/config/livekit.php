<?php

return [

    /*
    |--------------------------------------------------------------------------
    | LiveKit
    |--------------------------------------------------------------------------
    |
    | `url` — адрес, который отдаётся клиенту (браузер подключается к нему).
    | `api_url` — адрес LiveKit-сервера во внутренней сети Docker (backend).
    |
    */

    'url' => env('LIVEKIT_URL', 'ws://localhost:7880'),

    'api_url' => env('LIVEKIT_API_URL', 'http://livekit:7880'),

    'api_key' => env('LIVEKIT_API_KEY'),

    'api_secret' => env('LIVEKIT_API_SECRET'),

    'token_ttl' => (int) env('LIVEKIT_TOKEN_TTL', 3600),

    /*
     | Источники, которые участник может публиковать. canPublishSources
     | задаёт белый список и заменяет canPublish. Значения — имена элементов
     | protobuf-enum TrackSource (CAMERA, MICROPHONE, SCREEN_SHARE, ...).
     */
    'publish_sources' => ['CAMERA', 'MICROPHONE', 'SCREEN_SHARE', 'SCREEN_SHARE_AUDIO'],

    'room_prefix' => env('LIVEKIT_ROOM_PREFIX', 'studyroom-'),

    'empty_timeout' => (int) env('LIVEKIT_EMPTY_TIMEOUT', 300),

    'departure_timeout' => (int) env('LIVEKIT_DEPARTURE_TIMEOUT', 300),

    'max_participants' => (int) env('LIVEKIT_MAX_PARTICIPANTS', 20),

];
