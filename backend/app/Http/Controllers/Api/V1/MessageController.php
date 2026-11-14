<?php

namespace App\Http\Controllers\Api\V1;

use App\Events\MessageCreated;
use App\Http\Controllers\Controller;
use App\Http\Resources\MessageResource;
use App\Models\Message;
use App\Models\Room;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;
use Illuminate\Support\Facades\Log;

class MessageController extends Controller
{
    public function index(Request $request, Room $room): AnonymousResourceCollection
    {
        $this->authorize('view', $room);

        $messages = Message::query()
            ->where('room_id', $room->id)
            ->with('user')
            ->latest('id')
            ->limit(100)
            ->get()
            ->reverse()
            ->values();

        return MessageResource::collection($messages);
    }

    public function store(Request $request, Room $room): JsonResponse
    {
        $this->authorize('view', $room);

        $data = $request->validate([
            'body' => ['required', 'string', 'max:2000'],
        ]);

        $message = $room->messages()->create([
            'user_id' => $request->user()->id,
            'body' => $data['body'],
            'type' => 'text',
        ]);

        $message->load('user');

        try {
            MessageCreated::dispatch($message);
        } catch (\Throwable $e) {
            // Сообщение сохранено; если WebSocket-сервер недоступен, чат обновится
            // при следующей загрузке истории.
            Log::warning('Не удалось разослать сообщение в Reverb', [
                'message_id' => $message->id,
                'reason' => $e->getMessage(),
            ]);
        }

        return response()->json(['data' => (new MessageResource($message))->resolve()], 201);
    }
}
