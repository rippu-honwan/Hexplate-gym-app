import Foundation

/// A saved workout copied forward: "Save as routine" (session-routines.js routineFromSession) and
/// "Repeat today" (session-repeat.js repeatSessionEntries). The saved record is never touched.
public enum SessionCopy {
    public typealias Object = [String: JSONValue]

    // MARK: JavaScript number reads

    /// `Number(v)` when finite (null reads as 0, as in JavaScript).
    static func finite(_ v: JSONValue?) -> Double? {
        switch v {
        case nil: return nil
        case .null?: return 0
        case .bool(let b)?: return b ? 1 : 0
        case .number(let d)?: return d.isFinite ? d : nil
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? 0 : Double(t).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }
    static func positive(_ v: JSONValue?) -> Double? { finite(v).flatMap { $0 > 0 ? $0 : nil } }
    static func present(_ v: JSONValue?) -> Bool { v != nil && v != .null }

    // MARK: Modes (workout-model.js modeForEntry, history.js defaultConfig)

    static let modes = ["reps", "time", "cardio"]
    static func token(_ v: JSONValue?) -> String { v?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "" }
    static func explicitMode(_ o: Object) -> String? {
        let m = token(o["mode"])
        if modes.contains(m) { return m }
        switch token(o["unit"]) {
        case "rep", "reps", "repetition", "repetitions": return "reps"
        case "sec", "secs", "second", "seconds": return "time"
        case "min", "mins", "minute", "minutes": return "cardio"
        default: return nil
        }
    }
    static func inferredMode(_ o: Object) -> String? {
        if let m = explicitMode(o) { return m }
        if token(o["mode"]) == "amrap" { return "reps" }
        if present(o["min"]) || present(o["speed"]) { return "cardio" }
        if present(o["sec"]) || present(o["seconds"]) || present(o["durationSec"]) { return "time" }
        if present(o["r"]) || present(o["reps"]) || present(o["actualReps"]) { return "reps" }
        return nil
    }
    static func modeForSet(_ row: Object, _ target: Object) -> String {
        explicitMode(row) ?? inferredMode(target) ?? inferredMode(row) ?? "reps"
    }
    static func modeForEntry(_ entry: Object, fallback: String) -> String? {
        let target = entry["target"]?.object ?? entry
        let rows = entry["sets"]?.arrayValue ?? []
        let work = rows.filter { !Session.isWarmup($0) }
        let found = Set((work.isEmpty ? rows : work).map { modeForSet($0.object ?? [:], target) })
        if found.count > 1 { return nil }
        if let m = found.first { return m }
        return inferredMode(target) ?? (modes.contains(fallback) ? fallback : "reps")
    }
    static func defaultConfig(_ id: String?, _ m: String?, _ c: ExerciseCatalog) -> Object {
        let ex = id.flatMap { c[$0] }
        let mode = m ?? (ex?.isHold == true ? "time" : RoutineOps.mode(["id": id.map(JSONValue.string) ?? .null], catalog: c))
        if mode == "cardio" { return ["sets": .number(1), "min": .number(20), "speed": .number(8)] }
        var cfg: Object = mode == "time"
            ? ["sets": .number(3), "sec": .number(45), "weight": .number(0), "mode": .string("time")]
            : ["sets": .number(3), "reps": .number(10), "weight": .number(0), "mode": .string("reps")]
        if ex?.isBodyweightEquipment == true { cfg["bodyweight"] = .bool(true) }
        return cfg
    }
    /// Planned sets a count of logged rows stands for: a per-side hold logs L and R rows (history.js setsFromRows).
    static func setsFromRows(_ cfg: Object, _ rows: Int, _ c: ExerciseCatalog) -> Int {
        RoutineOps.mode(cfg, catalog: c) == "time" && Session.isPerSide(cfg) ? (rows + 1) / 2 : rows
    }

    // MARK: Save as routine

    static func evenTotal(_ v: JSONValue?) -> Double? { positive(v).map { max(2, 2 * Session.jsRound($0 / 2)) } }
    static func doneSides(_ row: Object) -> [String] { ["L", "R"].filter { row["sides"]?.object?[$0]?.object?["done"] == .bool(true) } }
    static func perSideReps(_ row: Object, _ target: Object) -> Double? {
        guard Session.isSideSet(.object(row)) else { return positive(row["r"]) }
        let done = doneSides(row), sides = row["sides"]?.object ?? [:]
        if done.count == 1 { return evenTotal(target["reps"]) ?? evenTotal(sides[done[0]]?.object?["r"]) }
        if done.count < 2 { return nil }
        return evenTotal(.number(done.reduce(0) { $0 + (positive(sides[$1]?.object?["r"]) ?? 0) }))
    }
    static func perSideWeight(_ row: Object) -> Double? {
        guard Session.isSideSet(.object(row)) else { return finite(row["w"]) }
        let sides = row["sides"]?.object ?? [:]
        return doneSides(row).compactMap { finite(sides[$0]?.object?["w"]) }.max()
    }
    static func scalarGroup(_ v: JSONValue?) -> String? {
        switch v {
        case .string(let s)?: return s.isEmpty ? nil : s
        case .number(let d)?: return WorkoutEdit.jsString(.number(d))
        default: return nil
        }
    }
    static let sessionOnly = ["planned", "plan", "carried", "rid", "noProg", "muscleSnapshot", "rowReps"]

    /// One saved entry as a plan (session-routines.js copiedEntry).
    static func copiedEntry(_ entry: Object, _ source: Object?, _ c: ExerciseCatalog) -> Object {
        let rows = entry["sets"]?.arrayValue ?? []
        let work = rows.filter { !Session.isWarmup($0) }
        let row = work.last { $0.object?["done"] == .bool(true) }?.object
        let target = entry["target"]?.object ?? [:]
        var withId = target; withId["id"] = entry["id"] ?? .null
        let defaults = defaultConfig(entry["id"]?.stringValue, modeForEntry(entry, fallback: RoutineOps.mode(withId, catalog: c)), c)
        let merged = defaults.merging(target) { $1 }
        var cfg = merged
        cfg["id"] = entry["id"] ?? .null
        cfg["sets"] = .number(Double(max(1, setsFromRows(merged, work.count, c))))
        cfg["warmupSets"] = .number(Double(rows.count - work.count))
        let mode = RoutineOps.mode(cfg, catalog: c)
        if mode == "time", let row {
            cfg["sec"] = present(row["sec"]) ? row["sec"] : cfg["sec"]
            cfg["weight"] = present(row["w"]) ? row["w"] : present(cfg["weight"]) ? cfg["weight"] : .number(0)
        } else if mode == "cardio", let row {
            if present(row["min"]) { cfg["min"] = row["min"] }
            if present(row["speed"]) { cfg["speed"] = row["speed"] }
        } else if mode == "reps" {
            let perSide = Session.isPerSide(cfg)
            if let reps = row.map({ perSide ? perSideReps($0, cfg) : positive($0["r"]) }) ?? nil { cfg["reps"] = .number(reps) }
            if let row, let w = perSideWeight(row) { cfg["weight"] = .number(w) }
            if perSide && row == nil, let even = evenTotal(cfg["reps"]) { cfg["reps"] = .number(even) }
        }
        if let planned = entry["planned"]?.object {
            cfg["sets"] = .number(max(1, positive(planned["sets"]) ?? 1))
            if mode == "reps", positive(planned["reps"]) != nil {
                cfg["reps"] = planned["reps"]
                cfg["repsMin"] = positive(planned["repsMin"]) != nil ? planned["repsMin"] : nil
            }
            if mode == "time", positive(planned["sec"]) != nil { cfg["sec"] = planned["sec"] }
        }
        if !Session.truthy(cfg["prog"]), let p = source?["prog"]?.stringValue, !p.isEmpty { cfg["prog"] = .string(p) }
        cfg["sg"] = scalarGroup(entry["sg"].flatMap { $0 == .null ? nil : $0 } ?? target["sg"]).map(JSONValue.string)
        for k in sessionOnly { cfg[k] = nil }
        return cfg
    }

    /// Fresh superset tags for each run of a shared tag; a run of one is no group (session-routines.js groupIds).
    static func groupIds(_ ex: [Object], newId: () -> String) -> [Object] {
        var next = ex, i = 0
        while i < next.count {
            guard let raw = next[i]["sg"]?.stringValue, !raw.isEmpty else { next[i]["sg"] = nil; i += 1; continue }
            let start = i
            while i + 1 < next.count, next[i + 1]["sg"]?.stringValue == raw { i += 1 }
            if i == start { next[start]["sg"] = nil } else {
                let mapped = JSONValue.string("sg-\(newId())")
                for j in start...i { next[j]["sg"] = mapped }
            }
            i += 1
        }
        return next
    }

    /// The workout as a new routine; nil when nothing in it was logged.
    public static func routine(from w: Object, name: String?, routines: [Object], catalog c: ExerciseCatalog,
                               newId: () -> String = { RoutineOps.newId() }) -> Object? {
        let byId = Dictionary(routines.compactMap { r in r["id"]?.stringValue.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let ex = groupIds(sourceEntries(w).map { e in copiedEntry(e, Session.entryRoutineId(w, e).flatMap { byId[$0] }, c) }, newId: newId)
        if ex.isEmpty { return nil }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ["id": .string(newId()), "name": .string(trimmed.isEmpty ? "Workout" : trimmed), "ex": .array(ex.map(JSONValue.object))]
    }
    static func sourceEntries(_ w: Object) -> [Object] {
        (w["entries"]?.arrayValue ?? []).compactMap(\.object).filter { !($0["sets"]?.arrayValue ?? []).isEmpty }
    }

    // MARK: Repeat today

    /// One warm-up row in front of the work, half way from the last warm-up (history.js insertWarmupRow).
    // ponytail: numeric steps only; owned dumbbell lists (ownedWeightsFor) are not ported.
    static func insertWarmupRow(_ rows: [JSONValue], _ mode: String, _ target: Object, step: Double, floor: Double, assisted: Bool) -> [JSONValue] {
        let firstWork = rows.firstIndex { !Session.isWarmup($0) }
        let at = firstWork ?? rows.count
        let prev = at > 0 ? rows[at - 1].object : nil
        let work = firstWork.flatMap { rows[$0].object }
        let n = Session.n
        func rampTo(_ to: Double) -> Double {
            let from = n(prev?["w"])
            if !(to > 0) { return 0 }
            if assisted {
                let top = from > 0 ? from : 2 * to
                if !(top > to) { return to }
                return max(to, (((to + (top - to) / 2) / step) - 1e-9).rounded(.up) * step)
            }
            if to <= from { return to }
            return min(to, max(0, floor, ((from + (to - from) / 2) / step).rounded(.down) * step))
        }
        var warm: Object
        switch mode {
        case "cardio":
            warm = ["min": prev?["min"] ?? work?["min"] ?? .number(Session.or(target["min"], 20)),
                    "speed": prev?["speed"] ?? work?["speed"] ?? .number(Session.or(target["speed"], 8))]
            if let inc = (prev ?? work)?["incline"] { warm["incline"] = inc }
        case "time":
            warm = ["sec": prev?["sec"] ?? work?["sec"] ?? .number(Session.or(target["sec"], 45)),
                    "w": .number(rampTo(work.map { n($0["w"]) } ?? n(target["weight"])))]
        default:
            warm = ["w": .number(rampTo(work.map { n($0["w"]) } ?? n(target["weight"]))),
                    ]
            if let r = work.map({ $0["r"] }) ?? prev.map({ $0["r"] }) ?? target["reps"] { warm["r"] = r }
        }
        warm["done"] = .bool(false); warm["phase"] = .string("warmup"); warm["warmup"] = .bool(true)
        var next = rows
        next.insert(mode == "reps" && Session.isPerSide(target) ? Session.makeSideSet(warm) : .object(warm), at: at)
        return next
    }

    /// A saved workout's exercises as a new session's entries, each seeded from that workout alone,
    /// and how many were left out because they no longer exist.
    // ponytail: intensifier shaping (applyIntensifierPlan) is skipped, as at native session start.
    public static func repeatEntries(_ s: Object, _ w: Object, catalog c: ExerciseCatalog,
                                     exists: (String) -> Bool) -> (entries: [JSONValue], skipped: Int) {
        let src = sourceEntries(w)
        guard let ex = routine(from: w, name: w["name"]?.stringValue, routines: (s["routines"]?.arrayValue ?? []).compactMap(\.object), catalog: c, newId: { UUID().uuidString })?["ex"]?.arrayValue?.compactMap(\.object)
        else { return ([], 0) }
        var entries: [Object] = [], skipped = 0
        let unit = s["unit"]?.stringValue ?? "kg"
        for (i, copied) in ex.enumerated() {
            let id = copied["id"]?.stringValue ?? ""
            guard exists(id) else { skipped += 1; continue }
            let source = i < src.count ? src[i] : [:]
            var cfg = copied; cfg["sg"] = nil
            let done = setsFromRows(cfg, (source["sets"]?.arrayValue ?? []).filter { $0.object?["done"] == .bool(true) && !Session.isWarmup($0) }.count, c)
            if done > 0 { cfg["sets"] = .number(Double(done)) }
            let mode = RoutineOps.mode(cfg, catalog: c)
            let step = mode == "reps" ? Session.weightIncrement(cfg, unit: unit, c) : Session.defaultIncrement(id, unit: unit, c)
            var only = s; var one = w; one["entries"] = .array([.object(source)]); only["workouts"] = .array([.object(one)])
            var rows = Session.buildSets(only, cfg, rid: nil, useTarget: false, planReps: false, c)
            let floor = Session.barFloor(only, id, c), assisted = Session.isAssisted(cfg, c)
            for _ in 0..<min(5, max(0, Int(Session.jsRound(Session.n(cfg["warmupSets"]))))) {
                rows = insertWarmupRow(rows, mode, cfg, step: step, floor: floor, assisted: assisted)
            }
            rows = rows.map { r in guard case .object(var o) = r else { return r }; o["done"] = .bool(false); return .object(o) }
            var e: Object = ["id": cfg["id"] ?? .null, "target": .object(cfg), "plan": .null, "sets": .array(rows)]
            if let sg = copied["sg"] { e["sg"] = sg }
            entries.append(e)
        }
        // A superset whose other half was left out is one exercise on its own.
        let out = entries.enumerated().map { i, e -> JSONValue in
            guard let sg = e["sg"] else { return .object(e) }
            if (i > 0 && entries[i - 1]["sg"] == sg) || (i + 1 < entries.count && entries[i + 1]["sg"] == sg) { return .object(e) }
            var lone = e; lone["sg"] = nil; return .object(lone)
        }
        return (out, skipped)
    }
}
