// Data shapes for the full-parity Hexplate web dashboard, aligned with:
// - server/hexserver/analytics_api.py
// - server/hexserver/coach_web.py
// - server/hexserver/stats.py & schedule.py & motion.py

/** Main muscles in body order, as stats.py DEFAULT_TARGETS lists them. */
export const MUSCLES = [
  'chest', 'upper-back', 'deltoids', 'biceps', 'triceps',
  'quadriceps', 'hamstring', 'gluteal', 'calves', 'abs',
] as const
export type MuscleSlug = (typeof MUSCLES)[number]

/** Weekly working-set range per muscle (stats.py DEFAULT_TARGETS, lib/muscle-targets.js). */
export const MUSCLE_TARGETS: Record<MuscleSlug, readonly [lo: number, hi: number]> = {
  chest: [10, 20], 'upper-back': [10, 20], deltoids: [8, 20], biceps: [8, 18], triceps: [6, 16],
  quadriceps: [8, 18], hamstring: [6, 16], gluteal: [4, 16], calves: [8, 16], abs: [6, 16],
}

export const MUSCLE_NAMES: Record<MuscleSlug, string> = {
  chest: 'Chest', 'upper-back': 'Upper back', deltoids: 'Shoulders', biceps: 'Biceps', triceps: 'Triceps',
  quadriceps: 'Quads', hamstring: 'Hamstrings', gluteal: 'Glutes', calves: 'Calves', abs: 'Abs',
}

export type Split = 'push' | 'pull' | 'legs' | 'upper' | 'lower'
export type SessionStatus = 'pr' | 'completed' | 'deload' | 'recovery'

export interface Session {
  id: string
  d: string
  routine: string
  split: Split
  minutes: number
  vol: number
  workSets: number
  prs: number
  topExercise: string
  muscleSets: Partial<Record<MuscleSlug, number>>
  status: SessionStatus
}

export interface MuscleDetail {
  fatigue: number
  lastSessionSets: number
  hoursToRecovered: number
}

export interface GlobalLoad {
  acute: number
  chronic: number
  ratio: number | null
}

export interface LoadSummary {
  muscles: Record<MuscleSlug, MuscleDetail>
  global: GlobalLoad
}

export type ReadinessVerdict = 'good' | 'light' | 'rest'

export interface ReadinessDay {
  d: string
  score: number
  verdict: ReadinessVerdict
  sleepHours: number
  hrvMs: number
  rhrBpm: number
}

export interface Macros {
  kcal: number
  protein: number
  carbs: number
  fat: number
}

export type Goals = Macros

export interface NutritionDay {
  d: string
  totals: Macros
  meals: number
}

export interface WeeklyProgress {
  workoutsLeft: { left: number; of: number; done: number } | null
  streak: { current: number; best: number; freezes: number; weekDone: boolean; next: number | null }
  muscleSets: { slug: string; name: string; sets: number; lo: number; hi: number; status: 'below' | 'in' | 'above' }[]
}

export interface PlanDayItem {
  date: string
  weekday: number
  isToday: boolean
  routineIds: string[]
  routineNames: string[]
  isRest: boolean
  isAIClone: boolean
}

export interface RoutineExerciseItem {
  id: string
  name: string
  sets: number
  reps: number | null
  repsMin: number | null
  repsMax: number | null
  weight: number | null
  sec: number | null
  min: number | null
  restSec: number | null
  mode: string | null
  note: string | null
}

export interface RoutineItem {
  id: string
  name: string
  exerciseCount: number
  totalSets: number
  exercises: RoutineExerciseItem[]
}

export interface PlanData {
  mode: 'week' | 'rotation'
  weekStart: number
  weekTarget: number | null
  weekDays: PlanDayItem[]
  rotation: {
    sequence: { id: string; name: string; isRest: boolean }[]
    queueIds: string[]
    doneIds: string[]
    remainingIds: string[]
  } | null
  routines: RoutineItem[]
}

export interface TrainedExerciseSummary {
  id: string
  name: string
  sessions: number
  lastDate: string
  bestE1rm: number | null
  bestWeight: number | null
  bestReps: number | null
}

