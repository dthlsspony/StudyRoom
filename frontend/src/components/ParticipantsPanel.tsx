import { useState } from 'react'
import { api } from '../lib/api'
import type { StageParticipant } from './VideoStage'

interface ParticipantsPanelProps {
  roomId: number
  participants: StageParticipant[]
  /** может ли текущий пользователь заглушать других (ведущий) */
  canModerate: boolean
  /** собственный identity — его заглушить нельзя */
  localIdentity: string
}

/**
 * Список участников эфира: статус микрофона и кнопка заглушения.
 * Заглушить может только ведущий, и только участника (не себя).
 */
export default function ParticipantsPanel({
  roomId,
  participants,
  canModerate,
  localIdentity,
}: ParticipantsPanelProps) {
  const [pending, setPending] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function toggleMute(participant: StageParticipant) {
    setPending(participant.identity)
    setError(null)
    try {
      if (participant.micMuted) {
        await api.participants.unmute(roomId, participant.identity)
      } else {
        await api.participants.mute(roomId, participant.identity)
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Не удалось изменить состояние микрофона')
    } finally {
      setPending(null)
    }
  }

  return (
    <div className="participants">
      <div className="panel-head">
        <h2>Участники</h2>
        <span className="muted small">{participants.length}</span>
      </div>

      {error && <div className="alert alert-error">{error}</div>}

      {participants.length === 0 && <p className="muted">В эфире пока никого нет</p>}

      <ul className="participant-list">
        {participants.map((participant) => (
          <li key={participant.identity} className="participant">
            <span className={`participant-mic ${participant.micMuted ? 'muted' : 'active'}`}>
              {participant.micMuted ? '🔇' : '🎙'}
            </span>
            <span className="participant-name">
              {participant.name}
              {participant.isLocal ? ' (вы)' : ''}
              {participant.isHost ? ' · ведущий' : ''}
            </span>
            {participant.sharingScreen && <span className="muted small">показывает экран</span>}

            {canModerate && !participant.isHost && (
              <button
                type="button"
                className="ghost small"
                disabled={pending === participant.identity}
                onClick={() => void toggleMute(participant)}
                title={
                  participant.identity === localIdentity
                    ? 'Себя заглушить нельзя'
                    : undefined
                }
              >
                {participant.micMuted ? 'Разрешить' : 'Заглушить'}
              </button>
            )}
          </li>
        ))}
      </ul>
    </div>
  )
}
