import { useCallback, useEffect, useRef, useState } from 'react'
import { Room, RoomEvent, Track } from 'livekit-client'
import type { Participant } from 'livekit-client'
import { api, ApiError } from '../lib/api'
import { getMediaDiagnostics, mediaProblemMessage } from '../lib/media'

interface VideoStageProps {
  roomId: number
  isLive: boolean
  canPublish: boolean
  onStreamUnavailable?: () => void
}

interface Tile {
  identity: string
  name: string
  isLocal: boolean
  participant: Participant
}

function VideoTile({
  participant,
  isLocal,
  tick,
}: {
  participant: Participant
  isLocal: boolean
  tick: number
}) {
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const container = containerRef.current
    if (!container) {
      return
    }

    const attached: { track: Track; element: HTMLMediaElement }[] = []

    participant.trackPublications.forEach((publication) => {
      const track = publication.track
      if (!track) {
        return
      }
      const element = track.attach()
      element.classList.add(track.kind === Track.Kind.Video ? 'lk-video' : 'lk-audio')

      // Собственный микрофон не должен звучать в собственных наушниках:
      // LiveKit не отправляет его собеседникам, но локально трек проигрывается.
      if (isLocal && track.kind === Track.Kind.Audio) {
        element.muted = true
      }

      container.appendChild(element)
      attached.push({ track, element })
    })

    return () => {
      attached.forEach(({ track, element }) => {
        track.detach(element)
        element.remove()
      })
    }
  }, [participant, tick, isLocal])

  const name = participant.name || participant.identity

  return (
    <div className="video-tile">
      <div className="video-track" ref={containerRef} />
      <span className="video-label">
        {name}
        {isLocal ? ' (вы)' : ''}
      </span>
    </div>
  )
}

