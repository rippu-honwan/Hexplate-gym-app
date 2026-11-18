import Foundation

/// What is planned for a day, and the rotation ("the loop"). Ported from
/// frontend/src/lib/queue.js, rotation.js, week-left.js and history.js effectiveRoutineIds;
/// ScheduleGoldenTests holds it to their output. Works on the document itself, like the JavaScript.
///
/// Two ways to schedule: a fixed week (`week`: weekday → routine ids, with `dayPlan` overrides per
/// date) and a rotation (`rotation.sequence`, of which `queue` is the pass being worked through).
public enum Schedule {
    public typealias Object = [String: JSONValue]
    public static let rest = "rest"

    // MARK: Reading the document

    static func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }
    static func routines(_ s: Object) -> [Object] { (s["routines"]?.arrayValue ?? []).compactMap(\.object) }
    static func workouts(_ s: Object) -> [Object] { (s["workouts"]?.arrayValue ?? []).compactMap(\.object) }
    static func hasRoutine(_ s: Object, _ id: String) -> Bool { routines(s).contains { $0["id"] == .string(id) } }
    static func routineIds(of w: Object) -> [String] {
        if let ids = w["routineIds"]?.arrayValue { return ids.compactMap(\.stringValue) }
        return w["routineId"]?.stringValue.map { $0.isEmpty ? [] : [$0] } ?? []
    }
    private static func day(of w: Object) -> String { w["d"]?.stringValue ?? "" }
    private static func start(of w: Object) -> Double { w["start"].flatMap { $0 == .null ? nil : $0.num } ?? 0 }
    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: The queue (queue.js)

    /// The pass being worked through: its routines that still exist, in order.
    public struct Queue: Equatable, Sendable {
        public let ids: [String]
        let since: Double?
        public let startsOn: String
        public let label: String
        let rotationId: JSONValue?
        let strict: Bool
    }

    public static func queue(_ s: Object) -> Queue? {
        guard let q = s["queue"]?.object, q["ids"]?.arrayValue != nil else { return nil }
        let ids = unique(strings(q["ids"])).filter { hasRoutine(s, $0) }
        guard !ids.isEmpty else { return nil }
        let since = q["since"].map { $0.num }
        return Queue(
            ids: ids,
            since: since,
            startsOn: q["startsOn"]?.stringValue ?? Day.iso(since ?? 0),
            label: q["label"]?.stringValue ?? "",
            rotationId: q["rotationId"],
            strict: q["strict"] == .bool(true)
        )
    }

    private static func counts(_ s: Object, _ q: Queue, _ w: Object, _ id: String) -> Bool {
        guard routineIds(of: w).contains(id) else { return false }
        if let since = q.since, start(of: w) >= since { return true }
        guard !q.strict, day(of: w) >= q.startsOn else { return false }
        let name = routines(s).first { $0["id"] == .string(id) }?["name"]?.stringValue
        return name.map { (w["name"]?.stringValue ?? "").components(separatedBy: " + ").contains($0) } ?? false
    }
    private static func isDone(_ s: Object, _ q: Queue, _ id: String) -> Bool { workouts(s).contains { counts(s, q, $0, id) } }

    public static func queueDone(_ s: Object) -> [String] { queue(s).map { q in q.ids.filter { isDone(s, q, $0) } } ?? [] }
    public static func queueRemaining(_ s: Object) -> [String] { queue(s).map { q in q.ids.filter { !isDone(s, q, $0) } } ?? [] }

    /// The remaining sessions pinned to a day from today on, earliest first.
    private static func activePins(_ s: Object, _ remaining: [String], _ today: String) -> [(iso: String, id: String)] {
        (s["dayPlan"]?.object ?? [:]).compactMap { iso, v in
            guard iso >= today, let id = v.stringValue, remaining.contains(id) else { return nil }
            return (iso, id)
        }.sorted { $0.iso < $1.iso }
    }

    private static func nextOn(_ s: Object, _ remaining: [String], _ on: String, _ today: String) -> String? {
        let pins = activePins(s, remaining, today)
        if let here = pins.first(where: { $0.iso == on }) { return here.id }
        return remaining.first { id in !pins.contains { $0.id == id } }
    }

    /// The queue's session for `iso`: only on the day the queue is on (today, or its start day).
    static func queueNext(_ s: Object, _ iso: String, _ today: String) -> String? {
        guard let q = queue(s) else { return nil }
        let on = today > q.startsOn ? today : q.startsOn
        return iso == on ? nextOn(s, queueRemaining(s), on, today) : nil
    }

    static func queueLiveOn(_ s: Object, _ iso: String, _ today: String) -> Bool {
        guard let q = queue(s) else { return false }
        return iso == (today > q.startsOn ? today : q.startsOn) && !queueRemaining(s).isEmpty
    }

    /// "open" or "done" for a queue session a day is pinned to, nil for anything else.
    static func pinState(_ s: Object, _ id: String?) -> String? {
        guard let q = queue(s), let id, !id.isEmpty, q.ids.contains(id) else { return nil }
        return isDone(s, q, id) ? "done" : "open"
    }

    public struct QueueView: Equatable, Sendable {
        public struct Item: Equatable, Sendable, Identifiable {
            public let id: String
            public let name: String
            /// "done", "next", "pinned" or "later".
            public let state: String
            /// The day a pinned session is pinned to.
            public let on: String?
        }
        public let label: String
        public let items: [Item]
        public let remaining: [String]
        public let complete: Bool
        public let startsOn: String
        /// The pass has not started yet (a rest day before it).
        public let waiting: Bool
    }

    public static func queueView(_ s: Object, today: String) -> QueueView? {
        guard let q = queue(s) else { return nil }
        let remaining = queueRemaining(s)
        let on = today > q.startsOn ? today : q.startsOn
        let next = nextOn(s, remaining, on, today)
        let pins = activePins(s, remaining, today)
        let items = q.ids.map { id -> QueueView.Item in
            let pin = id != next ? pins.first { $0.id == id && $0.iso != on } : nil
            let state = !remaining.contains(id) ? "done" : id == next ? "next" : pin != nil ? "pinned" : "later"
            let name = routines(s).first { $0["id"] == .string(id) }?["name"]?.stringValue ?? id
            return .init(id: id, name: name, state: state, on: pin?.iso)
        }
        return QueueView(label: q.label, items: items, remaining: remaining, complete: remaining.isEmpty, startsOn: q.startsOn, waiting: today < q.startsOn)
    }

    // MARK: Weeks (format.js, queue.js weekTally, week-left.js)

    /// 0 for a Sunday start, else Monday.
    static func weekStart(_ s: Object) -> Int { s["weekStart"] == .number(0) ? 0 : 1 }

    /// The first day of the week `iso` falls in, nil for a string that is not a date.
    public static func weekKey(_ iso: String, weekStart ws: Int) -> String? {
        guard let weekday = Day.weekday(iso) else { return nil }
        return Day.adding((ws - weekday - 7) % 7, to: iso)
    }

    public struct Tally: Equatable, Sendable {
        public let done: Int
        public let planned: Int
    }

    public static func weekTally(_ s: Object, today: String) -> Tally {
        let ws = weekStart(s)
        let week = weekKey(today, weekStart: ws)
        let all = workouts(s)
        let thisWeek = all.indices.filter { weekKey(day(of: all[$0]), weekStart: ws) == week }
        let q = queue(s).flatMap { today >= $0.startsOn ? $0 : nil }
        let queued = Set(q == nil ? [] : strings(s["queue"]?.object?["ids"]))
        let own = { (v: JSONValue) -> [String] in
            (v.stringValue.map { [$0] } ?? strings(v)).filter { hasRoutine(s, $0) && !queued.contains($0) }
        }
        let ownDays = (s["week"]?.object ?? [:]).values.filter { !own($0).isEmpty }.count
        guard let q else { return Tally(done: thisWeek.count, planned: ownDays) }
        // Each queue session is credited to the first workout that counts for it.
        let chrono = all.indices.sorted {
            let a = all[$0], b = all[$1]
            return day(of: a) != day(of: b) ? day(of: a) < day(of: b) : (a["start"]?.num ?? 0) != (b["start"]?.num ?? 0) ? (a["start"]?.num ?? 0) < (b["start"]?.num ?? 0) : $0 < $1
        }
        let credited = Set(q.ids.compactMap { id in chrono.first { counts(s, q, all[$0], id) } })
        let other = thisWeek.filter { !credited.contains($0) || routineIds(of: all[$0]).contains { !queued.contains($0) } }.count
        return Tally(done: queueDone(s).count + other, planned: q.ids.count + ownDays)
    }

    public struct Left: Equatable, Sendable {
        public let left: Int
        public let of: Int
        public let done: Int
    }

    /// "2 of 4 left this week", nil when there is nothing to count against.
    public static func workoutsLeft(_ s: Object, today: String) -> Left? {
        let q = queue(s)
        let rotationId = s["rotation"]?.object?["id"]
        let managed = q != nil && s["rotation"]?.object != nil && q?.rotationId == rotationId
        if scheduleMode(s) == "rotation" && (managed || q == nil) {
            let n = ((s["weekTarget"]?.num ?? 0) + 0.5).rounded(.down)
            guard n >= 1, n <= 7 else { return nil }
            let ws = weekStart(s), week = weekKey(today, weekStart: ws)
            let done = workouts(s).filter { weekKey(day(of: $0), weekStart: ws) == week }.count
            return Left(left: max(0, Int(n) - done), of: Int(n), done: done)
        }
        let tally = weekTally(s, today: today)
        guard tally.planned > 0 else { return nil }
        return Left(left: max(0, tally.planned - tally.done), of: tally.planned, done: tally.done)
    }

    // MARK: What a day holds (history.js)

    /// The routines planned for `iso`: the day's override, else the queue's session in front of
    /// the weekday's own routines.
    public static func routineIds(_ s: Object, on iso: String, today: String) -> [String] {
        let override = s["dayPlan"]?.object?[iso]?.stringValue
        if override == rest { return [] }
        let pin = pinState(s, override)
        if pin == nil, let override, !override.isEmpty, hasRoutine(s, override) { return [override] }
        let slot = Day.weekday(iso).flatMap { s["week"]?.object?[String($0)] }
        let weekday = (slot?.stringValue.map { [$0] } ?? strings(slot)).filter { hasRoutine(s, $0) }
        let q = pin == "open" ? override : queueNext(s, iso, today)
        // The weekday's own pointers to queue sessions stay hidden on the queue's day.
        let queued = strings(s["queue"]?.object?["ids"])
        let own = q != nil || queueLiveOn(s, iso, today) ? weekday.filter { !queued.contains($0) } : weekday
        return q.map { [$0] + own } ?? own
    }

    public struct NextDay: Equatable, Sendable {
        public let iso: String
        public let routineIds: [String]
    }

    /// The next day, after `iso`, that has a routine with exercises; nil when the week is all rest.
    public static func nextTrainingDay(_ s: Object, after iso: String, today: String) -> NextDay? {
        for i in 1...7 {
            guard let next = Day.adding(i, to: iso) else { return nil }
            let ids = routineIds(s, on: next, today: today)
            let trainable = ids.contains { id in
                !((routines(s).first { $0["id"] == .string(id) }?["ex"]?.arrayValue ?? []).isEmpty)
            }
            if trainable { return NextDay(iso: next, routineIds: ids) }
        }
        return nil
    }

    // MARK: The rotation (rotation.js)

    /// "rotation" or "week".
    public static func scheduleMode(_ s: Object) -> String {
        queue(s) != nil || s["scheduleMode"] == .string("rotation") ? "rotation" : "week"
    }

    /// A queue is there but none of it can be read (another device may have written it).
    public static func queueRecovery(_ s: Object) -> Bool {
        if let q = s["queue"], q != .null { return queue(s) == nil }
        return false
    }

    /// The loop's routines, each once, rest days left out.
    public static func rotationIds(_ s: Object) -> [String] {
        unique(strings(s["rotation"]?.object?["sequence"])).filter { hasRoutine(s, $0) }
    }

    /// The loop as written: routine ids and "rest"; empty when it holds no routine.
    public static func sequence(_ s: Object) -> [String] {
        let out = strings(s["rotation"]?.object?["sequence"]).filter { $0 == rest || hasRoutine(s, $0) }
        return out.contains { $0 != rest } ? out : []
    }

    /// No rest days and no routine twice: the whole loop is one pass.
    public static func isSimple(_ seq: [String]) -> Bool { !seq.contains(rest) && unique(seq) == seq }

    struct Segment { let start: Int; let ids: [String]; let rest: Int; let next: Int }

    /// The stretch of a loop from `at` to its next rest day or repeat, and where the one after starts.
    static func segment(_ seq: [String], at: Int?) -> Segment? {
        let n = seq.count
        guard n > 0, seq.contains(where: { $0 != rest }) else { return nil }
        var start = at.flatMap { $0 >= 0 && $0 < n ? $0 : nil } ?? 0
        while seq[start] == rest { start = (start + 1) % n }
        var ids: [String] = []
        var i = start
        while i < n, seq[i] != rest, !ids.contains(seq[i]) { ids.append(seq[i]); i += 1 }
        var restDays = 0, k = i % n, c = 0
        while c < n, seq[k] == rest { restDays += 1; k = (k + 1) % n; c += 1 }
        return Segment(start: start, ids: ids, rest: restDays, next: k)
    }

    private static func position(_ s: Object) -> Int? {
        guard let at = s["rotation"]?.object?["at"]?.numberValue, at == at.rounded() else { return nil }
        return Int(at)
    }

    private static func creditWindow(_ s: Object, _ q: Queue) -> [Object] {
        workouts(s).filter { w in day(of: w) >= q.startsOn && routineIds(of: w).contains { q.ids.contains($0) } }
    }
    private static func sinceAfter(_ s: Object, _ q: Queue, _ now: Double) -> Double {
        creditWindow(s, q).map { start(of: $0) + 1 }.reduce(now, max)
    }
    private static func lastCreditDay(_ s: Object) -> String? {
        queue(s).flatMap { q in creditWindow(s, q).map { day(of: $0) }.max() }
    }

    private static func sweepPins(_ s: inout Object, _ ids: [String], _ today: String) {
        guard !ids.isEmpty, var plan = s["dayPlan"]?.object else { return }
        for (iso, v) in plan where iso >= today && ids.contains(v.stringValue ?? "") { plan[iso] = nil }
        s["dayPlan"] = .object(plan)
    }

    private static func pass(_ ids: [String], label: String?, rotationId: JSONValue?, startsOn: String, since: Double, strict: Bool = false) -> JSONValue {
        var q: Object = ["ids": .array(ids.map(JSONValue.string)), "since": .number(since), "startsOn": .string(startsOn)]
        q["label"] = label.map(JSONValue.string)
        q["rotationId"] = rotationId
        if strict { q["strict"] = .bool(true) }
        return .object(q)
    }

    private static func label(_ s: Object) -> String { s["rotation"]?.object?["label"]?.stringValue ?? "" }
    private static func setRotation(_ s: inout Object, _ key: String, _ value: JSONValue) {
        var r = s["rotation"]?.object ?? [:]
        r[key] = value
        s["rotation"] = .object(r)
    }

    /// Starts a pass of the saved loop. False when there is no loop to start.
    @discardableResult
    public static func startPass(_ s: inout Object, today: String, now: Double) -> Bool {
        let seq = sequence(s)
        if !seq.isEmpty, !isSimple(seq), let seg = segment(seq, at: position(s)) {
            setRotation(&s, "at", .number(Double(seg.start)))
            s["queue"] = pass(seg.ids, label: label(s), rotationId: s["rotation"]?.object?["id"], startsOn: today, since: now)
            return true
        }
        let ids = rotationIds(s)
        guard !ids.isEmpty else { return false }
        s["queue"] = pass(ids, label: label(s), rotationId: s["rotation"]?.object?["id"], startsOn: today, since: now)
        return true
    }

    /// Saves the loop as `ids` (routine ids and "rest") and keeps the running pass in step.
    /// `newId` names a loop that has no id yet.
    public static func saveRotation(_ s: inout Object, ids: [String], label: String?, today: String, now: Double, newId: () -> String) {
        guard !ids.isEmpty else { return }
        let prev = queue(s)
        let prevRaw = s["queue"]?.object
        let id = s["rotation"]?.object?["id"].flatMap { $0 == .null ? nil : $0 } ?? .string(newId())
        let simple = isSimple(ids)
        var rotation: Object = ["id": id, "sequence": .array(ids.map(JSONValue.string))]
        rotation["label"] = label.map(JSONValue.string)

        var passIds = ids
        let ownPrev = prev != nil && s["rotation"]?.object != nil && prev?.rotationId == s["rotation"]?.object?["id"]
        if !simple {
            let at = position(s).flatMap { $0 < ids.count && $0 >= 0 && ids[$0] != rest ? $0 : nil } ?? 0
            guard let seg = segment(ids, at: at) else { return }
            rotation["at"] = .number(Double(seg.start))
            passIds = seg.ids
        }
        s["rotation"] = .object(rotation)

        var q: Object = [
            "ids": .array(passIds.map(JSONValue.string)),
            "since": prev != nil ? (prevRaw?["since"] ?? .number(now)) : .number(now),
            "startsOn": .string(prev?.startsOn ?? today),
            "rotationId": id,
        ]
        if case .some(.null) = q["since"] { q["since"] = .number(now) }
        q["label"] = label.map(JSONValue.string)
        if prev?.strict == true { q["strict"] = .bool(true) }
        s["queue"] = .object(q)
        sweepPins(&s, (prev?.ids ?? []).filter { !passIds.contains($0) }, today)

        guard let prev, queueView(s, today: today)?.complete == true, let current = queue(s) else { return }
        if simple {
            guard ids.allSatisfy(prev.ids.contains) else { return }
            let last = lastCreditDay(s)
            sweepPins(&s, current.ids, today)
            s["queue"] = pass(rotationIds(s), label: label, rotationId: id, startsOn: last.flatMap { Day.adding(1, to: $0) } ?? today, since: sinceAfter(s, current, now))
        } else if ownPrev {
            advanceLoop(&s, current, bound: lastCreditDay(s), today: today, now: now)
        }
    }

    private static func advanceLoop(_ s: inout Object, _ q: Queue, bound: String?, today: String, now: Double) {
        let seq = sequence(s)
        guard let seg = segment(seq, at: position(s)), let next = segment(seq, at: seg.next) else { return }
        sweepPins(&s, q.ids, today)
        setRotation(&s, "at", .number(Double(next.start)))
        let from = bound.flatMap { Day.adding(1, to: $0) } ?? today
        s["queue"] = pass(next.ids, label: label(s), rotationId: s["rotation"]?.object?["id"], startsOn: Day.adding(seg.rest, to: from) ?? from, since: sinceAfter(s, q, now))
    }

    public static func stopPass(_ s: inout Object, today: String) {
        if let q = queue(s) { sweepPins(&s, q.ids, today) }
        s["queue"] = .null
    }

    /// Switches to the rotation, starting a pass of the saved loop when there is one.
    @discardableResult
    public static func chooseRotation(_ s: inout Object, today: String, now: Double) -> Bool {
        s["scheduleMode"] = .string("rotation")
        if queueRecovery(s) || rotationIds(s).isEmpty { return false }
        return startPass(&s, today: today, now: now)
    }

    /// Back to fixed weekdays; the loop itself is kept for later.
    public static func chooseFixedWeek(_ s: inout Object, today: String) {
        let q = queue(s)
        let rotation = s["rotation"]?.object
        let external = q != nil && (rotation == nil || q?.rotationId != rotation?["id"])
        if !external { stopPass(&s, today: today) }
        s["scheduleMode"] = .string("week")
    }

    /// "Start the loop over": a fresh pass from the top, counting only what is logged from now.
    public static func startNewPass(_ s: inout Object, today: String, now: Double) {
        guard s["rotation"]?.object != nil else { return }
        let seq = sequence(s)
        let loop = !seq.isEmpty && !isSimple(seq) ? segment(seq, at: 0) : nil
        if let loop { setRotation(&s, "at", .number(Double(loop.start))) }
        let ids = loop?.ids ?? rotationIds(s)
        guard !ids.isEmpty else { return }
        let q = queue(s)
        if let q { sweepPins(&s, q.ids, today) }
        // A session already running on one of these routines still counts for the new pass.
        let a = s["active"]?.object
        let aStart = a?["start"]?.numberValue
        let running = a != nil && a?["backfill"].map({ $0 == .bool(false) || $0 == .null }) ?? true
            && aStart != nil && aStart! <= now && routineIds(of: a!).contains { ids.contains($0) }
        let from = running ? aStart! : now
        let since = q.map { sinceAfter(s, $0, from) } ?? from
        s["queue"] = pass(ids, label: label(s), rotationId: s["rotation"]?.object?["id"], startsOn: today, since: since, strict: true)
    }

    /// After a workout finished the pass: the next pass, starting the day after. False when the
    /// queue is not this loop's, or not finished.
    @discardableResult
    public static func refillAfter(_ s: inout Object, workout w: Object, today: String, now: Double) -> Bool {
        guard let q = queue(s), let rid = s["rotation"]?.object?["id"], isTruthy(q.rotationId), isTruthy(rid), q.rotationId == rid,
              queueView(s, today: today)?.complete == true else { return false }
        let bound = [w["d"]?.stringValue, lastCreditDay(s)].compactMap { $0 }.filter { !$0.isEmpty }.max()
        let full = sequence(s)
        if !full.isEmpty, !isSimple(full) {
            guard let seg = segment(full, at: position(s)), seg.ids == q.ids else { return false }
            advanceLoop(&s, q, bound: bound, today: today, now: now)
            return true
        }
        let seq = rotationIds(s)
        // The pass has to be the loop, from wherever it started.
        guard !q.ids.isEmpty, q.ids.count == seq.count, let i = seq.firstIndex(of: q.ids[0]),
              q.ids.indices.allSatisfy({ seq[(i + $0) % seq.count] == q.ids[$0] }) else { return false }
        let credited = routineIds(of: w)
        var next = seq
        if let last = q.ids.last(where: credited.contains), let at = seq.firstIndex(of: last) {
            next = Array(seq[(at + 1)...] + seq[...at])
        }
        sweepPins(&s, q.ids, today)
        s["queue"] = pass(next, label: label(s), rotationId: rid, startsOn: bound.flatMap { Day.adding(1, to: $0) } ?? today, since: sinceAfter(s, q, now))
        return true
    }

    @discardableResult
    public static func refillIfComplete(_ s: inout Object, today: String, now: Double) -> Bool {
        guard let q = queue(s), let rid = s["rotation"]?.object?["id"], isTruthy(q.rotationId), isTruthy(rid), q.rotationId == rid,
              queueView(s, today: today)?.complete == true else { return false }
        let last = creditWindow(s, q).enumerated().sorted { a, b in
            let da = day(of: a.element), db = day(of: b.element)
            if da != db { return da < db }
            let sa = a.element["start"]?.num ?? 0, sb = b.element["start"]?.num ?? 0
            return sa != sb ? sa < sb : a.offset < b.offset
        }.last?.element
        return last.map { refillAfter(&s, workout: $0, today: today, now: now) } ?? false
    }

    private static func isTruthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .none, .some(.null), .some(.bool(false)), .some(.string("")), .some(.number(0)): return false
        default: return true
        }
    }
}

extension Day {
    /// 0 for Sunday to 6 for Saturday, as JavaScript's getDay().
    static func weekday(_ iso: String) -> Int? {
        date(iso).map { Calendar(identifier: .gregorian).component(.weekday, from: $0) - 1 }
    }

    /// The day `n` days from `iso`.
    public static func adding(_ n: Int, to iso: String) -> String? {
        guard let d = date(iso), let moved = Calendar(identifier: .gregorian).date(byAdding: .day, value: n, to: d) else { return nil }
        return Day.iso(moved.timeIntervalSince1970 * 1000)
    }

    public static func today() -> String { iso(Date().timeIntervalSince1970 * 1000) }
}
