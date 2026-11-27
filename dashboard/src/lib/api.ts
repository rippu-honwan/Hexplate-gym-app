import type {
  AiConfigMasked,
  BackupStatus,
  BootstrapData,
  CoachChatTurn,
  CoachContextSummary,
  CoachProposal,
  CoachUndoStatus,
  ConnectPayload,
  ExerciseDetail,
  HexplateDataset,
  MotionDetail,
  ReportData,
  ServerAddresses,
  SigningStatus,
  SyncDataPayload,
  WorkoutDetail,
} from '@/types/hexplate'

export class ApiError extends Error {
  readonly code: string
  readonly status: number

  constructor(message: string, code: string, status: number) {
    super(message)
    this.name = 'ApiError'
    this.code = code
    this.status = status
  }
}

export function clientToday(): string {
  const d = new Date()
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

export function clientTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
  } catch {
    return 'UTC'
  }
}

async function requestJson<T>(url: string, init?: RequestInit): Promise<T> {
  const headers = new Headers(init?.headers)
  if (init?.body && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json')
  }
  const resp = await fetch(url, {
    credentials: 'same-origin',
    ...init,
    headers,
  })
  const text = await resp.text()
  let parsed: unknown = null
  if (text) {
    try {
      parsed = JSON.parse(text)
    } catch {
      parsed = null
    }
  }
  if (!resp.ok) {
    const obj = parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : {}
    const msg = typeof obj.error === 'string' && obj.error ? obj.error : text || `Request failed (${resp.status})`
    const code = typeof obj.code === 'string' && obj.code ? obj.code : `http-${resp.status}`
    throw new ApiError(msg, code, resp.status)
  }
  return parsed as T
}