export interface BodyData {
  unit: string
  weighIns: { d: string; w: number }[]
  latest: { d: string; w: number } | null
  delta30: number | null
  delta90: number | null
  goal: number | null
  measurements: {
    key: string
    name: string
    unit: string
    latest: number
    latestDate: string
    first: number
    delta: number | null
    count: number
  }[]
}

export interface StatsData {
  heatmap: { d: string; vol: number; count: number }[]
  topExercises: { id: string; name: string; sets: number; sessions: number }[]
  weeklyVolume: { week: string; vol: number; workouts: number; sets: number }[]
}

export interface RepsData {
  setsRecorded: number
  exercisesCount: number
  confirmed: number
  exact: number
  exactPct: number | null
  mae: number | null
  byExercise: { id: string; name: string; sets: number; checked: number; exact: number; mae: number | null }[]
  latest: { atMs: number; exId: string; exercise: string; weight: number | null; auto: number | null; final: number | null; off: number | null }[]
}

export interface MotionListData {
  workouts: { id: string; date: string; name: string; exercisesSummary: string; fileCount: number }[]
  unlinkedCount: number
}

export interface HexplateDataset {
  source: 'mock' | 'local'
  hasData?: boolean
  rev?: number
  unit?: string
  today: string
  sessions: Session[]
  readiness: ReadinessDay[]
  nutrition: NutritionDay[]
  goals: Goals
  bodyweightKg: number
  hasBodyweight?: boolean
  loadRatio: { d: string; ratio: number }[]
  recovery: LoadSummary
  weeklyProgress?: WeeklyProgress
  plan?: PlanData
  exercises?: TrainedExerciseSummary[]
  body?: BodyData
  stats?: StatsData
  reps?: RepsData
  motion?: MotionListData
}

export interface WorkoutDetail {
  id: string
  date: string
  name: string
  minutes: number | null
  volume: number
  workSets: number
  bodyweight: number | null
  note: string | null
  unit: string
  prsCount: number
  hasMotion: boolean
  entries: {
    id: string
    name: string
    isPr: boolean
    best: { e1rm: number; weight: number; reps: number } | null
    sets: {
      index: number | null
      side: 'L' | 'R' | null
      warmup: boolean
      done: boolean
      weight: number | null
      reps: number | null
      sec: number | null
      min: number | null
      rir: number | null
      hrAvg: number | null
    }[]
  }[]
}

export interface ExerciseDetail {
  id: string
  name: string
  unit: string
  sessionsCount: number
  firstDate: string
  lastDate: string
  bestE1rm: { est: number; w: number; r: number; d: string } | null
  heaviest: { w: number; r: number; d: string } | null
  sessions: { d: string; workoutId: string; e1rm: number | null; weight: number | null; reps: number | null; sets: number; volume: number; pr: boolean }[]
}

export interface ReportData {
  range: '7d' | '4w' | '3m'
  from: string
  to: string
  days: number
  unit: string
  current: { workouts: number; volume: number; sets: number; minutes: number }
  previous: { workouts: number; volume: number; sets: number; minutes: number }
  records: { exerciseId: string; exercise: string; weight: number | null; reps: number | null; e1rm: number | null; date: string; workoutId: string }[]
  muscles: { slug: string; name: string; sets: number }[]
  bodyweight: { d: string; w: number }[]
  workouts: { id: string; date: string; name: string; minutes: number | null; sets: number; volume: number; exercises: string[] }[]
}

export interface MotionDetail {
  id: string
  date: string
  name: string
  summary: { setsRecorded: number; exercisesCount: number; cleanSets: number; durationSec: number; totalRows: number }
  exercises: { index: number; exId: string; name: string; sets: number; clean: number; flags: string[] }[]
  flags: { flag: string; count: number }[]
  hzPoints: { label: string; exercise: string; value: number; flagged: boolean }[]
  gapPoints: { label: string; exercise: string; value: number; flagged: boolean }[]
  headPoints: { label: string; exercise: string; value: number; flagged: boolean }[]
  tailPoints: { label: string; exercise: string; value: number; flagged: boolean }[]
  traces: { exId: string; name: string; label: string; reps: number | null; auto: number | null; points: { t: number; ax: number; ay: number; az: number; mag: number }[]; ticks: number[] }[]
  liveAccuracy: { exId: string; name: string; sets: number; meanReps: number; mae: number; exactPct: number; bias: number }[]
  scatter: { label: string; exercise: string; logged: number; live: number }[]
  findings: string[]
}

