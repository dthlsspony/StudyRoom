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
     * Эфир завершается, если ушёл ведущий (тот, кто его запустил) — трансляции
     * больше нет. Если ведущий остался, но комната опустела — тоже завершаем:
     * иначе комната «висит» до таймаута пустой комнаты.
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

        $service = LiveKitService::fromConfig();
        $roomName = $room->livekitRoomName();

        $isStarter = (string) $stream->started_by === $identity;

        if (! $isStarter) {
            try {
                $participants = array_filter(
                    $service->listParticipants($roomName),
                    fn (array $participant) => ($participant['identity'] ?? null) !== $identity,
                );
            } catch (RuntimeException $e) {
                // Не смогли проверить состав — не закрываем эфир: LiveKit пришлёт room_finished.
                Log::warning('Не удалось получить список участников LiveKit', [
                    'room' => $roomName,
                    'reason' => $e->getMessage(),
                ]);

                return;
            }

            if ($participants !== []) {
                return;
            }
        }

        $this->markEnded($room);

        try {
            $service->deleteRoom($roomName);
        } catch (RuntimeException $e) {
            Log::warning('Не удалось удалить комнату LiveKit', [
                'room' => $roomName,
                'reason' => $e->getMessage(),
            ]);
        }
    }

    private function markLive(Room $room): void
    {
        // Эфир считается живым, только если в базе есть активная запись стрима.
        // Иначе вебхук resurrect-ит уже остановленный эфир.
        $hasActiveStream = $room->streams()
            ->where('status', Stream::STATUS_LIVE)
            ->exists();

        if ($hasActiveStream) {
            $room->forceFill(['is_live' => true])->save();
        }
    }

    private function markEnded(Room $room): void
    {
        $room->streams()
            ->where('status', Stream::STATUS_LIVE)
            ->update(['status' => Stream::STATUS_ENDED, 'ended_at' => now()]);

        $room->forceFill(['is_live' => false])->save();

        try {
            StreamEnded::dispatch($room);
        } catch (\Throwable $e) {
            Log::warning('Не удалось разослать событие об окончании эфира', [
                'room_id' => $room->getKey(),
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
