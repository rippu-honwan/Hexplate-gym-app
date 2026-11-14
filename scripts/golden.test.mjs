// Writes the numbers and labels the original JavaScript produces for a state file, so the Swift
// port (HexplateCore) can be tested against the code it replaces rather than against a reading
// of it. Run through the frontend's own vitest (see golden.sh); nothing in frontend/ is changed.
//
//   IN   a state document (JSON)
//   OUT  where to write the golden file
//   STAMP_IN, STAMP_OUT  optional: change cases and where to write how the JS stamps them
//   SCHEDULE_IN, SCHEDULE_OUT  optional: schedule cases and what the JS reads and does for them
//   CATALOGUE_OUT  optional: where to write the exercise index the app bundles (text only)
import { readFileSync, writeFileSync } from 'node:fs'
import { setsDone, sessionVolume, workoutDuration, setLabel } from '../../frontend/src/lib/history.js'
import { hasCompletedWork, isWarmupRow } from '../../frontend/src/lib/workout-model.js'
import { viewEntry } from '../../frontend/src/lib/ex-unit.js'
import { speedUnitOf } from '../../frontend/src/lib/speed.js'
import { hrLabel } from '../../frontend/src/lib/heart-rate.js'
import { setWeightDecimals, fmtVol, exerciseNameText, durPart } from '../../frontend/src/lib/format.js'
import { EXIDX, CATALOGUE, registerCustom } from '../../frontend/src/lib/exercises.js'
import { EXALIAS } from '../../frontend/src/lib/exercises-data.js'
import * as Q from '../../frontend/src/lib/queue.js'
import * as R from '../../frontend/src/lib/rotation.js'
import { workoutsLeft } from '../../frontend/src/lib/week-left.js'
import { effectiveRoutineIds, nextTrainingDay } from '../../frontend/src/lib/history.js'
import { stampChange } from '../../frontend/src/lib/sync-merge.js'

// The settings a screen's numbers depend on; each variant is the same history under other settings.
const VARIANTS = {
  asStored: {},
  countWarmups: { volumeWarmups: true },
  countBodyweight: { volumeBodyweight: true },
  twoDecimals: { wdec: 2 },
}

function golden(S) {
  setWeightDecimals(S.wdec)
  registerCustom(S.customEx || [])
  return S.workouts.map(w => ({
    id: w.id,
    setsDone: setsDone(w),
    durationMs: workoutDuration(w),
    durationText: durPart(workoutDuration(w)).join(''),
    volume: sessionVolume(w, S),
    volumeText: fmtVol(sessionVolume(w, S), S.unit),
    entries: w.entries.map(e => {
      const ve = viewEntry(S, e)
      return {
        id: e.id,
        name: EXIDX[e.id] ? exerciseNameText(EXIDX[e.id]) : (e.n || e.id),
        sets: ve.sets.filter(hasCompletedWork).map(s => ({
          label: setLabel(e.id, s, e.target, speedUnitOf(S)),
          hr: hrLabel(s),
          warmup: isWarmupRow(s),
        })),
      }
    }),
  }))
}

it('writes the golden file', () => {
  const state = JSON.parse(readFileSync(process.env.IN, 'utf8'))
  const out = {}
  for (const [name, patch] of Object.entries(VARIANTS)) out[name] = golden({ ...state, ...patch })
  writeFileSync(process.env.OUT, JSON.stringify(out, null, 1) + '\n')
})

// The exercise index Hexplate bundles: what its logic and labels read of each catalogue exercise.
// Text only; no media is read or copied.
it('writes the exercise index', () => {
  if (!process.env.CATALOGUE_OUT) return
  const exercises = CATALOGUE.map(e => ({ id: e.id, n: e.n, bp: e.bp, eq: e.eq }))
  writeFileSync(process.env.CATALOGUE_OUT, JSON.stringify({ exercises, aliases: EXALIAS }) + '\n')
})

// How the store stamps a change for sync (lib/sync-merge.js stampChange, store/useStore.js update):
// each case's `next` after stamping, with the time used as its `_ts`.
it('writes the stamp golden file', () => {
  if (!process.env.STAMP_IN) return
  const cases = JSON.parse(readFileSync(process.env.STAMP_IN, 'utf8'))
  const out = cases.map(c => {
    const next = structuredClone(c.next)
    next._ts = stampChange(structuredClone(c.prev), next, c.wall)
    return { name: c.name, next }
  })
  writeFileSync(process.env.STAMP_OUT, JSON.stringify(out, null, 1) + '\n')
})

// The schedule: what each day holds, the queue and the rotation, before and after each change.
it('writes the schedule golden file', () => {
  if (!process.env.SCHEDULE_IN) return
  const cases = JSON.parse(readFileSync(process.env.SCHEDULE_IN, 'utf8'))
  const addDays = (iso, n) => { const d = new Date(iso + 'T12:00:00'); d.setDate(d.getDate() + n); return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0') }
  const reads = (S, today) => {
    const next = nextTrainingDay(S, today)
    return {
      mode: R.scheduleModeOf(S), rotationIds: R.rotationIds(S), sequence: R.sequenceOf(S), recovery: R.queueRecovery(S),
      days: Array.from({ length: 14 }, (_, i) => addDays(today, i - 3)).map(iso => ({ iso, ids: effectiveRoutineIds(S, iso, today) })),
      next: next ? { iso: next.iso, ids: next.routines.map(r => r.id) } : null,
      view: Q.queueView(S, today), done: Q.queueDone(S), tally: Q.weekTally(S, today), left: workoutsLeft(S, today),
    }
  }
  const plan = S => ({ scheduleMode: S.scheduleMode ?? null, rotation: S.rotation ?? null, queue: S.queue ?? null, dayPlan: S.dayPlan })
  const out = cases.map(c => {
    // nextTrainingDay and uid read the clock and Math.random: both are pinned.
    vi.useFakeTimers(); vi.setSystemTime(new Date(c.today + 'T12:00:00')); vi.spyOn(Math, 'random').mockReturnValue(0.5)
    const S = structuredClone(c.state)
    const steps = [{ reads: reads(S, c.today) }]
    for (const [op, ...args] of c.ops) {
      let result
      if (op === 'saveRotation') result = R.saveRotation(S, args[0], args[1], c.today, c.now)
      else if (op === 'refillAfter') result = R.refillAfter(S, S.workouts.find(w => w.id === args[0]), c.today, c.now)
      else if (op === 'chooseFixedWeek' || op === 'stopPass') result = R[op](S, c.today)
      else result = R[op](S, c.today, c.now)
      steps.push({ op, result: result ?? null, plan: structuredClone(plan(S)), reads: reads(S, c.today) })
    }
    vi.useRealTimers(); vi.restoreAllMocks()
    return { name: c.name, steps }
  })
  writeFileSync(process.env.SCHEDULE_OUT, JSON.stringify(out, null, 1) + '\n')
})
