import Foundation

/// Editing a plan: routines and the exercises in them. Ported from frontend/src/lib/routines.js,
/// history.js and superset-meta.js; RoutineGoldenTests holds it to their output. A planned
/// exercise ("slot") is kept as the document has it, so fields Hexplate does not edit survive.
public enum RoutineOps {
    public typealias Object = [String: JSONValue]

    // MARK: Routines

    /// Ephemeral date-scoped AI Coach clones (`aiClone: true`) live in `routines[]` for openGym
    /// sync compatibility but stay hidden from user-facing routine lists.
    public static func isAIClone(_ routine: Object) -> Bool {
        routine["aiClone"] == .bool(true)
    }

    /// Routine IDs currently referenced by any schedule pointer or active session.
    /// When `dayPlanFrom` is provided, only `dayPlan` pins on or after `dayPlanFrom` count as
    /// active references (so past pins do not keep expired `aiClone` routines alive forever).
    static func referencedRoutineIds(in s: Object, dayPlanFrom: String? = nil) -> Set<String> {
        var ids = Set<String>()
        for (iso, value) in s["dayPlan"]?.object ?? [:] {
            if let from = dayPlanFrom, iso < from { continue }
            if let id = value.stringValue, !id.isEmpty, id != Schedule.rest { ids.insert(id) }
        }
        for value in s["week"]?.object?.values ?? [:].values {
            if let id = value.stringValue, !id.isEmpty { ids.insert(id) }
            for id in Schedule.strings(value) where !id.isEmpty { ids.insert(id) }
        }
        for id in Schedule.strings(s["rotation"]?.object?["sequence"]) where !id.isEmpty && id != Schedule.rest {
            ids.insert(id)
        }
        for id in Schedule.strings(s["queue"]?.object?["ids"]) where !id.isEmpty {
            ids.insert(id)
        }
        if let active = s["active"]?.object {
            for id in Schedule.strings(active["routineIds"]) where !id.isEmpty { ids.insert(id) }
            if let id = active["routineId"]?.stringValue, !id.isEmpty { ids.insert(id) }
        }
        return ids
    }

    /// Removes a routine, any `aiClone` routines derived from it (1d cascade), and every pointer to
    /// them in `week` (a day left empty loses its key) and `dayPlan`.
    public static func deleteRoutine(_ s: inout Object, id: String) {
        let raw = s["routines"]?.arrayValue ?? []
        var toDelete: Set<String> = [id]
        for r in raw.compactMap(\.object) where isAIClone(r) && r["cloneOf"] == .string(id) {
            if let cid = r["id"]?.stringValue { toDelete.insert(cid) }
        }
        s["routines"] = .array(raw.filter { v in
            guard let rid = v.object?["id"]?.stringValue else { return true }
            return !toDelete.contains(rid)
        })
        if var week = s["week"]?.object {
            for (day, v) in week {
                let ids = v.stringValue.map { [$0] } ?? Schedule.strings(v)
                guard ids.contains(where: toDelete.contains) else { continue }
                let left = ids.filter { !toDelete.contains($0) }
                week[day] = left.isEmpty ? nil : .array(left.map(JSONValue.string))
            }
            s["week"] = .object(week)
        }
        if var plan = s["dayPlan"]?.object {
            for (iso, v) in plan where v.stringValue.map(toDelete.contains) == true { plan[iso] = nil }
            s["dayPlan"] = .object(plan)
        }
    }

    /// Garbage-collects stale or past-orphan `aiClone` routines on app launch, clearing any past
    /// `dayPlan` pins pointing to pruned clones:
    /// 1. Clones not referenced by any current/future `dayPlan` (`iso >= today`), `week`,
    ///    `rotation`, `queue`, or `active` with missing/invalid `ephemeralDate` or
    ///    `ephemeralDate < today - maxAgeDays`.
    /// 2. Orphan clones (parent deleted/missing) with missing/invalid `ephemeralDate` or
    ///    `ephemeralDate < today` (keeping today's and future orphans runnable until their date passes).
    public static func pruneExpiredClones(_ s: inout Object, today: String, maxAgeDays: Int = 30) {
        guard let cutoff = Day.adding(-maxAgeDays, to: today),
              let raw = s["routines"]?.arrayValue, !raw.isEmpty else { return }
        let liveParents = Set(raw.compactMap(\.object).filter { !isAIClone($0) }.compactMap { $0["id"]?.stringValue })
        let activeReferences = referencedRoutineIds(in: s, dayPlanFrom: today)

        var kept: [JSONValue] = []
        var prunedIds = Set<String>()
        kept.reserveCapacity(raw.count)

        for value in raw {
            guard let r = value.object, isAIClone(r), let rid = r["id"]?.stringValue else {
                kept.append(value)
                continue
            }
            let ephem = r["ephemeralDate"]?.stringValue
            let validDate = ephem.map { Programmes.isISO(.string($0)) } ?? false
            let parentId = r["cloneOf"]?.stringValue
            let isOrphan = (parentId == nil || parentId!.isEmpty || !liveParents.contains(parentId!))
            let pruneOrphan = isOrphan && (!validDate || ephem! < today)
            let pruneExpiredUnreferenced = !activeReferences.contains(rid) && (!validDate || ephem! < cutoff)

            if pruneOrphan || pruneExpiredUnreferenced {
                prunedIds.insert(rid)
            } else {
                kept.append(value)
            }
        }

        if kept.count != raw.count {
            s["routines"] = .array(kept)
        }
        if !prunedIds.isEmpty, var plan = s["dayPlan"]?.object {
            var planChanged = false
            for (iso, v) in plan where v.stringValue.map(prunedIds.contains) == true {
                plan[iso] = nil
                planChanged = true
            }
            if planChanged { s["dayPlan"] = .object(plan) }
        }
    }

