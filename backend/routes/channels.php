<?php

use App\Models\Room;
use App\Models\User;
use Illuminate\Support\Facades\Broadcast;

Broadcast::channel('rooms.{roomId}', function (User $user, int $roomId): bool {
    $room = Room::find($roomId);

    return $room !== null && $user->can('view', $room);
});