export const api = {
  bootstrap: (today = clientToday()) =>
    requestJson<BootstrapData>(`/analytics/api/bootstrap?today=${encodeURIComponent(today)}`),

  i18n: (lang: 'en' | 'zh') =>
    requestJson<{ lang: 'en' | 'zh'; strings: Record<string, string> }>(`/analytics/api/i18n/${encodeURIComponent(lang)}`),

  dataset: (today = clientToday()) =>
    requestJson<HexplateDataset>(`/analytics/api/dataset?today=${encodeURIComponent(today)}`),

  workoutDetail: (wid: string) =>
    requestJson<WorkoutDetail>(`/analytics/api/workouts/${encodeURIComponent(wid)}`),

  exerciseDetail: (exId: string) =>
    requestJson<ExerciseDetail>(`/analytics/api/exercises/${encodeURIComponent(exId)}`),

  report: (range: '7d' | '4w' | '3m', today = clientToday()) =>
    requestJson<ReportData>(`/analytics/api/report?range=${encodeURIComponent(range)}&today=${encodeURIComponent(today)}`),

  motionDetail: (wid: string) =>
    requestJson<MotionDetail>(`/analytics/api/motion/${encodeURIComponent(wid)}`),

  syncData: () => requestJson<SyncDataPayload>('/analytics/api/data'),

  newPairCode: () =>
    requestJson<{ code: string; expiresInSeconds: number; serverAddresses: ServerAddresses }>('/analytics/api/data/pair', {
      method: 'POST',
    }),

  revokePhone: (hash: string) =>
    requestJson<{ ok: boolean }>('/analytics/api/data/revoke', {
      method: 'POST',
      body: JSON.stringify({ hash }),
    }),

  restoreVersion: (rev: number) =>
    requestJson<{ ok: boolean; rev: number }>('/analytics/api/data/restore', {
      method: 'POST',
      body: JSON.stringify({ rev }),
    }),

  connect: () => requestJson<ConnectPayload>('/analytics/api/connect'),

  addWebhook: (payload: { label: string; url: string; events: string[] }) =>
    requestJson<{ ok: boolean; id: string; secret: string }>('/analytics/api/connect/webhooks', {
      method: 'POST',
      body: JSON.stringify(payload),
    }),

  testWebhook: (id: string) =>
    requestJson<{ ok: boolean; message: string }>(`/analytics/api/connect/webhooks/${encodeURIComponent(id)}/test`, {
      method: 'POST',
    }),

  pauseWebhook: (id: string, paused: boolean) =>
    requestJson<{ ok: boolean; paused: boolean }>(`/analytics/api/connect/webhooks/${encodeURIComponent(id)}/pause`, {
      method: 'POST',
      body: JSON.stringify({ paused }),
    }),

  deleteWebhook: (id: string) =>
    requestJson<{ ok: boolean }>(`/analytics/api/connect/webhooks/${encodeURIComponent(id)}`, {
      method: 'DELETE',
    }),

  setLang: (lang: 'en' | 'zh') =>
    requestJson<{ ok: boolean; lang: 'en' | 'zh'; strings: Record<string, string> }>('/analytics/api/settings/lang', {
      method: 'POST',
      body: JSON.stringify({ lang }),
    }),

  setBackup: (on: boolean) =>
    requestJson<{ ok: boolean; backup: BackupStatus }>('/analytics/api/settings/backup', {
      method: 'POST',
      body: JSON.stringify({ on }),
    }),

  runBackup: () =>
    requestJson<{ ok: boolean; copied: number; backup: BackupStatus }>('/analytics/api/settings/backup/run', {
      method: 'POST',
    }),

  runSigning: () =>
    requestJson<{ ok: boolean; started: boolean; signing: SigningStatus }>('/analytics/api/settings/signing/run', {
      method: 'POST',
    }),

  getAiConfig: () => requestJson<AiConfigMasked>('/analytics/api/settings/ai'),

  saveAiConfig: (payload: {
    baseUrl?: string
    model?: string
    fallbackModel?: string
    apiKey?: string
    clearApiKey?: boolean
    dailyTokenCap?: number
    rateLimitPerMin?: number
    resetToEnv?: boolean
  }) =>
    requestJson<AiConfigMasked>('/analytics/api/settings/ai', {
      method: 'POST',
      body: JSON.stringify(payload),
    }),

  testAiConnection: (payload: { baseUrl?: string; model?: string; fallbackModel?: string; apiKey?: string }) =>
    requestJson<{ ok: boolean; model: string; elapsedMs: number }>('/analytics/api/settings/ai/test', {
      method: 'POST',
      body: JSON.stringify(payload),
    }),

  coachContext: (today = clientToday(), timezone = clientTimezone()) =>
    requestJson<{
      rev: number
      wid: string | null
      summary: CoachContextSummary
      ai: AiConfigMasked
      undo: CoachUndoStatus | null
    }>(`/analytics/api/ai/coach/context?today=${encodeURIComponent(today)}&timezone=${encodeURIComponent(timezone)}`),

  coachPropose: (payload: {
    message: string
    history?: CoachChatTurn[]
    today?: string
    timezone?: string
    lang?: 'en' | 'zh'
  }) =>
    requestJson<CoachProposal>('/analytics/api/ai/coach', {
      method: 'POST',
      body: JSON.stringify({
        today: clientToday(),
        timezone: clientTimezone(),
        ...payload,
      }),
    }),

  coachApply: (payload: {
    ops: Record<string, unknown>[]
    baseRev: number
    baseWid: string | null
    expectedDigests: Record<string, string>
    today?: string
    timezone?: string
    lang?: 'en' | 'zh'
  }) =>
    requestJson<{ ok: boolean; rev: number; wid: string | null; dayDiffs: CoachProposal['dayDiffs']; undo: CoachUndoStatus | null }>(
      '/analytics/api/ai/coach/apply',
      {
        method: 'POST',
        body: JSON.stringify({
          today: clientToday(),
          timezone: clientTimezone(),
          ...payload,
        }),
      },
    ),

  coachUndo: (payload: { tokenId: string; today?: string; timezone?: string }) =>
    requestJson<{ ok: boolean; rev: number; restoredDates: string[]; skippedDates: string[]; removedCloneIds: string[] }>(
      '/analytics/api/ai/coach/undo',
      {
        method: 'POST',
        body: JSON.stringify({
          today: clientToday(),
          timezone: clientTimezone(),
          ...payload,
        }),
      },
    ),
}
