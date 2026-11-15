import Foundation

/// How tired each muscle still is (lib/recovery.js fatigueOf) and the Home hint built on it
/// (lib/recovery-hint.js). Each session's effective sets per muscle, weighted by effort, decay
/// with the muscle's half-life; the gain on a session grows when the week is heavier than the
/// month. Fatigue is 0...1, above 0.5 counts as still recovering.
public enum Recovery {
    public typealias Object = [String: JSONValue]

    static let day = 86_400_000.0
    static let scanMs = 30 * day, rirWindowMs = 90 * day, acuteMs = 7 * day, chronicMs = 28 * day
    static let setsPerUnit = 8.0, cardioMinutes = 30.0, maxSets = 12.0, rirFloor = 0.3
    static let noviceWeekly = 4.0, bodyweightRef = 75.0, lbToKg = 0.45359237, hardRir = 3.0, repCap = 12.0
    static let hours24 = ["deltoids", "serratus", "biceps", "triceps", "forearm", "abs", "obliques", "hip-flexors", "tibialis"]
    static let hours48 = ["lower-back", "gluteal", "quadriceps", "hamstring", "adductors", "calves"]

    static func halfLife(_ slug: String) -> Double {
        (hours24.contains(slug) ? 24 : hours48.contains(slug) ? 48 : 30) * 3_600_000
    }

    // MARK: Reading rows the way JavaScript does

