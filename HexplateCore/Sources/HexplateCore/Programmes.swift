import Foundation

/// Programmes (programmes.js): routines run as a block of 1 to 16 weeks, each week with its own
/// intensity (a %1RM or an RPE per exercise, a week-wide RPE, a deload week).
///
///   S.programmes = { [id]: { id, name, at, weeks: [{deload?, rpe?, t?: {exId | "rid:exId": {pct?, rpe?}}}], days? | sequence? } }
///   S.programme  = null | { id, startedOn, pausedOn?, cycle, bump, saved: {week, scheduleMode, rotation, pass} }
///
/// Starting one writes its schedule into S.week or S.rotation and keeps the plan you had in
/// `saved`; ending it puts that plan back. Week 1 is the calendar week it started in.
public enum Programmes {
    public typealias Object = [String: JSONValue]

    public static let maxWeeks = 16, pctMin = 30.0, pctMax = 110.0, rpeMin = 6.0, rpeMax = 10.0, repeatBump = 2.5

    static func half(_ v: Double) -> Double { Session.jsRound(v * 2) / 2 }
    static func finite(_ v: JSONValue?) -> Double? { if case .number(let d)? = v, d.isFinite { return d }; return nil }
    public static func cleanPct(_ v: JSONValue?) -> Double? { finite(v).flatMap { $0 >= pctMin && $0 <= pctMax ? half($0) : nil } }
    public static func cleanRpe(_ v: JSONValue?) -> Double? { finite(v).flatMap { $0 >= rpeMin && $0 <= rpeMax ? half($0) : nil } }

    /// One week as stored: only what it says, so an empty week is `{}`.
    public static func cleanWeek(_ v: JSONValue?) -> Object {
        guard let w = v?.object else { return [:] }
        var out: Object = [:]
        if w["deload"] == .bool(true) { out["deload"] = .bool(true) }
        if let r = cleanRpe(w["rpe"]) { out["rpe"] = .number(r) }
        if let t = w["t"]?.object {
            var kept: Object = [:]
            for (k, x) in t where !k.isEmpty {
                guard let x = x.object else { continue }
                let pct = cleanPct(x["pct"]), rpe = cleanRpe(x["rpe"])
                if pct == nil && rpe == nil { continue }
                var c: Object = [:]
                if let pct { c["pct"] = .number(pct) }
                if let rpe { c["rpe"] = .number(rpe) }
                kept[k] = .object(c)
            }
            if !kept.isEmpty { out["t"] = .object(kept) }
        }
        return out
    }

    static func cleanDays(_ v: JSONValue?) -> Object {
        guard let days = v?.object else { return [:] }
        var out: Object = [:]
        for d in 0...6 {
            let raw = days[String(d)]
            let ids = (raw?.arrayValue ?? (raw.map { [$0] } ?? [])).compactMap(\.stringValue).filter { !$0.isEmpty }
            if !ids.isEmpty { out[String(d)] = .array(ids.map(JSONValue.string)) }
        }
        return out
    }

