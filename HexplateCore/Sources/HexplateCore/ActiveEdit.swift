import Foundation

/// Changes to the live session's exercise list from an exercise's ⋯ menu: move, superset, swap,
/// remove, keep out of progression (active-workout-order.js, active-exercise-swap.js,
/// session-noprog.js, Workout.jsx removeActiveExercise). Each mutates `S.active`.
public enum ActiveEdit {
    public typealias Object = [String: JSONValue]

    static func entries(_ a: Object) -> [JSONValue] { a["entries"]?.arrayValue ?? [] }
    static func sg(_ e: JSONValue) -> String? { e.object?["sg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    static func cur(_ a: Object) -> Int { Int(a["cur"]?.num ?? 0) }

    /// Neighbouring entries that share a superset tag, as index lists (supersetUnits).
    public static func units(_ list: [JSONValue]) -> [[Int]] {
        var out: [[Int]] = []
        for i in list.indices {
            if i > 0, let tag = sg(list[i]), sg(list[i - 1]) == tag { out[out.count - 1].append(i) } else { out.append([i]) }
        }
        return out
    }

    // MARK: Order

    static func unitMove(_ a: Object, _ i: Int, _ d: Int) -> (units: [[Int]], source: Int, target: Int)? {
        guard d == 1 || d == -1 else { return nil }
        let u = units(entries(a))
        guard let source = u.firstIndex(where: { $0.contains(i) }), u.indices.contains(source + d) else { return nil }
        return (u, source, source + d)
    }

    /// Inside a superset an exercise swaps with its partner; otherwise its whole unit moves.
    static func memberSwap(_ a: Object, _ i: Int, _ d: Int) -> (unit: [Int], target: Int)? {
        guard d == 1 || d == -1, let unit = units(entries(a)).first(where: { $0.contains(i) }), unit.count > 1, unit.contains(i + d) else { return nil }
        return (unit, i + d)
    }

    static func crossesMarker(_ a: Object, _ unit: [Int], _ i: Int, _ target: Int) -> Bool {
        let c = cur(a)
        return unit.contains(c) && min(i, target) < c && max(i, target) >= c
    }

    public static func canMove(_ a: Object, _ i: Int, _ d: Int) -> Bool {
        if let s = memberSwap(a, i, d) { return !crossesMarker(a, s.unit, i, s.target) }
        return unitMove(a, i, d) != nil
    }

    public static func move(_ a: inout Object, _ i: Int, _ d: Int) {
        let list = entries(a)
        if let s = memberSwap(a, i, d) {
            guard !crossesMarker(a, s.unit, i, s.target) else { return }
            var next = list
            next.swapAt(i, s.target)
            a["entries"] = .array(next)
            return
        }
        guard var m = unitMove(a, i, d) else { return }
        m.units.swapAt(m.source, m.target)
        let order = m.units.flatMap { $0 }
        a["entries"] = .array(order.map { list[$0] })
        a["cur"] = .number(Double(order.firstIndex(of: i) ?? 0))
    }

    // MARK: Supersets

    public static func pair(_ a: inout Object, _ first: Int, _ second: Int) {
        if let next = RoutineOps.pairAdjacent(entries(a), first, second) { a["entries"] = .array(next) }
    }

    public static func unpair(_ a: inout Object, _ i: Int) {
        if let next = RoutineOps.unpairSuperset(entries(a), i) { a["entries"] = .array(next) }
    }

    // MARK: Remove, swap, progression

    public static func remove(_ a: inout Object, _ i: Int) {
        var list = entries(a)
        guard list.indices.contains(i) else { return }
        list.remove(at: i)
        RoutineOps.cleanupSupersets(&list)
        a["entries"] = .array(list)
        var c = cur(a)
        if i < c { c -= 1 }
        if c >= list.count { c = max(0, list.count - 1) }
        a["cur"] = .number(Double(c))
    }

    public static func hasLoggedSet(_ e: Object) -> Bool { (e["sets"]?.arrayValue ?? []).contains { $0.object?["done"] == .bool(true) } }

    /// Puts `replacement` in place of entry `i`. With sets logged the original stays and the
    /// replacement goes after it: next to it inside its superset (`keepGroup`), else after the
    /// superset (swapActiveExercise).
    public static func swap(_ a: inout Object, _ i: Int, with replacement: Object, keepGroup: Bool = false) {
        var list = entries(a)
        guard list.indices.contains(i), let current = list[i].object else { return }
        if !hasLoggedSet(current) {
            var next = current.filter { !["id", "target", "plan", "planned", "carried", "sets", "sg"].contains($0.key) }
            next.merge(replacement) { _, b in b }
            if let tag = sg(list[i]) { next["sg"] = .string(tag) }
            list[i] = .object(next)
            a["entries"] = .array(list)
            a["cur"] = .number(Double(i))
            return
        }
        let keep = keepGroup && sg(list[i]) != nil
        let unit = units(list).first { $0.contains(i) } ?? [i]
        let at = keep ? i + 1 : (unit.count > 1 ? unit.last! + 1 : i + 1)
        var entry = replacement
        if let rid = current["rid"] { entry["rid"] = rid }
        if keep { entry["sg"] = list[i].object?["sg"] }
        list.insert(.object(entry), at: at)
        a["entries"] = .array(list)
        a["cur"] = .number(Double(at))
    }

    /// One exercise kept out of progression or counted again; counting one again means the
    /// session as a whole is no longer out (setEntryNoProg).
    public static func setNoProg(_ a: inout Object, _ i: Int, _ on: Bool) {
        var list = entries(a)
        guard list.indices.contains(i), var e = list[i].object else { return }
        e["noProg"] = on ? .bool(true) : nil
        list[i] = .object(e)
        a["entries"] = .array(list)
        if !on { a["noProg"] = nil }
    }
}

extension ActiveEdit {
    public static let noteMax = 500

    /// The session note: trimmed, at most 500 characters, blank removes it (SessionNote).
    public static func setNote(_ a: inout Object, _ text: String) {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(noteMax))
        a["note"] = t.isEmpty ? nil : .string(t)
    }

    /// A name of its own (RenameWorkout): trimmed, at most 60 characters; blank changes nothing.
    public static func rename(_ a: inout Object, _ text: String) {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !t.isEmpty else { return }
        a["name"] = .string(t)
        a["customName"] = .bool(true)
    }

    /// "Push + Pull", or "A + B + 2 more" past three (session-merge.js deriveSessionName).
    public static func sessionName(_ names: [String]) -> String? {
        if names.isEmpty { return nil }
        return names.count <= 3 ? names.joined(separator: " + ") : "\(names[0]) + \(names[1]) + \(names.count - 2) more"
    }

    /// Another routine's exercises at the end of the session (AddRoutineToSession).
    public static func addRoutine(_ a: inout Object, _ s: Object, _ routine: Object, catalog c: ExerciseCatalog) {
        let whole = a["noProg"] == .bool(true)
        let added = Session.entries(s, routine: routine, catalog: c).map { e -> JSONValue in
            guard whole, var o = e.object else { return e }
            o["noProg"] = .bool(true)
            return .object(o)
        }
        a["entries"] = .array(entries(a) + added)
        let old = a["routineIds"] ?? .null
        var ids = old.arrayValue ?? (old == .null ? [] : [old])
        ids.append(routine["id"] ?? .null)
        a["routineIds"] = .array(ids)
        if a["customName"] != .bool(true) {
            let routines = (s["routines"]?.arrayValue ?? []).compactMap(\.object)
            let names = ids.compactMap { id in routines.first { $0["id"] == id }?["name"]?.stringValue }
            a["name"] = sessionName(names).map(JSONValue.string) ?? .null
        }
    }

    /// The whole session kept out of progression, or counted again except what a deload or rehab
    /// routine keeps out itself (setSessionNoProg).
    public static func setSessionNoProg(_ a: inout Object, _ on: Bool, routineOwns: (Object) -> Bool) {
        var list = entries(a)
        for i in list.indices {
            guard var e = list[i].object else { continue }
            if on { e["noProg"] = .bool(true) } else if !routineOwns(e) { e["noProg"] = nil }
            list[i] = .object(e)
        }
        a["entries"] = .array(list)
        a["noProg"] = on ? .bool(true) : nil
    }

    /// The exercise's own rest this session: nil the default, 0 no timer (openExerciseRest).
    public static func setExerciseRest(_ a: inout Object, _ i: Int, _ sec: Double?) {
        var list = entries(a)
        guard list.indices.contains(i), var e = list[i].object else { return }
        var t = e["target"]?.object ?? [:]
        t["restSec"] = nil; t["restOff"] = nil
        if let sec { if sec > 0 { t["restSec"] = .number(sec) } else { t["restOff"] = .bool(true) } }
        e["target"] = .object(t)
        list[i] = .object(e)
        a["entries"] = .array(list)
    }

    /// ownExerciseRest: the exercise's own rest, 0 when switched off, nil for the default.
    public static func exerciseRest(_ target: Object?) -> Double? {
        let v = Session.jsRound(target?["restSec"]?.num ?? 0)
        if v.isFinite && v > 0 { return v }
        return target?["restOff"] == .bool(true) ? 0 : nil
    }
}

/// One set's own menu in a live session (Workout.jsx openSetMenu): failure, copy, phase, its own
/// rest, a note, remove. Rows as stored on the entry; each returns the new rows.
public enum SetEdit {
    public typealias Object = [String: JSONValue]
    public static let restMax = 15.0 * 60