export interface ServerAddresses {
  local: string
  ip: string | null
  port: number
}

export interface SyncDataPayload {
  tokens: { hash: string; index: number; createdAt: number }[]
  versions: { rev: number; receivedAt: number; workouts: number; bytes: number }[]
  serverAddresses: ServerAddresses
}

export interface WebhookItem {
  id: string
  label: string
  url: string
  maskedUrl: string
  events: string[]
  paused: boolean
  created_at: number
  last_at: number | null
  last_ok: boolean | null
  last_msg: string | null
}

export interface McpInfo {
  configJson: string
  claudeDesktopPath: string
  claudeCodePath: string
  dbExists: boolean
  tools: { name: string; description: string }[]
}

export interface ConnectPayload {
  webhooks: WebhookItem[]
  events: { key: string; label: string }[]
  mcp: McpInfo
}

export interface BackupStatus {
  on: boolean
  folder: string
  in_icloud: boolean
  copies: number
  motion: number
  at: number | null
  error: string | null
}

export interface SigningStatus {
  available: boolean
  running: boolean
  stage: string
  at: number | null
  expires: number | null
  device: string | null
  error: string | null
}

export interface AiConfigMasked {
  configured: boolean
  source: 'file' | 'env' | 'mixed' | 'none'
  baseUrl: string | null
  model: string
  fallbackModel?: string
  hasKey: boolean
  keyHint: string | null
  dailyTokenCap: number
  rateLimitPerMin: number
  dailyTokensUsed: number
  envFallbackAvailable: boolean
}

export interface CoachUndoStatus {
  tokenId: string
  acceptedAt: number | null
  acceptedDay: string
  touchedDates: string[]
  createdCloneIds: string[]
  status: 'available' | 'blockedByActive' | 'blockedByLoggedWorkout' | 'expired'
}

export interface CoachContextSummary {
  today: string
  scheduleMode: 'week' | 'rotation'
  recentWorkoutsCount: number
  topFatigued: { slug: string; fatigue: number; hoursToRecovered: number }[]
  todayNutrition: { total: Macros; goals: { kcal?: number; protein?: number; carbs?: number; fat?: number } }
  plannedNext7d: { date: string; weekday: string; routineName?: string; isRest: boolean; isAIClone?: boolean; locked?: string }[]
  todayLockedReason: string
}

export interface CoachDayDiff {
  date: string
  before: { isRest: boolean; routineId: string | null; routineName: string | null; isAIClone: boolean; exerciseCount: number }
  after: { isRest: boolean; routineId: string | null; routineName: string | null; isAIClone: boolean; exerciseCount: number }
  slotChanges: (
    | { kind: 'swapped'; slotIndex: number; fromExerciseId: string; fromName: string; toExerciseId: string; toName: string; sets: number; reps: number | null }
    | { kind: 'setsChanged'; slotIndex: number; exerciseId: string; name: string; beforeSets: number; afterSets: number; beforeReps: number | null; afterReps: number | null }
    | { kind: 'added'; slotIndex: number; exerciseId: string; name: string; sets: number; reps: number | null }
  )[]
  reasons: string[]
}

export interface CoachChatTurn {
  role: 'user' | 'assistant'
  content: string
}

export interface CoachProposal {
  answer: string
  note: string | null
  changes: Record<string, unknown>[]
  dayDiffs: CoachDayDiff[]
  touchedDates: string[]
  expectedDigests: Record<string, string>
  hasChanges: boolean
  baseRev: number
  baseWid: string | null
  summary: CoachContextSummary
}

export interface BootstrapData {
  hasData: boolean
  hasDocument: boolean
  rev: number
  wid: string | null
  syncedAt: number | null
  lang: 'en' | 'zh'
  languages: { code: 'en' | 'zh'; label: string }[]
  strings: Record<string, string>
  unit: string
  ai: AiConfigMasked
  aiUndo: CoachUndoStatus | null
  backup: BackupStatus
  signing: SigningStatus
  mcp: McpInfo
  pairedCount: number
  webhookCount: number
  serverAddresses: ServerAddresses
}
