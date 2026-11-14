<?php

namespace App\Http\Resources;

use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;

/**
 * @mixin \App\Models\Room
 */
class RoomResource extends JsonResource
{
    public function toArray(Request $request): array
    {
        // Флаг is_live в таблице может разойтись с записями стримов,
        // поэтому при наличии подзапроса считаем состояние по стримам.
        $isLive = array_key_exists('streams_exists', $this->resource->getAttributes())
            ? (bool) $this->streams_exists
            : (bool) $this->is_live;

        return [
            'id' => $this->id,
            'name' => $this->name,
            'description' => $this->description,
            'is_private' => (bool) $this->is_private,
            'capacity' => $this->capacity,
            'participants_count' => (int) ($this->users_count ?? $this->users()->count()),
            'is_live' => $isLive,
            'owner' => new UserResource($this->whenLoaded('owner')),
            'created_at' => $this->created_at?->toIso8601String(),
        ];
    }
}
