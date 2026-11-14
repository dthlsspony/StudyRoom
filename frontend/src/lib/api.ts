export interface User {
  id: number
  name: string
  email: string
}

export interface Room {
  id: number
  name: string
  description: string | null
  is_private: boolean
  capacity: number | null
  participants_count: number
  is_live: boolean
  owner: User
  created_at: string
}

export interface Message {
  id: number
  room_id: number
  body: string
  type: string
  user: User
  created_at: string
}

export interface StreamAccess {
  token: string | null
  ws_url: string
  room_name: string
  identity: string
  stream_id: number | null
  is_live: boolean
}

export interface Paginated<T> {
  data: T[]
  meta: {
    current_page: number
    last_page: number
    per_page: number
    total: number
  }
}

export interface Credentials {
  email: string
  password: string
  name?: string
}

export interface AuthResponse {
  token: string
  user: User
}

export class ApiError extends Error {
  status: number
  errors: Record<string, string[]>

  constructor(status: number, message: string, errors: Record<string, string[]> = {}) {
    super(message)
    this.status = status
    this.errors = errors
  }
}

const TOKEN_KEY = 'studyroom.token'

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY)
}

export function setToken(token: string | null): void {
  if (token) {
    localStorage.setItem(TOKEN_KEY, token)
  } else {
    localStorage.removeItem(TOKEN_KEY)
  }
}

async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const token = getToken()
  const headers = new Headers(options.headers)
  headers.set('Accept', 'application/json')
  if (options.body) {
    headers.set('Content-Type', 'application/json')
  }
  if (token) {
    headers.set('Authorization', `Bearer ${token}`)
  }

  const response = await fetch(`${path}`, { ...options, headers })

  if (response.status === 204) {
    return undefined as T
  }

  const payload = await response.json().catch(() => null)

  if (!response.ok) {
    const message =
      payload?.message ??
      (response.status === 401 ? 'Требуется авторизация' : 'Ошибка запроса')
    const errors = payload?.errors ?? {}
    throw new ApiError(response.status, message, errors)
  }

  return payload as T
}

function json(body: unknown): RequestInit {
  return { body: JSON.stringify(body) }
}

/**
 * Laravel оборачивает одиночные ресурсы в { data: ... }.
 */
function unwrap<T>(payload: { data: T }): T {
  return payload.data
}

export const api = {
  auth: {
    async register(payload: Credentials): Promise<AuthResponse> {
      const data = await request<AuthResponse>('/api/v1/auth/register', {
        method: 'POST',
        ...json(payload),
      })
      setToken(data.token)
      return data
    },
    async login(payload: Credentials): Promise<AuthResponse> {
      const data = await request<AuthResponse>('/api/v1/auth/login', {
        method: 'POST',
        ...json(payload),
      })
      setToken(data.token)
      return data
    },
    async logout(): Promise<void> {
      await request<void>('/api/v1/auth/logout', { method: 'POST' })
      setToken(null)
    },
    async me(): Promise<User> {
      return unwrap(await request<{ data: User }>('/api/v1/auth/me'))
    },
  },
  rooms: {
    async list(search = ''): Promise<Paginated<Room>> {
      const query = search ? `?search=${encodeURIComponent(search)}` : ''
      return request<Paginated<Room>>(`/api/v1/rooms${query}`)
    },
    async get(id: number): Promise<Room> {
      return unwrap(await request<{ data: Room }>(`/api/v1/rooms/${id}`))
    },
    async create(payload: { name: string; description?: string; is_private?: boolean }): Promise<Room> {
      return unwrap(
        await request<{ data: Room }>('/api/v1/rooms', { method: 'POST', ...json(payload) }),
      )
    },
    async update(
      id: number,
      payload: { name?: string; description?: string; is_private?: boolean },
    ): Promise<Room> {
      return unwrap(
        await request<{ data: Room }>(`/api/v1/rooms/${id}`, {
          method: 'PATCH',
          ...json(payload),
        }),
      )
    },
    async remove(id: number): Promise<void> {
      await request<void>(`/api/v1/rooms/${id}`, { method: 'DELETE' })
    },
    async join(id: number): Promise<void> {
      await request<void>(`/api/v1/rooms/${id}/join`, { method: 'POST' })
    },
    async leave(id: number): Promise<void> {
      await request<void>(`/api/v1/rooms/${id}/leave`, { method: 'POST' })
    },
  },
  messages: {
    async list(roomId: number): Promise<Paginated<Message>> {
      return request<Paginated<Message>>(`/api/v1/rooms/${roomId}/messages`)
    },
    async send(roomId: number, body: string): Promise<Message> {
      return unwrap(
        await request<{ data: Message }>(`/api/v1/rooms/${roomId}/messages`, {
          method: 'POST',
          ...json({ body }),
        }),
      )
    },
  },
  stream: {
    async start(roomId: number): Promise<StreamAccess> {
      return request<StreamAccess>(`/api/v1/rooms/${roomId}/stream`, { method: 'POST' })
    },
    async access(roomId: number): Promise<StreamAccess> {
      return request<StreamAccess>(`/api/v1/rooms/${roomId}/stream`)
    },
    async stop(roomId: number): Promise<void> {
      await request<void>(`/api/v1/rooms/${roomId}/stream`, { method: 'DELETE' })
    },
  },
}
