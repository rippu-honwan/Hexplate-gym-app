import Foundation

/// A workout in progress: the entries a routine starts with, progression included
/// (lib/session-start.js, lib/progression.js, lib/history.js buildSets), and the saved workout a
/// live session finishes as (lib/finish-workout.js). Everything stays openGym JSON.
///
/// ponytail: not ported, because no routine of the imported data uses them: triple progression
/// (treated as no progression), owned dumbbells and weight stacks as the progression grid,
/// programmes, back-off sets, pyramids, planned or automatic warm-up rows, dumbbell load
/// meanings and per-exercise units. Port each with its golden case when a routine needs it.
public enum Session {
    public typealias Object = [String: JSONValue]

    // MARK: Small JavaScript-shaped helpers

    static func n(_ v: JSONValue?) -> Double { v?.num ?? 0 }
    /// `Number(v)` where a missing value is NaN (nil here) and null is 0.
    static func number(_ v: JSONValue?) -> Double? { v == nil ? nil : v!.num }
    /// JavaScript `a ?? b` on JSON: missing and null both fall through.
    static func coalesce(_ a: JSONValue?, _ b: JSONValue?) -> JSONValue? { a == nil || a == .null ? b : a }
    static func jsRound(_ v: Double) -> Double { (v + 0.5).rounded(.down) }
    static func round1(_ v: Double) -> Double { jsRound(v * 10) / 10 }
    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .bool(let b)?: return b
        case .number(let x)?: return x != 0 && !x.isNaN
        case .string(let s)?: return !s.isEmpty
        case .array?, .object?: return true
        default: return false
        }
    }
    /// `a || b` for numbers.
    static func or(_ v: JSONValue?, _ fallback: Double) -> Double { n(v) != 0 ? n(v) : fallback }

    public static func isWarmup(_ s: JSONValue) -> Bool {
        guard let o = s.object else { return false }
        if let p = o["phase"], p != .null, p != .string("") { return p == .string("warmup") }
        return o["warmup"] == .bool(true)
    }
    public static func isSideSet(_ s: JSONValue) -> Bool {
        guard let sides = s.object?["sides"]?.object else { return false }
        return sides["L"]?.object != nil && sides["R"]?.object != nil
    }
    static func done(_ s: JSONValue?) -> Bool { s?.object?["done"] == .bool(true) }
    public static func hasCompletedWork(_ s: JSONValue) -> Bool {
        isSideSet(s) ? done(s.object!["sides"]!.object!["L"]) || done(s.object!["sides"]!.object!["R"]) : done(s)
    }

    static func mode(_ cfg: Object, _ c: ExerciseCatalog) -> String { RoutineOps.mode(cfg, catalog: c) }
    static func isPerSide(_ cfg: Object) -> Bool { truthy(cfg["side"]) }
    static func repStep(_ cfg: Object) -> Double { isPerSide(cfg) ? 2 : 1 }
    static func isAssisted(_ cfg: Object, _ c: ExerciseCatalog) -> Bool {
        if case .bool(let b)? = cfg["assisted"] { return b }
        if case .bool(let b)? = cfg["target"]?.object?["assisted"] { return b }
        return cfg["id"]?.stringValue.flatMap { c[$0] }?.isAssisted ?? false
    }
    static let loadedEquipment: Set<String> = ["barbell", "ez barbell", "olympic barbell", "trap bar", "dumbbell", "kettlebell", "clubbell", "macebell", "cable", "leverage machine", "smith machine", "sled machine", "weighted"]
    static func climbsReps(_ cfg: Object, _ c: ExerciseCatalog) -> Bool {
        let eq = cfg["id"]?.stringValue.flatMap { c[$0] }?.equipment ?? ""
        return RoutineOps.isBodyweight(cfg, catalog: c) || !loadedEquipment.contains(eq) || isAssisted(cfg, c)
    }
    static func defaultIncrement(_ id: String?, unit: String, _ c: ExerciseCatalog) -> Double {
        let heavy = ["upper legs", "lower legs", "back", "hips", "glutes"].contains(id.flatMap { c[$0] }?.bodyPart ?? "")
        return unit == "lb" ? (heavy ? 10 : 5) : (heavy ? 5 : 2.5)
    }
    static func weightIncrement(_ cfg: Object, unit: String, _ c: ExerciseCatalog) -> Double {
        n(cfg["inc"]) > 0 ? n(cfg["inc"]) : defaultIncrement(cfg["id"]?.stringValue, unit: unit, c)
    }

    // MARK: Weight arithmetic (lib/progression.js)

    static let deloadFactor = 0.9
    static let deloadAfter: [String: Int] = ["linear": 3, "greyskull": 1, "double": 3, "triple": 3, "time": 3]

    static func snapWeight(_ v: Double, _ step: Double) -> Double { step > 0 ? round1(jsRound(v / step) * step) : round1(v) }
    static func addStep(_ w: Double, _ step: Double, _ inc: Double) -> Double {
        let onGrid = inc > 0 && abs(w - jsRound(w / inc) * inc) <= 0.1
        return max(0, onGrid ? snapWeight(w + step, inc) : round1(w + step))
    }
    static func deloadTo(_ cur: Double, _ step: Double, _ factor: Double = deloadFactor) -> Double {
        var next = snapWeight(cur * factor, step)
        if next >= cur { next = snapWeight(cur - step, step) }
        return max(step, next)
    }
    static func deloadFactorOf(_ cfg: Object) -> Double {
        guard let f = cfg["deloadFactor"]?.numberValue, f >= 0.5, f <= 0.95 else { return deloadFactor }
        return f
    }
    public static func epley1RM(_ w: Double, _ r: Double) -> Double? {
        guard w.isFinite, r.isFinite, w > 0, r >= 1 else { return nil }
        return round1(w * (1 + r / 30))
    }
    static func deloadTarget1RM(_ w: Double, _ r: Double, _ factor: Double, _ perSide: Bool) -> Double? {
        epley1RM(w, perSide ? r / 2 : r).map { round1($0 * factor) }
    }
    static func normalizeRepRange(_ reps: JSONValue?, _ repsMin: JSONValue?, _ stride: Double) -> (reps: Double, repsMin: Double) {
        func positiveInt(_ v: JSONValue?, _ fallback: Double) -> Double {
            guard let x = number(v), x.isFinite, x > 0 else { return fallback }
            return max(1, jsRound(x))
        }
        func align(_ v: Double) -> Double { max(stride, (v / stride).rounded(.up) * stride) }
        let upper = align(positiveInt(reps, 10))
        let lower = align(positiveInt(repsMin, max(1, upper - 2)))
        return lower >= upper ? (lower + stride, lower) : (upper, lower)
    }

    struct Candidate { var weight, reps, error, repChange: Double; var target1RM: Double }

    static func selectDeloadCandidate(current: Double, targetWeight: Double?, targetReps: Double?, step: Double, factor: Double,
                                      reps: JSONValue?, repsMin: JSONValue?, perSide: Bool) -> Candidate? {
        guard let baseWeight = targetWeight, let baseReps = targetReps else { return nil }
        let stride: Double = perSide ? 2 : 1
        let upper = max(stride, (baseReps / stride).rounded(.up) * stride)
        let range = repsMin == nil || repsMin == .null ? nil : normalizeRepRange(reps, repsMin, stride)
        let top = range.map { min($0.reps, max($0.repsMin, upper)) } ?? upper
        let bottom = range?.repsMin ?? top
        let repValues = Array(Swift.stride(from: top, through: bottom, by: -stride))
        guard current > 0, let target = deloadTarget1RM(baseWeight, upper, factor, perSide), !repValues.isEmpty, step > 0 else { return nil }
        var all: [Candidate] = []
        func add(_ w: Double, _ r: Double) {
            let e = epley1RM(w, perSide ? r / 2 : r) ?? 0
            all.append(Candidate(weight: w, reps: r, error: abs(e - target), repChange: abs(r - upper), target1RM: target))
        }
        for r in repValues {
            let ideal = target / (1 + (perSide ? r / 2 : r) / 30)
            let allowCurrent = range != nil && r < upper
            let low: Double = snapWeight((ideal / step).rounded(.down) * step, step)
            let high: Double = snapWeight((ideal / step).rounded(.up) * step, step)
            var grid = Set([low, high].filter { (v: Double) -> Bool in v > 0 && v <= current + 1e-9 && (allowCurrent || v < current - 1e-9) })
            if allowCurrent { grid.insert(current) }
            grid.sorted().forEach { add($0, r) }
        }
        if all.isEmpty { repValues.forEach { add(current, $0) } }
        return all.min { a, b in
            if a.error != b.error { return a.error < b.error }
            if a.repChange != b.repChange { return a.repChange < b.repChange }
            if a.weight != b.weight { return a.weight > b.weight }
            return a.reps > b.reps
        }
    }

    // MARK: History reads

    static func entryRoutineId(_ w: Object, _ e: Object) -> String? {
        if let rid = e["rid"]?.stringValue, !rid.isEmpty { return rid }
        let entries = w["entries"]?.arrayValue ?? []
        if entries.contains(where: { truthy($0.object?["rid"]) }) { return nil }
        if let ids = w["routineIds"] {
            if let first = ids.arrayValue?.first { return first.stringValue }
            if let s = ids.stringValue { return s }
        }
        return w["routineId"]?.stringValue
    }
    static func excluded(_ w: Object, _ e: Object) -> Bool {
        w["excludeFromProgression"] == .bool(true) || e["noProg"] == .bool(true)
    }
    static func workouts(_ s: Object) -> [Object] { (s["workouts"]?.arrayValue ?? []).compactMap(\.object) }
    static func entry(in w: Object, _ exId: String, _ rid: String?) -> Object? {
        (w["entries"]?.arrayValue ?? []).compactMap(\.object).first { $0["id"]?.stringValue == exId && (rid == nil || entryRoutineId(w, $0) == rid) }
    }
    static func across(_ s: Object) -> Bool { s["lastFrom"] == .string("any") }

    /// The last logged work rows of an exercise (history.js lastEntryFor).
    static func lastSets(_ s: Object, _ exId: String, _ rid: String?) -> [JSONValue]? {
        lastEntry(s, exId, rid)?["sets"]?.arrayValue
    }

    /// Last time's entry of an exercise (history.js lastEntryFor): the same routine first unless
    /// "Last time means: Any workout", with `sets` cut to its done work sets.
    public static func lastEntry(_ s: Object, _ exId: String, _ rid: String?) -> Object? {
        func lastIn(_ rid: String?) -> Object? {
            for w in workouts(s).reversed() {
                guard var e = entry(in: w, exId, rid), !excluded(w, e) else { continue }
                let rows = (e["sets"]?.arrayValue ?? []).filter { done($0) && !isWarmup($0) }
                if !rows.isEmpty { e["sets"] = .array(rows); return e }
            }
            return nil
        }
        if let rid, !across(s), let own = lastIn(rid) { return own }
        return lastIn(nil)
    }

    struct Logged {
        var rid: String?, planned: Object?, target: Object
        var mode: String, goal: Double, reps: [Double], weight: Double, ok: Bool
        var low: Double { reps.min() ?? 0 }
        var amrap: Double { reps.last ?? 0 }
    }

    static func readSession(_ e: Object, fallback: Object, _ c: ExerciseCatalog) -> Logged {
        let own = e["target"]?.object
        let target = own ?? fallback
        var probe = target; probe["id"] = e["id"]
        let m = mode(probe, c)
        let logged = (e["sets"]?.arrayValue ?? []).filter { !isWarmup($0) }
        let rowGoals = m == "reps" && own != nil ? target["rowReps"]?.arrayValue.flatMap { $0.isEmpty ? nil : $0.map { max(0, $0.num) } } : nil
        let plannedRows = rowGoals.map { Double($0.count) } ?? or(target["sets"], Double(logged.count))
        let planned = m == "time" && isPerSide(target) ? plannedRows * 2 : plannedRows
        let enough = Double(logged.count) >= planned
        let sets = own != nil ? Array(logged.prefix(Int(max(1, planned)))) : logged
        let ws = sets.filter(done).map { n($0.object?["w"]) }
        let weight = isAssisted(["id": e["id"] ?? .null], c) ? (ws.filter { $0 > 0 }.min() ?? 0) : max(0, ws.max() ?? 0)
        var out = Logged(rid: nil, planned: nil, target: target, mode: m, goal: 0, reps: [], weight: weight, ok: false)
        if m == "time" {
            out.goal = n(target["sec"])
            out.reps = sets.map { done($0) ? n($0.object?["sec"]) : 0 }
            out.ok = out.goal > 0 && enough && !out.reps.isEmpty && out.reps.allSatisfy { $0 >= out.goal }
            return out
        }
        out.goal = rowGoals.map { $0.max() ?? 0 } ?? n(target["reps"])
        out.reps = sets.map { done($0) ? n($0.object?["r"]) : 0 }
        out.ok = out.goal > 0 && enough && !out.reps.isEmpty
            && out.reps.enumerated().allSatisfy { k, r in r >= (rowGoals.flatMap { k < $0.count ? $0[k] : nil } ?? out.goal) }
        return out
    }

    static func sessions(_ s: Object, _ exId: String, _ cfg: Object, _ rid: String?, _ c: ExerciseCatalog) -> [Logged] {
        func inRoutine(_ rid: String?) -> [Logged] {
            workouts(s).compactMap { w in
                guard let e = entry(in: w, exId, rid), !excluded(w, e),
                      (e["sets"]?.arrayValue ?? []).contains(where: { done($0) && !isWarmup($0) }) else { return nil }
                var l = readSession(e, fallback: cfg, c)
                l.rid = entryRoutineId(w, e)
                l.planned = e["planned"]?.object
                return l
            }
        }
        if let rid, !across(s) { let own = inRoutine(rid); if !own.isEmpty { return own } }
        return inRoutine(nil)
    }

    static let planKeys = ["sets", "reps", "repsMin", "sec", "setsMax"]
    static func samePlan(_ a: Object, _ b: Object) -> Bool {
        planKeys.allSatisfy { (a[$0] ?? .null) == (b[$0] ?? .null) }
    }

    public static func plannedOf(_ cfg: Object, _ c: ExerciseCatalog) -> Object {
        let m = mode(cfg, c)
        var out: Object = ["sets": .number(max(1, or(cfg["sets"], 1)))]
        if m == "reps", n(cfg["reps"]) > 0 { out["reps"] = cfg["reps"] }
        if m == "reps", n(cfg["repsMin"]) > 0 { out["repsMin"] = cfg["repsMin"] }
        if m == "time", n(cfg["sec"]) > 0 { out["sec"] = cfg["sec"] }
        if m == "reps", n(cfg["setsMax"]) > 0 { out["setsMax"] = cfg["setsMax"] }
        if let w = cfg["weight"], w != .null { out["weight"] = w }
        return out
    }

    static func stallCount(_ list: [Logged], _ policy: String) -> Int {
        var count = 0
        for i in list.indices.reversed() {
            let s = list[i]
            if s.ok { break }
            if i < list.count - 1 {
                if s.weight != list[i + 1].weight { break }
                if let a = s.planned, let b = list[i + 1].planned, !samePlan(a, b) { break }
            }
            if policy == "double" {
                var run: [Double] = []
                var j = i - 1
                while j >= 0 && list[j].weight == s.weight { run.append(list[j].low); j -= 1 }
                if let best = run.max(), s.low > best { break }
            }
            count += 1
        }
        return count
    }

    // MARK: Progression (lib/progression.js nextPrescription)

    static func policyFor(_ cfg: Object, _ routine: Object?, _ m: String, fallback: String) -> String {
        // ponytail: pyramids are not ported; a pyramid slot stays off, as in the original.
        if cfg["pyramid"] != nil && cfg["pyramid"] != .null { return "off" }
        let allowed: [String: [String]] = ["reps": ["off", "linear", "greyskull", "double"], "time": ["off", "time"]]
        let pick = [cfg["prog"], routine?["prog"]].compactMap { $0?.stringValue }.first { !$0.isEmpty }
            ?? (m == "reps" ? fallback : "off")
        return (allowed[m] ?? ["off"]).contains(pick) ? pick : "off"
    }

    static func why(_ text: String, _ args: JSONValue...) -> JSONValue { .array([.string(text)] + args) }

    /// What the next session of `cfg` should aim for: a `plan` object, as the original stores it.
    public static func nextPrescription(_ s: Object, _ cfg: Object, _ routine: Object?, _ c: ExerciseCatalog) -> Object {
        let m = mode(cfg, c)
        let progDefault = s["progDefault"]?.stringValue.flatMap { ["off", "linear", "greyskull", "double", "triple"].contains($0) ? $0 : nil } ?? "linear"
        let policy = policyFor(cfg, routine, m, fallback: progDefault)
        let unit = s["unit"]?.stringValue ?? "kg"
        let inc = m == "time" ? (n(cfg["inc"]) > 0 ? n(cfg["inc"]) : 5) : weightIncrement(cfg, unit: unit, c)
        var p: Object = ["policy": .string(policy)]
        if policy == "off" { p["kind"] = .string("off"); return p }
        let assisted = isAssisted(cfg, c)
        func harder(_ w: Double, _ step: Double) -> Double { assisted ? max(0, addStep(w, -step, inc)) : addStep(w, step, inc) }
        func easier(_ w: Double) -> Double { assisted ? addStep(w, inc, inc) : deloadTo(w, inc) }
        func out(_ kind: String, _ fields: Object, _ why: JSONValue) -> Object {
            p["kind"] = .string(kind)
            p.merge(fields) { $1 }
            p["why"] = why
            return p
        }
        let num = { (v: Double) in JSONValue.number(v) }
        let exId = cfg["id"]?.stringValue ?? ""
        let rid = routine?["id"]?.stringValue
        let list = sessions(s, exId, cfg, rid, c).filter { $0.mode == m }
        guard let last = list.last else { return out("first", [:], why("Nothing logged yet, so this session sets the baseline.")) }

        let all = across(s)
        let borrowed = rid != nil && !all && last.rid != rid
        let ownPlan = !all || rid == nil || last.rid == rid
        let changed = (last.planned != nil && ownPlan) ? !samePlan(last.planned!, plannedOf(cfg, c)) : borrowed
        if changed {
            let w = why(borrowed ? "First time in this routine, so starting from its own target." : "Plan changed, so starting from your new target.")
            let cw = n(cfg["weight"])
            let set: Object? = cw > 0 && last.planned != nil && (last.planned!["weight"] ?? .null) != cfg["weight"] ? ["weight": num(cw)] : nil
            if m == "time" {
                let sec = or(cfg["sec"], last.goal)
                return out("hold", (set ?? [:]).merging(sec != 0 ? ["sec": num(sec)] : [:]) { $1 }, w)
            }
            if set == nil && last.weight <= 0 && climbsReps(cfg, c) {
                return out("hold", ["weight": .number(0)].merging(n(cfg["reps"]) != 0 ? ["reps": cfg["reps"]!] : [:]) { $1 }, w)
            }
            let held = set ?? (last.weight > 0 ? ["weight": num(last.weight)] : cw > 0 ? ["weight": num(cw)] : [:])
            if policy == "double" {
                let range = normalizeRepRange(.number(or(cfg["reps"], or(.number(last.goal), 10))), cfg["repsMin"], repStep(cfg))
                let aim = set != nil ? range.repsMin : min(range.reps, max(range.repsMin, last.low + repStep(cfg)))
                return out("hold", held.merging(["reps": num(aim)]) { $1 }, w)
            }
            return out("hold", held.merging(n(cfg["reps"]) != 0 ? ["reps": cfg["reps"]!] : [:]) { $1 }, w)
        }

        let stalls = stallCount(list, policy)
        let deloadAt = deloadAfter[policy] ?? 3

        if m == "time" {
            let goal = or(.number(last.goal), n(cfg["sec"]))
            if last.ok { return out("up", ["sec": num(goal + inc)], why("Held every set for the full time. Target goes up by {0}s.", num(inc))) }
            if stalls >= deloadAt {
                let sec = deloadTo(goal, 5)
                return out("deload", ["sec": num(sec)], why("Short {0} sessions in a row. Back off to {1}s and build up again.", num(Double(stalls)), num(sec)))
            }
            return out("hold", last.goal != 0 ? ["sec": num(last.goal)] : cfg["sec"].map { ["sec": $0] } ?? [:], why("Came up short last time. Same target again."))
        }

        let w = last.weight
        if w <= 0 && climbsReps(cfg, c) {
            let goal = or(.number(last.goal), n(cfg["reps"]))
            let planSets = max(1, or(cfg["sets"], 1))
            let reached = last.planned != nil ? max(planSets, n(last.target["sets"])) : planSets
            let keep: Object = reached > planSets ? ["sets": num(reached)] : [:]
            if !last.ok || goal <= 0 {
                return out("hold", ["weight": .number(0)].merging(goal != 0 ? ["reps": num(goal)] : [:]) { $1 }.merging(keep) { $1 }, why("Bodyweight: same target again until every set is clean."))
            }
            let top = n(cfg["repsMax"]) > 0 ? n(cfg["repsMax"]) : 0
            if top > 0 && goal >= top {
                let sets = reached + 1
                let bottom = max(1, min(or(cfg["reps"], top), top))
                if sets <= 6 { return out("up", ["weight": .number(0), "reps": num(bottom), "sets": num(sets)], why("{0} reps in every set! Add a set and go back to {1}.", num(goal), num(bottom))) }
                return out("hold", ["weight": .number(0), "reps": num(goal)].merging(keep) { $1 }, why("{0} sets of {1}. Time to add weight or try a harder variation.", num(sets - 1), num(goal)))
            }
            let next = goal + repStep(cfg)
            return out("up", ["weight": .number(0), "reps": num(next)].merging(keep) { $1 }, why("Bodyweight: every rep last time, so go for {0} this time.", num(next)))
        }
        if w <= 0 {
            return out("hold", n(cfg["weight"]) > 0 ? ["weight": cfg["weight"]!] : [:], why("No weight logged last time. Enter what you lift and progression takes it from there."))
        }

        func epleyDeload() -> Object? {
            guard !assisted, policy == "linear" || policy == "double" else { return nil }
            var target = cfg.merging(last.target) { $1 }
            let prev = last.target
            target["weight"] = coalesce(prev["weight"], cfg["weight"])
            target["reps"] = coalesce(prev["reps"], cfg["reps"])
            target["repsMin"] = coalesce(prev["repsMin"], cfg["repsMin"])
            target["sets"] = coalesce(cfg["sets"], prev["sets"])
            target["bodyweight"] = coalesce(prev["bodyweight"], cfg["bodyweight"])
            target["side"] = coalesce(prev["side"], cfg["side"])
            target["intensifier"] = coalesce(prev["intensifier"], cfg["intensifier"])
            if RoutineOps.isBodyweight(target, catalog: c) || target["intensifier"]?.object?["type"] == .string("restpause") { return nil }
            guard let pick = selectDeloadCandidate(current: w, targetWeight: number(target["weight"]), targetReps: number(target["reps"]), step: inc,
                                                   factor: deloadFactorOf(cfg), reps: target["reps"], repsMin: policy == "double" ? target["repsMin"] : nil,
                                                   perSide: isPerSide(target)) else { return nil }
            var f: Object = ["weight": num(pick.weight), "reps": num(pick.reps), "target1RM": num(pick.target1RM), "deloadFactor": num(deloadFactorOf(cfg))]
            if let sets = target["sets"] { f["sets"] = sets }
            return out("deload", f, pick.weight >= w
                ? why("Stuck for {0} sessions. Hold {1} {2} and use {3} reps.", num(Double(stalls)), num(pick.weight), .string(unit), num(pick.reps))
                : why("Stuck for {0} sessions. Epley deload to {1} {2} for {3} reps.", num(Double(stalls)), num(pick.weight), .string(unit), num(pick.reps)))
        }

        if policy == "double" {
            let range = normalizeRepRange(.number(or(cfg["reps"], or(.number(last.goal), 10))), cfg["repsMin"], repStep(cfg))
            if last.ok && last.low >= range.reps {
                let up = harder(w, inc)
                return out("up", ["weight": num(up), "reps": num(range.repsMin)], assisted
                    ? why("Top of the rep range in every set. {0} {1} less help, back to {2} reps.", num(inc), .string(unit), num(range.repsMin))
                    : why("Top of the rep range in every set. {0} {1} more, back to {2} reps.", num(inc), .string(unit), num(range.repsMin)))
            }
            if stalls >= deloadAt {
                if let d = epleyDeload() { return d }
                let dw = easier(w)
                return out("deload", ["weight": num(dw), "reps": num(range.repsMin)], assisted
                    ? why("Stuck for {0} sessions. Back to {1} {2} of help, then build up again.", num(Double(stalls)), num(dw), .string(unit))
                    : why("Stuck for {0} sessions. Deload to {1} {2}.", num(Double(stalls)), num(dw), .string(unit)))
            }
            let aim = min(range.reps, max(range.repsMin, last.low + repStep(cfg)))
            return out("hold", ["weight": num(w), "reps": num(aim)], why("Same weight, aim for {0} reps this time.", num(aim)))
        }

        if last.ok {
            let dbl = policy == "greyskull" && last.goal > 0 && last.amrap >= last.goal * 2
            let step = dbl ? inc * 2 : inc
            return out("up", ["weight": num(harder(w, step))], dbl
                ? why("Last set hit {0} reps, twice the target! Take a double jump of {1} {2}.", num(last.amrap), num(step), .string(unit))
                : assisted ? why("Every rep last time. {0} {1} less help.", num(step), .string(unit))
                : why("Every rep last time. {0} {1} more.", num(step), .string(unit)))
        }
        if stalls >= deloadAt {
            if let d = epleyDeload() { return d }
            let dw = easier(w)
            return out("deload", ["weight": num(dw)], assisted
                ? why("Missed reps. {0} {1} of help while you build back up.", num(dw), .string(unit))
                : stalls > 1 ? why("Missed reps {0} sessions running. Reset to {1} {2} and work back up.", num(Double(stalls)), num(dw), .string(unit))
                : why("Missed reps. Reset to {0} {1} and work back up.", num(dw), .string(unit)))
        }
        return out("hold", ["weight": num(w)], why("Missed reps last time. Same weight again ({0} of {1} to go).", num(Double(deloadAt - stalls)), num(Double(deloadAt))))
    }

    // MARK: Building and shaping set rows

    static func makeSideSet(_ row: Object) -> JSONValue {
        let half = jsRound(n(row["r"]) / 2), w = n(row["w"])
        var next = row
        let side: JSONValue = .object(["w": .number(w), "r": .number(half), "done": .bool(false)])
        next["sides"] = .object(["L": side, "R": side])
        next["rir"] = nil; next["rpe"] = nil
        return syncSides(next)
    }

    public static func syncSides(_ row: Object) -> JSONValue {
        guard isSideSet(.object(row)), let sides = row["sides"]?.object else { return .object(row) }
        func sideOf(_ v: JSONValue?) -> Object {
            let o = v?.object ?? [:]
            var out: Object = ["w": .number(n(o["w"])), "r": .number(n(o["r"])), "done": .bool(o["done"] == .bool(true))]
            for k in ["rir", "rpe"] where o[k] != nil && o[k] != .null { out[k] = o[k] }
            if o["weightOrigin"] == .string("manual") { out["weightOrigin"] = o["weightOrigin"] }
            if o["type"] == .string("dropset") || o["type"] == .string("restpause") { out["type"] = o["type"] }
            for k in ["drops", "clusters"] where o[k]?.arrayValue != nil { out[k] = o[k] }
            return out
        }
        let L = sideOf(sides["L"]), R = sideOf(sides["R"])
        var out = row
        out["sides"] = .object(["L": .object(L), "R": .object(R)])
        out["r"] = .number(n(L["r"]) + n(R["r"]))
        out["w"] = .number(max(n(L["w"]), n(R["w"])))
        out["done"] = .bool(L["done"] == .bool(true) && R["done"] == .bool(true))
        for k in ["rir", "rpe", "drops", "clusters", "type"] { out[k] = nil }
        let rirs = [L["rir"], R["rir"]].compactMap { $0?.numberValue }, rpes = [L["rpe"], R["rpe"]].compactMap { $0?.numberValue }
        if let v = rirs.min() { out["rir"] = .number(v) } else if let v = rpes.max() { out["rpe"] = .number(v) }
        if let t = L["type"] ?? R["type"] { out["type"] = t }
        return .object(out)
    }

    /// The work rows a slot starts with (history.js buildWorkSets).
    static func buildSets(_ s: Object, _ cfg: Object, rid: String?, useTarget: Bool, planReps planOption: Bool, _ c: ExerciseCatalog) -> [JSONValue] {
        let last = lastSets(s, cfg["id"]?.stringValue ?? "", rid)
        let count = Int(max(1, or(cfg["sets"], 1)))
        let m = mode(cfg, c)
        func lastAt(_ i: Int) -> Object? { last.flatMap { (i < $0.count ? $0[i] : $0.last)?.object } }
        func prevAt(_ i: Int) -> Object? { useTarget ? nil : lastAt(i) }
        let planReps = planOption && n(cfg["reps"]) > 0
        if m == "cardio" {
            return (0..<count).map { i in
                let prev = prevAt(i)
                var row: Object = ["min": prev?["min"] ?? .number(or(cfg["min"], 20)), "speed": prev?["speed"] ?? .number(or(cfg["speed"], 8)), "done": .bool(false)]
                // ponytail: incline carried as stored; the original also normalises its units.
                if let inc = (prev ?? cfg)["incline"] { row["incline"] = inc }
                return .object(row)
            }
        }
        if m == "time" {
            let side = isPerSide(cfg)
            return (0..<(side ? count * 2 : count)).map { i in
                let carried = prevAt(i).flatMap { n($0["sec"]) > 0 ? $0 : nil }
                var row: Object = ["sec": .number(carried.map { n($0["sec"]) } ?? or(cfg["sec"], 45)),
                                   "w": .number(carried.map { n($0["w"]) } ?? n(cfg["weight"])), "done": .bool(false)]
                if side { row["side"] = .string(i % 2 == 0 ? "L" : "R") }
                return .object(row)
            }
        }
        let conf = s["exWeights"]?.object?[cfg["id"]?.stringValue ?? ""]?.object
        return (0..<count).map { i in
            let usable = prevAt(i).flatMap { n($0["r"]) > 0 ? $0 : nil }
            let lastRegular = lastAt(i)
            let w: JSONValue? = useTarget
                ? (n(cfg["weight"]) > 0 ? cfg["weight"] : (lastRegular.map { n($0["r"]) > 0 } == true ? lastRegular!["w"] : cfg["weight"]))
                : usable.map { $0["w"] ?? .null } ?? (n(conf?["w"]) > 0 ? conf!["w"] : cfg["weight"])
            var row: Object = ["done": .bool(false)]
            if let w { row["w"] = w }
            if let r = planReps || usable == nil ? cfg["reps"] : usable!["r"] { row["r"] = r }
            guard isPerSide(cfg) else { return .object(row) }
            guard let prev = usable, isSideSet(.object(prev)), let sides = prev["sides"]?.object,
                  case .object(var base) = makeSideSet(row), let baseSides = base["sides"]?.object else { return makeSideSet(row) }
            func carry(_ k: String) -> JSONValue {
                let o = sides[k]?.object
                return .object(["w": .number(n(o?["w"])), "r": planReps ? baseSides[k]!.object!["r"]! : .number(n(o?["r"])), "done": .bool(false)])
            }
            base["sides"] = .object(["L": carry("L"), "R": carry("R")])
            return syncSides(base)
        }
    }

    /// Writes a prescription into freshly built rows (progression.js applyPrescription).
    static func applyPrescription(_ sets: [JSONValue], _ p: Object) -> [JSONValue] {
        let kind = p["kind"]?.stringValue
        if kind == "off" || kind == "first" { return sets }
        let weight = p["weight"], reps = p["reps"], sec = p["sec"]
        var out: [JSONValue] = sets.map { s in
            guard case .object(var o) = s, !done(s) else { return s }
            if isWarmup(s) {
                if let reps, o["r"] != nil && o["r"] != .null { o["r"] = reps } else if let sec, o["sec"] != nil && o["sec"] != .null { o["sec"] = sec }
                return .object(o)
            }
            if isSideSet(s), var sides = o["sides"]?.object {
                for k in ["L", "R"] where !done(sides[k]) {
                    guard var side = sides[k]?.object else { continue }
                    if let weight { side["w"] = weight }
                    if let reps { side["r"] = .number(reps.num / 2) }
                    sides[k] = .object(side)
                }
                o["sides"] = .object(sides)
                return syncSides(o)
            }
            if let weight { o["w"] = weight }
            if let reps { o["r"] = reps }
            if let sec { o["sec"] = sec }
            return .object(o)
        }
        let target = Int(n(p["sets"]))
        let work = { out.filter { !isWarmup($0) } }
        // ponytail: with no work rows the original re-ramps warm-ups; slots always have one.
        if target > work().count, let seed = work().last?.object {
            var plain = seed
            plain["drops"] = nil; plain["clusters"] = nil; plain["done"] = .bool(false)
            while work().count < target {
                if isSideSet(.object(seed)) {
                    var row: Object = [:]
                    if let w = coalesce(weight, seed["w"]) { row["w"] = w }
                    if let r = coalesce(reps, seed["r"]) { row["r"] = r }
                    out.append(makeSideSet(row))
                } else { out.append(.object(plain)) }
            }
        }
        return out
    }

    // MARK: Starting

    /// The entries one routine starts with (session-start.js buildSessionEntries, rid added as in
    /// session-merge.js).
    /// `today` is the day a running programme's week is read on (Day.today() when nil).
    public static func entries(_ s: Object, routine: Object, catalog c: ExerciseCatalog, today: String? = nil) -> [JSONValue] {
        let noProg = routine["excludeFromProgression"] == .bool(true)
        let fromLastSetting = s["startFrom"] == .string("last")
        let rid = routine["id"]?.stringValue
        let day = s["active"]?.object?["d"]?.stringValue ?? today ?? Day.today()
        return (routine["ex"]?.arrayValue ?? []).compactMap(\.object).map { cfg in
            var plan: Object = noProg ? ["policy": .string("off"), "kind": .string("off")] : nextPrescription(s, cfg, routine, c)
            let policyKind = plan["kind"]?.stringValue
            // A running programme's target replaces the policy's prescription (programmes.js).
            let slot = noProg ? nil : Programmes.slot(s, rid: rid, exId: cfg["id"]?.stringValue ?? "", iso: day)
            if let slot {
                let step = mode(cfg, c) == "reps" ? weightIncrement(cfg, unit: s["unit"]?.stringValue ?? "kg", c) : defaultIncrement(cfg["id"]?.stringValue, unit: s["unit"]?.stringValue ?? "kg", c)
                plan = Programmes.plan(s, cfg, plan, slot, step: step, catalog: c)
            }
            let kind = plan["kind"]?.stringValue
            let planReps = !fromLastSetting || kind == "programme"
            let fromLast = !noProg && policyKind == "off" && slot == nil && fromLastSetting
            let built = applyPrescription(buildSets(s, cfg, rid: rid, useTarget: policyKind == "off" && !fromLast, planReps: planReps, c), plan)
            let rows = withWarmupBlock(s, cfg, built, c)
            var target = cfg
            for k in ["weight", "reps", "sec", "sets"] where plan[k] != nil { target[k] = plan[k] }
            target["rowReps"] = nil; target["backoffStep"] = nil
            var e: Object = ["id": cfg["id"] ?? .null, "target": .object(target), "plan": .object(plan), "sets": .array(rows), "planned": .object(plannedOf(cfg, c))]
            if let sg = cfg["sg"] { e["sg"] = sg }
            let m = mode(cfg, c)
            if !planReps && (kind != "off" || fromLast) && plan["reps"] == nil && m == "reps"
                && built.contains(where: { !isWarmup($0) && ($0.object?["r"] ?? .null) != (cfg["reps"] ?? .null) }) { e["carried"] = .bool(true) }
            // A programme's deload week stays out of progression, as a deload routine does.
            if noProg || slot?.deload == true { e["noProg"] = .bool(true) }
            if let rid { e["rid"] = .string(rid) }
            return .object(e)
        }
    }

    /// A new live session (`S.active`) for these routines, in order (sheets.jsx beginWorkout).
    public static func begin(_ s: Object, routineIds: [String], bodyweight: Double?, id: String, now: Double, day: String, catalog: ExerciseCatalog, today: String? = nil) -> Object {
        let routines = (s["routines"]?.arrayValue ?? []).compactMap(\.object)
        var seen = Set<String>()
        let picked = routineIds.filter { seen.insert($0).inserted }.compactMap { rid in routines.first { $0["id"]?.stringValue == rid } }
        let names = picked.compactMap { $0["name"]?.stringValue }
        let name = names.isEmpty ? "Freestyle" : names.count <= 3 ? names.joined(separator: " + ") : "\(names[0]) + \(names[1]) + \(names.count - 2) more"
        return ["id": .string(id), "d": .string(day), "start": .number(now), "routineIds": .array(picked.compactMap { $0["id"] }),
                "name": .string(name), "bw": bodyweight.map(JSONValue.number) ?? .null, "cur": .number(0),
                "entries": .array(picked.flatMap { entries(s, routine: $0, catalog: catalog, today: today) })]
    }

    // MARK: Finishing (lib/finish-workout.js)

    public static let forgottenGapMs: Double = 20 * 60 * 1000

    static func finishedRow(_ s: JSONValue) -> JSONValue {
        guard case .object(var o) = s else { return s }
        let planSec = o["planSec"]
        o["planSec"] = nil; o["weightOrigin"] = nil; o["restSec"] = nil
        if isSideSet(s), var sides = o["sides"]?.object {
            for k in ["L", "R"] { if case .object(var side)? = sides[k] { side["weightOrigin"] = nil; sides[k] = .object(side) } }
            o["sides"] = .object(sides)
        }
        if let planSec, planSec != .null, !done(.object(o)) { o["sec"] = planSec }
        return .object(o)
    }

    /// When a session ended: now, unless the last logged set was long ago (a forgotten finish).
    public static func sessionEnd(_ active: Object, now: Double, gap: Double = forgottenGapMs) -> Double {
        func length(_ s: JSONValue) -> Double {
            func pos(_ v: JSONValue?) -> Double { max(0, n(v)) }
            if isSideSet(s), let sides = s.object?["sides"]?.object { return (pos(sides["L"]?.object?["sec"]) + pos(sides["R"]?.object?["sec"])) * 1000 }
            return pos(s.object?["min"]) * 60000 + pos(s.object?["sec"]) * 1000
        }
        let ticks = (active["entries"]?.arrayValue ?? []).flatMap { $0.object?["sets"]?.arrayValue ?? [] }
            .filter { hasCompletedWork($0) && $0.object?["at"]?.numberValue != nil }
            .map { (at: $0.object!["at"]!.num, len: length($0)) }
            .sorted { $0.at < $1.at }
        guard let first = ticks.first else { return now }
        var reach = first.at + first.len
        for t in ticks.dropFirst() {
            if t.at - t.len - reach > gap { break }
            reach = max(reach, t.at + t.len)
        }
        return now - reach > gap ? reach : now
    }

    /// The heaviest completed work weight of an entry (history.js bestWeightForEntry), lightest for
    /// an assistance machine.
    // ponytail: ignores the stored-topW fallback, which only matters for imported old workouts.
    public static func bestWeight(_ entry: Object, _ c: ExerciseCatalog) -> Double {
        let assisted = isAssisted(["id": entry["id"] ?? .null], c)
        var best: Double?
        for s in entry["sets"]?.arrayValue ?? [] where !isWarmup(s) && hasCompletedWork(s) {
            let rows = isSideSet(s) ? ["L", "R"].compactMap { s.object!["sides"]!.object![$0] }.filter(done) : [s]
            for r in rows {
                let w = n(r.object?["w"])
                if assisted && !(w > 0) { continue }
                best = best.map { assisted ? min($0, w) : max($0, w) } ?? w
            }
        }
        return best ?? 0
    }

    /// The saved workout a live session becomes; nil keys are left out as the original does.
    public static func completedWorkout(_ active: Object, end: Double, prs: [String], catalog c: ExerciseCatalog) -> Object {
        var entries: [JSONValue] = (active["entries"]?.arrayValue ?? []).compactMap(\.object).compactMap { e in
            let sets = (e["sets"]?.arrayValue ?? []).map(finishedRow)
            guard sets.contains(where: hasCompletedWork) else { return nil }
            let top = bestWeight(e, c)
            var out: Object = ["id": e["id"] ?? .null, "sets": .array(sets), "topW": top != 0 ? .number(top) : .null, "target": e["target"] ?? .null]
            if truthy(e["rid"]) { out["rid"] = e["rid"] }
            if e["noProg"] == .bool(true) { out["noProg"] = .bool(true) }
            if truthy(e["planned"]) { out["planned"] = e["planned"] }
            if truthy(e["sg"]) { out["sg"] = e["sg"] }
            let note = (e["note"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                out["note"] = .string(note)
                if truthy(e["notePin"]) { out["notePin"] = .bool(true) }
            }
            return .object(out)
        }
        RoutineOps.cleanupSupersets(&entries)
        let routineIds: [JSONValue] = active["routineIds"]?.arrayValue ?? (truthy(active["routineId"]) ? [active["routineId"]!] : [])
        var w: Object = ["id": active["id"] ?? .null, "d": active["d"] ?? .null, "start": active["start"] ?? .null, "end": .number(end),
                         "routineIds": .array(routineIds), "routineId": routineIds.first ?? .null, "name": active["name"] ?? .null,
                         "bw": active["bw"] ?? .null, "entries": .array(entries), "prs": .array(prs.map(JSONValue.string))]
        if !entries.isEmpty && entries.allSatisfy({ $0.object?["noProg"] == .bool(true) }) { w["excludeFromProgression"] = .bool(true) }
        let note = (active["note"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { w["note"] = .string(note) }
        // MyGym: the watch's rating of the whole workout, when it came before the finish.
        if case .number? = active["sessionEffort"] { w["sessionEffort"] = active["sessionEffort"] }
        // The gym it was done at (Gyms), so History can say where.
        if let g = active["gym"]?.object, let id = g["id"], id != .null { w["gym"] = .object(["id": id, "name": .string(g["name"]?.stringValue ?? "")]) }
        w["vol"] = .number(volume(w, c))
        return w
    }

    /// Stored workout volume: completed work rows only, no body weight (history.js workoutVolume).
    static func volume(_ w: Object, _ c: ExerciseCatalog) -> Double {
        guard let workout = try? JSONValue.object(w).decoded(as: Workout.self) else { return 0 }
        return WorkoutMath.volume(workout, settings: ProfileSettings([:]), catalog: c, weighIns: [])
    }

    // MARK: Editing a live session

    /// An exercise added mid-session or to a freestyle workout: last time's rows, no progression
    /// (session-start.js freestyle entries).
    public static func freestyleEntry(_ s: Object, cfg: Object, catalog c: ExerciseCatalog) -> JSONValue {
        let rows = buildSets(s, cfg, rid: nil, useTarget: false, planReps: false, c)
        return .object(["id": cfg["id"] ?? .null, "target": .object(cfg), "plan": .null, "sets": .array(rows), "planned": .object(plannedOf(cfg, c))])
    }

    /// Marks a row (or one side of a per-side row) done or not, stamping when (`at`, ms).
    public static func settingDone(_ row: JSONValue, _ isDone: Bool, side: String? = nil, at: Double) -> JSONValue {
        guard case .object(var o) = row else { return row }
        if let side, var sides = o["sides"]?.object, var one = sides[side]?.object {
            one["done"] = .bool(isDone)
            sides[side] = .object(one)
            o["sides"] = .object(sides)
            if isDone { o["at"] = .number(at) }
            return syncSides(o)
        }
        if isSideSet(row), var sides = o["sides"]?.object {
            for k in ["L", "R"] { if case .object(var one)? = sides[k] { one["done"] = .bool(isDone); sides[k] = .object(one) } }
            o["sides"] = .object(sides)
            if isDone { o["at"] = .number(at) }
            return syncSides(o)
        }
        o["done"] = .bool(isDone)
        if isDone { o["at"] = .number(at) }
        return .object(o)
    }

    /// Adds a drop to a set: 20 % lighter on the exercise's weight steps (workout-model.js addDrop).
    public static func addingDrop(_ row: JSONValue, step: Double) -> JSONValue {
        guard case .object(var o) = row else { return row }
        let drops = o["drops"]?.arrayValue ?? []
        let prev = drops.last?.object ?? o
        let raw = max(0, n(prev["w"])) * 0.8
        var w = step > 0 ? jsRound(raw / step) * step : jsRound(raw * 2) / 2
        if step > 0, n(prev["w"]) > 0, w >= n(prev["w"]) { w = n(prev["w"]) - step }
        o["type"] = .string("dropset")
        o["drops"] = .array(drops + [.object(["w": .number((max(0, w) * 1000).rounded() / 1000), "r": .number(n(prev["r"]))])])
        return .object(o)
    }

    /// Adds a rest-pause burst: half the reps after a short rest (workout-model.js addCluster).
    public static func addingCluster(_ row: JSONValue, restSec: Double) -> JSONValue {
        guard case .object(var o) = row else { return row }
        let clusters = o["clusters"]?.arrayValue ?? []
        let prev = n((clusters.last?.object ?? o)["r"])
        o["type"] = .string("restpause")
        o["clusters"] = .array(clusters + [.object(["r": .number(max(1, jsRound(prev / 2))), "restSec": .number(restSec)])])
        return .object(o)
    }

    /// A warm-up row in front of the work: half the first work weight on the exercise's steps,
    /// never under the bar.
    // ponytail: one fixed 50 % row per tap; history.js insertWarmupRow's halving ramp waits for
    // automatic warm-ups.
    public static func addingWarmup(_ sets: [JSONValue], step: Double, floor: Double = 0) -> [JSONValue] {
        guard let first = sets.first(where: { !isWarmup($0) })?.object else { return sets }
        let w = max(floor, snapWeight(n(first["w"]) * 0.5, step))
        var row: Object = ["w": .number(w), "done": .bool(false), "phase": .string("warmup")]
        if let r = first["r"] { row["r"] = r }
        if let sec = first["sec"] { row["sec"] = sec; row["w"] = first["w"] }
        let at = sets.firstIndex { !isWarmup($0) } ?? 0
        return Array(sets[..<at]) + [.object(row)] + Array(sets[at...])
    }

    public static func increment(_ cfg: Object, unit: String, catalog c: ExerciseCatalog) -> Double {
        mode(cfg, c) == "reps" ? weightIncrement(cfg, unit: unit, c) : defaultIncrement(cfg["id"]?.stringValue, unit: unit, c)
    }

    /// The best weight ever logged for an exercise (history.js bestWeightFor).
    public static func bestWeightFor(_ s: Object, _ exId: String, catalog c: ExerciseCatalog) -> Double {
        let assisted = isAssisted(["id": .string(exId)], c)
        var best = 0.0
        for w in workouts(s) { for e in (w["entries"]?.arrayValue ?? []).compactMap(\.object) where e["id"]?.stringValue == exId {
            let b = bestWeight(e, c)
            if b > 0 { best = best > 0 ? (assisted ? min(best, b) : max(best, b)) : b }
        } }
        return best
    }

    /// Exercises whose heaviest work set beat every earlier workout (sheets.jsx doFinishWorkout).
    public static func records(_ active: Object, in s: Object, catalog c: ExerciseCatalog) -> [String] {
        (active["entries"]?.arrayValue ?? []).compactMap(\.object).compactMap { e in
            guard let id = e["id"]?.stringValue else { return nil }
            let assisted = isAssisted(["id": .string(id)], c)
            let loads = (e["sets"]?.arrayValue ?? []).filter { done($0) && !isWarmup($0) }.map { n($0.object?["w"]) }.filter { $0 > 0 }
            guard let top = assisted ? loads.min() : loads.max() else { return nil }
            let prev = bestWeightFor(s, id, catalog: c)
            return prev <= 0 || (assisted ? top < prev : top > prev) ? id : nil
        }
    }

    /// Last time's logged work rows, for the "last time" line.
    public static func lastRows(_ s: Object, _ exId: String, routineId: String?) -> [JSONValue] {
        lastSets(s, exId, routineId) ?? []
    }

    // MARK: Automatic warm-ups (lib/warmup-ramp.js, warmup-snap.js, bar.js)
    // ponytail: a slot's own warm-up rows (`warmup: "own"`), a planned warm-up count and owned
    // plates as the snapping grid are not ported; such slots start without automatic warm-ups.

    static let compoundName = try! NSRegularExpression(pattern: #"squat|deadlift|\bpress\b|\brow\b|rowing|pull-?up|chin-?up|\bdips?\b|lunge|clean|snatch|jerk|thrust|good ?morning|step-?up|push-?up|leg press|hack|rack pull|pulldown|pull-down|swing|carry|floor press|landmine"#, options: .caseInsensitive)
    static let isolationName = try! NSRegularExpression(pattern: #"curl|extension|raise|\bfly\b|flye|kickback|shrug|calf|crunch|pullover|pushdown|push-down|face pull|wrist|adduct|abduct|lateral|stretch|twist|\bsit-?up"#, options: .caseInsensitive)

    static func isCompound(_ id: String?, _ c: ExerciseCatalog) -> Bool {
        guard let ex = id.flatMap({ c[$0] }), !ex.isCardio else { return false }
        let r = NSRange(ex.name.startIndex..., in: ex.name)
        return compoundName.firstMatch(in: ex.name, range: r) != nil && isolationName.firstMatch(in: ex.name, range: r) == nil
    }

    /// Your own weight for a bar type (bar.js ownBarDefault): `barDefaults = {kg: {eq: w}, lb: {…}}`.
    static func barDefault(_ s: Object, _ eq: String) -> Double? {
        guard barEquipment[eq] != nil, let v = s["barDefaults"]?.object?[s["unit"] == .string("lb") ? "lb" : "kg"]?.object?[eq]?.numberValue,
              v.isFinite, v > 0 else { return nil }
        return v
    }

    static let barEquipment: [String: (kg: Double, lb: Double)] = ["barbell": (20, 45), "olympic barbell": (20, 45), "ez barbell": (10, 25), "smith machine": (9, 20), "trap bar": (25, 55)]

    /// The bar a lift is loaded on: the exercise's own setting, else the usual bar for its equipment.
    public static func barFloor(_ s: Object, _ id: String?, _ c: ExerciseCatalog) -> Double {
        guard let id, let eq = c[id]?.equipment, let bar = barEquipment[eq] else { return 0 }
        if let own = s["barWeights"]?.object?[id]?.numberValue, own >= 0 { return own }
        if let own = barDefault(s, eq) { return own }
        return s["unit"] == .string("lb") ? bar.lb : bar.kg
    }

    /// Whether this slot gets automatic warm-ups (warmupSource "auto").
    static func autoWarmups(_ s: Object, _ cfg: Object, _ c: ExerciseCatalog) -> Bool {
        if s["modules"]?.object?["plates"] == .bool(false) { return false }
        guard mode(cfg, c) == "reps", cfg["intensifier"]?.object?["type"] != .string("restpause") else { return false }
        switch cfg["warmup"]?.stringValue {
        case "none", "own": return false
        case "auto": return true
        default: break
        }
        if (cfg["warmupSets"]?.num ?? 0).rounded() > 0 { return false }
        switch s["warmupAuto"]?.stringValue {
        case "all": return true
        case "compounds": return isCompound(cfg["id"]?.stringValue, c)
        default: return false
        }
    }

    /// Warm-up rows in front of the work (warmupBlock + rungRows), the old ones replaced.
    static func withWarmupBlock(_ s: Object, _ cfg: Object, _ rows: [JSONValue], _ c: ExerciseCatalog) -> [JSONValue] {
        guard autoWarmups(s, cfg, c) else { return rows }
        let work = rows.first { !isWarmup($0) }.map { n($0.object?["w"]) } ?? 0
        let workRows = rows.filter { !isWarmup($0) }
        guard work > 0 else { return workRows }
        let unit = s["unit"]?.stringValue ?? "kg"
        let kg = unit == "lb" ? work * 0.45359237 : work
        let floor = barFloor(s, cfg["id"]?.stringValue, c)
        let id = cfg["id"]?.stringValue
        let bw = RoutineOps.isBodyweight(cfg, catalog: c) || id.flatMap { c[$0] }?.equipment == "weighted"
        typealias Rung = (wp: Double?, bar: Bool, r: Double)
        var rungs: [Rung] = []
        if !isAssisted(cfg, c) {
            if bw {
                rungs = kg >= 10 ? [(0, false, 5), (60, false, 3)] : [(0, false, 5)]
            } else if isCompound(id, c) {
                let hasBar = floor > 0 && floor < work
                if kg >= 60 { rungs = hasBar ? [(nil, true, 10), (40, false, 5), (60, false, 3), (80, false, 1)] : [(40, false, 8), (60, false, 4), (80, false, 1)] }
                else if kg >= 30 { rungs = hasBar ? [(nil, true, 10), (70, false, 3)] : [(50, false, 8), (75, false, 3)] }
                else { rungs = hasBar ? [(nil, true, 10)] : [(50, false, 8)] }
            } else if kg >= 40 { rungs = [(50, false, 10), (75, false, 4)] }
            else if kg >= 10 { rungs = [(50, false, 10)] }
        }
        let grid = weightIncrement(cfg, unit: unit, c)
        let tidy = { (x: Double) in (x * 1000).rounded() / 1000 }
        var block: [JSONValue] = [], last = -1.0
        for rung in rungs {
            let w: Double
            if rung.bar { w = min(work, max(0, floor)) }
            else if let pct = rung.wp, pct > 0 { w = min(work, max(0, floor, tidy(((work * pct / 100) / grid + 1e-9).rounded(.down) * grid))) }
            else { w = 0 }
            let body = rung.wp == 0 && !rung.bar
            if !body && (!(w > 0) || w >= work) { continue }
            if w <= last { continue }
            last = w
            var row: Object = ["w": .number(w), "r": .number(rung.r), "done": .bool(false), "phase": .string("warmup"), "warmup": .bool(true)]
            if rung.bar { row["wb"] = .bool(true) } else { row["wp"] = .number(rung.wp!) }
            if isPerSide(cfg) { row["r"] = .number(rung.r * 2); block.append(makeSideSet(row)) } else { block.append(.object(row)) }
        }
        return block + workRows
    }
}
