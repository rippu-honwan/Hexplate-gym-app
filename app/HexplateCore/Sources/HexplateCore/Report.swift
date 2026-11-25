import Foundation

/// The performance report: everything a stretch of training adds up to, as plain data
/// (openGym lib/report.js reportData). The app draws it as a PDF; this file only counts.
public enum Report {
    public typealias Object = [String: JSONValue]

    public struct Range: Equatable, Sendable { public let from, to: String; public let days: Int }

    public struct Totals: Equatable, Sendable {
        public var workouts = 0, sets = 0, prs = 0, days = 0
        public var volume = 0.0, ms = 0.0
        public var bwStart: Double?, bwEnd: Double?, bwChange: Double?
    }

    public struct Bucket: Equatable, Sendable { public let key, from: String; public var volume = 0.0; public var sets = 0, workouts = 0 }
    public struct CalendarDay: Equatable, Sendable { public let d: String; public let n: Int; public let volume: Double; public let level: Int }
    public struct Lift: Equatable, Sendable { public let id: String; public let points: [Stats.Point]; public let best: Stats.Point?; public let change: Double? }
    public struct Record: Equatable, Sendable { public let id, d, workout: String; public let entry: Object?; public let best: Stats.Point? }
    public struct Streak: Equatable, Sendable { public let weeks: Int?; public let longestWeeks, longestDays, activeDays, restDays: Int }

    public struct Data: Sendable {
        public let range: Range
        public let workouts: [Object]
        public let totals, prev: Totals
        public let perWeek: Double
        public let bucketUnit: String
        public let buckets: [Bucket]
        public let calendar: [CalendarDay]
        public let worked: [(slug: String, sets: Double)]
        public let missed: [String]
        public let lifts: [Lift]
        public let prs: [Record]
        public let bodyweight: [(d: String, w: Double)]
        public let streak: Streak
        public let weekStart: Int
    }

    static func valid(_ s: String?) -> String? { s.flatMap { Day.date($0).map(Day.iso) == $0 ? $0 : nil } }
    static func add(_ n: Int, _ iso: String) -> String { Day.adding(n, to: iso) ?? iso }
    static func between(_ a: String, _ b: String) -> Int {
        guard let x = Day.date(a), let y = Day.date(b) else { return 0 }
        return Int((y.timeIntervalSince(x) / 86400).rounded())
    }

    /// The days a report covers, both ends included (reportRange): '7d', '4w', '3m' back to the same
    /// date three months ago (the day after it), or 'custom' with swapped ends put right and a
    /// future end cut to today.
    public static func range(_ kind: String, from: String? = nil, to: String? = nil, today: String) -> Range {
        var start: String, end = today
        switch kind {
        case "7d": start = add(-6, today)
        case "4w": start = add(-27, today)
        case "3m":
            let cal = Calendar(identifier: .gregorian)
            let d = Day.date(today)!
            let day = cal.component(.day, from: d)
            var c = cal.dateComponents([.year, .month], from: d)
            c.month! -= 3; c.day = 1; c.hour = 12
            let first = cal.date(from: c)!
            let last = cal.range(of: .day, in: .month, for: first)!.count
            c.day = min(day, last)
            start = add(1, Day.iso(cal.date(from: c)!))
        default:
            start = valid(from) ?? add(-27, today)
            end = valid(to) ?? today
            if start > end { (start, end) = (end, start) }
            if end > today { end = today }
            if start > end { start = end }
        }
        return Range(from: start, to: end, days: between(start, end) + 1)
    }

    static func day(_ w: Object) -> String? { valid(w["d"]?.stringValue) }
    static func at(_ w: Object) -> Double { w["start"]?.numberValue ?? (day(w).map(Day.noon) ?? .nan) }

    /// Ticked work sets: warm-ups left out, a per-side set counted once per side.
    static func workSets(_ w: Object) -> Int {
        (w["entries"]?.arrayValue ?? []).compactMap(\.object).reduce(0) { n, e in
            n + (e["sets"]?.arrayValue ?? []).compactMap(\.object).reduce(0) { $0 + (Recovery.isWarmupRow($1) ? 0 : Challenges.doneUnits($1)) }
        }
    }

    /// The workouts of the range, by time (stable, like Array.sort).
    public static func inRange(_ s: Object, _ r: Range) -> [Object] {
        (s["workouts"]?.arrayValue ?? []).compactMap(\.object)
            .filter { day($0).map { $0 >= r.from && $0 <= r.to } ?? false }
            .enumerated().sorted { a, b in
                let (x, y) = (at(a.element), at(b.element))
                return x != y && !(x.isNaN || y.isNaN) ? x < y : a.offset < b.offset
            }.map(\.element)
    }

