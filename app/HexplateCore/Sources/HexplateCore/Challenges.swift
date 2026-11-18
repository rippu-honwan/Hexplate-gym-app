import Foundation

/// Monthly challenges (openGym lib/challenges.js, lib/challenge-copy.js): three small goals each
/// calendar month, one per kind where it can (a habit, an effort, something new), sized a bit above
/// the three months before. The picks are stored once made (`challenges[month] = {picked, done, at}`,
/// merged by the sync code); the progress is always read back from the workouts.
public enum Challenges {
    public typealias Object = [String: JSONValue]

    public static let picks = 3, lookback = 3, monthsKept = 24, weekDaysIn = 4
    static let weeksPerMonth = 4.348, lbKg = 0.45359237, factor = 1.15
    public static let kinds = ["habit", "effort", "explore"]
    public static let groups: [(id: String, muscles: [String])] = [
        ("chest", ["chest", "serratus"]), ("back", ["upper-back", "trapezius", "lower-back"]), ("shoulders", ["deltoids"]),
        ("arms", ["biceps", "triceps", "forearm"]),
        ("legs", ["gluteal", "quadriceps", "hamstring", "adductors", "calves", "hip-flexors", "tibialis"]), ("core", ["abs", "obliques"]),
    ]
    static let groupOf: [String: String] = Dictionary(uniqueKeysWithValues: groups.flatMap { g in g.muscles.map { ($0, g.id) } })

    // MARK: Months

    static func monthIndex(_ key: String) -> Int {
        let p = key.split(separator: "-").compactMap { Int($0) }
        return p[0] * 12 + (p[1] - 1)
    }
    public static func shift(_ key: String, _ n: Int) -> String {
        let i = monthIndex(key) + n
        return String(format: "%d-%02d", Int((Double(i) / 12).rounded(.down)), (i % 12 + 12) % 12 + 1)
    }
    static func daysIn(_ key: String) -> Int {
        let p = key.split(separator: "-").compactMap { Int($0) }
        let cal = Calendar(identifier: .gregorian)
        return cal.range(of: .day, in: .month, for: cal.date(from: DateComponents(year: p[0], month: p[1], day: 15))!)!.count
    }
    public static func isMonthKey(_ k: String) -> Bool { k.wholeMatch(of: /\d{4}-(0[1-9]|1[0-2])/) != nil }

    /// The profile's weeks with at least four days inside the month.
    static func weeks(of key: String, weekStart ws: Int) -> [String] {
        var order: [String] = [], per: [String: Int] = [:]
        for d in 1...daysIn(key) {
            guard let k = Schedule.weekKey(key + String(format: "-%02d", d), weekStart: ws) else { continue }
            if per[k] == nil { order.append(k) }
            per[k, default: 0] += 1
        }
        return order.filter { per[$0]! >= weekDaysIn }
    }

    // MARK: Reading a month back

    struct Facts: Sendable {
        var workouts = 0, weeks = 0, weeksTrained = 0
        var volumeKg = 0.0, prs = 0, pullups = 0.0, pushups = 0.0, cardioMin = 0.0
        var weighDays = 0, newEx = 0, groups = 0
    }

    static func rows(_ e: Object) -> [Object] { (e["sets"]?.arrayValue ?? []).compactMap(\.object).filter { !Recovery.isWarmupRow($0) } }
    static func sides(_ s: Object) -> (Object, Object)? {
        guard let sd = s["sides"]?.object, let l = sd["L"]?.object, let r = sd["R"]?.object else { return nil }
        return (l, r)
    }
    static func doneUnits(_ s: Object) -> Int {
        let on = { (o: Object) in Reminders.truthy(o["done"]) ? 1 : 0 }
        if let (l, r) = sides(s) { return on(l) + on(r) }
        return on(s)
    }
    static func reps(_ s: Object) -> Double {
        let r = { (o: Object) in o["done"] == .bool(true) ? max(0, o["r"]?.numberValue ?? 0) : 0 }
        if let (l, rr) = sides(s) { return r(l) + r(rr) }
        return r(s)
    }
    static func worked(_ e: Object) -> Bool { rows(e).contains { doneUnits($0) > 0 } }

