import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { api, ApiError } from '../lib/api'
import type { Room } from '../lib/api'
import { getEcho } from '../lib/echo'
import { useAuth } from '../context/AuthContext'
import ChatPanel from '../components/ChatPanel'
import VideoStage from '../components/VideoStage'
import ParticipantsPanel from '../components/ParticipantsPanel'
import type { StageParticipant } from '../components/VideoStage'

export default function RoomPage() {
  const { roomId } = useParams()
  const { user } = useAuth()
  const [room, setRoom] = useState<Room | null>(null)
  const [participants, setParticipants] = useState<StageParticipant[]>([])
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const id = Number(roomId)

  const loadRoom = useCallback(async () => {
    try {
      setRoom(await api.rooms.get(id))
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Не удалось загрузить комнату')
    }
  }, [id])

  useEffect(() => {
    void loadRoom()
  }, [loadRoom])

  // Стабильный колбэк: иначе VideoStage переподключается по кругу.
  const handleStreamUnavailable = useCallback(() => {
    void loadRoom()
  }, [loadRoom])

  // Эфир может закончиться, когда ведущий закрыл вкладку — сервер сообщит об этом.
  useEffect(() => {
    let disposed = false
    let cleanup: (() => void) | undefined

    getEcho()
      .then((echo) => {
        if (disposed) {
          return
        }
        echo.private(`rooms.${id}`).listen('.stream.ended', () => {
          void loadRoom()
        })
        cleanup = () => echo.leave(`rooms.${id}`)
      })
      .catch(() => {
        // Живые обновления не критичны: состояние обновится при следующей загрузке.
      })

    return () => {
      disposed = true
      cleanup?.()
    }
  }, [id, loadRoom])

  async function handleStartStream() {
    setBusy(true)
    setError(null)
    try {
      await api.stream.start(id)
      await loadRoom()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Не удалось запустить эфир')
    } finally {
      setBusy(false)
    }
  }

  async function handleStopStream() {
    setBusy(true)
    setError(null)
    try {
      await api.stream.stop(id)
      await loadRoom()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Не удалось остановить эфир')
    } finally {
      setBusy(false)
    }
  }

  if (!room) {
    return (
      <div className="app-shell">
        <header className="app-header">
          <Link to="/rooms">← К комнатам</Link>
        </header>
        <main className="app-main">
          {error ? <div className="alert alert-error">{error}</div> : <p>Загрузка…</p>}
        </main>
      </div>
    )
  }

  const isOwner = room.owner.id === user?.id

  return (
    <div className="app-shell">
      <header className="app-header">
        <div>
          <Link to="/rooms" className="muted">
            ← К комнатам
          </Link>
          <h1>{room.name}</h1>
          {room.description && <p className="muted">{room.description}</p>}
        </div>
        <div className="stage-actions">
          {isOwner && !room.is_live && (
            <button type="button" onClick={() => void handleStartStream()} disabled={busy}>
              Начать эфир
            </button>
          )}
          {isOwner && room.is_live && (
            <button
              type="button"
              className="ghost danger"
              onClick={() => void handleStopStream()}
              disabled={busy}
            >
              Остановить эфир
            </button>
          )}
        </div>
      </header>

      <main className="app-main room-layout">
        {error && <div className="alert alert-error">{error}</div>}

        <section className="panel">
          <VideoStage
            roomId={id}
            isLive={room.is_live}
            canPublish={isOwner}
            hostIdentity={String(room.owner.id)}
            onStreamUnavailable={handleStreamUnavailable}
            onParticipantsChange={setParticipants}
          />
        </section>

        <div className="side-column">
          <section className="panel">
            <ParticipantsPanel
              roomId={id}
              participants={participants}
              canModerate={isOwner}
              localIdentity={String(user?.id ?? '')}
            />
          </section>

          <section className="panel">
            <ChatPanel roomId={id} />
          </section>
        </div>
      </main>
    </div>
  )
}