export default function VideoStage({
  roomId,
  isLive,
  canPublish,
  onStreamUnavailable,
}: VideoStageProps) {
  const roomRef = useRef<Room | null>(null)
  const [tiles, setTiles] = useState<Tile[]>([])
  const [status, setStatus] = useState<'idle' | 'connecting' | 'connected' | 'error'>('idle')
  const [error, setError] = useState<string | null>(null)
  const [mediaWarning, setMediaWarning] = useState<string | null>(null)
  const [mediaHint, setMediaHint] = useState<string | null>(null)
  const [micEnabled, setMicEnabled] = useState(false)
  const [cameraEnabled, setCameraEnabled] = useState(false)
  const [tick, setTick] = useState(0)

  const syncTiles = useCallback((room: Room) => {
    const list: Tile[] = []

    room.remoteParticipants.forEach((participant) => {
      list.push({
        identity: participant.identity,
        name: participant.name ?? participant.identity,
        isLocal: false,
        participant,
      })
    })

    const local = room.localParticipant
    list.push({
      identity: local.identity,
      name: local.name ?? local.identity,
      isLocal: true,
      participant: local,
    })

    setTiles(list)
    setTick((value) => value + 1)
  }, [])

  const disconnect = useCallback(() => {
    const room = roomRef.current
    if (room) {
      room.removeAllListeners()
      void room.disconnect()
      roomRef.current = null
    }
    setTiles([])
    setStatus('idle')
    setMicEnabled(false)
    setCameraEnabled(false)
    setMediaWarning(null)
  }, [])

  const connect = useCallback(async () => {
    setStatus('connecting')
    setError(null)
    setMediaWarning(null)

    try {
      const access = await api.stream.access(roomId)

      if (!access.is_live || !access.token) {
        // Эфир в базе помечен живым, но в LiveKit его уже нет — просим обновить комнату.
        if (isLive) {
          onStreamUnavailable?.()
        }
        setStatus('idle')
        return
      }

      const room = new Room({ adaptiveStream: true, dynacast: true })
      roomRef.current = room

      room.on(RoomEvent.ParticipantConnected, () => syncTiles(room))
      room.on(RoomEvent.ParticipantDisconnected, () => syncTiles(room))
      room.on(RoomEvent.TrackSubscribed, () => syncTiles(room))
      room.on(RoomEvent.TrackUnsubscribed, () => syncTiles(room))
      room.on(RoomEvent.TrackMuted, () => syncTiles(room))
      room.on(RoomEvent.TrackUnmuted, () => syncTiles(room))
      room.on(RoomEvent.LocalTrackPublished, () => syncTiles(room))
      room.on(RoomEvent.Disconnected, () => {
        setStatus('idle')
        setTiles([])
      })

      await room.connect(access.ws_url, access.token, { autoSubscribe: true })
      syncTiles(room)
      setStatus('connected')

      if (canPublish) {
        // Отказ доступа к устройствам не должен выглядеть как отказ подключения.
        try {
          await room.localParticipant.setMicrophoneEnabled(true)
          await room.localParticipant.setCameraEnabled(true)
          setMicEnabled(true)
          setCameraEnabled(true)
          setMediaWarning(null)
        } catch {
          const diagnostics = await getMediaDiagnostics()
          setMediaWarning(
            mediaProblemMessage(diagnostics) ??
              'Не удалось получить доступ к камере или микрофону. Разрешите доступ в браузере и включите устройства кнопками ниже.',
          )
        }
      }
    } catch (e) {
      setStatus('error')
      setError(
        e instanceof ApiError
          ? e.message
          : e instanceof Error
            ? e.message
            : 'Не удалось подключиться к эфиру',
      )
    }
  }, [roomId, canPublish, isLive, onStreamUnavailable, syncTiles])

  useEffect(() => {
    if (isLive) {
      void connect()
    } else {
      disconnect()
    }

    return () => disconnect()
  }, [isLive, connect, disconnect])

  useEffect(() => {
    if (status !== 'connected') {
      setMediaHint(null)
      return
    }

    let cancelled = false

    getMediaDiagnostics().then((diagnostics) => {
      if (cancelled) {
        return
      }

      if (cameraEnabled) {
        setMediaHint(null)
        return
      }

      setMediaHint(
        diagnostics.permission === 'prompt'
          ? 'Браузер ещё не спрашивал разрешение на камеру — нажмите «Включить камеру», чтобы появился запрос.'
          : 'Камера выключена. Нажмите «Включить камеру», чтобы включить её.',
      )
    })

    return () => {
      cancelled = true
    }
  }, [status, cameraEnabled])

  async function toggleMic() {
    const room = roomRef.current
    if (!room) {
      return
    }
    const next = !micEnabled
    try {
      await room.localParticipant.setMicrophoneEnabled(next)
      setMicEnabled(next)
      setMediaWarning(null)
    } catch {
      const diagnostics = await getMediaDiagnostics()
      setMediaWarning(
        mediaProblemMessage(diagnostics) ??
          'Не удалось включить микрофон: проверьте доступ к устройству в браузере.',
      )
    }
  }

  async function toggleCamera() {
    const room = roomRef.current
    if (!room) {
      return
    }
    const next = !cameraEnabled
    try {
      await room.localParticipant.setCameraEnabled(next)
      setCameraEnabled(next)
      setMediaWarning(null)
    } catch {
      const diagnostics = await getMediaDiagnostics()
      setMediaWarning(
        mediaProblemMessage(diagnostics) ??
          'Не удалось включить камеру: проверьте доступ к устройству в браузере.',
      )
    }
  }

  return (
    <div className="video-stage">
      <div className="panel-head">
        <h2>Эфир</h2>
        <div className="stage-actions">
          {status === 'connected' && (
            <>
              <button
                type="button"
                className={micEnabled ? 'ghost' : 'ghost danger'}
                onClick={() => void toggleMic()}
              >
                {micEnabled ? 'Выключить микрофон' : 'Включить микрофон'}
              </button>
              <button
                type="button"
                className={cameraEnabled ? 'ghost' : 'ghost danger'}
                onClick={() => void toggleCamera()}
              >
                {cameraEnabled ? 'Выключить камеру' : 'Включить камеру'}
              </button>
              <button type="button" className="ghost" onClick={disconnect}>
                Отключиться
              </button>
            </>
          )}
        </div>
      </div>

      {error && <div className="alert alert-error">{error}</div>}

      {mediaWarning && <div className="alert alert-warning">{mediaWarning}</div>}

      {mediaHint && <p className="muted small">{mediaHint}</p>}

      {status === 'connecting' && <p className="muted">Подключение к эфиру…</p>}

      {!isLive && status === 'idle' && (
        <p className="muted">Эфир не запущен. Владелец комнаты может его начать.</p>
      )}

      <div className="video-grid">
        {tiles.map((tile) => (
          <VideoTile
            key={tile.identity}
            participant={tile.participant}
            isLocal={tile.isLocal}
            tick={tick}
          />
        ))}
      </div>
    </div>
  )
}
