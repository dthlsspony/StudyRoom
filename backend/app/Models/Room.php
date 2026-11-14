<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\BelongsToMany;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Illuminate\Database\Eloquent\Relations\HasOne;

#[Fillable(['name', 'description', 'owner_id', 'is_private', 'capacity', 'is_live', 'livekit_room_name'])]
class Room extends Model
{
    use HasFactory;

    protected function casts(): array
    {
        return [
            'is_private' => 'boolean',
            'is_live' => 'boolean',
            'capacity' => 'integer',
        ];
    }

    public function owner(): BelongsTo
    {
        return $this->belongsTo(User::class, 'owner_id');
    }

    public function users(): BelongsToMany
    {
        return $this->belongsToMany(User::class)->withTimestamps();
    }

    public function messages(): HasMany
    {
        return $this->hasMany(Message::class);
    }

    public function streams(): HasMany
    {
        return $this->hasMany(Stream::class);
    }

    public function latestStream(): HasOne
    {
        return $this->hasOne(Stream::class)->latestOfMany();
    }

    /**
     * Имя комнаты в LiveKit.
     */
    public function livekitRoomName(): string
    {
        return $this->livekit_room_name ?: config('livekit.room_prefix').$this->getKey();
    }
}
