// Writes the numbers and labels the original JavaScript produces for a state file, so the Swift
// port (HexplateCore) can be tested against the code it replaces rather than against a reading
// of it. Run through the frontend's own vitest (see golden.sh); nothing in frontend/ is changed.
//
//   IN   a state document (JSON)
//   OUT  where to write the golden file
//   STAMP_IN, STAMP_OUT  optional: change cases and where to write how the JS stamps them
//   SCHEDULE_IN, SCHEDULE_OUT  optional: schedule cases and what the JS reads and does for them
//   ROUTINE_IN, ROUTINE_OUT  optional: routine editing cases and what the JS makes of them
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
import { effectiveRoutineIds, nextTrainingDay, pairAdjacent, unpairSuperset, cleanupSg, pickedExerciseConfig, exLine } from '../../frontend/src/lib/history.js'
import { deleteRoutine, copyRoutine } from '../../frontend/src/lib/routines.js'
import { muscleWeightsOf } from '../../frontend/src/lib/muscles.js'
import { eqAvailable, profileEquipment } from '../../frontend/src/lib/equipment.js'
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

// What Hexplate bundles of the catalogue: per exercise what its logic and screens read, the
// muscle and equipment vocabulary, the body map's outlines and the English how-to text.
// Text and shapes only; no exercise media is read or copied.
it('writes the exercise index', async () => {
  if (!process.env.CATALOGUE_OUT) return
  const M = await import('../../frontend/src/lib/muscles.js')
  const E = await import('../../frontend/src/lib/equipment.js')
  const nonEmpty = o => (Object.keys(o).length ? o : undefined)
  const exercises = CATALOGUE.map(e => ({
    id: e.id, n: e.n, bp: e.bp, eq: e.eq, tg: e.tg, mg: e.mg, sm: e.sm,
    ...(e.hd ? { hd: true } : {}),
    ...(e.nd ? { nd: e.nd } : {}),
    mw: nonEmpty(M.muscleWeightsOf(e)),
    acc: E.accessoriesOf(e).length ? E.accessoriesOf(e) : undefined,
  }))
  // Every spelling the dataset uses for a muscle, and the muscle it means (null: not drawable).
  const spellings = new Set(M.MUSCLES)
  for (const e of CATALOGUE) [e.tg, e.mg, ...[].concat(e.sm || [])].forEach(x => x && spellings.add(String(x).toLowerCase().trim()))
  const alias = {}
  for (const x of spellings) alias[x] = Object.keys(M.muscleWeightsOf({ id: 'probe', custom: true, n: 'probe', tg: x }))[0] ?? null
  const byBodyPart = {}
  for (const bp of new Set(CATALOGUE.map(e => e.bp))) byBodyPart[bp] = M.muscleWeightsOf({ id: 'probe', custom: true, n: 'probe', bp })
  const meta = { equipment: E.ALL_EQUIPMENT, accessories: E.ACCESSORIES, muscles: M.MUSCLES, muscleNames: M.MUSCLE_NAME, inert: M.INERT, alias, byBodyPart }
  writeFileSync(process.env.CATALOGUE_OUT, JSON.stringify({ exercises, aliases: EXALIAS, meta }) + '\n')

  const dir = process.env.CATALOGUE_OUT.replace(/[^/]+$/, '')
  writeFileSync(dir + 'body-paths.json', JSON.stringify((await import('../../frontend/src/lib/body-paths.js')).default) + '\n')
  const steps = (await import('../../frontend/src/instr/en.js')).default
  const about = (await import('../../frontend/src/exercise-desc/en.js')).default
  const text = {}
  for (const e of CATALOGUE) if (steps[e.id] || about[e.id]) text[e.id] = { ...(about[e.id] ? { d: about[e.id] } : {}), ...(steps[e.id] ? { i: steps[e.id] } : {}) }
  writeFileSync(dir + 'exercise-text.json', JSON.stringify(text) + '\n')
  // Structural balance standards (lib/structuralBalanceTemplates.js), the default first.
  const B = await import('../../frontend/src/lib/structuralBalanceTemplates.js')
  writeFileSync(dir + 'balance-templates.json', JSON.stringify({ defaultId: B.DEFAULT_TEMPLATE_ID, borderlinePct: B.BORDERLINE_BAND_PCT, templates: B.TEMPLATE_LIST }) + '\n')
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

// Editing a plan: deleting and copying a routine, supersets, a picked exercise's defaults, the
// line a planned exercise reads as.
it('writes the routine golden file', () => {
  if (!process.env.ROUTINE_IN) return
  const cases = JSON.parse(readFileSync(process.env.ROUTINE_IN, 'utf8'))
  registerCustom([{ id: 'cx-custom', n: 'one arm custom thing', custom: true, eq: 'body weight', bp: 'waist' }])
  setWeightDecimals(1)
  const out = cases.map(c => {
    const safe = fn => { try { return fn() } catch (e) { return { error: true } } }
    let result
    if (c.op === 'deleteRoutine') { const s = structuredClone(c.state); const dropped = deleteRoutine(s, c.id); result = { state: s, dropped } }
    else if (c.op === 'copyRoutine') { const r = copyRoutine(c.routine); result = { ...r, id: null } }
    else if (c.op === 'pair') result = safe(() => pairAdjacent(c.items, c.first, c.second))
    else if (c.op === 'unpair') result = safe(() => unpairSuperset(c.items, c.idx))
    else if (c.op === 'cleanup') { const ex = structuredClone(c.items); cleanupSg(ex); result = ex }
    else if (c.op === 'picked') result = pickedExerciseConfig(c.id)
    else if (c.op === 'exLine') result = exLine(c.cfg, c.unit, c.unit === 'lb' ? 'mph' : 'kmh')
    else if (c.op === 'muscles') result = muscleWeightsOf(c.ex)
    else if (c.op === 'available') result = eqAvailable(profileEquipment(c.profile), c.ex)
    return { name: c.name, result }
  })
  writeFileSync(process.env.ROUTINE_OUT, JSON.stringify(out, null, 1) + '\n')
})

// A workout: the entries a routine starts with (progression included) and the saved workout a
// live session finishes as.
it('writes the session golden file', async () => {
  if (!process.env.SESSION_IN) return
  const { buildSessionEntries } = await import('../../frontend/src/lib/session-start.js')
  const { buildCompletedWorkout, sessionEnd } = await import('../../frontend/src/lib/finish-workout.js')
  const { workoutVolume } = await import('../../frontend/src/lib/history.js')
  const cases = JSON.parse(readFileSync(process.env.SESSION_IN, 'utf8'))
  setWeightDecimals(1)
  const out = cases.map(c => {
    vi.useFakeTimers(); vi.setSystemTime(new Date('2026-11-15T12:00:00'))
    let result
    if (c.op === 'start') {
      const S = structuredClone(c.state)
      const r = S.routines.find(x => x.id === c.routineId)
      result = buildSessionEntries(S, r).map(e => ({ ...e, rid: r.id }))
    } else {
      const end = sessionEnd(c.active, c.now)
      const w = buildCompletedWorkout(structuredClone(c.active), { end, prs: [] })
      w.vol = workoutVolume(w)
      result = w
    }
    vi.useRealTimers()
    return { name: c.name, result: JSON.parse(JSON.stringify(result)) }
  })
  writeFileSync(process.env.SESSION_OUT, JSON.stringify(out, null, 1) + '\n')
})

// Stats and body: one-rep maxes, strength levels, weekly sets per muscle, weigh-ins.
it('writes the stats golden file', async () => {
  if (!process.env.STATS_IN) return
  const O = await import('../../frontend/src/lib/onerm.js')
  const { strengthLevels } = await import('../../frontend/src/lib/strength-level.js')
  const { weeklyMuscleSets } = await import('../../frontend/src/lib/muscle-targets.js')
  const { addWeighIn } = await import('../../frontend/src/lib/weigh-ins.js')
  const cases = JSON.parse(readFileSync(process.env.STATS_IN, 'utf8'))
  const ids = ['0043', '0025', '0289', '0027', '0031', '0662', '0017', '0334']
  const out = []
  for (const c of cases) {
    vi.useFakeTimers(); vi.setSystemTime(new Date('2026-11-15T12:00:00'))
    let result
    if (c.op === 'stats') {
      const S = structuredClone(c.state)
      const f = O.formulaOf(S)
      result = {
        series: Object.fromEntries(ids.map(id => [id, O.e1rmSeries(S, id, f).map(p => ({ d: p.d, y: p.y, w: p.w, r: p.r }))])),
        best: Object.fromEntries(ids.map(id => [id, O.best1RM(S, id, f)?.est ?? null])),
        levels: strengthLevels(S).map(l => ({ lift: l.lift, id: l.id, level: l.level, ratio: l.ratio, e1rm: l.e1rm, bw: l.bw, next: l.next, thresholds: l.thresholds })),
        muscles: weeklyMuscleSets(S, c.today).map(m => ({ slug: m.slug, sets: m.sets, lo: m.lo, hi: m.hi, status: m.status })),
      }
    } else if (c.op === 'balance') {
      const { computeBalance } = await import('../../frontend/src/lib/structuralBalance.js')
      const { TEMPLATE_LIST } = await import('../../frontend/src/lib/structuralBalanceTemplates.js')
      const r6 = v => (v == null || !isFinite(v) ? null : Math.round(v * 1e6) / 1e6)
      result = Object.fromEntries(TEMPLATE_LIST.map(t => [t.id, computeBalance(structuredClone(c.state), t).map(x => ({
        roleId: x.roleId, configuredExerciseId: x.configuredExerciseId, targetPct: x.targetPct, isOverridden: x.isOverridden,
        mappedExerciseId: x.mappedExerciseId, actualPct: r6(x.actualPct), status: x.status, needsBodyweight: x.needsBodyweight, needsAnchor: x.needsAnchor,
        current: x.current ? { kg: r6(x.current.estKg ?? x.current.repsKg ?? null), w: x.current.w, r: x.current.r, exId: x.current.exId, d: x.current.d } : null,
      }))]))
    } else if (c.op === 'plates') {
      const { plateStack } = await import('../../frontend/src/lib/plates.js')
      result = c.rows.map(([w, inv]) => plateStack(w, inv))
    } else if (c.op === 'estimate') {
      result = c.rows.map(([w, r, f, rir]) => O.estimate1RM(w, r, f, rir))
    } else {
      const S = structuredClone(c.state)
      for (const a of c.adds) addWeighIn(S, a)
      result = S.bodyweight
    }
    vi.useRealTimers()
    out.push({ name: c.name, result: JSON.parse(JSON.stringify(result)) })
  }
  writeFileSync(process.env.STATS_OUT, JSON.stringify(out, null, 1) + '\n')
})

// The recovery model (fatigue per muscle) and the Home hint built on it.
it('writes the recovery golden file', async () => {
  if (!process.env.RECOVERY_IN) return
  const { fatigueOf } = await import('../../frontend/src/lib/recovery.js')
  const { recoveryHint, hintText } = await import('../../frontend/src/lib/recovery-hint.js')
  const cases = JSON.parse(readFileSync(process.env.RECOVERY_IN, 'utf8'))
  const r6 = m => Object.fromEntries(Object.entries(m).map(([k, v]) => [k, Math.round(v * 1e6) / 1e6]))
  const out = []
  for (const c of cases) {
    const now = new Date(c.today + 'T12:00:00').getTime() + (c.hours || 0) * 3600000
    vi.useFakeTimers(); vi.setSystemTime(now)
    let result
    if (c.op === 'fatigue') {
      result = r6(fatigueOf(structuredClone(c.workouts), now, { unit: c.unit, bodyweightKg: c.bodyweightKg }))
    } else {
      const S = structuredClone(c.state)
      const fatigue = fatigueOf(S.workouts, now, { unit: S.unit, bodyweightKg: c.bodyweightKg })
      const hint = recoveryHint(S, { now, today: c.today, fatigue })
      result = { hint, text: hintText(hint, c.today) }
    }
    vi.useRealTimers()
    out.push({ name: c.name, result: JSON.parse(JSON.stringify(result)) })
  }
  writeFileSync(process.env.RECOVERY_OUT, JSON.stringify(out, null, 1) + '\n')
})

// Live-session edits from an exercise's menu (Workout.jsx removeActiveExercise is inlined: it
// lives in a React view).
it('writes the edit golden file', async () => {
  if (!process.env.EDIT_IN) return
  const H = await import('../../frontend/src/lib/history.js')
  const O = await import('../../frontend/src/lib/active-workout-order.js')
  const { swapActiveExercise } = await import('../../frontend/src/lib/active-exercise-swap.js')
  const { setEntryNoProg, setSessionNoProg, joinSessionNoProg } = await import('../../frontend/src/lib/session-noprog.js')
  const { buildSessionEntries } = await import('../../frontend/src/lib/session-start.js')
  const { deriveSessionName } = await import('../../frontend/src/lib/session-merge.js')
  setWeightDecimals(1)
  const W = await import('../../frontend/src/lib/workout-model.js')
  const { withSetNote } = await import('../../frontend/src/lib/set-notes.js')
  const cases = JSON.parse(readFileSync(process.env.EDIT_IN, 'utf8'))
  const out = []
  for (const c of cases) {
    if (c.rows) {
      let rows = structuredClone(c.rows)
      const steps = []
      for (const [op, i, v] of c.ops) {
        if (op === 'failure') {
          const [start, count] = H.setSpanAt(rows, i)
          const on = !W.isFailureSet(rows[i])
          for (let j = start; j < start + count; j++) if (W.isFailureSet(rows[j]) !== on) rows[j] = W.toggleFailure(rows[j])
        } else if (op === 'warmup') rows = H.makeWarmupAt(rows, i)
        else if (op === 'work') rows = H.makeWorkAt(rows, i)
        else if (op === 'rest') {
          const row = rows[H.setSpanAt(rows, i)[0]]
          if (v == null) delete row.restSec
          else row.restSec = Math.max(0, Math.min(15 * 60, Math.round(v)))
        } else if (op === 'note') { const at = H.setSpanAt(rows, i)[0]; rows[at] = withSetNote(rows[at], v) }
        else if (op === 'copy') rows = H.copyRowAt(rows, i)
        else if (op === 'remove') rows = H.removeRowAt(rows, i)
        steps.push(structuredClone(rows))
      }
      out.push({ name: c.name, result: JSON.parse(JSON.stringify(steps)) })
      continue
    }
    const a = structuredClone(c.active)
    const steps = []
    vi.useFakeTimers(); vi.setSystemTime(new Date('2026-11-15T12:00:00'))
    for (const [op, x, y, z] of c.ops) {
      if (op === 'canMove') { steps.push(O.canMoveActiveWorkoutEntry(a, x, y)); continue }
      if (op === 'move') O.moveActiveWorkoutEntry(a, x, y)
      else if (op === 'pair') a.entries = H.pairAdjacent(a.entries, x, y)
      else if (op === 'unpair') a.entries = H.unpairSuperset(a.entries, x)
      else if (op === 'remove') {
        a.entries.splice(x, 1); H.cleanupSg(a.entries)
        if (x < a.cur) a.cur--
        if (a.cur >= a.entries.length) a.cur = Math.max(0, a.entries.length - 1)
      } else if (op === 'swap') swapActiveExercise(a, x, structuredClone(y), { loggedConfirmed: true, groupDisposition: z ? 'keep' : 'detach' })
      else if (op === 'noProg') setEntryNoProg(a, x, y)
      else if (op === 'note') { const text = x.trim().slice(0, 500); if (text) a.note = text; else delete a.note }
      else if (op === 'rename') { const n = x.trim().slice(0, 60); if (n) { a.name = n; a.customName = true } }
      else if (op === 'addRoutine') {
        const S = c.state, r = S.routines.find(q => q.id === x)
        const added = buildSessionEntries(structuredClone(S), r).map(en => ({ ...en, rid: r.id }))
        a.entries.push(...added.map(en => joinSessionNoProg(a, en)))
        a.routineIds = [...[].concat(a.routineIds || []), r.id]
        if (!a.customName) a.name = deriveSessionName(a.routineIds.map(id => S.routines.find(q => q.id === id)?.name).filter(Boolean))
      } else if (op === 'sessionNoProg') {
        const owns = en => !!en?.rid && c.state.routines.some(r => r.id === en.rid && r.excludeFromProgression === true)
        setSessionNoProg(a, x, owns)
      } else if (op === 'exRest') {
        const en = a.entries[x]
        const { restSec: _s, restOff: _o, ...target } = en.target || {}
        en.target = y == null ? target : y > 0 ? { ...target, restSec: y } : { ...target, restOff: true }
      }
      steps.push(structuredClone(a))
    }
    vi.useRealTimers()
    out.push({ name: c.name, result: JSON.parse(JSON.stringify(steps)) })
  }
  writeFileSync(process.env.EDIT_OUT, JSON.stringify(out, null, 1) + '\n')
})

// Editing a saved workout: open it, change the copy (path ops), save over the record.
it('writes the workout edit golden file', async () => {
  if (!process.env.WEDIT_IN) return
  const E = await import('../../frontend/src/lib/session-edit.js')
  const cases = JSON.parse(readFileSync(process.env.WEDIT_IN, 'utf8'))
  setWeightDecimals(1)
  const strip = v => JSON.parse(JSON.stringify(v, (k, x) => (k === '_ts' ? undefined : x)))
  const out = []
  for (const c of cases) {
    const S = structuredClone(c.state)
    let error = null
    try {
      E.editCompletedSession(S, c.key)
      for (const [op, path, v] of c.ops) {
        const parent = path.slice(0, -1).reduce((o, k) => o[k], S.active), last = path[path.length - 1]
        if (op === 'set') parent[last] = v
        else if (Array.isArray(parent)) parent.splice(last, 1)
        else delete parent[last]
      }
      E.saveWorkoutEdit(S, 1_800_000_000_000)
    } catch (e) { error = e.message }
    out.push({ name: c.name, result: strip({ error, workouts: S.workouts, exWeights: S.exWeights, active: S.active ?? null }) })
  }
  writeFileSync(process.env.WEDIT_OUT, JSON.stringify(out, null, 1) + '\n')
})

// The workout CSV export of the history fixture.
it('writes the CSV golden file', async () => {
  if (!process.env.CSV_OUT) return
  const { workoutsCSV } = await import('../../frontend/src/lib/export-csv.js')
  const state = JSON.parse(readFileSync(process.env.IN, 'utf8'))
  registerCustom(state.customEx || [])
  writeFileSync(process.env.CSV_OUT, workoutsCSV(state))
})

// The watch link: the snapshot the watch runs from (each entry's best set and the Health type are
// left out: not ported) and patching a set from a watch event.
it('writes the watch golden file', async () => {
  if (!process.env.WATCH_IN) return
  const W = await import('../../frontend/src/lib/watch-sync.js')
  const cases = JSON.parse(readFileSync(process.env.WATCH_IN, 'utf8'))
  setWeightDecimals(1)
  const strip = v => JSON.parse(JSON.stringify(v, (k, x) => (k === 'best' || k === 'healthType' ? undefined : x)))
  const out = []
  for (const c of cases) {
    vi.useFakeTimers(); vi.setSystemTime(new Date(c.today ? c.today + 'T12:00:00' : '2026-11-15T12:00:00'))
    const S = structuredClone(c.state)
    let result
    if (c.op === 'snapshot') result = strip(W.buildSnapshot(S, { ready: W.buildReady(S, c.today) }))
    else {
      const ok = W.patchSetIn(S, c.ref, c.fields, null, { ifNewer: c.ifNewer })
      result = { ok, workouts: S.workouts, active: S.active ?? null }
    }
    vi.useRealTimers()
    out.push({ name: c.name, result: JSON.parse(JSON.stringify(result)) })
  }
  writeFileSync(process.env.WATCH_OUT, JSON.stringify(out, null, 1) + '\n')
})
