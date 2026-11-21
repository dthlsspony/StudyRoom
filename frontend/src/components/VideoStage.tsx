import { useCallback, useEffect, useRef, useState } from 'react'
import { Room, RoomEvent, Track } from 'livekit-client'
import type { Participant } from 'livekit-client'
import { api, ApiError } from '../lib/api'
import { getMediaDiagnostics, mediaProblemMessage } from '../lib/media'

export interface StageParticipant {
  identity: string
  name: string
  isLocal: boolean
  isHost: boolean
  micMuted: boolean
  cameraMuted: boolean
  sharingScreen: boolean
}

interface VideoStageProps {
  roomId: number
  isLive: boolean
  canPublish: boolean
  /** identity ведущего (id владельца комнаты) */
  hostIdentity: string
  onStreamUnavailable?: () => void
  onParticipantsChange?: (participants: StageParticipant[]) => void
}

interface Tile {
  identity: string
  name: string
  isLocal: boolean
  isHost: boolean
  participant: Participant
  micMuted: boolean
  cameraMuted: boolean
  sharingScreen: boolean
}

type TileFilter = 'camera' | 'screen'

/**
 * Состояния публикации участника: заглушён ли микрофон, камера и демонстрирует ли экран.
 */
function publishStates(participant: Participant) {
  let micMuted = true
  let cameraMuted = true
  let sharingScreen = false

  participant.trackPublications.forEach((publication) => {
    const track = publication.track
    if (!track) {
      return
    }
    const muted = publication.isMuted || track.isMuted

    if (track.kind === Track.Kind.Audio) {
      micMuted = muted
    } else if (track.kind === Track.Kind.Video) {
      if (String(track.source) === 'screen_share') {
        sharingScreen = !muted
      } else {
        cameraMuted = muted
      }
    }
  })

  return { micMuted, cameraMuted, sharingScreen }
}

/**
 * Метаданные участника приходят строкой JSON: {"muted": true} — метка,
 * поставленная ведущим.
 */
function parseMetadata(metadata?: string | null): { muted?: boolean } {
  if (!metadata) {
    return {}
  }
  try {
    const parsed = JSON.parse(metadata)
    return typeof parsed === 'object' && parsed !== null ? parsed : {}
  } catch {
    return {}
  }
}

function VideoTile({
  participant,
  isLocal,
  isHost,
  filter,
  tick,
}: {
  participant: Participant
  isLocal: boolean
  isHost: boolean
  filter: TileFilter
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

      // Экран приходит отдельным видеотреком с источником screen_share.
      const isScreen = String(track.source) === 'screen_share'
      if ((filter === 'screen') !== isScreen) {
        return
      }

      const element = track.attach()
      element.classList.add(isScreen ? 'lk-screen' : 'lk-video')

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
  }, [participant, tick, filter, isLocal])

  const name = participant.name || participant.identity

  return (
    <div className={isHost ? 'video-tile video-tile-host' : 'video-tile'}>
      <div className="video-track" ref={containerRef} />
      <span className="video-label">
        {name}
        {isLocal ? ' (вы)' : ''}
        {isHost ? ' · ведущий' : ''}
      </span>
    </div>
  )
}