    struct Reader {
        let s: Object
        let catalog: ExerciseCatalog
        let volume: [String: Double]
        let workouts: [(day: String, w: Object)]
        let firstSeen: [String: String]

        init(_ s: Object, history: History) {
            self.s = s
            catalog = history.catalog
            volume = Dictionary(history.workouts.map { ($0.id, WorkoutMath.volume($0, settings: history.settings, catalog: history.catalog, weighIns: history.weighIns)) },
                                uniquingKeysWith: { a, _ in a })
            workouts = Schedule.workouts(s).compactMap { w in
                guard let d = w["d"]?.stringValue, Day.date(d) != nil else { return nil }
                return (d, w)
            }
            var first: [String: String] = [:]
            for (day, w) in workouts {
                for e in (w["entries"]?.arrayValue ?? []).compactMap(\.object) {
                    guard let id = e["id"]?.stringValue, Challenges.worked(e) else { continue }
                    let k = catalog[id]?.id ?? id
                    if first[k].map({ day < $0 }) ?? true { first[k] = day }
                }
            }
            firstSeen = first
        }

        func name(_ e: Object) -> String {
            let id = e["id"]?.stringValue ?? ""
            return (catalog[id]?.name ?? e["exercise"]?.object?["n"]?.stringValue ?? e["ex"]?.object?["n"]?.stringValue ?? e["name"]?.stringValue ?? "").lowercased()
        }

        func mainGroups(_ e: Object) -> [String] {
            guard let ex = catalog[e["id"]?.stringValue ?? ""] else { return [] }
            return catalog.muscleWeights(of: ex).filter { $0.value >= 1 }.compactMap { Challenges.groupOf[$0.key] }
        }

        func cardioMin(_ e: Object) -> Double {
            let cardio = catalog[e["id"]?.stringValue ?? ""]?.isCardio == true
            var m = 0.0
            for s in Challenges.rows(e) where Challenges.doneUnits(s) > 0 {
                if let min = s["min"]?.numberValue, min > 0 { m += min }
                else if cardio, let sec = s["sec"]?.numberValue, sec > 0 { m += sec / 60 }
            }
            return m
        }

        func facts(_ key: String) -> Facts {
            let ws = Schedule.weekStart(s)
            let list = workouts.filter { $0.day.hasPrefix(key + "-") }
            let weeks = Challenges.weeks(of: key, weekStart: ws)
            var f = Facts(workouts: list.count, weeks: weeks.count)
            var trained = Set<String>(), exDone = Set<String>(), groups = Set<String>()
            var volume = 0.0
            for (day, w) in list {
                if let k = Schedule.weekKey(day, weekStart: ws) { trained.insert(k) }
                volume += w["id"]?.stringValue.flatMap { self.volume[$0] } ?? 0
                f.prs += Set((w["prs"]?.arrayValue ?? []).compactMap(\.stringValue)).count
                for e in (w["entries"]?.arrayValue ?? []).compactMap(\.object) {
                    let n = name(e)
                    let reps = Challenges.rows(e).reduce(0) { $0 + Challenges.reps($1) }
                    if n.contains(/\b(pull|chin)[\s-]?ups?\b/) { f.pullups += reps }
                    else if n.contains(/\bpush[\s-]?ups?\b/) { f.pushups += reps }
                    f.cardioMin += cardioMin(e)
                    guard Challenges.worked(e) else { continue }
                    if let id = e["id"]?.stringValue { exDone.insert(catalog[id]?.id ?? id) }
                    mainGroups(e).forEach { groups.insert($0) }
                }
            }
            f.weeksTrained = weeks.filter { trained.contains($0) }.count
            f.volumeKg = s["unit"] == .string("lb") ? volume * Challenges.lbKg : volume
            let from = key + "-01", to = key + String(format: "-%02d", Challenges.daysIn(key))
            f.newEx = exDone.filter { k in firstSeen[k].map { $0 >= from && $0 <= to } ?? false }.count
            f.weighDays = Set((s["bodyweight"]?.arrayValue ?? []).compactMap(\.object).compactMap { b -> String? in
                guard let d = b["d"]?.stringValue, d.hasPrefix(key + "-"), (b["w"]?.numberValue ?? 0) > 0 else { return nil }
                return d
            }).count
            f.groups = groups.count
            return f
        }
    }

