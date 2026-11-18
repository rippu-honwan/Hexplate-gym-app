import Foundation

/// "Your year": one calendar year looked back on, card by card (openGym lib/wrapped.js). This is
/// the engine: what the year holds, which years there are, when the season is on (Dec 1 to Jan 31)
/// and whether Home shows its card. It stores nothing but `wrapped = {opened, dismissed, phone}`.
public enum Wrapped {
    public typealias Object = [String: JSONValue]

    static let minSessionMs = 60000.0, lbKg = 0.45359237
    public static let notifyHour = 18
    public static let dayparts = ["morning", "midday", "afternoon", "evening", "night"]
    static let legs = ["quadriceps", "hamstring", "gluteal", "calves", "adductors"]
    static let upper = ["chest", "deltoids", "biceps", "triceps", "trapezius", "upper-back", "forearm"]

    static func day(_ w: Object) -> String? { w["d"]?.stringValue.flatMap { Day.date($0) != nil ? $0 : nil } }

    /// The workouts of one local calendar year, oldest first.
    static func workouts(_ s: Object, year: Int) -> [Object] {
        let y = String(year)
        return Schedule.workouts(s).enumerated().filter { day($0.element)?.hasPrefix(y + "-") == true }.sorted { a, b in
            let da = day(a.element)!, db = day(b.element)!
            if da != db { return da < db }
            let sa = a.element["start"]?.numberValue ?? 0, sb = b.element["start"]?.numberValue ?? 0
            return sa != sb ? sa < sb : a.offset < b.offset
        }.map(\.element)
    }

    /// Every year with a workout, newest first.
    public static func years(_ s: Object) -> [Int] {
        Set(Schedule.workouts(s).compactMap { day($0).flatMap { Int($0.prefix(4)) } }).filter { $0 >= 1970 && $0 <= 9999 }.sorted(by: >)
    }