    static func weighIns(_ s: Object, _ r: Range) -> [WeighIn] {
        let all: [WeighIn] = (s["bodyweight"]?.arrayValue ?? []).compactMap { try? $0.decoded(as: WeighIn.self) }
        let kept = all.filter { (b: WeighIn) -> Bool in valid(b.date) != nil && b.date >= r.from && b.date <= r.to && b.weight > 0 }
        return kept.enumerated().sorted { (a, b) -> Bool in
            a.element.time != b.element.time ? a.element.time < b.element.time : a.offset < b.offset
        }.map(\.element)
    }

    /// Effective sets per muscle: ticked work sets by each exercise's muscle weights (muscles.js loadOfWorkouts).
    static func muscleLoad(_ ws: [Object], _ c: ExerciseCatalog) -> [String: Double] {
        var load: [String: Double] = [:]
        for w in ws {
            for e in (w["entries"]?.arrayValue ?? []).compactMap(\.object) {
                let ticked = Double((e["sets"]?.arrayValue ?? []).compactMap(\.object).filter { $0["done"] == .bool(true) && !Recovery.isWarmupRow($0) }.count)
                if ticked > 0, let ex = e["id"]?.stringValue.flatMap({ c[$0] }) {
                    for (m, share) in c.muscleWeights(of: ex) { load[m, default: 0] += share * ticked }
                }
            }
        }
        return load
    }

    /// How a JavaScript object orders its keys: integer-like ones ascending, then the rest as added.
    static func jsKeyOrder(_ keys: [String]) -> [String] {
        let int = { (k: String) in UInt32(k).map { String($0) == k } ?? false }
        return keys.filter(int).sorted { UInt32($0)! < UInt32($1)! } + keys.filter { !int($0) }
    }

    /// Decodes a workout object and computes its session volume using the same rules as History.
    static func volume(_ w: Object, settings: ProfileSettings, catalog: ExerciseCatalog, weighIns: [WeighIn]) -> Double {
        (try? JSONValue.object(w).decoded(as: Workout.self)).map {
            WorkoutMath.volume($0, settings: settings, catalog: catalog, weighIns: weighIns)
        } ?? 0
    }

