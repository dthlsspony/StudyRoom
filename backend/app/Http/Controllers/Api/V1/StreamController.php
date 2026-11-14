<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Room;
use App\Models\Stream;
use App\Services\LiveKit\LiveKitService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use RuntimeException;

class StreamController extends Controller
{
    /**
     * Текущий доступ к эфиру: токен участника и адрес LiveKit.
     */
    public function show(Request $request, Room $room): JsonResponse
    {
        $this->authorize('view', $room);

        return $this->access($request, $room);
    }

    /**
     * Токен участника для текущего эфира.
     */
    private function access(Request $request, Room $room): JsonResponse
    {
        $service = LiveKitService::fromConfig();
        $hasActiveStream = $room->latestStream?->status === Stream::STATUS_LIVE;

        // Флаг в таблице мог разойтись с записями стримов — приводим в порядок.
        if ($room->is_live && ! $hasActiveStream) {
            $room->forceFill(['is_live' => false])->save();
        }

        $isLive = $room->is_live && $hasActiveStream;

        if ($isLive) {
            $isLive = $this->syncWithLiveKit($service, $room);
        }

        return response()->json([
            'token' => $isLive
                ? $service->createParticipantToken($request->user(), $room->livekitRoomName())
                : null,
            'ws_url' => $service->clientUrl(),
            'room_name' => $room->livekitRoomName(),
            'identity' => (string) $request->user()->id,
            'stream_id' => $room->latestStream?->id,
            'is_live' => $isLive,
        ]);
    }

    /**
     * Сверяет состояние БД с LiveKit: комната могла закрыться по таймауту,
     * а вебхук — не дойти. Тогда эфир считаем завершённым.
     */
    private function syncWithLiveKit(LiveKitService $service, Room $room): bool
    {
        $roomName = $room->livekitRoomName();

        try {
            if (! $service->roomExists($roomName)) {
                $this->endStream($room);

                return false;
            }

            // Комната есть, но в ней никого: ведущий ушёл, а вебхук participant_left
            // мог не дойти. Проверяем только для эфиров, идущих дольше минуты,
            // чтобы не погасить эфир сразу после запуска.
            $stream = $room->latestStream;

            if ($stream?->started_at?->addMinutes(1)?->isPast() && $service->listParticipants($roomName) === []) {
                $this->endStream($room);

                return false;
            }
        } catch (RuntimeException $e) {
            // LiveKit недоступен — не трогаем состояние, пусть клиент подождёт.
            report($e);
        }

        return true;
    }

    /**
     * Завершить эфир: закрыть запись в БД и удалить комнату LiveKit.
     */
    private function endStream(Room $room): void
    {
        $room->streams()
            ->where('status', Stream::STATUS_LIVE)
            ->update(['status' => Stream::STATUS_ENDED, 'ended_at' => now()]);

        $room->forceFill(['is_live' => false])->save();
    }

    /**
     * Запустить эфир в комнате (владелец).
     */
    public function start(Request $request, Room $room): JsonResponse
    {
        $this->authorize('stream', $room);

        $service = LiveKitService::fromConfig();
        $roomName = $room->livekitRoomName();

        // Эфир уже идёт — возвращаем доступ к текущему, не создавая второй стрим.
        if ($room->is_live && $room->latestStream?->status === Stream::STATUS_LIVE) {
            return $this->access($request, $room);
        }

        try {
            $service->createRoom($roomName, $room->capacity);
        } catch (RuntimeException $e) {
            return response()->json([
                'message' => 'Не удалось создать эфир: '.$e->getMessage(),
            ], 502);
        }

        $stream = $room->streams()->create([
            'started_by' => $request->user()->id,
            'livekit_room_name' => $roomName,
            'status' => Stream::STATUS_LIVE,
            'started_at' => now(),
        ]);

        $room->forceFill([
            'is_live' => true,
            'livekit_room_name' => $roomName,
        ])->save();

        return response()->json([
            'token' => $service->createParticipantToken($request->user(), $roomName),
            'ws_url' => $service->clientUrl(),
            'room_name' => $roomName,
            'identity' => (string) $request->user()->id,
            'stream_id' => $stream->id,
            'is_live' => true,
        ], 201);
    }

    /**
     * Остановить эфир (владелец).
     */
    public function stop(Request $request, Room $room): JsonResponse
    {
        $this->authorize('stream', $room);

        $service = LiveKitService::fromConfig();
        $roomName = $room->livekitRoomName();

        $room->streams()
            ->where('status', Stream::STATUS_LIVE)
            ->update(['status' => Stream::STATUS_ENDED, 'ended_at' => now()]);

        $room->forceFill(['is_live' => false])->save();

        try {
            $service->deleteRoom($roomName);
        } catch (RuntimeException) {
            // Эфир уже закрыт на стороне LiveKit — это не мешает завершить сессию.
        }

        return response()->json(['message' => 'Эфир остановлен']);
    }
}
