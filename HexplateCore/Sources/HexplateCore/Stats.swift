import Foundation

/// Training statistics read from the document: one-rep maxes (lib/onerm.js), strength levels
/// (lib/strength-level.js) and weekly sets per muscle (lib/muscle-targets.js).
///
/// ponytail: structural balance (lib/structuralBalance*.js) is not ported yet.
public enum Stats {
    public typealias Object = [String: JSONValue]
    static func n(_ v: JSONValue?) -> Double { v?.num ?? 0 }
    static func jsRound(_ v: Double) -> Double { (v + 0.5).rounded(.down) }
    static func round1(_ v: Double) -> Double { jsRound(v * 10) / 10 }

    // MARK: One-rep max

    public static let formulas: [String: @Sendable (Double, Double) -> Double] = [
        "epley": { w, r in w * (1 + r / 30) },
        "brzycki": { w, r in w * 36 / (37 - r) },
        "lombardi": { w, r in w * pow(r, 0.1) },
        "oconner": { w, r in w * (1 + r / 40) },
        "mayhew": { w, r in (w * 100) / (52.2 + 41.9 * exp(-0.055 * r)) },
        "wathan": { w, r in (w * 100) / (48.8 + 53.8 * exp(-0.075 * r)) },
        "lander": { w, r in (w * 100) / (101.3 - 2.67123 * r) },
    ]
    /// The JavaScript key order, which the weighted sum follows.
    static let formulaOrder = ["epley", "brzycki", "lombardi", "oconner", "mayhew", "wathan", "lander"]
    public static let formulaNames = ["epley": "Epley", "brzycki": "Brzycki", "lombardi": "Lombardi", "oconner": "O’Conner",
                                      "mayhew": "Mayhew", "wathan": "Wathan", "lander": "Lander", "weighted": "Weighted"]

    public static func formula(_ s: Object) -> String {
        let f = s["oneRmFormula"]?.stringValue ?? ""
        return f == "weighted" || formulas[f] != nil ? f : "epley"
    }

    static let rirPct: [Double] = [100, 95.5, 92.2, 89.2, 86.3, 83.7, 81.1, 78.6, 76.2, 73.9, 71.7, 69.5, 67.5, 65.5, 63.6]
    static let weights: [String: (a: Double, v: @Sendable (Double) -> Double)] = [
        "epley": (0.95, { $0 <= 6 ? 1 : max(0.4, 1 - ($0 - 6) * 0.12) }),
        "brzycki": (1.10, { $0 <= 8 ? 1 : max(0.3, 1 - ($0 - 8) * 0.18) }),
        "lombardi": (0.85, { $0 <= 5 ? 1 : max(0.4, 1 - ($0 - 5) * 0.10) }),
        "oconner": (0.90, { $0 <= 6 ? 1 : max(0.4, 1 - ($0 - 6) * 0.12) }),
        "mayhew": (0.95, { $0 <= 8 ? 1 : max(0.5, 1 - ($0 - 8) * 0.10) }),
        "wathan": (0.90, { $0 <= 7 ? 1 : max(0.4, 1 - ($0 - 7) * 0.12) }),
        "lander": (0.85, { $0 <= 7 ? 1 : max(0.35, 1 - ($0 - 7) * 0.15) }),
        "rir": (1.00, { $0 <= 10 ? 1 : max(0.4, 1 - ($0 - 10) * 0.15) }),
    ]

    static func weightedEstimate(_ w: Double, _ reps: Double) -> Double {
        var total = 0.0, sum = 0.0
        for name in formulaOrder {
            let wt = weights[name]!.a * weights[name]!.v(reps)
            total += formulas[name]!(w, reps) * wt
            sum += wt
        }
        let idx = min(max(Int(jsRound(reps)) - 1, 0), rirPct.count - 1)
        let rirWt = weights["rir"]!.a * weights["rir"]!.v(reps)
        total += (w * 100) / rirPct[idx] * rirWt
        sum += rirWt
        return total / sum
    }