    // MARK: The user's level

    public struct Level: Sendable {
        var fresh = true
        var workouts = 0.0, perWeek = 0.0, weekRate = 0.0, volumeKg = 0.0, prs = 0.0
        var pullups = 0.0, pushups = 0.0, cardioMin = 0.0, weighDays = 0.0, groups = 0.0
    }

    static func level(_ r: Reader, _ key: String) -> Level {
        let firstMonth = r.workouts.map(\.day).min().map { String($0.prefix(7)) }
        let keys = (1...lookback).map { shift(key, -$0) }.filter { k in firstMonth.map { k >= $0 } ?? false }
        guard !keys.isEmpty else { return Level() }
        let facts = keys.map { r.facts($0) }
        let avg = { (f: (Facts) -> Double) in facts.reduce(0) { $0 + f($1) } / Double(keys.count) }
        var l = Level(fresh: false)
        l.workouts = avg { Double($0.workouts) }
        l.perWeek = l.workouts / weeksPerMonth
        l.weekRate = avg { $0.weeks > 0 ? Double($0.weeksTrained) / Double($0.weeks) : 0 }
        l.volumeKg = avg(\.volumeKg)
        l.prs = avg { Double($0.prs) }
        l.pullups = avg(\.pullups)
        l.pushups = avg(\.pushups)
        l.cardioMin = avg(\.cardioMin)
        l.weighDays = avg { Double($0.weighDays) }
        l.groups = avg { Double($0.groups) }
        return l
    }

    /// FACTOR more than usual, at least `bump` more, rounded up to `step`, between `min` and `max`.
    static func stretch(_ usual: Double, min lo: Double, max hi: Double, step: Double = 1, bump: Double? = nil, factor f: Double = factor) -> Double {
        let u = usual > 0 ? usual : 0
        let raw = u > 0 ? Swift.max(u * f, u + (bump ?? step)) : lo
        let n = (raw / step - 1e-9).rounded(.up) * step
        return Swift.min(hi, Swift.max(lo, n))
    }

    // MARK: The list

    public struct Pick: Equatable, Sendable {
        public let id: String
        public let n: Double
        public let u: String?
        public init(id: String, n: Double, u: String?) { (self.id, self.n, self.u) = (id, n, u) }
    }

    struct Challenge: Sendable {
        let id, kind, icon: String
        let fits: @Sendable (Level) -> Bool
        let target: @Sendable (Level, _ unit: String, _ weeks: Int) -> Pick
        let have: @Sendable (Facts, Pick) -> Double
    }