    /// A copy under a new id: "Push (Copy)", and "Push (Copy 2)" for a copy of that.
    /// Strips ephemeral AI clone markers so user-duplicated routines stay visible and are never GC'd.
    public static func copyRoutine(_ routine: Object, newId: String) -> Object {
        var copy = routine
        copy["id"] = .string(newId)
        copy["aiClone"] = nil
        copy["cloneOf"] = nil
        copy["ephemeralDate"] = nil
        let name = routine["name"]?.stringValue ?? ""
        if let m = name.wholeMatch(of: /^(.*) \(Copy(?: (\d+))?\)$/) {
            copy["name"] = .string("\(m.1) (Copy \((m.2.flatMap { Int($0) } ?? 1) + 1))")
        } else {
            copy["name"] = .string(name + " (Copy)")
        }
        return copy
    }

    public static func newRoutine(id: String, name: String) -> Object {
        ["id": .string(id), "name": .string(name), "emoji": .string("figureStrength"), "ex": .array([])]
    }

    /// An id as the Capacitor app makes them: the time in base 36 and five random characters.
    public static func newId(now: Double = Date().timeIntervalSince1970 * 1000) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        return String(Int(now), radix: 36) + String((0..<5).map { _ in alphabet.randomElement()! })
    }

    // MARK: Supersets

    private static func sg(_ e: JSONValue?) -> String? { e?.object?["sg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }

    private static func group(_ items: [JSONValue], around i: Int) -> ClosedRange<Int> {
        guard let tag = sg(items[i]) else { return i...i }
        var first = i, last = i
        while first > 0, sg(items[first - 1]) == tag { first -= 1 }
        while last + 1 < items.count, sg(items[last + 1]) == tag { last += 1 }
        return first...last
    }

    /// Supersets two neighbours; either one's group, when it has one, takes the other in.
    /// Nil when the two are not neighbours in the list.
    public static func pairAdjacent(_ items: [JSONValue], _ first: Int, _ second: Int) -> [JSONValue]? {
        guard items.indices.contains(first), items.indices.contains(second), abs(first - second) == 1 else { return nil }
        var next = items
        let left = min(first, second), right = max(first, second)
        var tag = sg(next[left]) ?? sg(next[right])
        if tag == nil {
            let base = "sg-\(left)-\(right)"
            var candidate = base, n = 2
            while next.contains(where: { sg($0) == candidate }) { candidate = "\(base)-\(n)"; n += 1 }
            tag = candidate
        }
        for i in Set(group(next, around: left)).union(group(next, around: right)) {
            guard var e = next[i].object else { continue }
            e["sg"] = .string(tag!)
            next[i] = .object(e)
        }
        return next
    }

    /// Takes one exercise out of its superset; a neighbour left alone loses its tag too.
    public static func unpairSuperset(_ items: [JSONValue], _ idx: Int) -> [JSONValue]? {
        guard items.indices.contains(idx), var e = items[idx].object else { return nil }
        var next = items
        e["sg"] = nil
        next[idx] = .object(e)
        dropLonelyTags(&next)
        return next
    }

    private static func dropLonelyTags(_ ex: inout [JSONValue]) {
        // Each entry is judged against its neighbours as they are at that moment, front to back.
        for i in ex.indices {
            guard let tag = sg(ex[i]), var e = ex[i].object else { continue }
            let before = i > 0 ? sg(ex[i - 1]) : nil, after = i + 1 < ex.count ? sg(ex[i + 1]) : nil
            if before != tag && after != tag { e["sg"] = nil; ex[i] = .object(e) }
        }
    }

    /// After any edit of the list: tags that lost their partner go, and every member of a group
    /// carries the group's name and rest (superset-meta.js syncSupersetMeta).
    public static func cleanupSupersets(_ ex: inout [JSONValue]) {
        dropLonelyTags(&ex)
        var names: [String: String] = [:], rests: [String: Double] = [:], order: [String] = []
        for i in ex.indices {
            guard var e = ex[i].object else { continue }
            guard let tag = sg(ex[i]) else {
                e["sgName"] = nil; e["sgRest"] = nil
                ex[i] = .object(e)
                continue
            }
            if !order.contains(tag) { order.append(tag) }
            if names[tag] == nil, let name = e["sgName"]?.stringValue, !name.isEmpty { names[tag] = name }
            if rests[tag] == nil, let rest = e["sgRest"]?.num, rest > 0 { rests[tag] = rest }
        }
        for tag in order {
            let name = String((names[tag] ?? "").trimmingCharacters(in: .whitespaces).prefix(40))
            let rest = rests[tag].map { ($0 + 0.5).rounded(.down) } ?? 0
            for i in ex.indices where sg(ex[i]) == tag {
                guard var e = ex[i].object else { continue }
                e["sgName"] = name.isEmpty ? nil : .string(name)
                e["sgRest"] = rest > 0 ? .number(rest) : nil
                ex[i] = .object(e)
            }
        }
    }

    // MARK: A planned exercise

    /// What a freshly picked exercise starts with: a hold is timed, cardio has minutes and a
    /// speed, a one-limb exercise is per side (history.js pickedExerciseConfig).
    public static func pickedConfig(id: String, catalog: ExerciseCatalog) -> Object {
        let ex = catalog[id]
        if ex?.isHold != true, ex?.isCardio == true {
            return ["sets": .number(1), "min": .number(20), "speed": .number(8)]
        }
        let timed = ex?.isHold == true
        var cfg: Object = ["sets": .number(3), "weight": .number(0), "mode": .string(timed ? "time" : "reps")]
        cfg[timed ? "sec" : "reps"] = .number(timed ? 45 : 10)
        if ex?.isBodyweightEquipment == true { cfg["bodyweight"] = .bool(true) }
        if ex?.isOneLimb == true {
            cfg["side"] = .bool(true)
            if !timed { cfg["reps"] = .number(20) }
        }
        return cfg
    }

    /// How a slot is logged (history.js modeOf).
    public static func mode(_ cfg: Object, catalog: ExerciseCatalog) -> String {
        if let m = cfg["mode"]?.stringValue, ["reps", "time", "cardio"].contains(m) { return m }
        if present(cfg["min"]) || present(cfg["speed"]) { return "cardio" }
        return cfg["id"]?.stringValue.flatMap { catalog[$0] }?.isCardio == true ? "cardio" : "reps"
    }

    public static func isBodyweight(_ cfg: Object, catalog: ExerciseCatalog) -> Bool {
        if let v = cfg["bodyweight"], v != .null { return v == .bool(true) }
        return cfg["id"]?.stringValue.flatMap { catalog[$0] }?.isBodyweightEquipment == true
    }

    private static func present(_ v: JSONValue?) -> Bool { v != nil && v != .null }
    private static func positive(_ v: JSONValue?, or fallback: Double) -> Double { (v?.num ?? 0) != 0 ? v!.num : fallback }

    /// "3 × 8–10 · 62.5 kg", "3 × 12–16 · 20 kg · 6–8/side", "2 × 0:45": what a slot asks for
    /// (history.js exLine).
    // ponytail: pyramids and back-off sets read as their plain sets × reps; port pyramid.js and
    // backoff.js when the editor can make them.
    public static func line(_ cfg: Object, catalog: ExerciseCatalog, settings: ProfileSettings) -> String {
        let num = { (n: Double) in Format.number(n, decimals: settings.weightDecimals) }
        let m = mode(cfg, catalog: catalog)
        let n = Format.plain(positive(cfg["sets"], or: 1))
        let weight = cfg["weight"]?.num ?? 0
        let load = weight == 0 ? "" : " · " + (isBodyweight(cfg, catalog: catalog) ? "+" : "") + num(weight) + " " + settings.unit
        let side = cfg["side"] == .bool(true)

        if m == "cardio" {
            let kmh = positive(cfg["speed"], or: 8)
            let shown = settings.speedUnit == "mph" ? (kmh / 1.609344 * 100 + 0.5).rounded(.down) / 100 : kmh
            let incline = (cfg["incline"]?.num ?? 0) > 0 ? " · \(num(cfg["incline"]!.num))% incline" : ""
            return "\(n) × \(Format.plain(positive(cfg["min"], or: 20))) min @ \(num(shown)) \(settings.speedUnit == "mph" ? "mph" : "km/h")" + incline
        }
        if m == "time" {
            return "\(n) × \(Format.seconds(positive(cfg["sec"], or: 45)))" + load + (side ? " · per side" : "")
        }
        let reps = cfg["reps"]?.num ?? 0, low = cfg["repsMin"]?.num ?? 0
        let range = { (text: (Double) -> String) in low > 0 && low < reps ? "\(text(low))–\(text(reps))" : text(reps) }
        let setsMax = cfg["setsMax"]?.num ?? 0
        let sets = setsMax > positive(cfg["sets"], or: 1) ? "\(n)–\(Format.plain(setsMax))" : n
        return "\(sets) × \(range(Format.plain))" + load + (side ? " · \(range { num($0 / 2) })/side" : "")
    }
}
