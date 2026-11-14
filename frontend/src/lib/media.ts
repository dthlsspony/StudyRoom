export interface MediaDiagnostics {
  /** Защищённый контекст: https:// или http://localhost. */
  secureContext: boolean
  /** Доступен ли API getUserMedia. */
  hasMediaDevices: boolean
  /** Текущее разрешение браузера на камеру. */
  permission: 'granted' | 'denied' | 'prompt' | 'unknown'
}

/**
 * Собирает состояние доступа к камере и микрофону, чтобы объяснить
 * пользователю, почему браузер не спрашивает разрешение.
 */
export async function getMediaDiagnostics(): Promise<MediaDiagnostics> {
  const diagnostics: MediaDiagnostics = {
    secureContext: typeof window !== 'undefined' ? window.isSecureContext : false,
    hasMediaDevices: Boolean(navigator.mediaDevices?.getUserMedia),
    permission: 'unknown',
  }

  try {
    if (navigator.permissions?.query) {
      const status = await navigator.permissions.query({ name: 'camera' as PermissionName })
      diagnostics.permission = status.state as MediaDiagnostics['permission']
    }
  } catch {
    diagnostics.permission = 'unknown'
  }

  return diagnostics
}

/**
 * Человеческое объяснение проблемы с доступом к устройствам.
 * Возвращает null, если всё в порядке.
 */
export function mediaProblemMessage(diagnostics: MediaDiagnostics): string | null {
  if (!diagnostics.secureContext) {
    return 'Страница открыта не как защищённая: браузер разрешает доступ к камере только на https:// или на http://localhost. Откройте приложение по адресу localhost.'
  }

  if (!diagnostics.hasMediaDevices) {
    return 'Браузер не даёт доступ к камере и микрофону на этой странице: нужен https:// или http://localhost.'
  }

  if (diagnostics.permission === 'denied') {
    return 'Доступ к камере заблокирован для этого сайта — браузер больше не будет спрашивать. Разрешите его в настройках: значок камеры в адресной строке → «Разрешить», затем перезагрузите страницу.'
  }

  return null
}