    /// An estimated one-rep max, or nil past what the formula can tell (onerm.js estimate1RM).
    public static func estimate1RM(_ w: Double, _ r: Double, formula: String = "epley", rir: Double? = nil) -> Double? {
        guard w.isFinite, r.isFinite, w > 0, r >= 1 else { return nil }
        let validRir = rir.map { $0 >= 0 } ?? false
        if r == 1 && (!validRir || rir == 0) { return round1(w) }
        if formula == "weighted" {
            let eff = validRir ? r + rir! : r
            guard eff <= 15 else { return nil }
            let est = weightedEstimate(w, eff)
            return est.isFinite && est > 0 ? round1(est) : nil
        }
        guard r <= 12 else { return nil }
        let est = r == 1 ? w : (formulas[formula] ?? formulas["epley"]!)(w, jsRound(r))
        return est.isFinite && est > 0 ? round1(est) : nil
    }

    public struct Point: Equatable, Sendable { public let day: String; public let estimate, weight, reps: Double }

    static func bestSet(_ e: Object, formula: String, catalog: ExerciseCatalog) -> Point? {
        if e["target"]?.object?["assisted"] == .bool(true) { return nil }
        if let id = e["id"]?.stringValue, catalog[id]?.isAssisted == true { return nil }
        var best: Point?
        for s in e["sets"]?.arrayValue ?? [] where !Session.isWarmup(s) && Session.hasCompletedWork(s) && isReps(s) {
            let rows = Session.isSideSet(s) ? ["L", "R"].compactMap { s.object!["sides"]!.object![$0] }.filter { $0.object?["done"] == .bool(true) } : [s]
            for row in rows {
                let o = row.object ?? [:]
                guard let est = estimate1RM(n(o["w"]), n(o["r"]), formula: formula, rir: o["rir"]?.numberValue) else { continue }
                if best == nil || est > best!.estimate { best = Point(day: "", estimate: est, weight: n(o["w"]), reps: jsRound(n(o["r"]))) }
            }
        }
        return best
    }

    /// A row logged as reps, not time or distance.
    static func isReps(_ s: JSONValue) -> Bool {
        guard let o = s.object else { return false }
        if let m = o["mode"]?.stringValue { return m == "reps" }
        return o["sec"] == nil && o["min"] == nil
    }

    /// The best estimate per workout, oldest first (onerm.js e1rmSeries).
    public static func oneRepMaxSeries(_ s: Object, _ exId: String, catalog: ExerciseCatalog) -> [Point] {
        if catalog[exId]?.isAssisted == true { return [] }
        let f = formula(s)
        var out: [Point] = []
        for w in (s["workouts"]?.arrayValue ?? []).compactMap(\.object) {
            var best: Point?
            for e in (w["entries"]?.arrayValue ?? []).compactMap(\.object) where e["id"]?.stringValue == exId {
                if let p = bestSet(e, formula: f, catalog: catalog), best == nil || p.estimate > best!.estimate { best = p }
            }
            if let best { out.append(Point(day: w["d"]?.stringValue ?? "", estimate: best.estimate, weight: best.weight, reps: best.reps)) }
        }
        return out
    }

    public static func bestOneRepMax(_ s: Object, _ exId: String, catalog: ExerciseCatalog) -> Point? {
        oneRepMaxSeries(s, exId, catalog: catalog).reduce(nil) { best, p in best == nil || p.estimate > best!.estimate ? p : best }
    }

    // MARK: Strength levels

