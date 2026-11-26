// Pure aggregation over a HexplateDataset: every filter in the UI goes through here, so KPIs,
// charts and the table always agree.
import type { HexplateDataset, MuscleSlug, Split } from '../types/hexplate.ts'
import { MUSCLES, MUSCLE_NAMES, MUSCLE_TARGETS } from '../types/hexplate.ts'
import { addDays, bucketLabel, bucketOf, nextBucket, type DateLang, type Granularity } from './dates.ts'

export type RangeKey = '7d' | '30d' | '90d' | '6m'
export const RANGES: { key: RangeKey; label: string; days: number }[] = [
  { key: '7d', label: '7D', days: 7 },
  { key: '30d', label: '30D', days: 30 },
  { key: '90d', label: '90D', days: 90 },
  { key: '6m', label: '6M', days: 182 },
]

export type SplitFilter = 'all' | Split
export const SPLITS: { key: SplitFilter; label: string }[] = [
  { key: 'all', label: 'All splits' },
  { key: 'push', label: 'Push' },
  { key: 'pull', label: 'Pull' },
  { key: 'legs', label: 'Legs' },
  { key: 'upper', label: 'Upper' },
  { key: 'lower', label: 'Lower' },
]

export interface Window { from: string; to: string; prevFrom: string; prevTo: string; days: number }

export function windowFor(range: RangeKey, today: string): Window {
  const days = RANGES.find((r) => r.key === range)!.days
  const from = addDays(today, -(days - 1))
  return { from, to: today, prevFrom: addDays(from, -days), prevTo: addDays(from, -1), days }
}

const within = (from: string, to: string) => <T extends { d: string }>(r: T) => r.d >= from && r.d <= to

export function select(data: HexplateDataset, range: RangeKey, split: SplitFilter) {
  const win = windowFor(range, data.today)
  const now = within(win.from, win.to)
  const before = within(win.prevFrom, win.prevTo)
  const bySplit = data.sessions.filter((s) => split === 'all' || s.split === split)
  return {
    win,
    sessions: bySplit.filter(now),
    prevSessions: bySplit.filter(before),
    readiness: data.readiness.filter(now),
    prevReadiness: data.readiness.filter(before),
    nutrition: data.nutrition.filter(now),
    prevNutrition: data.nutrition.filter(before),
    loadRatio: data.loadRatio.filter(now),
    prevLoadRatio: data.loadRatio.filter(before),
  }
}
export type Selection = ReturnType<typeof select>

export const sum = (xs: number[]) => xs.reduce((a, b) => a + b, 0)
export const avg = (xs: number[]) => (xs.length ? sum(xs) / xs.length : 0)

/** Relative change in percent, or null when there is nothing to compare against. */
export function pctChange(now: number, before: number): number | null {
  return before ? ((now - before) / Math.abs(before)) * 100 : null
}

export interface Point { key: string; label: string; value: number | null }

/** One point per bucket across the window, empty buckets included (0 for sums, null for averages). */
export function series<T extends { d: string }>(
  rows: T[], value: (r: T) => number, win: Pick<Window, 'from' | 'to'>, g: Granularity, agg: 'sum' | 'avg', lang: DateLang = 'en',
): Point[] {
  const groups = new Map<string, number[]>()
  for (const r of rows) {
    const k = bucketOf(r.d, g)
    const list = groups.get(k)
    if (list) list.push(value(r))
    else groups.set(k, [value(r)])
  }
  const out: Point[] = []
  for (let b = bucketOf(win.from, g); b <= win.to; b = nextBucket(b, g)) {
    const xs = groups.get(b) ?? []
    out.push({ key: b, label: bucketLabel(b, g, lang), value: agg === 'sum' ? sum(xs) : xs.length ? avg(xs) : null })
  }
  return out
}

/**
 * KPI sparkline: one point per day across the window, each the trailing `span`-day sum or mean, so
 * rest days don't turn the line into a comb. `rows` must also cover the `span - 1` days before `from`.
 */
export function trailing<T extends { d: string }>(
  rows: T[], value: (r: T) => number, win: Pick<Window, 'from' | 'to'>, agg: 'sum' | 'avg', span: number,
): (number | null)[] {
  const daily = series(rows, value, { from: addDays(win.from, -(span - 1)), to: win.to }, 'daily', agg)
  return daily.slice(span - 1).map((_, i) => {
    const xs = daily.slice(i, i + span).map((p) => p.value).filter((v): v is number => v !== null)
    return xs.length ? (agg === 'sum' ? sum(xs) : avg(xs)) : null
  })
}

export type TargetStatus = 'below' | 'in' | 'above'
export interface MuscleTargetRow { slug: MuscleSlug; name: string; sets: number; lo: number; hi: number; status: TargetStatus }

/** Average weekly effective sets per muscle over the window vs its range (stats.weekly_muscle_sets). */
export function muscleTargets(sessions: { muscleSets: Partial<Record<MuscleSlug, number>> }[], days: number): MuscleTargetRow[] {
  const weeks = Math.max(1, days / 7)
  return MUSCLES.map((slug) => {
    const [lo, hi] = MUSCLE_TARGETS[slug]
    const sets = Math.round((sum(sessions.map((s) => s.muscleSets[slug] ?? 0)) / weeks) * 10) / 10
    const status: TargetStatus = sets < lo - 1e-9 ? 'below' : sets > hi + 1e-9 ? 'above' : 'in'
    return { slug, name: MUSCLE_NAMES[slug], sets, lo, hi, status }
  })
}
