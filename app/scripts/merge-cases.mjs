// Writes HexplateCore's merge-cases.json: pairs of (local, server) copies made from the history
// fixture with real stamped edits (stampChange), the way two devices drift apart.
//   node app/scripts/merge-cases.mjs
import fs from 'node:fs'
import { stampChange } from '../../frontend/src/lib/sync-merge.js'
const FIX = new URL('../HexplateCore/Tests/HexplateCoreTests/Fixtures/', import.meta.url)
const base = JSON.parse(fs.readFileSync(new URL('history-state.json', FIX)))
base._ts = 1763000000000
const clone = x => JSON.parse(JSON.stringify(x))
// One edit of a copy, stamped at `at` like the store does.
const edit = (s, at, fn) => { const next = clone(s); fn(next); next._ts = stampChange(s, next, at); return next }
const w0 = base.workouts[0]
const cases = [
  { name: 'same', local: base, server: base },
  { name: 'local logged a workout', local: edit(base, 1763000100000, s => s.workouts.push({ ...clone(w0), id: 'new-local', d: '2026-11-17', start: 1763300000000 })), server: base },
  { name: 'both logged', local: edit(base, 1763000100000, s => s.workouts.push({ ...clone(w0), id: 'a', d: '2026-11-17' })), server: edit(base, 1763000200000, s => s.workouts.push({ ...clone(w0), id: 'b', d: '2026-11-18' })) },
  { name: 'server deleted a workout', local: base, server: edit(base, 1763000200000, s => s.workouts.shift()) },
  { name: 'local deleted, server changed a setting', local: edit(base, 1763000100000, s => s.workouts.pop()), server: edit(base, 1763000300000, s => { s.restSec = 120 }) },
  { name: 'both changed a setting', local: edit(base, 1763000400000, s => { s.restSec = 60 }), server: edit(base, 1763000300000, s => { s.restSec = 120; s.unit = 'kg' }) },
  { name: 'server has nothing', local: base, server: { workouts: [] } },
]
fs.writeFileSync(new URL('merge-cases.json', FIX), JSON.stringify(cases))
console.log('wrote', cases.length, 'cases')
