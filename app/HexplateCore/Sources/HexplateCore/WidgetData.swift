import Foundation

/// What the Home Screen and Lock Screen widgets show (widgets.js buildWidgetSnapshot): a small
/// JSON the app writes to the App Group and the widget extension reads.
// ponytail: no monthly challenges (the native app has none yet); the widget skips a null block.
public enum WidgetData {
    public typealias Object = [String: JSONValue]
    public static let version = 2, days = 8, exercisesMax = 8, trendPoints = 7

    // MARK: Streak (streak.js streakInfo)

    public static let freezeEvery = 4, freezeMax = 2
    public static let badges = [4, 12, 26, 52, 104]

    public struct Streak: Equatable {
        public let current, best, freezes: Int
        public let thisWeekDone: Bool
        public let next: Int?
        /// The weeks (their first day) a freeze covered in the running streak.
        public var frozen: [String] = []
        /// Trained weeks still needed for the next freeze, 0 with the bank full.
        public var toNextFreeze = WidgetData.freezeEvery
        public var weekKey = ""
        /// The milestones the best run has reached.
        public var badges: [Int] { WidgetData.badges.filter { best >= $0 } }
    }

    /// Weeks in a row with a workout; every fourth week earns a freeze (at most two) that covers a missed one.
    public static func streak(_ s: Object, today: String) -> Streak {
        let ws = Schedule.weekStart(s)
        guard let cur = Schedule.weekKey(today, weekStart: ws) else { return Streak(current: 0, best: 0, freezes: 0, thisWeekDone: false, next: badges[0]) }
        var trained = Set<String>()
        for w in (s["workouts"]?.arrayValue ?? []).compactMap(\.object) {
            guard let d = w["d"]?.stringValue, Programmes.isISO(.string(d)), let k = Schedule.weekKey(d, weekStart: ws), k <= cur else { continue }
            trained.insert(k)
        }
        guard var wk = trained.min() else { return Streak(current: 0, best: 0, freezes: 0, thisWeekDone: false, next: badges[0], weekKey: cur) }
        let floor = Day.adding(-7 * 1500, to: cur) ?? wk
        if wk < floor { wk = floor }
        var run = 0, best = 0, freezes = 0, earned = 0
        var frozen: [String] = []
        while wk <= cur {
            if trained.contains(wk) {
                run += 1; earned += 1
                if earned % freezeEvery == 0 && freezes < freezeMax { freezes += 1 }
            } else if wk != cur {
                if freezes > 0 { freezes -= 1; frozen.append(wk) } else { run = 0; earned = 0; freezes = 0; frozen = [] }
            }
            best = max(best, run)
            guard let next = Day.adding(7, to: wk) else { break }
            wk = next
        }
        return Streak(current: run, best: best, freezes: freezes, thisWeekDone: trained.contains(cur), next: badges.first { best < $0 },
                      frozen: frozen, toNextFreeze: freezes >= freezeMax ? 0 : freezeEvery - earned % freezeEvery, weekKey: cur)
    }

    public struct Celebration: Equatable, Sendable {
        public let kind: String   // "badge" or "week"
        public let weeks: Int
        /// What `streakSeen` becomes once it was shown.
        public let seen: JSONValue
    }

    /// What Home celebrates now, once: a milestone reached since the last one shown, or this week
    /// done (its plan all trained, or without a plan its first workout) (streak.js streakCelebration).
    public static func celebration(_ s: Object, _ info: Streak, done: Int, planned: Int) -> Celebration? {
        let seen = s["streakSeen"]?.object ?? [:]
        let top = info.badges.last ?? 0
        let weekDone = info.thisWeekDone && (planned > 0 ? done >= planned : true)
        let seenBadge = Int(seen["badge"]?.numberValue ?? 0)
        let wk: JSONValue = weekDone ? .string(info.weekKey) : (seen["wk"] ?? .null)
        if top > seenBadge { return Celebration(kind: "badge", weeks: top, seen: .object(["badge": .number(Double(top)), "wk": wk])) }
        if weekDone && seen["wk"] != .string(info.weekKey) {
            return Celebration(kind: "week", weeks: info.current, seen: .object(["badge": .number(Double(seenBadge)), "wk": wk]))
        }
        return nil
    }

    // MARK: The snapshot

    static func routineIdsOf(_ w: Object) -> [String] {
        if let a = w["routineIds"]?.arrayValue { return a.compactMap(\.stringValue) }
        return w["routineId"]?.stringValue.map { [$0] } ?? []
    }

    static func weekdayName(_ iso: String) -> String {
        guard let d = Day.date(iso) else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE"
        return f.string(from: d)
    }

