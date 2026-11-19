// Writes tests/fixtures/webhook-golden.json from openGym's own webhook code (api/integrations),
// which hexserver/webhooks.py ports. Run from the repo root, with frontend/ linked to the openGym checkout:
//   node server/scripts/webhook-golden.mjs
import { realpathSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const repo = join(dirname(fileURLToPath(import.meta.url)), '../..')
const og = dirname(realpathSync(join(repo, 'frontend')))
const { detectEvents, eventData, envelope, testData } = await import(join(og, 'api/integrations/events.js'))
const { signature } = await import(join(og, 'api/integrations/crypto.js'))

const now = Date.parse('2026-05-30T18:00:00Z')
const day = 86400000
const s = (w, r, more = {}) => ({ w, r, done: true, ...more })
const w1 = { id: 'w1', d: '2026-05-30', name: 'Upper A', start: now - 2 * 3600e3, end: now - 3600e3, bw: 71.2, note: 'Felt strong',
  entries: [
    { id: '0025', sets: [s(40, 10, { warmup: true }), s(60, 8, { rir: 2 }), s(60, 7), { w: 60, r: 6 }] },
    { id: '0336', sets: [{ sides: { L: { w: 12, r: 10, done: true }, R: { w: 12, r: 9, done: true } }, w: 12, r: 10 }] },
    { id: 'c1', sets: [s(20, 12, { phase: 'work' }), s(10, 15, { phase: 'warmup' })] },
    { id: '0685', sets: [{ min: 20, speed: 9.5, incline: 2, done: true }] },
    { id: '0001', sets: [{ sec: 45, done: true, rpe: 8 }] },
  ], prs: ['0025', 'c1'] }
const w2 = { id: 'w2', d: '2026-05-29', name: 'Lower', start: now - 30 * 3600e3, end: now - 29 * 3600e3, entries: [{ id: '0043', sets: [s(100, 5), s(102.5, 5)] }] }
const old = { id: 'w0', d: '2026-04-01', entries: [{ id: '0043', sets: [s(90, 5)] }], prs: ['0043'] }
const noTime = { id: 7, d: '2026-05-28', entries: [] }
const future = { id: 'wf', d: '2026-06-03', entries: [] }
const doc = (workouts, bodyweight = [], more = {}) => ({ unit: 'kg', customEx: [{ id: 'c1', name: 'My cable fly' }], workouts, bodyweight, ...more })

const cases = [
  ['first sync', null, doc([old, w2, w1], [{ d: '2026-05-30', w: 71.2, t: now - 5 * 3600e3 }])],
  ['one new workout', doc([old, w2]), doc([old, w2, w1])],
  ['nothing new', doc([old, w2]), doc([old, w2])],
  ['old and future skipped', doc([]), doc([old, future, noTime])],
  ['weigh-in changed and new', doc([], [{ d: '2026-05-29', w: 72 }, { d: '2026-05-30', w: 71 }]),
    doc([], [{ d: '2026-05-29', w: 71.8 }, { d: '2026-05-30', w: 71 }, { d: '2026-05-01', w: 73 }, { d: 'bad', w: 70 }, { d: '2026-05-30', w: 'x' }])],
  ['pounds', doc([]), doc([w2], [{ d: '2026-05-30', w: 160 }], { unit: 'lb' })],
  ['more than ten', doc([]), doc(Array.from({ length: 13 }, (_, i) => ({ id: 'm' + i, d: '2026-05-30', end: now - (13 - i) * 60e3, entries: [] })))],
]
const out = {
  now,
  cases: cases.map(([name, prev, next]) => ({
    name, prev, next,
    events: detectEvents(prev, next, { now }).map(ev => ({ type: ev.type, entity: ev.entity, at: ev.at, data: eventData(ev, next) })),
  })),
  test: Object.fromEntries(['workout.finished', 'workout.pr', 'weighin.logged'].map(t => [t, testData(t, now)])),
  envelope: envelope({ id: 'd1', type: 'workout.finished', data: { a: 1 }, at: now, test: true }),
  signature: { secret: 'whsec_test', body: '{"a":1}', ts: 1780000000, header: signature('whsec_test', '{"a":1}', 1780000000) },
}
writeFileSync(join(repo, 'server/tests/fixtures/webhook-golden.json'), JSON.stringify(out, null, 1) + '\n')
console.log('wrote', out.cases.length, 'cases')