    static func o(_ rows: [JSONValue], _ i: Int) -> Object? { rows.indices.contains(i) ? rows[i].object : nil }

    /// The rows one set takes up: a timed per-side hold is an L row and an R row (setSpanAt).
    public static func span(_ rows: [JSONValue], _ i: Int) -> (start: Int, count: Int) {
        let side = { (j: Int) in o(rows, j)?["side"]?.stringValue }
        if side(i) == "L" && side(i + 1) == "R" { return (i, 2) }
        if side(i) == "R" && side(i - 1) == "L" { return (i - 1, 2) }
        return (i, 1)
    }

    public static func isFailure(_ row: JSONValue) -> Bool {
        row.object?["failure"] == .bool(true) && !Recovery.isWarmupRow(row.object)
    }

    /// Taken to failure, on or off for the whole set.
    public static func toggleFailure(_ rows: [JSONValue], _ i: Int) -> [JSONValue] {
        guard rows.indices.contains(i) else { return rows }
        var next = rows
        let s = span(rows, i), on = !isFailure(rows[i])
        for j in s.start..<(s.start + s.count) where isFailure(next[j]) != on {
            guard var r = next[j].object else { continue }
            r["failure"] = r["failure"] == .bool(true) ? nil : .bool(true)
            next[j] = .object(r)
        }
        return next
    }

