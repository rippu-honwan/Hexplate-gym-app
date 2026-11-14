// Writes the numbers and labels the original JavaScript produces for a state file, so the Swift
// port (HexplateCore) can be tested against the code it replaces rather than against a reading
// of it. Run through the frontend's own vitest (see golden.sh); nothing in frontend/ is changed.
//
//   IN   a state document (JSON)
//   OUT  where to write the golden file
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
