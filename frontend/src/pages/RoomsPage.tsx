import { useCallback, useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { api, ApiError } from '../lib/api'
import type { Room } from '../lib/api'
import { useAuth } from '../context/AuthContext'

export default function RoomsPage() {
  const { user, logout } = useAuth()
  const navigate = useNavigate()
  const [rooms, setRooms] = useState<Room[]>([])
  const [search, setSearch] = useState('')
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const loadRooms = useCallback(async (term: string) => {
    try {
      const result = await api.rooms.list(term)
      setRooms(result.data)
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Не удалось загрузить комнаты')
    }
  }, [])

  useEffect(() => {
    void loadRooms(search)
  }, [loadRooms, search])

  async function handleCreate(event: React.FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const room = await api.rooms.create({ name, description })
      setName('')
      setDescription('')
      await loadRooms(search)
      navigate(`/rooms/${room.id}`)
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Не удалось создать комнату')
    } finally {
      setBusy(false)
    }
  }

  async function handleJoin(room: Room) {
    try {
      await api.rooms.join(room.id)
    } catch {
      // Вход в комнату не критичен: чат и стрим доступны и без явного join.
    }
    navigate(`/rooms/${room.id}`)
  }

  return (
    <div className="app-shell">
      <header className="app-header">
        <div>
          <h1>StudyRoom</h1>
          <span className="muted">{user?.name}</span>
        </div>
        <button type="button" className="ghost" onClick={() => void logout()}>
          Выйти
        </button>
      </header>

      <main className="app-main">
        <section className="panel">
          <div className="panel-head">
            <h2>Комнаты</h2>
            <input
              type="search"
              placeholder="Поиск…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>

          {error && <div className="alert alert-error">{error}</div>}

          <ul className="room-list">
            {rooms.map((room) => (
              <li key={room.id} className="room-item">
                <div>
                  <Link to={`/rooms/${room.id}`} className="room-name">
                    {room.name}
                  </Link>
                  {room.description && <p className="muted">{room.description}</p>}
                  <span className="muted small">
                    владелец: {room.owner.name} · участников: {room.participants_count}
                    {room.is_live ? ' · 🔴 идёт эфир' : ''}
                  </span>
                </div>
                <button type="button" onClick={() => void handleJoin(room)}>
                  Войти
                </button>
              </li>
            ))}
            {rooms.length === 0 && <li className="muted">Комнат пока нет</li>}
          </ul>
        </section>

        <section className="panel">
          <h2>Новая комната</h2>
          <form className="stack" onSubmit={handleCreate}>
            <label>
              Название
              <input
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                required
                maxLength={120}
              />
            </label>
            <label>
              Описание
              <textarea
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                rows={4}
                maxLength={1000}
              />
            </label>
            <button type="submit" disabled={busy || name.trim() === ''}>
              {busy ? 'Создаём…' : 'Создать'}
            </button>
          </form>
        </section>
      </main>
    </div>
  )
}
