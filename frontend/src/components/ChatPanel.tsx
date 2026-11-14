import { useEffect, useRef, useState } from 'react'
import { api, ApiError } from '../lib/api'
import type { Message } from '../lib/api'
import { getEcho } from '../lib/echo'

interface ChatPanelProps {
  roomId: number
}

export default function ChatPanel({ roomId }: ChatPanelProps) {
  const [messages, setMessages] = useState<Message[]>([])
  const [draft, setDraft] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const bottomRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    let cancelled = false

    api.messages
      .list(roomId)
      .then((result) => {
        if (!cancelled) {
          setMessages(result.data)
        }
      })
      .catch((e) => {
        if (!cancelled) {
          setError(e instanceof ApiError ? e.message : 'Не удалось загрузить сообщения')
        }
      })
      .finally(() => {
        if (!cancelled) {
          setLoading(false)
        }
      })

    return () => {
      cancelled = true
    }
  }, [roomId])

  useEffect(() => {
    let disposed = false
    let cleanup: (() => void) | undefined

    getEcho()
      .then((echo) => {
        if (disposed) {
          return
        }
        echo
          .private(`rooms.${roomId}`)
          .listen('.message.created', (payload: Message) => {
            setMessages((current) =>
              current.some((message) => message.id === payload.id)
                ? current
                : [...current, payload],
            )
          })
        cleanup = () => echo.leave(`rooms.${roomId}`)
      })
      .catch(() => {
        // Живые обновления не критичны: чат остаётся рабочим через REST.
      })

    return () => {
      disposed = true
      cleanup?.()
    }
  }, [roomId])

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  async function handleSend(event: React.FormEvent) {
    event.preventDefault()
    const body = draft.trim()
    if (!body) {
      return
    }

    setDraft('')
    try {
      const message = await api.messages.send(roomId, body)
      setMessages((current) =>
        current.some((item) => item.id === message.id) ? current : [...current, message],
      )
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Сообщение не отправлено')
      setDraft(body)
    }
  }

  return (
    <div className="chat">
      <div className="chat-head">
        <h2>Чат</h2>
      </div>

      <div className="chat-messages">
        {loading && <p className="muted">Загрузка…</p>}
        {error && <div className="alert alert-error">{error}</div>}
        {messages.map((message) => (
          <div key={message.id} className="chat-message">
            <span className="chat-author">{message.user.name}</span>
            <span className="chat-body">{message.body}</span>
            <time className="muted small">
              {new Date(message.created_at).toLocaleTimeString('ru-RU', {
                hour: '2-digit',
                minute: '2-digit',
              })}
            </time>
          </div>
        ))}
        {messages.length === 0 && !loading && <p className="muted">Сообщений пока нет</p>}
        <div ref={bottomRef} />
      </div>

      <form className="chat-input" onSubmit={handleSend}>
        <input
          type="text"
          placeholder="Сообщение…"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          maxLength={2000}
        />
        <button type="submit" disabled={draft.trim() === ''}>
          Отправить
        </button>
      </form>
    </div>
  )
}