    /// `numeric`: nil for missing, null, "" or a boolean, else a finite Number().
    static func numeric(_ v: JSONValue?) -> Double? {
        switch v {
        case .number(let x)?: return x.isFinite ? x : nil
        case .string(let s)?:
            guard !s.isEmpty else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return 0 }
            return Double(t).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    /// `workoutAt`: the start, else noon of the day, else NaN.
    static func at(_ w: Object) -> Double {
        if case .number(let s)? = w["start"], s.isFinite { return s }
        return Day.noon(w["d"]?.stringValue ?? "")
    }

    /// `isWarmupRow`: an explicit phase wins over the old warm-up flag.
    static func isWarmupRow(_ row: Object?) -> Bool {
        guard let row else { return false }
        if let p = row["phase"], p != .null, p != .string("") {
            let token = p.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return ["warmup", "warm-up", "warm_up"].contains(token)
        }
        return row["warmup"] == .bool(true)
    }

    /// `rirOf`: rated reps in reserve, RPE turned into RIR, or 0 for a set taken to failure.
    // ponytail: a rating stored as a string is read as its number; JavaScript would concatenate it.
    static func rir(_ row: Object?) -> Double? {
        guard let row else { return nil }
        if let v = row["rir"], v != .null { return numeric(v) }
        if let v = row["rpe"], v != .null { return numeric(v).map { 10 - $0 } }
        return row["failure"] == .bool(true) && !isWarmupRow(row) ? 0 : nil
    }

    static func done(_ row: Object?) -> Bool { row?["done"] == .bool(true) }

    // MARK: Units and loads

    static let unitKeys = ["unit", "u", "weightUnit", "weight_unit", "loadUnit"]
    static func stamped(_ v: JSONValue?) -> Bool {
        switch v {
        case nil, .null?: return false
        case .string(let s)?: return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: return true
        }
    }
    static func unit(_ records: Object?...) -> JSONValue {
        for r in records.compactMap({ $0 }) { if let k = unitKeys.first(where: { stamped(r[$0]) }) { return r[k]! } }
        return .string("kg")
    }
    static func hasUnitStamp(_ records: Object?...) -> Bool {
        records.compactMap { $0 }.contains { r in unitKeys.contains { stamped(r[$0]) } }
    }
    static func isPounds(_ u: JSONValue) -> Bool {
        if u == .string("kg") || u == .null { return false }
        guard case .string(let s) = u else { return false }
        return ["lb", "lbs", "pound", "pounds"].contains(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    static func kg(_ v: JSONValue?, _ u: JSONValue) -> Double {
        guard let n = numeric(v) else { return 0 }
        return max(0, n) * (isPounds(u) ? lbToKg : 1)
    }

    /// The profile settings the loads are read against (`opts`).
    struct Opts { let record: Object; let bodyweightKg: Double? }

    static func bodyweightKg(_ w: Object, _ o: Opts, _ loadUnit: JSONValue?) -> Double {
        if let s = numeric(w["bw"]) ?? numeric(w["bodyweight"]) {
            return kg(.number(s), unit(["unit": w["bwUnit"] ?? .null], ["unit": w["bodyweightUnit"] ?? .null], w, loadUnit.map { ["unit": $0] }, o.record))
        }
        if let b = o.bodyweightKg { return max(0, b) }
        return bodyweightRef
    }

    /// The catalogue's exercise, or the entry itself for one the catalogue does not know.
    static func equipment(_ entry: Object, _ c: ExerciseCatalog) -> String? {
        entry["id"]?.stringValue.flatMap { c[$0] }?.equipment ?? entry["eq"]?.stringValue
    }

    static func bodyweightConfigured(_ entry: Object, _ set: Object, _ w: Object, _ o: Opts, _ c: ExerciseCatalog) -> Bool {
        let target = entry["target"]?.object
        if let t = target, let v = t["bodyweight"] { return Session.truthy(v) }
        if let v = entry["bodyweight"] { return Session.truthy(v) }
        guard equipment(entry, c) == "body weight" else { return false }
        let added = kg(set["w"], unit(set, target, entry, w, o.record))
        let context = numeric(w["bw"]) != nil || numeric(w["bodyweight"]) != nil || o.bodyweightKg != nil
            || hasUnitStamp(set, target, entry, w)
        return added == 0 || context
    }

    /// `loadKgFor`: the row's load in kg, with the lifter's body added for body weight work.
    static func loadKg(_ entry: Object, _ set: Object, _ w: Object, _ o: Opts, row: Object, _ c: ExerciseCatalog) -> Double {
        let target = entry["target"]?.object
        let rowUnit = unit(row, set, target, entry, w, o.record)
        let added = kg(row["w"], rowUnit)
        guard bodyweightConfigured(entry, set, w, o, c) else { return added }
        let loadUnit = hasUnitStamp(row, set, target, entry) ? rowUnit : nil
        return bodyweightKg(w, o, loadUnit) + added
    }

    // MARK: Muscles

    static func snapshot(_ ex: Object?, _ c: ExerciseCatalog) -> [String: Double]? {
        guard let mw = ex?["muscleWeights"]?.object else { return nil }
        var out: [String: Double] = [:]
        for slug in c.meta.muscles { if let v = numeric(mw[slug]), v >= 0, v <= 1 { out[slug] = v } }
        return out.isEmpty ? nil : out.filter { $0.value > 0 }
    }

    /// `musclesOf(exerciseFor(entry))`: the catalogue first, a stored snapshot for an unknown one.
    // ponytail: an unknown exercise without a muscleWeights snapshot counts for nothing; JS also
    // reads its target, group and body part.
    static func muscles(_ entry: Object, _ c: ExerciseCatalog) -> [String: Double] {
        if let ex = entry["id"]?.stringValue.flatMap({ c[$0] }) {
            return c.muscleWeights(of: ex).filter { $0.value > 0 && c.meta.muscles.contains($0.key) }
        }
        return snapshot(entry, c) ?? [:]
    }

    /// `loadOf`: a stored snapshot wins over the catalogue.
    static func historicalMuscles(_ entry: Object, _ c: ExerciseCatalog) -> [String: Double] {
        let historical = entry["exercise"]?.object ?? entry
        if historical["muscleWeights"].map(Session.truthy) == true { return snapshot(historical, c) ?? [:] }
        return muscles(entry, c)
    }

    static func entries(_ w: Object) -> [Object] { (w["entries"]?.arrayValue ?? []).compactMap(\.object) }
    static func rows(_ e: Object) -> [Object] { (e["sets"]?.arrayValue ?? []).map { $0.object ?? [:] } }

    // MARK: Effort

    static func rirWeight(_ rir: Double?) -> Double {
        guard let rir, rir > hardRir else { return 1 }
        if rir >= 6 { return rirFloor }
        return 1 - (1 - rirFloor) * (rir - hardRir) / (6 - hardRir)
    }

    static func estimateRir(load: Double, reps: Double?, anchor: Double) -> Double? {
        guard anchor > 0, load > 0, let r = reps, r >= 1, r <= repCap else { return nil }
        return min(10, max(0, 30 * (anchor / load - 1) - r))
    }

    /// `resolveSetRir`: (rir, logged).
    static func resolveRir(_ row: Object, _ set: Object, _ entry: Object, _ w: Object, _ anchors: [String: Double], _ o: Opts, _ c: ExerciseCatalog) -> (Double, Bool)? {
        if let logged = rir(row) { return (logged, true) }
        guard let anchor = anchors[entry["id"]?.stringValue ?? ""], anchor > 0 else { return nil }
        let load = loadKg(entry, set, w, o, row: row, c)
        return estimateRir(load: load, reps: numeric(row["r"]), anchor: anchor).map { ($0, false) }
    }

    static func sessionEffSets(_ w: Object, _ anchors: [String: Double], _ o: Opts, _ c: ExerciseCatalog) -> [String: Double] {
        var sums: [String: Double] = [:]
        for entry in entries(w) {
            let weights = muscles(entry, c)
            let id = entry["id"] ?? .null
            let mode = RoutineOps.mode((entry["target"]?.object ?? [:]).merging(["id": id]) { _, b in b }, catalog: c)
            func score(_ row: Object, _ set: Object, requireDone: Bool) {
                if requireDone && !done(row) { return }
                let resolved = resolveRir(row, set, entry, w, anchors, o, c)
                let count = resolved?.1 != true && isWarmupRow(set) ? rirFloor : rirWeight(resolved?.0)
                // Number(row.min): missing is NaN (no scaling), null is 0.
                let minutes: Double? = row["min"] == nil ? nil : row["min"] == .null ? 0 : numeric(row["min"])
                let scale = mode == "cardio" && minutes != nil ? max(0, minutes!) / cardioMinutes : 1
                for (slug, weight) in weights { sums[slug, default: 0] += count * scale * weight }
            }
            for set in rows(entry) {
                score(set, set, requireDone: true)
                if done(set), set["type"] == .string("dropset"), let drops = set["drops"]?.arrayValue {
                    for d in drops { score(d.object ?? [:], set, requireDone: false) }
                }
            }
        }
        return sums.mapValues { min($0, maxSets) }
    }

    /// `sessionBests`: each exercise's best estimated one-rep max in kg, effort included.
    static func sessionBests(_ w: Object, _ o: Opts, _ c: ExerciseCatalog) -> [String: Double] {
        var best: [String: Double] = [:]
        for entry in entries(w) {
            let id = entry["id"]?.stringValue ?? ""
            if Session.isAssisted(["id": entry["id"] ?? .null], c) { continue }
            for set in rows(entry) where done(set) {
                let pair = set["sides"]?.object
                let sides: [Object] = Session.isSideSet(.object(set))
                    ? [pair?["L"]?.object ?? [:], pair?["R"]?.object ?? [:]].filter { done($0) } : [set]
                for side in sides {
                    let reps = numeric(side["r"])
                    let logged = rir(side) ?? rir(set)
                    let eff = reps.map { r in logged.map { r + $0 } ?? r }
                    guard let eff, let est = Stats.estimate1RM(loadKg(entry, set, w, o, row: side, c), eff) else { continue }
                    if est > (best[id] ?? -.infinity) { best[id] = est }
                }
            }
        }
        return best
    }

    // MARK: Fatigue

    struct Item { let w: Object; let index: Int; let ts: Double }

    static func ordered(_ ws: [Object], after cutoff: Double = -.infinity) -> [Item] {
        ws.enumerated().map { Item(w: $1, index: $0, ts: at($1)) }
            .filter { $0.ts.isFinite && $0.ts > cutoff }
            .sorted { $0.ts != $1.ts ? $0.ts < $1.ts : $0.index < $1.index }
    }

    /// The muscle → fatigue (0...1) map at `now`.
    public static func fatigue(_ workouts: [Object], now: Double, unit: String?, bodyweightKg: Double?, catalog c: ExerciseCatalog) -> [String: Double] {
        var result = Dictionary(uniqueKeysWithValues: c.meta.muscles.map { ($0, 0.0) })
        guard now.isFinite else { return result }
        let o = Opts(record: unit.map { ["unit": .string($0)] } ?? [:], bodyweightKg: bodyweightKg)
        let pool = ordered(workouts, after: now - (scanMs + rirWindowMs))
        let bests = pool.map { sessionBests($0.w, o, c) }
        var effSets: [[String: Double]] = []
        for (i, item) in pool.enumerated() {
            var anchors: [String: Double] = [:]
            for j in 0...i where pool[j].ts > item.ts - rirWindowMs {
                for (id, est) in bests[j] where est > (anchors[id] ?? -.infinity) { anchors[id] = est }
            }
            effSets.append(sessionEffSets(item.w, anchors, o, c))
        }
        var events: [String: [(ts: Double, stim: Double)]] = [:]
        for (i, item) in pool.enumerated() where item.ts > now - scanMs {
            var acute: [String: Double] = [:], chronic: [String: Double] = [:]
            for j in 0...i {
                let age = item.ts - pool[j].ts
                guard age >= 0, age <= chronicMs else { continue }
                for (slug, v) in effSets[j] {
                    if age <= acuteMs { acute[slug, default: 0] += v }
                    chronic[slug, default: 0] += v
                }
            }
            for (slug, stim) in effSets[i] where stim > 0 {
                let gain = min(2, max(0.5, ((acute[slug] ?? 0) + noviceWeekly) / ((chronic[slug] ?? 0) / 4 + noviceWeekly)))
                events[slug, default: []].append((item.ts, stim / setsPerUnit * gain))
            }
        }
        for (slug, list) in events where result[slug] != nil {
            let hl = halfLife(slug)
            var value = 0.0, last = list[0].ts
            for e in list {
                value = value * pow(0.5, (e.ts - last) / hl) + e.stim
                last = e.ts
            }
            value *= pow(0.5, max(0, now - last) / hl)
            result[slug] = 1 - exp(-value)
        }
        return result
    }

    // MARK: The Home hint

    public struct Hint: Equatable, Sendable {
        /// "rest", "lighter", "split", "covered" or "neglect".
        public let kind: String
        public var region: String?, group: String?, day: String?, routine: String?
        public var days: Int?
    }

    static let regions: KeyValuePairs = ["legs": ["quadriceps", "hamstring", "gluteal"], "upper": ["chest", "upper-back", "deltoids"]]
    static let groups: KeyValuePairs = ["legs": ["quadriceps", "hamstring", "gluteal"], "back": ["upper-back"], "chest": ["chest"], "shoulders": ["deltoids"]]
    static func region(_ r: String) -> [String] { regions.first { $0.key == r }!.value }

    static func daysBetween(_ a: String, _ b: String) -> Int { Int(((Day.noon(b) - Day.noon(a)) / day).rounded()) }

    /// When each muscle last had one effective set of work or more, ms.
    static func lastWorked(_ ws: [Object], _ c: ExerciseCatalog) -> [String: Double] {
        var out: [String: Double] = [:]
        for w in ws {
            let ts = at(w)
            guard ts.isFinite else { continue }
            var load: [String: Double] = [:]
            for e in entries(w) {
                let sets = Double(rows(e).filter { Session.truthy($0["done"]) && !isWarmupRow($0) }.count)
                guard sets > 0 else { continue }
                for (slug, v) in historicalMuscles(e, c) { load[slug, default: 0] += v * sets }
            }
            for (slug, v) in load where v >= 1 && !((out[slug] ?? -.infinity) >= ts) { out[slug] = ts }
        }
        return out
    }

    /// Today's hint, or nil (recoveryHint). `fatigue` is `fatigue(...)` at `now`.
    public static func hint(_ s: Object, now: Double, today: String, fatigue: [String: Double], catalog c: ExerciseCatalog) -> Hint? {
        if s["recoveryHint"] == .bool(false) || s["recoveryHintDay"] == .string(today) || Session.truthy(s["active"]) { return nil }
        let ws = (s["workouts"]?.arrayValue ?? []).compactMap(\.object)
        if ws.contains(where: { $0["d"] == .string(today) }) { return nil }
        guard ws.filter({ let t = at($0); return t > now - 30 * day && t <= now }).count >= 3 else { return nil }
        let last = lastWorked(ws, c)
        func latest(_ slugs: [String]) -> Double { slugs.map { last[$0] ?? 0 }.max() ?? 0 }
        func lastDay(_ slugs: [String]) -> String? { let t = latest(slugs); return t > 0 ? Day.iso(t) : nil }
        let recovering = regions.filter { $0.value.contains { (fatigue[$0] ?? 0) > 0.5 } }.map(\.key)
        let neglected = groups.map { g -> (group: String, at: Double, days: Int?) in
            let t = latest(g.value)
            return (g.key, t, t > 0 ? daysBetween(Day.iso(t), today) : nil)
        }
        .filter { $0.at > now - 60 * day && ($0.days ?? 0) >= 7 }
        .enumerated().sorted { $0.element.days! != $1.element.days! ? $0.element.days! > $1.element.days! : $0.offset < $1.offset }.map(\.element)
        let all = (s["routines"]?.arrayValue ?? []).compactMap(\.object)
        let routines = Schedule.routineIds(s, on: today, today: today)
            .compactMap { id in all.first { $0["id"]?.stringValue == id } }
            .filter { !($0["ex"]?.arrayValue ?? []).isEmpty }
        let hasPlan = (s["week"]?.object ?? [:]).values.contains { v in
            switch v { case .array(let a): return !a.isEmpty; default: return Session.truthy(v) }
        } || !(s["queue"]?.object?["ids"]?.arrayValue ?? []).isEmpty
        if routines.isEmpty && (hasPlan || s["dayPlan"]?.object?[today] == .string("rest")) {
            return recovering.first.map { Hint(kind: "rest", region: $0, day: lastDay(region($0))) }
        }
        if !routines.isEmpty {
            var load: [String: Double] = [:]
            for cfg in routines.flatMap({ ($0["ex"]?.arrayValue ?? []).compactMap(\.object) }) {
                let sets = Session.or(cfg["sets"], 1)
                for (slug, v) in historicalMuscles(cfg, c) { load[slug, default: 0] += v * sets }
            }
            func sets(_ r: String) -> Double { region(r).reduce(0) { $0 + (load[$1] ?? 0) } }
            let heavy = recovering.filter { sets($0) >= 3 }.enumerated()
                .sorted { sets($0.element) != sets($1.element) ? sets($0.element) > sets($1.element) : $0.offset < $1.offset }.map(\.element)
            if let r = heavy.first {
                return Hint(kind: "lighter", region: r, day: lastDay(region(r)), routine: routines.map { $0["name"]?.stringValue ?? "" }.joined(separator: " + "))
            }
            let covered = neglected.first { g in groups.first { $0.key == g.group }!.value.contains { (load[$0] ?? 0) >= 1 } }
            return covered.map { Hint(kind: "covered", group: $0.group, days: $0.days) }
        }
        if recovering.count == 1 { return Hint(kind: "split", region: recovering[0], day: lastDay(region(recovering[0]))) }
        if !recovering.isEmpty { return nil }
        return neglected.first.map { Hint(kind: "neglect", group: $0.group, days: $0.days) }
    }

    /// The hint's words: the main line and the follow-up (hintText).
    public static func text(_ h: Hint, today: String) -> (String, String) {
        let day = dayWord(h.day, today)
        let regionLine = h.region == "legs" ? "Your legs are still recovering from \(day)." : "Your upper body is still recovering from \(day)."
        let n = h.days ?? 0
        let groupLine = switch h.group ?? "" {
        case "legs": "Your legs haven’t had any work in \(n) days."
        case "back": "Your back hasn’t had any work in \(n) days."
        case "chest": "Your chest hasn’t had any work in \(n) days."
        default: "Your shoulders haven’t had any work in \(n) days."
        }
        return switch h.kind {
        case "rest": ("Rest day, good timing.", regionLine)
        case "lighter": (regionLine, "Go a bit lighter today, or swap the session.")
        case "split": (regionLine, h.region == "legs" ? "Upper body today?" : "Legs today?")
        case "covered": (groupLine, "Today’s plan takes care of that.")
        default: (groupLine, "A few sets today would be nice.")
        }
    }

    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// "yesterday", a weekday within the week, else a short date.
    static func dayWord(_ d: String?, _ today: String) -> String {
        guard let d, !d.isEmpty, let date = Day.date(d) else { return "" }
        let n = daysBetween(d, today)
        if n == 1 { return "yesterday" }
        if n > 1 && n < 7, let w = Day.weekday(d) { return weekdays[w] }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