    static let all: [Challenge] = [
        Challenge(id: "workouts", kind: "habit", icon: "dumbbell.fill", fits: { _ in true },
                  target: { l, _, _ in Pick(id: "workouts", n: stretch(l.workouts, min: 4, max: 28), u: nil) }, have: { f, _ in Double(f.workouts) }),
        Challenge(id: "weeks", kind: "habit", icon: "calendar", fits: { $0.fresh || $0.weekRate < 0.99 },
                  target: { _, _, w in Pick(id: "weeks", n: Double(w), u: nil) }, have: { f, _ in Double(f.weeksTrained) }),
        Challenge(id: "volume", kind: "effort", icon: "scalemass.fill", fits: { $0.volumeKg > 0 },
                  target: { l, unit, _ in
                      if unit == "lb" {
                          let usual = l.volumeKg / lbKg
                          let step: Double = usual < 20000 ? 1000 : usual < 100000 ? 5000 : 10000
                          return Pick(id: "volume", n: stretch(usual, min: 2000, max: 5_000_000, step: step, factor: 1.1), u: "lb")
                      }
                      let step: Double = l.volumeKg < 10000 ? 500 : l.volumeKg < 50000 ? 1000 : 5000
                      return Pick(id: "volume", n: stretch(l.volumeKg, min: 1000, max: 2_000_000, step: step, factor: 1.1), u: "kg")
                  }, have: { f, p in p.u == "lb" ? f.volumeKg / lbKg : f.volumeKg }),
        Challenge(id: "prs", kind: "effort", icon: "trophy.fill", fits: { $0.prs > 0 },
                  target: { l, _, _ in Pick(id: "prs", n: stretch(l.prs, min: 2, max: 12), u: nil) }, have: { f, _ in Double(f.prs) }),
        Challenge(id: "pullups", kind: "effort", icon: "figure.strengthtraining.functional", fits: { $0.pullups > 0 },
                  target: { l, _, _ in Pick(id: "pullups", n: stretch(l.pullups, min: 20, max: 3000, step: 10), u: nil) }, have: { f, _ in f.pullups }),
        Challenge(id: "pushups", kind: "effort", icon: "figure.core.training", fits: { $0.pushups > 0 },
                  target: { l, _, _ in Pick(id: "pushups", n: stretch(l.pushups, min: 30, max: 5000, step: 10), u: nil) }, have: { f, _ in f.pushups }),
        Challenge(id: "cardio", kind: "effort", icon: "figure.run", fits: { $0.cardioMin > 0 },
                  target: { l, _, _ in Pick(id: "cardio", n: stretch(l.cardioMin, min: 30, max: 3000, step: 15), u: nil) }, have: { f, _ in f.cardioMin.rounded(.down) }),
        Challenge(id: "newex", kind: "explore", icon: "sparkles", fits: { _ in true },
                  target: { l, _, _ in Pick(id: "newex", n: l.fresh ? 3 : l.perWeek < 2 ? 2 : l.perWeek < 4 ? 3 : 4, u: nil) }, have: { f, _ in Double(f.newEx) }),
        Challenge(id: "muscles", kind: "explore", icon: "figure.strengthtraining.traditional", fits: { $0.fresh || $0.groups < Double(groups.count) - 0.01 },
                  target: { _, _, _ in Pick(id: "muscles", n: Double(groups.count), u: nil) }, have: { f, _ in Double(f.groups) }),
        Challenge(id: "weighins", kind: "explore", icon: "scalemass", fits: { $0.weighDays > 0 && $0.weighDays < 24 },
                  target: { l, _, _ in Pick(id: "weighins", n: stretch(l.weighDays, min: 4, max: 25, bump: 2), u: nil) }, have: { f, _ in Double(f.weighDays) }),
    ]
    static func challenge(_ id: String) -> Challenge? { all.first { $0.id == id } }

    /// The month's three, fresh: one per kind, turning with the month among those that fit.
    static func pick(_ r: Reader, _ key: String) -> [Pick] {
        let l = level(r, key)
        let unit = r.s["unit"] == .string("lb") ? "lb" : "kg"
        let weeks = weeks(of: key, weekStart: Schedule.weekStart(r.s)).count
        let at = monthIndex(key)
        let fitting = all.filter { $0.fits(l) }
        var picked: [Challenge] = []
        for (i, kind) in kinds.enumerated() {
            let pool = fitting.filter { $0.kind == kind }
            if !pool.isEmpty { picked.append(pool[(at + i) % pool.count]) }
        }
        var rest = fitting.filter { c in !picked.contains { $0.id == c.id } }
        var i = 0
        while picked.count < picks && !rest.isEmpty { picked.append(rest.remove(at: (at + i) % rest.count)); i += 1 }
        return picked.prefix(picks).map { $0.target(l, unit, weeks) }
    }

    // MARK: What is stored

    public struct Month: Equatable, Sendable {
        public var picked: [Pick]
        public var done: [String]
        public var at: Double
    }

    static func validId(_ s: String) -> Bool { s.wholeMatch(of: /[a-z][a-z0-9-]{0,31}/) != nil }

    static func cleanPick(_ v: JSONValue) -> Pick? {
        guard let o = v.object, let id = o["id"]?.stringValue, validId(id), let n = o["n"]?.numberValue ?? o["n"]?.stringValue.flatMap(Double.init),
              n.isFinite, n > 0, n <= 1e7 else { return nil }
        let u = o["u"]?.stringValue
        return Pick(id: id, n: n, u: u == "kg" || u == "lb" ? u : nil)
    }