export default function VideoStage({
  roomId,
  isLive,
  canPublish,
  hostIdentity,
  onStreamUnavailable,
  onParticipantsChange,
}: VideoStageProps) {
  const roomRef = useRef<Room | null>(null)
  const [tiles, setTiles] = useState<Tile[]>([])
  const [screenTile, setScreenTile] = useState<Tile | null>(null)
  const [status, setStatus] = useState<'idle' | 'connecting' | 'connected' | 'error'>('idle')
  const [error, setError] = useState<string | null>(null)
  const [mediaWarning, setMediaWarning] = useState<string | null>(null)
  const [mediaHint, setMediaHint] = useState<string | null>(null)
  const [micEnabled, setMicEnabled] = useState(false)
  const [cameraEnabled, setCameraEnabled] = useState(false)
  const [screenSharing, setScreenSharing] = useState(false)
  const [mutedByHost, setMutedByHost] = useState(false)
  const [tick, setTick] = useState(0)

  // Колбэки и флаги держим в refs: иначе родитель создаёт новые функции при
  // каждом рендере, connect() меняется вместе с ними, и эффект подключения
  // зацикливается.
  const isLiveRef = useRef(isLive)
  const streamUnavailableRef = useRef(onStreamUnavailable)
  const participantsChangeRef = useRef(onParticipantsChange)

  useEffect(() => {
    isLiveRef.current = isLive
    streamUnavailableRef.current = onStreamUnavailable
    participantsChangeRef.current = onParticipantsChange
  }, [isLive, onStreamUnavailable, onParticipantsChange])

  const syncTiles = useCallback((room: Room) => {
    const list: Tile[] = []
    let screen: Tile | null = null

    const push = (participant: Participant, local: boolean) => {
      const states = publishStates(participant)
      const tile: Tile = {
        identity: participant.identity,
        name: participant.name || participant.identity,
        isLocal: local,
        isHost: participant.identity === hostIdentity,
        participant,
        ...states,
      }
      if (states.sharingScreen) {
        screen = tile
      }
      list.push(tile)
    }

    room.remoteParticipants.forEach((participant) => push(participant, false))
    push(room.localParticipant, true)

    setTiles(list)
    setScreenTile(screen)
    setTick((value) => value + 1)

    const report: StageParticipant[] = list.map((tile) => ({
      identity: tile.identity,
      name: tile.name,
      isLocal: tile.isLocal,
      isHost: tile.isHost,
      micMuted: tile.micMuted,
      cameraMuted: tile.cameraMuted,
      sharingScreen: tile.sharingScreen,
    }))
    participantsChangeRef.current?.(report)
  }, [hostIdentity])

  const disconnect = useCallback(() => {
    const room = roomRef.current
    if (room) {
      room.removeAllListeners()
      void room.disconnect()
      roomRef.current = null
    }
    setTiles([])
    setScreenTile(null)
    setStatus('idle')
    setMicEnabled(false)
    setCameraEnabled(false)
    setScreenSharing(false)
    setMutedByHost(false)
    setMediaWarning(null)
    participantsChangeRef.current?.([])
  }, [])

  const connect = useCallback(async () => {
    setStatus('connecting')
    setError(null)
    setMediaWarning(null)

    try {
      const access = await api.stream.access(roomId)

      if (!access.is_live || !access.token) {
        if (isLiveRef.current) {
          streamUnavailableRef.current?.()
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
      room.on(RoomEvent.LocalTrackUnpublished, () => syncTiles(room))

      // Ведущий может заглушить участника: сервер ставит запрет на публикацию,
      // а в metadata приходит метка — клиент сам выключает микрофон.
      room.on(RoomEvent.ParticipantMetadataChanged, (_previousMetadata, participant) => {
        const muted = parseMetadata(participant?.metadata).muted === true

        if (participant && participant.identity === room.localParticipant.identity) {
          setMutedByHost(muted)
          if (muted) {
            void room.localParticipant.setMicrophoneEnabled(false).then(() => {
              setMicEnabled(false)
              syncTiles(room)
            })
          }
        }
        syncTiles(room)
      })

      room.on(RoomEvent.Disconnected, () => {
        setStatus('idle')
        setTiles([])
      })

      await room.connect(access.ws_url, access.token, { autoSubscribe: true })
      setError(null)
      syncTiles(room)
      setStatus('connected')

      if (canPublish) {
        try {
          await room.localParticipant.setMicrophoneEnabled(true)
          await room.localParticipant.setCameraEnabled(true)
          setMicEnabled(true)
          setCameraEnabled(true)
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
        e instanceof ApiError ? e.message : e instanceof Error ? e.message : 'Не удалось подключиться к эфиру',
      )
    }
  }, [roomId, canPublish, syncTiles])

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
      if (cancelled || cameraEnabled) {
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
      syncTiles(room)
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
      syncTiles(room)
    } catch {
      const diagnostics = await getMediaDiagnostics()
      setMediaWarning(
        mediaProblemMessage(diagnostics) ??
          'Не удалось включить камеру: проверьте доступ к устройству в браузере.',
      )
    }
  }

  async function toggleScreenShare() {
    const room = roomRef.current
    if (!room) {
      return
    }
    try {
      const next = !screenSharing
      await room.localParticipant.setScreenShareEnabled(next)
      setScreenSharing(next)
      setMediaWarning(null)
      syncTiles(room)
    } catch (e) {
      setMediaWarning(
        e instanceof Error
          ? `Не удалось запустить демонстрацию экрана: ${e.message}`
          : 'Не удалось запустить демонстрацию экрана',
      )
    }
  }

  // Плитка ведущего показывается отдельно, чтобы окна участников не стояли рядом с ней.
  const hostTile = tiles.find((tile) => tile.isHost) ?? null
  const otherTiles = tiles.filter((tile) => !tile.isHost)

  return (
    <div className="video-stage">
      <div className="panel-head">
        <h2>Эфир</h2>
        <div className="stage-actions">
          {status === 'connected' && (
            <>
              {canPublish && (
                <button
                  type="button"
                  className={screenSharing ? 'ghost active' : 'ghost'}
                  onClick={() => void toggleScreenShare()}
                >
                  {screenSharing ? 'Остановить показ экрана' : 'Показать экран'}
                </button>
              )}
              <button
                type="button"
                className={micEnabled ? 'ghost' : 'ghost danger'}
                onClick={() => void toggleMic()}
                disabled={mutedByHost}
              >
                {mutedByHost
                  ? 'Вас заглушил ведущий'
                  : micEnabled
                    ? 'Выключить микрофон'
                    : 'Включить микрофон'}
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

      {screenTile && (
        <div className="screen-share">
          <VideoTile
            participant={screenTile.participant}
            isLocal={screenTile.isLocal}
            isHost={screenTile.isHost}
            filter="screen"
            tick={tick}
          />
        </div>
      )}

      {hostTile && (
        <div className="host-tile">
          <VideoTile
            participant={hostTile.participant}
            isLocal={hostTile.isLocal}
            isHost
            filter="camera"
            tick={tick}
          />
        </div>
      )}

      {otherTiles.length > 0 && (
        <div className="video-grid">
          {otherTiles.map((tile) => (
            <VideoTile
              key={tile.identity}
              participant={tile.participant}
              isLocal={tile.isLocal}
              isHost={false}
              filter="camera"
              tick={tick}
            />
          ))}
        </div>
      )}
    </div>
  )
}
