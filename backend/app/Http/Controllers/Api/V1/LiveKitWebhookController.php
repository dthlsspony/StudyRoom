<?php

namespace App\Http\Controllers\Api\V1;

use App\Events\ParticipantPresence;
use App\Events\StreamEnded;
use App\Http\Controllers\Controller;
use App\Models\Room;
use App\Models\Stream;
use App\Services\LiveKit\LiveKitService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use RuntimeException;

/**
 * Приём вебхуков LiveKit: участники в комнате, старт и завершение эфира.
 */
class LiveKitWebhookController extends Controller
{
    public function __invoke(Request $request): JsonResponse
    {
        $service = LiveKitService::fromConfig();

        try {
            $payload = $service->verifyWebhook($request->getContent(), $request->header('Authorization'));
        } catch (RuntimeException $e) {
            Log::warning('LiveKit webhook rejected', ['reason' => $e->getMessage()]);

            return response()->json(['message' => 'Некорректная подпись вебхука'], 401);
        }

        $event = (string) ($payload['event'] ?? '');
        $roomName = $payload['room']['name'] ?? null;

        if ($roomName === null) {
            return response()->json(['message' => 'Вебхук без комнаты'], 200);
        }

        $room = Room::where('livekit_room_name', $roomName)->first();

        if ($room === null) {
            return response()->json(['message' => 'Комната не найдена'], 200);
        }

        match ($event) {
            'room_started' => $this->markLive($room),
            'room_finished' => $this->markEnded($room),
            'participant_joined' => $this->announcePresence(
                $room,
                ParticipantPresence::JOINED,
                (string) ($payload['participant']['identity'] ?? ''),
                $payload['participant']['name'] ?? null,
            ),
            'participant_left' => $this->handleParticipantLeft(
                $room,
                (string) ($payload['participant']['identity'] ?? ''),
                $payload['participant']['name'] ?? null,
            ),
            default => null,
        };

        return response()->json(['message' => 'ok']);
    }

    /**
     * Участник покинул комнату.
     *
     * Эфир держит ведущий: если ушёл именно он — трансляция закончилась.
     * Уход остальных участников ничего не меняет: комната ещё не пуста,
     * а свежий эфир, в который никто не успел войти, закрывать нельзя.
     */
    private function handleParticipantLeft(Room $room, string $identity, ?string $name): void
    {
        $this->announcePresence($room, ParticipantPresence::LEFT, $identity, $name);

        if ($identity === '' || ! $room->is_live) {
            return;
        }

        $stream = $room->latestStream;

        if ($stream === null || $stream->status !== Stream::STATUS_LIVE) {
            return;
        }

        if ((string) $stream->started_by !== $identity) {
            return;
        }

        $this->markEnded($room);

        try {
            LiveKitService::fromConfig()->deleteRoom($room->livekitRoomName());
        } catch (RuntimeException $e) {
            Log::warning('Не удалось удалить комнату LiveKit', [
                'room' => $room->livekitRoomName(),
                'reason' => $e->getMessage(),
            ]);
        }
    }

    private function announcePresence(Room $room, string $action, string $identity, ?string $name): void
    {
        if ($identity === '') {
            return;
        }

        ParticipantPresence::dispatch($room, $action, $identity, $name);
    }
}