    static func cleanMonth(_ v: JSONValue?) -> Month? {
        guard let o = v?.object else { return nil }
        var picked: [Pick] = []
        for p in o["picked"]?.arrayValue ?? [] {
            if let c = cleanPick(p), !picked.contains(where: { $0.id == c.id }) { picked.append(c) }
            if picked.count >= picks { break }
        }
        let ids = picked.map(\.id)
        var seen = Set<String>()
        let done = (o["done"]?.arrayValue ?? []).compactMap(\.stringValue).filter { validId($0) && seen.insert($0).inserted }
            .filter { ids.isEmpty || ids.contains($0) }.prefix(picks).sorted()
        let at = o["at"]?.numberValue ?? 0
        if picked.isEmpty && done.isEmpty { return nil }
        return Month(picked: picked, done: done, at: at.isFinite && at > 0 ? at : 0)
    }

    /// Only real months, the last 24, capped lists.
    public static func clean(_ v: JSONValue?) -> [String: Month] {
        guard let o = v?.object else { return [:] }
        var out: [String: Month] = [:]
        for k in o.keys.filter(isMonthKey).sorted().suffix(monthsKept) {
            if let m = cleanMonth(o[k]) { out[k] = m }
        }
        return out
    }

    static func json(_ all: [String: Month]) -> JSONValue? {
        guard !all.isEmpty else { return nil }
        return .object(all.mapValues { m in
            .object([
                "picked": .array(m.picked.map { p in .object(["id": .string(p.id), "n": .number(p.n)].merging(p.u.map { ["u": .string($0)] } ?? [:]) { a, _ in a }) }),
                "done": .array(m.done.map(JSONValue.string)), "at": .number(m.at),
            ])
        })
    }

    public struct Current: Equatable, Sendable {
        public let key: String
        public let picked: [Pick]
        public let done: [String]
        public let stored: Bool
        public init(key: String, picked: [Pick], done: [String], stored: Bool) { (self.key, self.picked, self.done, self.stored) = (key, picked, done, stored) }
    }

    /// The month's challenges: the stored picks, or fresh ones (not saved yet).
    public static func month(_ s: Object, history: History, key: String) -> Current {
        let m = clean(s["challenges"])[key]
        if let m, !m.picked.isEmpty { return Current(key: key, picked: m.picked, done: m.done, stored: true) }
        return Current(key: key, picked: pick(Reader(s, history: history), key), done: m?.done ?? [], stored: false)
    }

    /// Into `s` (openGym markDone): the month's picks if none are stored yet, and `ids` marked
    /// done; the stored value is cleaned on the way. True when the done list grew.
    @discardableResult
    public static func save(_ s: inout Object, key: String, picked: [Pick], done ids: [String] = [], now: Double) -> Bool {
        var all = clean(s["challenges"])
        if all[key]?.picked.isEmpty ?? true {
            all[key] = Month(picked: picked, done: all[key]?.done ?? [], at: now)
            all = clean(json(all))
        }
        guard var m = all[key] else { return false }
        let before = m.done.count
        var seen = Set<String>()
        m.done = (m.done + ids).filter { seen.insert($0).inserted }
        all[key] = m
        let cleaned = clean(json(all))
        s["challenges"] = json(cleaned) ?? .null
        return (cleaned[key]?.done.count ?? 0) > before
    }

    // MARK: Progress

    public struct Progress: Equatable, Sendable {
        public let id, icon: String
        public let n: Double
        public let u: String?
        public let have: Double
        public let pct: Double
        public let done: Bool
        public let known: Bool
    }

    public static func progress(_ s: Object, history: History, month m: Current) -> [Progress] {
        let f = Reader(s, history: history).facts(m.key)
        return m.picked.map { p in
            let c = challenge(p.id)
            let have = Swift.max(0, c.map { $0.have(f, p) } ?? 0)
            let done = have >= p.n || m.done.contains(p.id)
            return Progress(id: p.id, icon: c?.icon ?? "star.fill", n: p.n, u: p.u, have: have, pct: done ? 1 : Swift.min(1, have / p.n), done: done, known: c != nil)
        }
    }

    /// Reached now but not stored as done yet.
    public static func newlyDone(_ m: Current, _ progress: [Progress]) -> [String] {
        progress.filter { $0.known && $0.have >= $0.n && !m.done.contains($0.id) }.map(\.id)
    }

