import Echo from 'laravel-echo'
import Pusher from 'pusher-js'
import { getToken } from './api'

interface BroadcastConfig {
  key: string
  wsHost: string
  wsPort: number
  forceTLS: boolean
  enabledTransports: ('ws' | 'wss' | 'xhr_streaming' | 'xhr_polling' | 'sockjs')[]
}

let instance: Echo<'pusher'> | null = null

/**
 * Создаёт (или возвращает существующий) Echo-подключение к Reverb.
 *
 * Параметры берём из переменных окружения фронтенда: их задаёт
 * docker-compose (см. VITE_REVERB_*), чтобы фронт и бэк не расходились.
 */
export async function getEcho(): Promise<Echo<'pusher'>> {
  if (instance) {
    return instance
  }

  const config: BroadcastConfig = {
    key: import.meta.env.VITE_REVERB_KEY ?? 'studyroomappkey',
    wsHost: import.meta.env.VITE_REVERB_HOST ?? 'localhost',
    wsPort: Number(import.meta.env.VITE_REVERB_PORT ?? 8081),
    forceTLS: import.meta.env.VITE_REVERB_SCHEME === 'https',
    enabledTransports: ['ws'],
  }

  const token = getToken()

  instance = new Echo<'pusher'>({
    broadcaster: 'pusher',
    key: config.key,
    wsHost: config.wsHost,
    wsPort: config.wsPort,
    forceTLS: config.forceTLS,
    enabledTransports: config.enabledTransports,
    cluster: 'mt1',
    authEndpoint: '/api/broadcasting/auth',
    auth: {
      headers: token ? { Authorization: `Bearer ${token}` } : {},
    },
    Pusher,
  })

  return instance
}

export function disconnectEcho(): void {
  instance?.disconnect()
  instance = null
}