    public static let levels = ["Beginner", "Novice", "Intermediate", "Advanced", "Elite"]
    struct Standard { let lift: String; let ids: [String]; let m: [Double]; let f: [Double] }
    static let standards: [Standard] = [
        .init(lift: "squat", ids: ["0043", "3593"], m: [0.75, 1.25, 1.5, 2.25, 2.75], f: [0.5, 0.75, 1.25, 1.5, 2]),
        .init(lift: "bench", ids: ["0025"], m: [0.5, 0.75, 1, 1.5, 2], f: [0.25, 0.5, 0.75, 1, 1.5]),
        .init(lift: "deadlift", ids: ["0032", "0117"], m: [1, 1.5, 2, 2.5, 3], f: [0.5, 1, 1.25, 1.75, 2.5]),
        .init(lift: "press", ids: ["1162"], m: [0.35, 0.55, 0.8, 1.05, 1.35], f: [0.2, 0.35, 0.5, 0.75, 1]),
        .init(lift: "row", ids: ["0027"], m: [0.5, 0.75, 1, 1.5, 1.75], f: [0.25, 0.4, 0.65, 0.9, 1.2]),
        .init(lift: "frontSquat", ids: ["0042"], m: [0.55, 0.8, 1.2, 1.6, 2], f: [0.35, 0.55, 0.85, 1.15, 1.5]),
        .init(lift: "incline", ids: ["0047"], m: [0.4, 0.65, 0.85, 1.2, 1.5], f: [0.2, 0.4, 0.6, 0.85, 1.1]),
        .init(lift: "rdl", ids: ["0085"], m: [0.6, 1, 1.4, 1.9, 2.4], f: [0.4, 0.65, 1, 1.4, 1.8]),
        .init(lift: "hipThrust", ids: ["1060"], m: [0.5, 1, 1.75, 2.5, 3.25], f: [0.5, 1, 1.5, 2.25, 3]),
        .init(lift: "curl", ids: ["0031"], m: [0.2, 0.4, 0.6, 0.85, 1.15], f: [0.1, 0.2, 0.4, 0.6, 0.85]),
        // ponytail: per-bell standards read the weight as stored; the original converts a "total" dumbbell load.
        .init(lift: "dbBench", ids: ["0289"], m: [0.2, 0.35, 0.5, 0.75, 1], f: [0.1, 0.2, 0.35, 0.5, 0.7]),
        .init(lift: "dbPress", ids: ["0405"], m: [0.15, 0.25, 0.4, 0.6, 0.8], f: [0.1, 0.15, 0.25, 0.4, 0.55]),
        .init(lift: "dbCurl", ids: ["0294"], m: [0.1, 0.2, 0.3, 0.45, 0.6], f: [0.05, 0.1, 0.2, 0.3, 0.4]),
    ]

    static func ageCoefficient(_ age: Double?) -> Double {
        let table: [(Double, Double)] = [(40, 1), (45, 1.06), (50, 1.13), (55, 1.21), (60, 1.3), (65, 1.43), (70, 1.59), (75, 1.79), (80, 2.03)]
        guard let a = age, a > 40 else { return 1 }
        if a >= 80 { return 2.03 }
        for i in 1..<table.count where a <= table[i].0 {
            let (a0, c0) = table[i - 1], (a1, c1) = table[i]
            return c0 + (c1 - c0) * (a - a0) / (a1 - a0)
        }
        return 1
    }

    public struct Level: Equatable, Sendable {
        public let lift, id: String
        public let level: Int
        public let ratio, oneRepMax, bodyweight: Double
        public let thresholds: [Double]
        /// The load that reaches the next level, nil at the top.
        public let nextWeight: Double?
    }

    public static func lastBodyweight(_ s: Object) -> Double? {
        s["bodyweight"]?.arrayValue?.last?.object?["w"]?.num
    }

    /// The lifts with a standard, best first (strength-level.js strengthLevels).
    public static func strengthLevels(_ s: Object, catalog: ExerciseCatalog, year: Int = Calendar.current.component(.year, from: .now)) -> [Level] {
        guard let bw = lastBodyweight(s), bw > 0 else { return [] }
        let female = s["sex"] == .string("female")
        let birth = s["birthYear"].map { jsRound($0.num) }
        let age = birth.flatMap { $0 >= 1900 && $0 <= Double(year) ? Double(year) - $0 : nil }
        let k = ageCoefficient(age)
        var out: [(Level, Int)] = []
        for (order, st) in standards.enumerated() {
            let th = (female ? st.f : st.m).map { jsRound($0 / k * 1000) / 1000 }
            var best: Level?
            for id in st.ids {
                guard let one = bestOneRepMax(s, id, catalog: catalog), one.estimate > 0 else { continue }
                let ratio = one.estimate / bw
                var level = 0
                for (i, t) in th.enumerated() where ratio >= t - 1e-9 { level = i }
                let next = level < 4 ? (th[level + 1] * bw * 2).rounded(.up) / 2 : nil
                let l = Level(lift: st.lift, id: id, level: level, ratio: jsRound(ratio * 100) / 100, oneRepMax: one.estimate, bodyweight: bw, thresholds: th, nextWeight: next)
                if best == nil || l.ratio > best!.ratio { best = l }
            }
            if let best { out.append((best, order)) }
        }
        return out.sorted { a, b in
            a.0.level != b.0.level ? a.0.level > b.0.level : a.0.ratio != b.0.ratio ? a.0.ratio > b.0.ratio : a.1 < b.1
        }.map(\.0)
    }