    public struct Shelf: Equatable, Sendable { public let key: String; public let done, total: Int; public let gold: Bool }

    /// Every month with a badge, newest first.
    public static func shelf(_ s: Object) -> [Shelf] {
        clean(s["challenges"]).sorted { $0.key > $1.key }.map { k, m in
            Shelf(key: k, done: m.done.count, total: m.picked.isEmpty ? picks : m.picked.count,
                  gold: !m.picked.isEmpty && m.picked.allSatisfy { m.done.contains($0.id) })
        }.filter { $0.done > 0 }
    }

    /// Off with Monthly challenges or the Motivation module turned off.
    public static func on(_ s: Object) -> Bool {
        s["monthlyChallenges"] != .bool(false) && s["modules"]?.object?["motivation"] != .bool(false)
    }

    // MARK: Words (challenge-copy.js), in English with the app translating the templates

    static func volText(_ n: Double, _ from: String?, _ unit: String, _ num: (Double) -> String) -> String {
        let v = (from ?? "kg") == unit ? n : unit == "lb" ? n / lbKg : n * lbKg
        if unit == "lb" { return (v >= 10000 ? num(jsRound(v / 100) / 10) + "k" : num(jsRound(v))) + " lb" }
        return num(jsRound(v / 100) / 10) + " t"
    }
    static func jsRound(_ v: Double) -> Double { (v + 0.5).rounded(.down) }

    /// The goal as a template and its number: ("{0} workouts this month", "14").
    public static func title(_ p: Pick, unit: String, num: (Double) -> String) -> (key: String, count: Double?, arg: String?) {
        let n = p.n
        switch p.id {
        case "workouts": return (n == 1 ? "{0} workout this month" : "{0} workouts this month", n, nil)
        case "weeks": return ("Train every week this month", nil, nil)
        case "volume": return ("Lift {0} this month", nil, volText(n, p.u, unit, num))
        case "prs": return (n == 1 ? "Hit {0} new PR" : "Hit {0} new PRs", n, nil)
        case "pullups": return (n == 1 ? "{0} pull-up this month" : "{0} pull-ups this month", n, nil)
        case "pushups": return (n == 1 ? "{0} push-up this month" : "{0} push-ups this month", n, nil)
        case "cardio": return (n == 1 ? "{0} minute of cardio" : "{0} minutes of cardio", n, nil)
        case "newex": return (n == 1 ? "Try {0} exercise you have never done" : "Try {0} exercises you have never done", n, nil)
        case "muscles": return ("Every muscle group at least once", nil, nil)
        case "weighins": return (n == 1 ? "Log your weight on {0} day" : "Log your weight on {0} days", n, nil)
        default: return ("Challenges", nil, nil)
        }
    }

    /// The goal in English, as openGym writes it.
    public static func englishTitle(_ p: Pick, unit: String, num: (Double) -> String) -> String {
        let t = title(p, unit: unit, num: num)
        return t.key.replacingOccurrences(of: "{0}", with: t.arg ?? t.count.map(num) ?? "")
    }

    /// How far: "7 / 14", or "32.4 / 50 t" for volume.
    public static func count(_ p: Progress, unit: String, num: (Double) -> String) -> String {
        if p.id == "volume" {
            let have = unit == "lb" ? (p.u == "lb" ? p.have : p.have / lbKg) : (p.u == "lb" ? p.have * lbKg : p.have)
            let goal = (p.u ?? "kg") == unit ? p.n : unit == "lb" ? p.n / lbKg : p.n * lbKg
            let shown = unit == "lb"
                ? (goal >= 10000 ? num((have / 100).rounded(.down) / 10) + "k" : num(have.rounded(.down)))
                : num((have / 100).rounded(.down) / 10)
            return "\(shown) / \(volText(p.n, p.u, unit, num))"
        }
        return "\(num(Swift.min(p.have.rounded(.down), 99999))) / \(num(p.n))"
    }

    /// openGym fmtNum: one decimal at most, grouped, in `locale`.
    public static func number(_ locale: Locale) -> (Double) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return { v in f.string(from: NSNumber(value: jsRound(v * 10) / 10 + 0)) ?? "\(v)" }
    }
}