    static func dayOf(_ s: Object, _ iso: String, today: String, catalog c: ExerciseCatalog, settings: ProfileSettings) -> Object {
        let all = (s["routines"]?.arrayValue ?? []).compactMap(\.object)
        let routines = Schedule.routineIds(s, on: iso, today: today).compactMap { id in all.first { $0["id"]?.stringValue == id } }
            .filter { !($0["ex"]?.arrayValue ?? []).isEmpty }
        var day: Object = ["iso": .string(iso), "weekday": .string(weekdayName(iso))]
        guard !routines.isEmpty else { day["name"] = .null; day["count"] = .number(0); return day }
        day["name"] = .string(ActiveEdit.sessionName(routines.map { $0["name"]?.stringValue ?? "" }) ?? "")
        day["ids"] = .array(routines.compactMap { $0["id"] })
        day["count"] = .number(Double(routines.reduce(0) { $0 + ($1["ex"]?.arrayValue?.count ?? 0) }))
        if iso == today {
            let cfgs = routines.flatMap { ($0["ex"]?.arrayValue ?? []).compactMap(\.object) }.prefix(exercisesMax)
            day["exercises"] = .array(cfgs.map { cfg in
                let id = cfg["id"]?.stringValue ?? ""
                return .object(["name": .string(c[id]?.displayName ?? cfg["name"]?.stringValue ?? id),
                                "line": .string(RoutineOps.line(cfg, catalog: c, settings: settings))])
            })
            let queued = Set(Schedule.queue(s)?.ids ?? [])
            let logged = (s["workouts"]?.arrayValue ?? []).compactMap(\.object).filter { $0["d"]?.stringValue == today }
            day["done"] = .bool(routines.allSatisfy { r in
                let id = r["id"]?.stringValue ?? ""
                let cid = Schedule.canonical(s, id)
                return !queued.contains(cid) && logged.contains { routineIdsOf($0).contains(cid) }
            })
        }
        return day
    }

    static func lastPR(_ s: Object, catalog c: ExerciseCatalog, unit: String) -> JSONValue {
        let ws = (s["workouts"]?.arrayValue ?? []).compactMap(\.object).filter { !($0["prs"]?.arrayValue ?? []).isEmpty }
        guard var w = ws.first else { return .null }
        for b in ws.dropFirst() {
            let (bd, wd) = (b["d"]?.stringValue ?? "", w["d"]?.stringValue ?? "")
            if bd > wd || (bd == wd && (b["end"]?.num ?? 0) > (w["end"]?.num ?? 0)) { w = b }
        }
        let id = w["prs"]?.arrayValue?.first?.stringValue ?? ""
        let entry = (w["entries"]?.arrayValue ?? []).compactMap(\.object).first { $0["id"]?.stringValue == id }
        let name = c[id]?.displayName ?? entry?["target"]?.object?["name"]?.stringValue ?? entry?["name"]?.stringValue ?? id
        let best = entry.map { Session.bestWeight($0, c) } ?? 0
        return .object(["name": .string(name), "value": .string(best > 0 ? "\(Format.number(best)) \(unit)" : ""), "d": w["d"] ?? .null])
    }

    static func active(_ s: Object) -> JSONValue {
        guard let a = s["active"]?.object, let entries = a["entries"]?.arrayValue, a["editingWorkoutId"] == nil || a["editingWorkoutId"] == .null else { return .null }
        var done = 0, total = 0
        for e in entries { for r in e.object?["sets"]?.arrayValue ?? [] { total += 1; if r.object?["done"] == .bool(true) { done += 1 } } }
        return .object(["id": a["id"] ?? .null, "name": a["name"] ?? .string(""), "start": a["start"]?.numberValue.map(JSONValue.number) ?? .null,
                        "done": .number(Double(done)), "total": .number(Double(total))])
    }

    static func labels(streak n: Int) -> Object {
        let words: [String: String] = [
            "today": "Today", "restDay": "Rest day", "upNext": "Up next", "thisWeek": "This week", "weekStreak": "Week streak",
            "streak": "\(n) week streak", "lastPR": "Last PR", "done": "Done", "running": "Workout running",
            "weightGoal": "Weight goal", "nextWorkout": "Next workout", "records": "Records", "volume": "Volume", "challenges": "Challenges",
            "freezes": "Streak freezes", "nothingPlanned": "Nothing planned", "noWeighIn": "No weigh-ins yet", "startNow": "Start",
        ]
        return words.mapValues(JSONValue.string)
    }

    static func compact(_ n: Double) -> String { n >= 10_000 ? Format.number(Session.jsRound(n / 100) / 10) + "k" : Format.number(Session.jsRound(n)) }

