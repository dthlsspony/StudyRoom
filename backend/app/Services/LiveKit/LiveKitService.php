<?php

namespace App\Services\LiveKit;

use App\Models\User;
use Firebase\JWT\JWT;
use Firebase\JWT\Key;
use Illuminate\Http\Client\ConnectionException;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Str;
use RuntimeException;

/**
 * Клиент LiveKit Server API.
 *
 * Официального PHP SDK у LiveKit нет, поэтому используем их же протокол:
 *  - токен участника — JWT (HS256), подписанный секретом API;
 *  - управление комнатами — Twirp RPC (`/twirp/livekit.RoomService/...`).
 */
class LiveKitService
{
    public function __construct(
        private readonly string $apiKey,
        private readonly string $apiSecret,
        private readonly string $apiUrl,
        private readonly string $clientUrl,
        private readonly int $tokenTtl,
    ) {}

    public static function fromConfig(): self
    {
        $apiKey = (string) config('livekit.api_key');
        $apiSecret = (string) config('livekit.api_secret');

        if ($apiKey === '' || $apiSecret === '') {
            throw new RuntimeException('LIVEKIT_API_KEY и LIVEKIT_API_SECRET не заданы');
        }

        // HS256 требует ключ длиной не менее 32 байт (256 бит).
        if (strlen($apiSecret) < 32) {
            throw new RuntimeException('LIVEKIT_API_SECRET должен быть не короче 32 символов');
        }

        return new self(
            $apiKey,
            $apiSecret,
            (string) config('livekit.api_url'),
            (string) config('livekit.url'),
            (int) config('livekit.token_ttl'),
        );
    }

    /**
     * Токен для входа в комнату.
     *
     * @param  array<string, mixed>  $grants  дополнительные разрешения (video grant)
     */
    public function createParticipantToken(User $user, string $roomName, array $grants = []): string
    {
        $video = array_merge([
            'room' => $roomName,
            'roomJoin' => true,
            'canPublish' => true,
            'canSubscribe' => true,
            'canPublishData' => true,
            'canPublishSources' => (array) config('livekit.publish_sources'),
        ], $grants);

        return $this->encode([
            'sub' => (string) $user->id,
            'name' => $user->name,
            'metadata' => json_encode([
                'user_id' => $user->id,
                'email' => $user->email,
            ], JSON_THROW_ON_ERROR),
            'video' => $video,
        ]);
    }

    /**
     * Сервисный токен для вызовов RoomService.
     *
     * @param  array<string, mixed>  $grants
     */
    public function createServiceToken(array $grants = []): string
    {
        return $this->encode([
            'sub' => 'studyroom-backend',
            'video' => array_merge([
                'roomCreate' => true,
                'roomList' => true,
                'roomAdmin' => true,
            ], $grants),
        ]);
    }

    /**
     * @param  array<string, mixed>  $payload
     */
    private function encode(array $payload): string
    {
        $now = time();

        return JWT::encode(array_merge([
            'iss' => $this->apiKey,
            'nbf' => $now - 5,
            'exp' => $now + $this->tokenTtl,
            'jti' => (string) Str::uuid(),
        ], $payload), $this->apiSecret, 'HS256');
    }

    public function clientUrl(): string
    {
        return $this->clientUrl;
    }

    /**
     * Создать комнату в LiveKit. Если комната уже есть — ошибку игнорируем.
     */
    public function createRoom(string $name, ?int $maxParticipants = null): bool
    {
        try {
            $this->call('CreateRoom', [
                'name' => $name,
                'empty_timeout' => (int) config('livekit.empty_timeout'),
                'departure_timeout' => (int) config('livekit.departure_timeout'),
                'max_participants' => $maxParticipants ?? (int) config('livekit.max_participants'),
            ]);

            return true;
        } catch (RuntimeException $e) {
            if ($this->isAlreadyExists($e)) {
                return false;
            }

            throw $e;
        }
    }

