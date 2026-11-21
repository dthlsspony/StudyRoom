<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Room;
use App\Services\LiveKit\LiveKitService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use RuntimeException;

/**
 * Участники эфира: список со статусом микрофона и модерация со стороны ведущего.
 */
class ParticipantController extends Controller
{
    /**
     * Участники комнаты, подключённые к LiveKit.
     */
    public function index(Request $request, Room $room): JsonResponse
    {
        $this->authorize('view', $room);

        $service = LiveKitService::fromConfig();

        try {
            $participants = $service->listParticipants($room->livekitRoomName());
        } catch (RuntimeException $e) {
            // Комнаты в LiveKit ещё нет — эфир не идёт.
            return response()->json(['data' => []]);
        }

        $hostId = (string) $room->owner_id;

        $data = array_map(function (array $participant) use ($hostId) {
            $mic = null;
            $camera = null;
            $screen = null;

            foreach ($participant['tracks'] ?? [] as $track) {
                $source = $track['source'] ?? null;
                $muted = (bool) ($track['muted'] ?? false);

                match ($source) {
                    'microphone' => $mic = $muted,
                    'camera' => $camera = $muted,
                    'screen_share' => $screen = $muted,
                    default => null,
                };
            }

            $metadata = $this->decodeMetadata($participant['metadata'] ?? null);

            return [
                'identity' => (string) ($participant['identity'] ?? ''),
                'name' => $participant['name'] ?? $participant['identity'] ?? '',
                'is_host' => (string) ($participant['identity'] ?? '') === $hostId,
                'mic_muted' => $mic ?? true,
                'camera_muted' => $camera ?? true,
                'sharing_screen' => $screen !== null && ! $screen,
                'muted_by_host' => (bool) ($metadata['muted'] ?? false),
                'connected' => true,
            ];
        }, $participants);

        usort($data, function (array $a, array $b): int {
            if ($a['is_host'] !== $b['is_host']) {
                return $a['is_host'] ? -1 : 1;
            }

            return strcasecmp((string) $a['name'], (string) $b['name']);
        });

        return response()->json(['data' => $data]);
    }

    /**
     * Ведущий заглушает микрофон участника.
     */
    public function mute(Room $room, string $identity): JsonResponse
    {
        $this->authorize('moderate', $room);

        if (! $this->ensureNotHost($room, $identity)) {
            return response()->json(['message' => 'Ведущего заглушить нельзя'], 403);
        }

        $this->applyModeration($room, $identity, muted: true);

        return response()->json(['data' => ['identity' => $identity, 'muted_by_host' => true]]);
    }

    /**
     * Ведущий разрешает участнику включить микрофон.
     */
    public function unmute(Room $room, string $identity): JsonResponse
    {
        $this->authorize('moderate', $room);

        if (! $this->ensureNotHost($room, $identity)) {
            return response()->json(['message' => 'Ведущего заглушить нельзя'], 403);
        }

        $this->applyModeration($room, $identity, muted: false);

        return response()->json(['data' => ['identity' => $identity, 'muted_by_host' => false]]);
    }

    /**
     * Ведущего заглушать нельзя — только участников.
     */
    private function ensureNotHost(Room $room, string $identity): bool
    {
        return $identity !== (string) $room->owner_id;
    }

    /**
     * Ограничение публикации на стороне сервера + отметка в metadata,
     * чтобы клиент участника тоже выключил микрофон.
     */
    private function applyModeration(Room $room, string $identity, bool $muted): void
    {
        $service = LiveKitService::fromConfig();
        $roomName = $room->livekitRoomName();

        $current = [];
        foreach ($service->listParticipants($roomName) as $participant) {
            if ((string) ($participant['identity'] ?? '') === $identity) {
                $current = $this->decodeMetadata($participant['metadata'] ?? null);
            }
        }

        $current['muted'] = $muted;

        $service->updateParticipant($roomName, $identity, [
            'metadata' => json_encode($current, JSON_THROW_ON_ERROR),
            // Серверное ограничение: участник не сможет включить микрофон сам.
            'permission' => ['canPublish' => ! $muted],
        ]);
    }

    /**
     * @return array<string, mixed>
     */
    private function decodeMetadata(?string $metadata): array
    {
        if (! $metadata) {
            return [];
        }

        $decoded = json_decode($metadata, true);

        return is_array($decoded) ? $decoded : [];
    }
}
