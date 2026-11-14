<?php

use App\Http\Controllers\Api\V1\AuthController;
use App\Http\Controllers\Api\V1\LiveKitWebhookController;
use App\Http\Controllers\Api\V1\MessageController;
use App\Http\Controllers\Api\V1\RoomController;
use App\Http\Controllers\Api\V1\StreamController;
use Illuminate\Support\Facades\Route;

Route::prefix('v1')->group(function (): void {
    Route::prefix('auth')->group(function (): void {
        Route::post('register', [AuthController::class, 'register']);
        Route::post('login', [AuthController::class, 'login']);

        Route::middleware('auth:sanctum')->group(function (): void {
            Route::post('logout', [AuthController::class, 'logout']);
            Route::get('me', [AuthController::class, 'me']);
        });
    });

    Route::middleware('auth:sanctum')->group(function (): void {
        Route::get('rooms', [RoomController::class, 'index']);
        Route::post('rooms', [RoomController::class, 'store']);
        Route::get('rooms/{room}', [RoomController::class, 'show']);
        Route::patch('rooms/{room}', [RoomController::class, 'update']);
        Route::delete('rooms/{room}', [RoomController::class, 'destroy']);
        Route::post('rooms/{room}/join', [RoomController::class, 'join']);
        Route::post('rooms/{room}/leave', [RoomController::class, 'leave']);

        Route::get('rooms/{room}/messages', [MessageController::class, 'index']);
        Route::post('rooms/{room}/messages', [MessageController::class, 'store']);

        Route::get('rooms/{room}/stream', [StreamController::class, 'show']);
        Route::post('rooms/{room}/stream', [StreamController::class, 'start']);
        Route::delete('rooms/{room}/stream', [StreamController::class, 'stop']);
    });

    // Вебхуки LiveKit проверяются подписью, а не токеном пользователя.
    Route::post('livekit/webhook', LiveKitWebhookController::class);
});