    /// Everything the widgets show. `history` gives each workout's volume as Stats counts it.
    public static func snapshot(_ s: Object, history: History, today: String, catalog c: ExerciseCatalog) -> Object {
        let settings = history.settings
        let unit = s["unit"] == .string("lb") ? "lb" : "kg"
        let days = (0..<days).compactMap { Day.adding($0, to: today) }.map { dayOf(s, $0, today: today, catalog: c, settings: settings) }
        let tally = Schedule.weekTally(s, today: today)
        let st = streak(s, today: today)
        let ws = Schedule.weekStart(s)
        let weekFrom = Schedule.weekKey(today, weekStart: ws) ?? today
        let workouts = (s["workouts"]?.arrayValue ?? []).compactMap(\.object)

        // Weight goal: the last weigh-in, the goal, how far to go, the last few weigh-ins.
        var weight: JSONValue = .null
        let bw = (s["bodyweight"]?.arrayValue ?? []).compactMap(\.object)
        if s["modules"]?.object?["body"] != .bool(false), let last = bw.last?["w"]?.numberValue {
            let goal = BodyData.goal(s)
            let toGo = goal.map { Session.round1(abs(last - $0)) }
            weight = .object(["current": .number(last), "goal": goal.map(JSONValue.number) ?? .null, "toGo": toGo.map(JSONValue.number) ?? .null,
                              "unit": .string(unit), "trend": .array(bw.suffix(trendPoints).compactMap { $0["w"]?.numberValue }.map(JSONValue.number)),
                              "currentText": .string("\(Format.number(last)) \(unit)"), "goalText": goal.map { .string("\(Format.number($0)) \(unit)") } ?? .null,
                              "line": .string(goal == nil ? "No goal set" : toGo! < 0.1 ? "Goal reached" : "\(Format.number(toGo!)) \(unit) to go")])
        }

        // PRs this month, and volume this week against last.
        let month = String(today.prefix(7))
        let prs = workouts.filter { ($0["d"]?.stringValue ?? "").hasPrefix(month) }.reduce(0) { $0 + ($1["prs"]?.arrayValue?.count ?? 0) }
        let prevKey = Day.adding(-7, to: weekFrom).flatMap { Schedule.weekKey($0, weekStart: ws) }
        var now = 0.0, before = 0.0
        for w in history.workouts {
            let k = Schedule.weekKey(w.date, weekStart: ws)
            if k == weekFrom { now += history.volume(w) } else if k == prevKey { before += history.volume(w) }
        }
        let pct: Int? = before > 0 ? Int(Session.jsRound((now - before) / before * 100)) : nil

        let next = days.first { d in d["name"] != nil && d["name"] != .null && !(d["iso"]?.stringValue == today && d["done"] == .bool(true)) }
        let left = Schedule.workoutsLeft(s, today: today)
        return [
            "v": .number(Double(version)), "today": .string(today), "weekFrom": .string(weekFrom),
            "weekUntil": Day.adding(7, to: weekFrom).map(JSONValue.string) ?? .null, "unit": .string(unit),
            "accent": .string("#40c8e0"), "ink": .string("#000000"),
            "days": .array(days.map(JSONValue.object)),
            "week": .object(["done": .number(Double(tally.done)), "planned": .number(Double(tally.planned))]),
            "weekLeft": left.map { .object(["left": .number(Double($0.left)), "of": .number(Double($0.of))]) } ?? .null,
            "streak": .number(Double(st.current)),
            "lastPR": lastPR(s, catalog: c, unit: unit),
            "active": active(s),
            "streakInfo": .object(["current": .number(Double(st.current)), "best": .number(Double(st.best)), "freezes": .number(Double(st.freezes)),
                                   "weekDone": .bool(st.thisWeekDone), "next": st.next.map { .number(Double($0)) } ?? .null,
                                   "line": .string("\(st.current) week streak"), "bestLine": .string("Best: \(st.best)")]),
            "weight": weight,
            "next": next.map { d in .object(["name": d["name"]!, "iso": d["iso"]!, "weekday": d["weekday"] ?? .null,
                                              "today": .bool(d["iso"]?.stringValue == today), "ids": d["ids"] ?? .array([]), "count": d["count"] ?? .number(0)]) } ?? .null,
            "records": .object(["month": .number(Double(prs)), "monthLine": .string(prs == 1 ? "1 PR this month" : "\(prs) PRs this month"),
                                "last": lastPR(s, catalog: c, unit: unit)]),
            "volume": .object(["now": .number(Session.jsRound(now)), "prev": .number(Session.jsRound(before)), "unit": .string(unit),
                               "pct": pct.map { .number(Double($0)) } ?? .null, "nowText": .string("\(compact(now)) \(unit)"),
                               "prevText": .string("\(compact(before)) \(unit)"),
                               "line": .string(pct.map { "\($0 > 0 ? "+" : "")\($0)% vs last week" } ?? "Last week: \(compact(before)) \(unit)")]),
            "challenges": .null, "level": .null,
            "labels": .object(labels(streak: st.current)),
        ]
    }
}
