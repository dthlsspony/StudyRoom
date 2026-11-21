<?php

namespace App\Policies;

use App\Models\Room;
use App\Models\User;

class RoomPolicy
{
    public function viewAny(User $user): bool
    {
        return true;
    }

    public function view(User $user, Room $room): bool
    {
        if (! $room->is_private) {
            return true;
        }

        return $this->isMember($user, $room) || $user->id === $room->owner_id;
    }

    public function create(User $user): bool
    {
        return true;
    }

    public function update(User $user, Room $room): bool
    {
        return $user->id === $room->owner_id;
    }

    public function delete(User $user, Room $room): bool
    {
        return $user->id === $room->owner_id;
    }

    public function stream(User $user, Room $room): bool
    {
        return $user->id === $room->owner_id;
    }

    /**
     * Модерация: заглушить участника может только ведущий.
     */
    public function moderate(User $user, Room $room): bool
    {
        return $user->id === $room->owner_id;
    }

    public function join(User $user, Room $room): bool
    {
        return true;
    }

    private function isMember(User $user, Room $room): bool
    {
        return $room->users()->where('users.id', $user->id)->exists();
    }
}