    public function deleteRoom(string $name): void
    {
        try {
            $this->call('DeleteRoom', ['room' => $name], [
                'room' => $name,
                'roomAdmin' => true,
            ]);
        } catch (RuntimeException $e) {
            if ($this->isAlreadyExists($e)) {
                return;
            }

            throw $e;
        }
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    public function listRooms(): array
    {
        $response = $this->call('ListRooms', []);

        return $response['rooms'] ?? [];
    }

    /**
     * Есть ли комната в LiveKit прямо сейчас.
     */
    public function roomExists(string $name): bool
    {
        foreach ($this->listRooms() as $room) {
            if (($room['name'] ?? null) === $name) {
                return true;
            }
        }

        return false;
    }

    /**
     * Участники комнаты в LiveKit.
     *
     * @return array<int, array<string, mixed>>
     */
    public function listParticipants(string $roomName): array
    {
        // ListParticipants требует прав администратора именно этой комнаты,
        // поэтому сервисный токен должен быть ограничен её именем.
        $response = $this->call('ListParticipants', ['room' => $roomName], [
            'room' => $roomName,
            'roomAdmin' => true,
        ]);

        return $response['participants'] ?? [];
    }

    /**
     * Обновить участника: metadata и права публикации.
     *
     * canPublish = false — серверное ограничение: заглушённый участник не сможет
     * публиковать звук или видео, даже если попытается включить микрофон сам.
     *
     * @param  array<string, mixed>  $options  metadata, permission, name
     * @return array<string, mixed>
     */
    public function updateParticipant(string $roomName, string $identity, array $options = []): array
    {
        return $this->call('UpdateParticipant', [
            'room' => $roomName,
            'identity' => $identity,
        ] + $options, [
            'room' => $roomName,
            'roomAdmin' => true,
        ]);
    }

    /**
     * @param  array<string, mixed>  $payload
     * @param  array<string, mixed>  $grants  дополнительные права (например, доступ администратора к комнате)
     * @return array<string, mixed>
     */
    private function call(string $method, array $payload, array $grants = []): array
    {
        $url = rtrim($this->apiUrl, '/').'/twirp/livekit.RoomService/'.$method;

        // Пустой массив сериализуется в [], а Twirp ждёт объект {}.
        $body = $payload === [] ? new \stdClass : $payload;

        try {
            $response = Http::withToken($this->createServiceToken($grants))
                ->acceptJson()
                ->asJson()
                ->post($url, $body);
        } catch (ConnectionException $e) {
            throw new RuntimeException('LiveKit недоступен: '.$e->getMessage(), previous: $e);
        }

        if ($response->failed()) {
            throw new RuntimeException(sprintf(
                'LiveKit %s вернул ошибку %d: %s',
                $method,
                $response->status(),
                $response->body(),
            ));
        }

        return $response->json() ?? [];
    }

    private function isAlreadyExists(RuntimeException $e): bool
    {
        $message = strtolower($e->getMessage());

        foreach (['already exists', 'not_found', 'not found', 'does not exist'] as $needle) {
            if (str_contains($message, $needle)) {
                return true;
            }
        }

        return false;
    }

    /**
     * Проверить подпись вебхука LiveKit.
     *
     * LiveKit подписывает тело запроса JWT-токеном: в claims есть `sha256` —
     * base64(sha256(raw body)). Кроме того проверяется issuer и срок жизни токена.
     *
     * @return array<string, mixed> разобранное тело вебхука
     */
    public function verifyWebhook(string $body, ?string $authorizationHeader): array
    {
        if ($authorizationHeader === null || $authorizationHeader === '') {
            throw new RuntimeException('Отсутствует заголовок Authorization');
        }

        $token = Str::contains($authorizationHeader, 'Bearer ')
            ? Str::after($authorizationHeader, 'Bearer ')
            : $authorizationHeader;

        try {
            $decoded = JWT::decode($token, new Key($this->apiSecret, 'HS256'));
        } catch (\Throwable $e) {
            throw new RuntimeException('Не удалось проверить подпись вебхука: '.$e->getMessage(), previous: $e);
        }

        $claims = (array) $decoded;

        if (($claims['iss'] ?? null) !== $this->apiKey) {
            throw new RuntimeException('Вебхук подписан некорректным ключом');
        }

        $expected = base64_encode(hash('sha256', $body, true));

        if (! hash_equals($expected, (string) ($claims['sha256'] ?? ''))) {
            throw new RuntimeException('Контрольная сумма тела вебхука не совпадает');
        }

        $payload = json_decode($body, true);

        if (! is_array($payload)) {
            throw new RuntimeException('Тело вебхука не является корректным JSON');
        }

        return $payload;
    }
}
