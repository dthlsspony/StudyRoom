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
     | задаёт белый список и заменяет canPublish. ВАЖНО: значения в нижнем
     | регистре ('camera', 'microphone', 'screen_share', 'screen_share_audio') —
     | LiveKit сравнивает их с sourceToString() трека регистрозависимо, и
     | 'MICROPHONE' верхним регистром молча отклоняет публикацию.
     */
    'publish_sources' => ['camera', 'microphone', 'screen_share', 'screen_share_audio'],

    'room_prefix' => env('LIVEKIT_ROOM_PREFIX', 'studyroom-'),

    'empty_timeout' => (int) env('LIVEKIT_EMPTY_TIMEOUT', 300),

    'departure_timeout' => (int) env('LIVEKIT_DEPARTURE_TIMEOUT', 300),

    'max_participants' => (int) env('LIVEKIT_MAX_PARTICIPANTS', 20),

];