    static func isType(_ r: Object, _ t: String) -> Bool { r["type"] == .string(t) }
    public static func canBeWarmup(_ row: JSONValue) -> Bool {
        guard let r = row.object else { return false }
        return !Recovery.isWarmupRow(r) && !isType(r, "dropset") && !isType(r, "restpause")
    }

    /// A row moved to the edge of the warm-ups (placeRow).
    static func place(_ rows: [JSONValue], _ i: Int, _ row: Object) -> [JSONValue] {
        var next = rows
        next.remove(at: i)
        let firstWork = next.firstIndex { !Recovery.isWarmupRow($0.object) } ?? next.count
        next.insert(.object(row), at: firstWork)
        return next
    }

    public static func makeWarmup(_ rows: [JSONValue], _ i: Int) -> [JSONValue] {
        guard let src = o(rows, i), canBeWarmup(rows[i]) else { return rows }
        var warm: Object
        if Session.isSideSet(rows[i]), let sides = src["sides"]?.object {
            func side(_ v: JSONValue?) -> JSONValue {
                let s = v?.object ?? [:]
                var out: Object = ["w": .number(s["w"]?.num ?? 0), "done": .bool(Session.truthy(s["done"]))]
                out["r"] = s["r"]
                return .object(out)
            }
            warm = Session.syncSides(["phase": .string("warmup"), "warmup": .bool(true), "edited": .bool(true), "sides": .object(["L": side(sides["L"]), "R": side(sides["R"])])]).object ?? [:]
        } else {
            warm = ["w": .number(src["w"]?.num ?? 0), "done": .bool(Session.truthy(src["done"])),
                    "phase": .string("warmup"), "warmup": .bool(true), "edited": .bool(true)]
            warm["r"] = src["r"]
        }
        if let at = src["at"], at != .null { warm["at"] = at }
        return place(rows, i, warm)
    }