    /// A programme as this app keeps it; nil for something that is not one. Unknown fields are kept.
    public static func normalize(_ v: JSONValue?) -> Object? {
        guard let p = v?.object, let id = p["id"]?.stringValue, !id.isEmpty else { return nil }
        var weeks = (p["weeks"]?.arrayValue ?? []).prefix(maxWeeks).map { JSONValue.object(cleanWeek($0)) }
        if weeks.isEmpty { weeks = [.object([:])] }
        let seq = (p["sequence"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
        var out = p
        out["name"] = .string(String(WorkoutEdit.jsString(p["name"] ?? .string("")).trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))
        out["weeks"] = .array(Array(weeks))
        if seq.contains(where: { $0 != Schedule.rest }) {
            out["sequence"] = .array(seq.map(JSONValue.string)); out["days"] = nil
        } else {
            out["sequence"] = nil; out["days"] = .object(cleanDays(p["days"]))
        }
        return out
    }

    /// Every programme, newest first.
    public static func all(_ s: Object) -> [Object] {
        (s["programmes"]?.object ?? [:]).values.compactMap(normalize).sorted { ($0["at"]?.num ?? 0) > ($1["at"]?.num ?? 0) }
    }
    public static func byId(_ s: Object, _ id: String) -> Object? { normalize(s["programmes"]?.object?[id]) }

    /// The routine ids a programme schedules that still exist, each once, in schedule order.
    public static func routineIds(_ s: Object, _ p: Object) -> [String] {
        let have = Set((s["routines"]?.arrayValue ?? []).compactMap { $0.object?["id"]?.stringValue })
        let ids: [String] = p["sequence"]?.arrayValue.map { $0.compactMap(\.stringValue) }
            ?? (p["days"]?.object ?? [:]).keys.sorted().flatMap { (p["days"]?.object?[$0]?.arrayValue ?? []).compactMap(\.stringValue) }
        var seen = Set<String>()
        return ids.filter { $0 != Schedule.rest && have.contains($0) && seen.insert($0).inserted }
    }

    /// The schedule you train by now, the way a programme stores it.
    public static func currentSchedule(_ s: Object) -> Object {
        let seq = Schedule.sequence(s)
        if (Schedule.queue(s) != nil || s["scheduleMode"] == .string("rotation")) && seq.contains(where: { $0 != Schedule.rest }) {
            return ["sequence": .array(seq.map(JSONValue.string))]
        }
        return ["days": .object(cleanDays(s["week"]))]
    }

    /// A new programme over the schedule you train by now; not saved yet.
    public static func make(_ s: Object, name: String, weeks: Int = 4, id: String, now: Double) -> Object {
        let n = max(1, min(maxWeeks, weeks))
        var p: Object = ["id": .string(id), "name": .string(name), "at": .number(now), "weeks": .array(Array(repeating: .object([:]), count: n))]
        p.merge(currentSchedule(s)) { $1 }
        return normalize(.object(p)) ?? p
    }

    public static func save(_ s: inout Object, _ p: Object) {
        guard let clean = normalize(.object(p)), let id = clean["id"]?.stringValue else { return }
        var all = s["programmes"]?.object ?? [:]
        all[id] = .object(clean)
        s["programmes"] = .object(all)
    }

    public static func delete(_ s: inout Object, _ id: String, today: String, now: Double) {
        if s["programme"]?.object?["id"]?.stringValue == id { end(&s, today: today, now: now) }
        guard var all = s["programmes"]?.object, all[id] != nil else { return }
        all[id] = nil
        s["programmes"] = .object(all)
    }

    /// `n` weeks: the ones kept as they were, new ones copied from the last without its deload.
    public static func resizeWeeks(_ weeks: [JSONValue], _ n: Int) -> [JSONValue] {
        let k = max(1, min(maxWeeks, n))
        var out = weeks.prefix(k).map(cleanWeek)
        while out.count < k {
            var next = out.last ?? [:]
            next["deload"] = nil
            out.append(next)
        }
        return out.map { .object(cleanWeek(.object($0))) }
    }

    /// A week's targets with every %1RM raised by `step` points.
    public static func stepWeek(_ week: JSONValue?, step: Double = repeatBump) -> Object {
        let w = cleanWeek(week)
        var out: Object = [:]
        if let r = w["rpe"] { out["rpe"] = r }
        if let t = w["t"]?.object {
            out["t"] = .object(t.mapValues { v in
                guard var o = v.object else { return v }
                if let pct = o["pct"]?.numberValue { o["pct"] = .number(cleanPct(.number(min(pctMax, pct + step))) ?? pct) }
                return .object(o)
            })
        }
        return cleanWeek(.object(out))
    }

    // MARK: The running programme

    static func isISO(_ v: JSONValue?) -> Bool {
        guard let s = v?.stringValue, s.count == 10 else { return false }
        return s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
    static func days(_ a: String, _ b: String) -> Int {
        Int(Session.jsRound((Day.noon(b) - Day.noon(a)) / 86_400_000))
    }
    static func weeksBetween(_ a: String, _ b: String, _ ws: Int) -> Int {
        guard let ka = Schedule.weekKey(a, weekStart: ws), let kb = Schedule.weekKey(b, weekStart: ws) else { return 0 }
        return Int(Session.jsRound(Double(days(ka, kb)) / 7))
    }

    public struct Status {
        public let programme: Object, run: Object
        public let week, weeks, cycle: Int
        public let done, paused: Bool
        /// The week's targets, nil once done or while paused.
        public let current: Object?
    }

    /// Where the running programme stands on `today`; nil when none runs or its definition is gone.
    public static func status(_ s: Object, today: String) -> Status? {
        guard let run = s["programme"]?.object, isISO(run["startedOn"]), let start = run["startedOn"]?.stringValue,
              let id = run["id"]?.stringValue, let p = byId(s, id) else { return nil }
        let paused = isISO(run["pausedOn"])
        let pausedOn = run["pausedOn"]?.stringValue ?? ""
        let at = paused && pausedOn < today ? pausedOn : today
        let week = max(1, weeksBetween(start, at, Schedule.weekStart(s)) + 1)
        let weeks = p["weeks"]?.arrayValue ?? []
        let done = week > weeks.count
        return Status(programme: p, run: run, week: min(week, weeks.count), weeks: weeks.count,
                      cycle: max(1, Int(Session.jsRound(run["cycle"]?.num ?? 1))), done: done, paused: paused,
                      current: done || paused ? nil : weeks[week - 1].object)
    }

    /// "Week 2 of 6", "Push block, paused", "Programme done", or nil.
    public static func chip(_ s: Object, today: String) -> String? {
        guard let st = status(s, today: today) else { return nil }
        if st.done { return "Programme done" }
        if st.paused { return "\(st.programme["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Programme"), paused" }
        return "Week \(st.week) of \(st.weeks)"
    }

    static func applySchedule(_ s: inout Object, _ p: Object, today: String, now: Double, newId: () -> String) {
        let have = Set((s["routines"]?.arrayValue ?? []).compactMap { $0.object?["id"]?.stringValue })
        if let seq = p["sequence"]?.arrayValue?.compactMap(\.stringValue) {
            let kept = seq.filter { $0 == Schedule.rest || have.contains($0) }
            if kept.contains(where: { $0 != Schedule.rest }) {
                Schedule.stopPass(&s, today: today)
                s["rotation"] = .null
                Schedule.saveRotation(&s, ids: kept, label: p["name"]?.stringValue ?? "", today: today, now: now, newId: newId)
                s["scheduleMode"] = .string("rotation")
                return
            }
        }
        Schedule.chooseFixedWeek(&s, today: today)
        var week: Object = [:]
        for (d, ids) in p["days"]?.object ?? [:] {
            let kept = (ids.arrayValue ?? []).compactMap(\.stringValue).filter { have.contains($0) }
            if !kept.isEmpty { week[d] = .array(kept.map(JSONValue.string)) }
        }
        s["week"] = .object(week)
    }

    /// Starts programme `id` today. One already running is ended first, so `saved` holds the plan
    /// from before any programme. False when there is no such programme.
    @discardableResult
    public static func start(_ s: inout Object, _ id: String, today: String, now: Double, newId: () -> String = { RoutineOps.newId() }) -> Bool {
        guard let p = byId(s, id) else { return false }
        if s["programme"]?.object != nil { end(&s, today: today, now: now) }
        let q = Schedule.queue(s)
        let saved: Object = ["week": s["week"]?.object.map(JSONValue.object) ?? .object([:]),
                             "scheduleMode": s["scheduleMode"] ?? .null, "rotation": s["rotation"] ?? .null,
                             "pass": .bool(q != nil && s["rotation"]?.object != nil && q?.rotationId == s["rotation"]?.object?["id"])]
        applySchedule(&s, p, today: today, now: now, newId: newId)
        s["programme"] = .object(["id": .string(id), "startedOn": .string(today), "cycle": .number(1), "bump": .number(0), "saved": .object(saved)])
        return true
    }

    public static func pause(_ s: inout Object, today: String) {
        guard var run = s["programme"]?.object, !isISO(run["pausedOn"]) else { return }
        run["pausedOn"] = .string(today)
        s["programme"] = .object(run)
    }

    /// Resumes where it was paused: the start moves on by the whole weeks the pause lasted.
    public static func resume(_ s: inout Object, today: String) {
        guard var run = s["programme"]?.object, isISO(run["pausedOn"]), let paused = run["pausedOn"]?.stringValue,
              let start = run["startedOn"]?.stringValue else { return }
        let gap = max(0, weeksBetween(paused, today, Schedule.weekStart(s)))
        run["pausedOn"] = nil
        run["startedOn"] = .string(Day.adding(gap * 7, to: start) ?? start)
        s["programme"] = .object(run)
    }

    /// Ends the programme and puts back the plan you had before it.
    public static func end(_ s: inout Object, today: String, now: Double) {
        guard let run = s["programme"]?.object else { s["programme"] = .null; return }
        s["programme"] = .null
        guard let saved = run["saved"]?.object else { return }
        if let q = Schedule.queue(s), s["rotation"]?.object == nil || q.rotationId == s["rotation"]?.object?["id"] {
            Schedule.stopPass(&s, today: today)
        }
        s["week"] = .object(saved["week"]?.object ?? [:])
        s["rotation"] = saved["rotation"] ?? .null
        s["scheduleMode"] = saved["scheduleMode"] ?? .null
        if saved["pass"] == .bool(true) && s["rotation"]?.object != nil { _ = Schedule.startPass(&s, today: today, now: now) }
    }

    /// Runs the same programme again from week 1, every %1RM `bump` points heavier on top.
    public static func again(_ s: inout Object, today: String, bump: Double = 0) {
        guard var run = s["programme"]?.object else { return }
        run["cycle"] = .number(Double(max(1, Int(run["cycle"]?.num ?? 1)) + 1))
        run["bump"] = .number((run["bump"]?.num ?? 0) + bump)
        run["startedOn"] = .string(today)
        run["pausedOn"] = nil
        s["programme"] = .object(run)
    }

    // MARK: Targets for a session

    public struct Slot { public let pct, rpe: Double?; public let deload: Bool; public let week, weeks: Int }

    /// The programme's target for one exercise of one routine on `iso`, or nil when it says nothing.
    public static func slot(_ s: Object, rid: String?, exId: String, iso: String) -> Slot? {
        guard let st = status(s, today: iso), let w = st.current, let rid, routineIds(s, st.programme).contains(rid) else { return nil }
        let t = w["t"]?.object
        let own = t?["\(rid):\(exId)"]?.object ?? t?[exId]?.object ?? [:]
        let pct = own["pct"]?.numberValue
        let rpe = own["rpe"]?.numberValue ?? w["rpe"]?.numberValue
        let deload = w["deload"] == .bool(true)
        if pct == nil && rpe == nil && !deload { return nil }
        let bump = s["programme"]?.object?["bump"]?.num ?? 0
        return Slot(pct: pct.map { min(pctMax, $0 + bump) }, rpe: rpe, deload: deload, week: st.week, weeks: st.weeks)
    }

    /// `pct` % of the exercise's best estimated 1RM on the exercise's steps, never under the bar.
    // ponytail: owned dumbbell lists (ownedWeightsFor) are not ported; the step is used instead.
    public static func pctWeight(_ s: Object, _ exId: String, _ pct: Double, step: Double, floor: Double, catalog c: ExerciseCatalog) -> Double? {
        guard let best = Stats.bestOneRepMax(s, exId, catalog: c), best.estimate > 0, pct > 0 else { return nil }
        let ideal = best.estimate * pct / 100
        let w = step > 0 ? Session.round1(Session.jsRound(ideal / step) * step) : Session.round1(ideal)
        return max(w, floor)
    }

    /// The prescription a slot makes of the policy's (session-start.js programmePlan).
    static func plan(_ s: Object, _ cfg: Object, _ plan: Object, _ slot: Slot, step: Double, catalog c: ExerciseCatalog) -> Object {
        let reps = Session.mode(cfg, c) == "reps" && !RoutineOps.isBodyweight(cfg, catalog: c) && !Session.isAssisted(cfg, c)
        let id = cfg["id"]?.stringValue ?? ""
        var weight = reps ? slot.pct.flatMap { pctWeight(s, id, $0, step: step, floor: Session.barFloor(s, id, c), catalog: c) } : nil
        if weight == nil && slot.deload && reps {
            let base = plan["weight"]?.numberValue ?? cfg["weight"]?.num ?? 0
            if base > 0 { weight = Session.deloadTo(base, step, Session.deloadFactor) }
        }
        let text = slot.pct != nil && weight != nil ? "Week {0} of {1}: {2}% of your best 1RM" : slot.deload ? "Week {0} of {1}: deload week" : "Week {0} of {1}"
        var prog: Object = ["week": .number(Double(slot.week)), "weeks": .number(Double(slot.weeks))]
        if let p = slot.pct { prog["pct"] = .number(p) }
        if let r = slot.rpe { prog["rpe"] = .number(r) }
        if slot.deload { prog["deload"] = .bool(true) }
        var out: Object = ["policy": plan["policy"] ?? .null, "kind": .string("programme"),
                           "why": .array([.string(text), .number(Double(slot.week)), .number(Double(slot.weeks)), slot.pct.map(JSONValue.number) ?? .null]),
                           "prog": .object(prog)]
        if let weight { out["weight"] = .number(weight) } else if let w = plan["weight"] { out["weight"] = w }
        return out
    }
}
