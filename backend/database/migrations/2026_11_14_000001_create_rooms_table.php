<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('rooms', function (Blueprint $table) {
            $table->id();
            $table->string('name', 120);
            $table->text('description')->nullable();
            $table->foreignId('owner_id')->constrained('users')->cascadeOnDelete();
            $table->boolean('is_private')->default(false);
            $table->unsignedInteger('capacity')->nullable();
            $table->boolean('is_live')->default(false);
            $table->string('livekit_room_name')->nullable();
            $table->timestamps();

            $table->index(['is_private', 'created_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('rooms');
    }
};
