// Self-check for the aggregation layer: `npm run check:data` (Node 22 strips the types).
import assert from 'node:assert/strict'
import { buildMockDataset } from '../data/mock.ts'
import { muscleTargets, select, series, sum, trailing } from './analytics.ts'

const data = buildMockDataset()
const all7 = select(data, '7d', 'all')
const all6m = select(data, '6m', 'all')
const legs6m = select(data, '6m', 'legs')

// Ranges and splits genuinely change the selection.
assert.equal(all7.win.days, 7)
assert.ok(all7.sessions.length > 0 && all7.sessions.length < all6m.sessions.length)
assert.ok(legs6m.sessions.length > 0 && legs6m.sessions.every((s) => s.split === 'legs'))
assert.ok(all6m.prevSessions.length > 0, 'previous period exists for deltas')
assert.ok(all6m.sessions.every((s) => s.d >= all6m.win.from && s.d <= all6m.win.to))

// Every granularity keeps the window total.
for (const g of ['daily', 'weekly', 'monthly'] as const) {
  const pts = series(all6m.sessions, (s) => s.vol, all6m.win, g, 'sum')
  assert.equal(sum(pts.map((p) => p.value ?? 0)), sum(all6m.sessions.map((s) => s.vol)), g)
}
assert.equal(series(all7.sessions, (s) => s.vol, all7.win, 'daily', 'sum').length, 7)

// A legs-only filter leaves no chest work.
const legsTargets = muscleTargets(legs6m.sessions, legs6m.win.days)
assert.equal(legsTargets.find((r) => r.slug === 'chest')!.sets, 0)
assert.ok(legsTargets.find((r) => r.slug === 'quadriceps')!.sets > 0)

console.log('analytics check passed:', all6m.sessions.length, 'sessions in 6M,', legs6m.sessions.length, 'legs')

// Sparklines: one point per window day, and a 1-day span is just the daily series.
const tr = trailing(all6m.sessions.concat(all6m.prevSessions), (s) => s.vol, all6m.win, 'sum', 7)
assert.equal(tr.length, all6m.win.days)
assert.deepEqual(trailing(all7.sessions, (s) => s.vol, all7.win, 'sum', 1), series(all7.sessions, (s) => s.vol, all7.win, 'daily', 'sum').map((p) => p.value))
console.log('trailing sparkline check passed')