    // MARK: Weekly sets per muscle

    public static let defaultTargets: [(slug: String, range: [Double])] = [
        ("chest", [10, 20]), ("upper-back", [10, 20]), ("deltoids", [8, 20]), ("biceps", [8, 18]), ("triceps", [6, 16]),
        ("quadriceps", [8, 18]), ("hamstring", [6, 16]), ("gluteal", [4, 16]), ("calves", [8, 16]), ("abs", [6, 16]),
    ]

    public struct MuscleWeek: Equatable, Sendable {
        public let slug: String
        public let sets, low, high: Double
        /// "below", "in" or "above".
        public let status: String
    }

    static func target(_ s: Object, _ slug: String, _ fallback: [Double]) -> [Double] {
        if let own = s["muscleTargets"]?.object?[slug]?.arrayValue, own.count == 2 {
            let lo = jsRound(own[0].num), hi = jsRound(own[1].num)
            if lo >= 0 && hi >= lo && hi <= 40 { return [lo, hi] }
        }
        return fallback
    }

    /// Ticked-off work sets this week, shared out by each exercise's muscle weights.
    public static func weeklyMuscleSets(_ s: Object, today: String, catalog: ExerciseCatalog) -> [MuscleWeek] {
        let start = s["weekStart"] == .number(0) ? 0 : 1
        let week = Schedule.weekKey(today, weekStart: start)
        var load: [String: Double] = [:]
        for w in (s["workouts"]?.arrayValue ?? []).compactMap(\.object) where Schedule.weekKey(w["d"]?.stringValue ?? "", weekStart: start) == week {
            for e in (w["entries"]?.arrayValue ?? []).compactMap(\.object) {
                let sets = Double((e["sets"]?.arrayValue ?? []).filter { $0.object?["done"] == .bool(true) && !Session.isWarmup($0) }.count)
                guard sets > 0, let ex = e["id"]?.stringValue.flatMap({ catalog[$0] }) else { continue }
                for (slug, share) in catalog.muscleWeights(of: ex) where share > 0 { load[slug, default: 0] += share * sets }
            }
        }
        return defaultTargets.map { slug, range in
            let t = target(s, slug, range)
            let sets = round1(load[slug] ?? 0)
            return MuscleWeek(slug: slug, sets: sets, low: t[0], high: t[1], status: sets < t[0] - 1e-9 ? "below" : sets > t[1] + 1e-9 ? "above" : "in")
        }
    }

    // MARK: Volume and training days

    /// Stored volume per week (keyed by the week's first day), oldest first, for the last `weeks` weeks.
    public static func weeklyVolume(_ s: Object, today: String, weeks: Int = 12) -> [(week: String, volume: Double)] {
        let start = s["weekStart"] == .number(0) ? 0 : 1
        guard let current = Schedule.weekKey(today, weekStart: start) else { return [] }
        var by: [String: Double] = [:]
        for w in (s["workouts"]?.arrayValue ?? []).compactMap(\.object) {
            if let k = Schedule.weekKey(w["d"]?.stringValue ?? "", weekStart: start) { by[k, default: 0] += n(w["vol"]) }
        }
        return (0..<weeks).reversed().compactMap { i in Day.adding(-7 * i, to: current).map { ($0, by[$0] ?? 0) } }
    }

    /// Days with a workout.
    public static func trainingDays(_ s: Object) -> Set<String> {
        Set((s["workouts"]?.arrayValue ?? []).compactMap { $0.object?["d"]?.stringValue })
    }
}