    public static func makeWork(_ rows: [JSONValue], _ i: Int) -> [JSONValue] {
        guard var src = o(rows, i), Recovery.isWarmupRow(src) else { return rows }
        for k in ["phase", "warmup", "edited"] { src[k] = nil }
        return place(rows, i, src)
    }

    /// The set's own rest this session: nil goes back to the exercise's, 0 is no timer.
    public static func setRest(_ rows: [JSONValue], _ i: Int, _ sec: Double?) -> [JSONValue] {
        let start = span(rows, i).start
        guard var r = o(rows, start) else { return rows }
        r["restSec"] = sec.map { .number(Session.jsRound(max(0, min(restMax, $0)))) }
        var next = rows
        next[start] = .object(r)
        return next
    }

    /// ownSetRest: the set's own rest in seconds, nil when it has none.
    public static func ownRest(_ row: JSONValue?) -> Double? {
        guard case .number(let v)? = row?.object?["restSec"], v.isFinite, v >= 0 else { return nil }
        return Session.jsRound(v)
    }

    public static func note(_ row: JSONValue?) -> String {
        (row?.object?["note"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// withSetNote: control characters become spaces, at most 140 characters, blank removes it.
    public static func setNote(_ rows: [JSONValue], _ i: Int, _ text: String) -> [JSONValue] {
        let start = span(rows, i).start
        guard var r = o(rows, start) else { return rows }
        let clean = String(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? " " : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // ponytail: counts characters, JavaScript counts UTF-16 units; differs only past 140 with emoji.
        let cut = String(clean.prefix(140))
        r["note"] = cut.isEmpty ? nil : .string(cut)
        var next = rows
        next[start] = .object(r)
        return next
    }

    static let notCopied = ["done", "at", "planSec", "weightOrigin", "type", "drops", "clusters", "media"]
    static func bare(_ r: Object) -> Object { r.filter { !notCopied.contains($0.key) } }

    /// "One more like this one": an unticked copy right below (copyRowAt).
    public static func copy(_ rows: [JSONValue], _ i: Int) -> [JSONValue] {
        guard rows.indices.contains(i) else { return rows }
        let work = { (j: Int) -> String? in
            guard let r = o(rows, j), !Recovery.isWarmupRow(r) else { return nil }
            return r["side"]?.stringValue
        }
        let start = work(i) == "R" && work(i - 1) == "L" ? i - 1 : i
        let end = work(start) == "L" && work(start + 1) == "R" ? start + 1 : start
        let copies: [JSONValue] = rows[start...end].map { row in
            let src = row.object ?? [:]
            if Session.isSideSet(row), let sides = src["sides"]?.object {
                func side(_ v: JSONValue?) -> JSONValue { var s = bare(v?.object ?? [:]); s["done"] = .bool(false); return .object(s) }
                var out = bare(src)
                out["sides"] = .object(["L": side(sides["L"]), "R": side(sides["R"])])
                out["done"] = .bool(false)
                return Session.syncSides(out)
            }
            var out = bare(src)
            out["done"] = .bool(false)
            return .object(out)
        }
        var next = rows
        next.insert(contentsOf: copies, at: end + 1)
        return next
    }

    /// The set (both rows of a timed per-side pair) out; the last set always stays (removeRowAt).
    public static func remove(_ rows: [JSONValue], _ i: Int) -> [JSONValue] {
        guard rows.indices.contains(i) else { return rows }
        let s = span(rows, i)
        guard rows.count > s.count else { return rows }
        var next = rows
        next.removeSubrange(s.start..<(s.start + s.count))
        return next
    }
}
