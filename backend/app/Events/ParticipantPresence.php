<?php

namespace App\Events;

use App\Models\Room;
use Illuminate\Broadcasting\PrivateChannel;
use Illuminate\Contracts\Broadcasting\ShouldBroadcastNow;
use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

class ParticipantPresence implements ShouldBroadcastNow
{
    use Dispatchable, SerializesModels;

    public const JOINED = 'joined';

    public const LEFT = 'left';

    public function __construct(
        public Room $room,
        public string $action,
        public string $identity,
        public ?string $name = null,
    ) {}

    /**
     * @return array<int, PrivateChannel>
     */
    public function broadcastOn(): array
    {
        return [new PrivateChannel('rooms.'.$this->room->getKey())];
    }

    public function broadcastAs(): string
    {
        return 'participant.'.$this->action;
    }

    /**
     * @return array<string, mixed>
     */
    public function broadcastWith(): array
    {
        return [
            'action' => $this->action,
            'identity' => $this->identity,
            'name' => $this->name,
            'room_id' => $this->room->getKey(),
        ];
    }
}