    public static func data(_ s: Object, catalog c: ExerciseCatalog, kind: String, from: String? = nil, to: String? = nil, today: String) -> Data {
        let r = range(kind, from: from, to: to, today: today)
        let ws = Schedule.weekStart(s)
        let settings = ProfileSettings(s)
        let allWeighIns = (s["bodyweight"]?.arrayValue ?? []).compactMap { try? $0.decoded(as: WeighIn.self) }
        let volume = { (w: Object) -> Double in
            Self.volume(w, settings: settings, catalog: c, weighIns: allWeighIns)
        }
        let duration = { (w: Object) -> Double in (try? JSONValue.object(w).decoded(as: Workout.self)).map(WorkoutMath.duration) ?? 0 }

        func totals(_ list: [Object], _ bw: [WeighIn]) -> Totals {
            var t = Totals()
            t.workouts = list.count
            for w in list {
                t.volume += volume(w); t.sets += workSets(w); t.ms += duration(w)
                t.prs += Set((w["prs"]?.arrayValue ?? []).compactMap(\.stringValue)).count
            }
            t.days = Set(list.compactMap(day)).count
            t.volume = Stats.round1(t.volume)
            t.bwStart = bw.first?.weight; t.bwEnd = bw.last?.weight
            if bw.count > 1 { t.bwChange = Stats.round1(bw.last!.weight - bw.first!.weight) }
            return t
        }

        let workouts = inRange(s, r)
        let bw = weighIns(s, r)
        let before = Range(from: add(-r.days, r.from), to: add(-1, r.from), days: r.days)
        let t = totals(workouts, bw)

        // Buckets: per day up to two weeks, per week up to about four months, else per month.
        let unit = r.days <= 14 ? "day" : r.days <= 124 ? "week" : "month"
        let key = { (d: String) in unit == "day" ? d : unit == "week" ? Schedule.weekKey(d, weekStart: ws) ?? d : String(d.prefix(7)) + "-01" }
        var buckets: [Bucket] = [], index: [String: Int] = [:]
        var d = r.from
        while d <= r.to {
            let k = key(d)
            if index[k] == nil { index[k] = buckets.count; buckets.append(Bucket(key: k, from: d)) }
            d = add(1, d)
        }
        for w in workouts {
            guard let wd = day(w), let i = index[key(wd)] else { continue }
            buckets[i].volume += volume(w); buckets[i].sets += workSets(w); buckets[i].workouts += 1
        }
        for i in buckets.indices { buckets[i].volume = Stats.round1(buckets[i].volume) }

        // Consistency calendar: every day, shaded 0–4 by volume quartiles.
        var agg: [String: (n: Int, volume: Double)] = [:]
        for w in workouts { let wd = day(w)!; agg[wd, default: (0, 0)].n += 1; agg[wd]!.volume += volume(w) }
        let values = agg.values.map(\.volume).filter { $0 > 0 }.sorted()
        let q = { (p: Double) in values.isEmpty ? 0 : values[min(values.count - 1, Int((p * Double(values.count)).rounded(.down)))] }
        let (t1, t2, t3) = (q(0.25), q(0.5), q(0.75))
        var calendar: [CalendarDay] = []
        d = r.from
        while d <= r.to {
            let a = agg[d]
            let level = a == nil ? 0 : a!.volume == 0 ? 1 : a!.volume >= t3 ? 4 : a!.volume >= t2 ? 3 : a!.volume >= t1 ? 2 : 1
            calendar.append(CalendarDay(d: d, n: a?.n ?? 0, volume: Stats.round1(a?.volume ?? 0), level: level))
            d = add(1, d)
        }

        // Muscles: worked by effective sets (most first), and the ones never reached.
        let load = muscleLoad(workouts, c)
        let muscles = c.meta.muscles
        let worked = muscles.enumerated().filter { (load[$0.element] ?? 0) > 0 }
            .sorted { a, b in load[a.element]! != load[b.element]! ? load[a.element]! > load[b.element]! : a.offset < b.offset }
            .map { (slug: $0.element, sets: Stats.round1(load[$0.element]!)) }
        let missed = muscles.filter { !((load[$0] ?? 0) > 0) }

        // Lifts: the most-trained exercises with an estimated 1RM, at most four.
        let formula = Stats.formula(s)
        var seen: [String: (sessions: Set<String>, top: Double)] = [:], order: [String] = []
        for w in workouts {
            for e in (w["entries"]?.arrayValue ?? []).compactMap(\.object) {
                guard let id = e["id"]?.stringValue, c[id]?.isAssisted != true,
                      let best = Stats.bestSet(e, formula: formula, catalog: c) else { continue }
                if seen[id] == nil { seen[id] = ([], 0); order.append(id) }
                seen[id]!.sessions.insert(w["id"]?.stringValue ?? "\(at(w))")
                seen[id]!.top = max(seen[id]!.top, best.estimate)
            }
        }
        let lifts = jsKeyOrder(order).enumerated()
            .sorted { a, b in
                let (x, y) = (seen[a.element]!, seen[b.element]!)
                return x.sessions.count != y.sessions.count ? x.sessions.count > y.sessions.count : x.top != y.top ? x.top > y.top : a.offset < b.offset
            }
            .prefix(4).map { id -> Lift in
                let pts = Stats.oneRepMaxSeries(s, id.element, catalog: c).filter { $0.day >= r.from && $0.day <= r.to }
                let best = pts.reduce(nil as Stats.Point?) { b, p in b == nil || p.estimate > b!.estimate ? p : b }
                return Lift(id: id.element, points: pts, best: best, change: pts.count > 1 ? Stats.round1(pts.last!.estimate - pts.first!.estimate) : nil)
            }

        // New bests, newest day first (stable within a day).
        var prs: [Record] = []
        for w in workouts {
            var ids: [String] = []
            for id in (w["prs"]?.arrayValue ?? []).compactMap(\.stringValue) where !ids.contains(id) { ids.append(id) }
            for id in ids {
                let entry = (w["entries"]?.arrayValue ?? []).compactMap(\.object).first { $0["id"]?.stringValue == id }
                prs.append(Record(id: id, d: day(w) ?? "", workout: w["name"]?.stringValue ?? "", entry: entry,
                                  best: entry.flatMap { Stats.bestSet($0, formula: formula, catalog: c) }))
            }
        }
        prs = prs.enumerated().sorted { a, b in a.element.d != b.element.d ? a.element.d > b.element.d : a.offset < b.offset }.map(\.element)

        // Runs of weeks and of days in a row with a workout.
        func run(_ keys: [String], step: Int) -> Int {
            var best = 0, n = 0, prev: String?
            for k in keys { n = prev.map { between($0, k) == step } == true ? n + 1 : 1; best = max(best, n); prev = k }
            return best
        }
        let weekKeys = Set(workouts.compactMap { day($0).flatMap { Schedule.weekKey($0, weekStart: ws) } }).sorted()
        let dayKeys = Set(workouts.compactMap(day)).sorted()

        return Data(
            range: r, workouts: workouts, totals: t, prev: totals(inRange(s, before), weighIns(s, before)),
            perWeek: Stats.jsRound(Double(workouts.count) / (Double(r.days) / 7) * 10) / 10,
            bucketUnit: unit, buckets: buckets, calendar: calendar, worked: worked, missed: missed,
            lifts: Array(lifts), prs: prs, bodyweight: bw.map { ($0.date, $0.weight) },
            streak: Streak(weeks: r.to == today ? WidgetData.streak(s, today: today).current : nil,
                           longestWeeks: run(weekKeys, step: 7), longestDays: run(dayKeys, step: 1),
                           activeDays: t.days, restDays: r.days - t.days),
            weekStart: ws)
    }
}
