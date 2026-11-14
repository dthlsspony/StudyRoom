<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Http\Resources\RoomResource;
use App\Models\Room;
use App\Models\Stream;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\AnonymousResourceCollection;

class RoomController extends Controller
{
    public function index(Request $request): AnonymousResourceCollection
    {
        $user = $request->user();
        $search = trim((string) $request->query('search', ''));

        $rooms = Room::query()
            ->with('owner')
            ->withCount('users')
            ->withExists(['streams' => fn ($query) => $query->where('status', Stream::STATUS_LIVE)])
            ->when($search !== '', fn ($query) => $query->where('name', 'ilike', "%{$search}%"))
            ->where(function ($query) use ($user) {
                $query->where('is_private', false)
                    ->orWhere('owner_id', $user->id)
                    ->orWhereHas('users', fn ($q) => $q->where('users.id', $user->id));
            })
            ->latest()
            ->paginate(20)
            ->withQueryString();

        return RoomResource::collection($rooms);
    }

    public function store(Request $request): JsonResponse
    {
        $data = $request->validate([
            'name' => ['required', 'string', 'min:2', 'max:120'],
            'description' => ['nullable', 'string', 'max:2000'],
            'is_private' => ['boolean'],
            'capacity' => ['nullable', 'integer', 'min:1', 'max:1000'],
        ]);

        $room = Room::create([
            'name' => $data['name'],
            'description' => $data['description'] ?? null,
            'is_private' => (bool) ($data['is_private'] ?? false),
            'capacity' => $data['capacity'] ?? null,
            'owner_id' => $request->user()->id,
        ]);

        $room->users()->syncWithoutDetaching([$request->user()->id]);
        $room->load('owner')->loadCount('users');

        return response()->json(['data' => (new RoomResource($room))->resolve()], 201);
    }

    public function show(Room $room): RoomResource
    {
        $this->authorize('view', $room);

        $room->load('owner')->loadCount('users')
            ->loadExists(['streams' => fn ($query) => $query->where('status', Stream::STATUS_LIVE)]);

        return new RoomResource($room);
    }

    public function update(Request $request, Room $room): RoomResource
    {
        $this->authorize('update', $room);

        $data = $request->validate([
            'name' => ['sometimes', 'string', 'min:2', 'max:120'],
            'description' => ['sometimes', 'nullable', 'string', 'max:2000'],
            'is_private' => ['sometimes', 'boolean'],
            'capacity' => ['sometimes', 'nullable', 'integer', 'min:1', 'max:1000'],
        ]);

        $room->fill($data)->save();
        $room->load('owner')->loadCount('users');

        return new RoomResource($room);
    }

    public function destroy(Room $room): JsonResponse
    {
        $this->authorize('delete', $room);

        $room->delete();

        return response()->json(['message' => 'Комната удалена']);
    }

    public function join(Request $request, Room $room): RoomResource
    {
        $this->authorize('view', $room);

        $room->users()->syncWithoutDetaching([$request->user()->id]);
        $room->load('owner')->loadCount('users');

        return new RoomResource($room);
    }

    public function leave(Request $request, Room $room): JsonResponse
    {
        $room->users()->detach($request->user()->id);

        return response()->json(['message' => 'Вы покинули комнату']);
    }
}