    /// The year the season is about (Dec 2026 and Jan 2027 are both 2026), nil out of season.
    public static func seasonYear(_ now: Date) -> Int? {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: now)
        if c.month == 12 { return c.year }
        if c.month == 1 { return c.year! - 1 }
        return nil
    }

    public static func yearList(_ v: JSONValue?) -> [Int] {
        (v?.arrayValue ?? []).compactMap { $0.numberValue.flatMap { $0 == $0.rounded() ? Int($0) : nil } }
    }

    /// `wrapped` with `year` added to `opened` or `dismissed`, the last five years kept.
    public static func adding(_ s: Object, _ list: String, year: Int) -> JSONValue {
        let w = s["wrapped"]?.object ?? [:]
        var out: Object = ["opened": .array(yearList(w["opened"]).map { .number(Double($0)) }),
                           "dismissed": .array(yearList(w["dismissed"]).map { .number(Double($0)) }),
                           "phone": w["phone"]?.numberValue.map { .number($0) } ?? .null]
        out[list] = .array(Array(Set(yearList(w[list]) + [year])).sorted().suffix(5).map { .number(Double($0)) })
        return .object(out)
    }

    /// The year Home's card is about: in season, with workouts that year, not opened or dismissed yet.
    public static func homeCardYear(_ s: Object, now: Date) -> Int? {
        guard let y = seasonYear(now) else { return nil }
        let w = s["wrapped"]?.object ?? [:]
        if yearList(w["opened"]).contains(y) || yearList(w["dismissed"]).contains(y) { return nil }
        return workouts(s, year: y).isEmpty ? nil : y
    }

    public static func notifyOn(_ s: Object) -> Bool {
        s["wrappedNotify"] != .bool(false) && s["modules"]?.object?["motivation"] != .bool(false)
    }

    /// When to plan the season's one notification: Dec 1 18:00 local, from November on, with
    /// workouts this year. nil: nothing to plan.
    public static func notifyAt(_ s: Object, now: Date) -> Date? {
        guard notifyOn(s) else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: now)
        guard let at = cal.date(from: DateComponents(year: year, month: 12, day: 1, hour: notifyHour)),
              now < at, cal.component(.month, from: now) >= 11, !workouts(s, year: year).isEmpty else { return nil }
        return at
    }

    public static func daypart(_ hour: Int) -> String {
        switch hour {
        case 5..<11: return "morning"
        case 11..<14: return "midday"
        case 14..<17: return "afternoon"
        case 17..<21: return "evening"
        default: return "night"
        }
    }

    // MARK: The year in numbers

    public struct Stats: Equatable, Sendable {
        public struct Streak: Equatable, Sendable { public var weeks = 0; public var from: String?; public var to: String? }
        public struct Top: Equatable, Sendable { public let id: String; public let sets: Int; public let name: String? }
        public struct Muscle: Equatable, Sendable { public let id: String; public let share: Double }
        public struct Record: Equatable, Sendable { public let id: String; public let w: Double; public let d: String; public let gain: Double?; public let prev: Double? }
        public struct Body: Equatable, Sendable { public let from, to, delta: Double; public let n: Int; public let fromDay, toDay: String }
        public struct Shares: Equatable, Sendable { public let legs, upper, cardio, early, late, weekend: Double }

        public let year: Int
        public let unit: String
        public let workouts, days: Int
        public let perWeek: Double
        public let ms: Double
        public let timed: Int
        public let avgMs, volume, volumeKg: Double
        public let sets: Int
        public let streak: Streak
        public let topExercise: Top?
        public let topMuscle: Muscle?
        public let load: [String: Double]
        public let distinctExercises, prs: Int
        public let biggestPr: Record?
        public let favDay: (day: Int, n: Int)?
        public let daypart: (part: String, n: Int)?
        public let bestMonth: (month: Int, n: Int, vol: Double)?
        public let months: [Int]
        public let body: Body?
        public let shares: Shares
        public let first: String

        public static func == (a: Stats, b: Stats) -> Bool {
            a.year == b.year && a.workouts == b.workouts && a.volume == b.volume && a.streak == b.streak && a.topExercise == b.topExercise
        }
    }

    static func workSets(_ e: Object) -> [Object] {
        Challenges.rows(e).filter { Challenges.doneUnits($0) > 0 }
    }
    static func weight(_ s: Object) -> Double { s["w"]?.numberValue ?? 0 }

    /// The longest run of weeks in a row with a workout inside the year (week keys).
    static func longestStreak(_ ws: [Object], weekStart: Int) -> Stats.Streak {
        let keys = Set(ws.compactMap { day($0).flatMap { Schedule.weekKey($0, weekStart: weekStart) } }).sorted()
        var best = Stats.Streak(), run = 0
        var from: String?, prev: String?
        for k in keys {
            if let p = prev, Day.adding(7, to: p) == k { run += 1 } else { run = 1; from = k }
            if run > best.weeks { best = Stats.Streak(weeks: run, from: from, to: k) }
            prev = k
        }
        return best
    }

    /// The biggest new best of the year: the lift that grew most past its old best, else the
    /// heaviest record. Assisted lifts are never picked (less help is better).
    static func biggestPr(_ s: Object, year: Int, _ ws: [Object], _ c: ExerciseCatalog) -> Stats.Record? {
        var order: [String] = [], recorded: [String: (w: Double, d: String)] = [:]
        for w in ws {
            for id in (w["prs"]?.arrayValue ?? []).compactMap(\.stringValue) where c[id]?.isAssisted != true {
                let top = max(0, (w["entries"]?.arrayValue ?? []).compactMap(\.object).filter { $0["id"]?.stringValue == id }
                    .flatMap { workSets($0).map(weight) }.max() ?? 0)
                if top > 0 && top >= (recorded[id]?.w ?? 0) {
                    if recorded[id] == nil { order.append(id) }
                    recorded[id] = (top, day(w) ?? "")
                }
            }
        }
        guard !recorded.isEmpty else { return nil }
        let start = "\(year)-01-01"
        var before: [String: Double] = [:]
        for w in Schedule.workouts(s) {
            guard let d = day(w), d < start else { continue }
            for e in (w["entries"]?.arrayValue ?? []).compactMap(\.object) {
                guard let id = e["id"]?.stringValue, recorded[id] != nil else { continue }
                let top = max(0, workSets(e).map(weight).max() ?? 0)
                if top > (before[id] ?? 0) { before[id] = top }
            }
        }
        var pick: Stats.Record?
        for id in order {
            let r = recorded[id]!, prev = before[id] ?? 0
            let cand = Stats.Record(id: id, w: r.w, d: r.d, gain: prev > 0 ? r.w - prev : nil, prev: prev > 0 ? prev : nil)
            guard let p = pick else { pick = cand; continue }
            let a = (cand.gain ?? 0) > 0, b = (p.gain ?? 0) > 0
            if a != b { if a { pick = cand }; continue }
            let ka = a ? cand.gain! : cand.w, kb = b ? p.gain! : p.w
            if ka > kb || (ka == kb && (cand.w > p.w || (cand.w == p.w && id < p.id))) { pick = cand }
        }
        return pick
    }

    /// First and last weigh-in of the year; nil with fewer than two or the card switched off.
    static func bodyChange(_ s: Object, year: Int) -> Stats.Body? {
        if s["wrappedBody"] == .bool(false) { return nil }
        let list = (s["bodyweight"]?.arrayValue ?? []).compactMap(\.object).enumerated().filter { _, b in
            guard let d = b["d"]?.stringValue, d.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil, d.hasPrefix("\(year)-") else { return false }
            return (b["w"]?.numberValue ?? 0) > 0
        }.sorted { a, b in
            let da = a.element["d"]!.stringValue!, db = b.element["d"]!.stringValue!
            if da != db { return da < db }
            let ta = a.element["t"]?.numberValue ?? 0, tb = b.element["t"]?.numberValue ?? 0
            return ta != tb ? ta < tb : a.offset < b.offset
        }.map(\.element)
        guard list.count >= 2, let f = list.first, let l = list.last else { return nil }
        let from = f["w"]!.numberValue!, to = l["w"]!.numberValue!
        return Stats.Body(from: from, to: to, delta: to - from, n: list.count, fromDay: f["d"]!.stringValue!, toDay: l["d"]!.stringValue!)
    }

    /// Everything the cards say about `year`, nil without a workout. Ties settle the same way every time.
    public static func stats(_ s: Object, history: History, year: Int, now: Date) -> Stats? {
        let ws = workouts(s, year: year)
        guard !ws.isEmpty else { return nil }
        let c = history.catalog
        let unit = s["unit"] == .string("lb") ? "lb" : "kg"
        let wkStart = Schedule.weekStart(s)
        let volumeOf = Dictionary(history.workouts.map { ($0.id, WorkoutMath.volume($0, settings: history.settings, catalog: c, weighIns: history.weighIns)) },
                                  uniquingKeysWith: { a, _ in a })
        let cal = Calendar(identifier: .gregorian)

        var ms = 0.0, timed = 0, volume = 0.0, sets = 0, prs = 0
        var days = Set<String>()
        var exOrder: [String] = [], perEx: [String: (sets: Int, vol: Double, name: String?)] = [:]
        var byWeekday = [Int](repeating: 0, count: 7)
        var byPart: [String: Int] = Dictionary(uniqueKeysWithValues: dayparts.map { ($0, 0) })
        var months = [(n: Int, vol: Double)](repeating: (0, 0), count: 12)
        var cardioSets = 0, early = 0, late = 0, weekend = 0
        var load: [String: Double] = [:]

        for w in ws {
            let d = day(w)!
            days.insert(d)
            let date = Day.date(d)!
            let wd = cal.component(.weekday, from: date) - 1, mo = cal.component(.month, from: date) - 1
            byWeekday[wd] += 1
            if wd == 0 || wd == 6 { weekend += 1 }
            let vol = w["id"]?.stringValue.flatMap { volumeOf[$0] } ?? 0
            volume += vol
            months[mo].n += 1
            months[mo].vol += vol
            if let start = w["start"]?.numberValue, let end = w["end"]?.numberValue, start.isFinite, end - start >= minSessionMs {
                ms += end - start
                timed += 1
                let h = cal.component(.hour, from: Date(timeIntervalSince1970: start / 1000))
                byPart[daypart(h), default: 0] += 1
                if h >= 4 && h < 9 { early += 1 }
                if h >= 20 || h < 4 { late += 1 }
            }
            prs += Set((w["prs"]?.arrayValue ?? []).compactMap(\.stringValue)).count
            for e in (w["entries"]?.arrayValue ?? []).compactMap(\.object) {
                // Muscle load: ticked work sets, by each exercise's muscle weights (muscles.js loadOfWorkouts).
                let ticked = Double((e["sets"]?.arrayValue ?? []).compactMap(\.object).filter { $0["done"] == .bool(true) && !Recovery.isWarmupRow($0) }.count)
                if ticked > 0, let ex = e["id"]?.stringValue.flatMap({ c[$0] }) {
                    for (m, share) in c.muscleWeights(of: ex) { load[m, default: 0] += share * ticked }
                }
                guard let id = e["id"]?.stringValue else { continue }
                let done = workSets(e)
                let n = done.reduce(0) { $0 + Challenges.doneUnits($1) }
                guard n > 0 else { continue }
                sets += n
                if c[id]?.isCardio == true { cardioSets += n }
                if perEx[id] == nil { exOrder.append(id); perEx[id] = (0, 0, nil) }
                perEx[id]!.sets += n
                perEx[id]!.vol += done.reduce(0) { $0 + weight($1) * ($1["r"]?.numberValue ?? 0) }
                if perEx[id]!.name == nil { perEx[id]!.name = e["exercise"]?.object?["n"]?.stringValue ?? e["ex"]?.object?["n"]?.stringValue }
            }
        }

        var top: (id: String, sets: Int, vol: Double, name: String?)?
        for id in exOrder {
            let v = perEx[id]!
            if let t = top, !(v.sets > t.sets || (v.sets == t.sets && (v.vol > t.vol || (v.vol == t.vol && id < t.id)))) { continue }
            top = (id, v.sets, v.vol, v.name)
        }
        var topMuscle: String?, total = 0.0
        for m in c.meta.muscles {
            let v = load[m] ?? 0
            total += v
            if v > 0 && (topMuscle == nil || v > load[topMuscle!]!) { topMuscle = m }
        }
        let share = { (list: [String]) in total > 0 ? list.reduce(0) { $0 + (load[$1] ?? 0) } / total : 0 }

        var favDay: Int?
        for d in (0..<7).map({ (wkStart + $0) % 7 }) where byWeekday[d] > 0 && (favDay == nil || byWeekday[d] > byWeekday[favDay!]) { favDay = d }
        var part: String?
        for p in dayparts where byPart[p]! > 0 && (part == nil || byPart[p]! > byPart[part!]!) { part = p }
        var best: Int?
        for (i, m) in months.enumerated() where m.n > 0 {
            if let b = best, !(m.n > months[b].n || (m.n == months[b].n && m.vol > months[b].vol)) { continue }
            best = i
        }

        // Weeks so far: from the first workout's week to the year's end, or to now / the last workout for the year in progress.
        let first = Day.date(day(ws[0])!)!
        let yearEnd = cal.date(from: DateComponents(year: year, month: 12, day: 31, hour: 12))!
        let lastWorkout = Day.date(day(ws.last!)!)!
        let lastDay = min(yearEnd, max(now, lastWorkout))
        let weeks = max(1, Int(((lastDay.timeIntervalSince(first)) / (7 * 86400)).rounded(.toNearestOrAwayFromZero)) + 1)

        return Stats(
            year: year, unit: unit, workouts: ws.count, days: days.count, perWeek: Double(ws.count) / Double(weeks),
            ms: ms, timed: timed, avgMs: timed > 0 ? ms / Double(timed) : 0,
            volume: volume, volumeKg: unit == "lb" ? volume * lbKg : volume, sets: sets,
            streak: longestStreak(ws, weekStart: wkStart),
            topExercise: top.map { Stats.Top(id: $0.id, sets: $0.sets, name: $0.name) },
            topMuscle: topMuscle.map { Stats.Muscle(id: $0, share: load[$0]! / total) }, load: load,
            distinctExercises: perEx.count, prs: prs, biggestPr: biggestPr(s, year: year, ws, c),
            favDay: favDay.map { ($0, byWeekday[$0]) }, daypart: part.map { ($0, byPart[$0]!) },
            bestMonth: best.map { ($0, months[$0].n, months[$0].vol) }, months: months.map(\.n),
            body: bodyChange(s, year: year),
            shares: Stats.Shares(legs: share(legs), upper: share(upper), cardio: sets > 0 ? Double(cardioSets) / Double(sets) : 0,
                                 early: timed > 0 ? Double(early) / Double(timed) : 0, late: timed > 0 ? Double(late) / Double(timed) : 0,
                                 weekend: Double(weekend) / Double(ws.count)),
            first: day(ws[0])!)
    }

    /// The cards the year makes, in order (wrapped-cards.js wrappedCards): one with nothing to say is left out.
    public static func cards(_ st: Stats?) -> [String] {
        guard let st else { return [] }
        var out = ["intro", "workouts"]
        if st.ms >= 3_600_000 || (st.ms > 0 && st.timed > 0) { out.append("time") }
        if st.volume > 0 { out.append("volume") }
        if st.streak.weeks > 0 { out.append("streak") }
        if st.topExercise != nil { out.append("top") }
        if st.prs > 0 { out.append("records") }
        if st.favDay != nil { out.append("rhythm") }
        if st.bestMonth != nil && st.workouts >= 3 { out.append("month") }
        if st.body != nil { out.append("body") }
        return out + ["personality", "summary"]
    }

    // MARK: Fun with numbers

    public static let things: [(key: String, kg: Double)] = [
        ("eiffel", 7_300_000), ("iss", 420_000), ("whale", 150_000), ("trex", 8000), ("elephant", 6000),
        ("car", 1500), ("piano", 480), ("panda", 100), ("cat", 4.5),
    ]

    /// The biggest thing `kg` comes to two of, else one of, else cats; one decimal under 10.
    public static func comparison(_ kg: Double) -> (key: String, count: Double)? {
        guard kg > 0 else { return nil }
        let pick = things.first { kg / $0.kg >= 2 } ?? things.first { kg / $0.kg >= 1 } ?? things.last!
        let raw = kg / pick.kg
        return (pick.key, raw < 10 ? ((raw * 10) + 0.5).rounded(.down) / 10 : (raw + 0.5).rounded(.down))
    }

    public static let personalities = ["early", "night", "legs", "streak", "records", "weekend", "cardio", "marathon", "quick", "explorer", "upper", "steady"]

    /// The first pattern that fits; every one is a compliment.
    public static func personality(_ st: Stats?) -> String {
        guard let st else { return "steady" }
        let enough = st.timed >= 5
        if enough && st.shares.early >= 0.4 { return "early" }
        if enough && st.shares.late >= 0.4 { return "night" }
        if st.shares.legs >= 0.35, let m = st.topMuscle?.id, legs.contains(m) { return "legs" }
        if st.streak.weeks >= 12 { return "streak" }
        if st.prs >= 20 { return "records" }
        if st.workouts >= 5 && st.shares.weekend >= 0.5 { return "weekend" }
        if st.shares.cardio >= 0.4 { return "cardio" }
        if enough && st.avgMs >= 75 * 60000 { return "marathon" }
        if enough && st.avgMs > 0 && st.avgMs <= 35 * 60000 { return "quick" }
        if st.distinctExercises >= 40 { return "explorer" }
        if st.shares.upper >= 0.6 { return "upper" }
        return "steady"
    }
}
