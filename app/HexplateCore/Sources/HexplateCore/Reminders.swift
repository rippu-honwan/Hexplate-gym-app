import Foundation

/// The workout-day reminder and the missed-workout nudge, as local notifications: which days get
/// one, at what time, saying what (openGym lib/mobile.js buildReminderNotifications /
/// buildNudgeNotifications, lib/nudge.js, lib/day-notes.js excusedOn). Settings live in the synced
/// profile as openGym keeps them: `reminder = {on, time "HH:MM", nudge, tone}`.
/// Texts are English source strings with `{0}` for the routine; the app translates them.
public enum Reminders {
    public typealias Object = [String: JSONValue]

    public static let reminderDays = 60, nudgeDays = 7
    public static let tones = ["friendly", "guilt", "drill"]
    static let maxMisses = 3, lookbackDays = 14
    static let evening = 20 * 60, latest = 21 * 60 + 30, afterReminder = 120

    public static let copy: [String: (title: String, lines: [String])] = [
        "friendly": ("Everything okay?", [
            "{0} is still waiting. What’s up?",
            "No {0} today? Even a short session tomorrow counts.",
            "Rough day? {0} will keep. Tomorrow is a fresh start.",
            "Hey, {0} didn’t happen today. All good?",
        ]),
        "guilt": ("I miss you", [
            "{0} waited by the door all evening. For you.",
            "The barbell asked about you today. I didn’t know what to say.",
            "Was it something I said? {0} misses you.",
            "I saved you a spot on the bench. It’s still empty.",
        ]),
        "drill": ("Attention, recruit!", [
            "Your gains are packing their bags. {0} tomorrow, no excuses!",
            "{0} doesn’t do itself, recruit. Move it!",
            "Excuses don’t lift weights. Report for {0} tomorrow!",
            "Your muscles filed a missing-person report. Show up for {0}!",
        ]),
    ]

    /// One notification: `id` 1000+ for the reminder, 2000+ for the nudge (openGym's ids).
    public struct Note: Equatable, Sendable {
        public let id: Int
        public let day: String
        public let hour: Int, minute: Int
        public let title: String
        /// English source with `{0}` for `names` joined by " + ", or for `count` routines when `names` is empty.
        public let body: String
        public let names: [String]
        public let count: Int

        /// The body in English, as openGym writes it.
        public var english: String {
            body.replacingOccurrences(of: "{0}", with: names.isEmpty ? "\(count) routine\(count == 1 ? "" : "s")" : names.joined(separator: " + "))
        }
    }

    static func reminder(_ s: Object) -> Object? { s["reminder"]?.object }
    /// JavaScript's truthiness, as openGym reads the switches.
    public static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0 && !n.isNaN
        case .string(let t)?: return !t.isEmpty
        case .array?, .object?: return true
        default: return false
        }
    }
    public static func tone(_ r: Object?) -> String { r?["tone"]?.stringValue.flatMap { tones.contains($0) ? $0 : nil } ?? "friendly" }

    /// A day with a note (sick, travelling, ...) is excused: no reminder, no nudge, no miss.
    public static func excused(_ s: Object, _ iso: String) -> Bool {
        guard let n = s["dayNotes"]?.object?[iso]?.object else { return false }
        let tags = ["sick", "travel", "rest", "injured"]
        if let t = n["tag"]?.stringValue, tags.contains(t) { return true }
        return !(n["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func logged(_ s: Object, _ iso: String) -> Bool { Schedule.workouts(s).contains { $0["d"]?.stringValue == iso } }

    static func shift(_ iso: String, _ days: Int) -> String {
        guard let d = Day.date(iso), let n = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: d) else { return iso }
        return Day.iso(n)
    }

    /// Minutes after midnight the nudge is owed from: 20:00, or 2 h after the reminder when later; nil after 21:30.
    static func nudgeMinute(_ time: String) -> Int? {
        let p = time.split(separator: ":", omittingEmptySubsequences: false)
        let r = p.count == 2 && p.allSatisfy { $0.count == 2 } ? p.compactMap { Int($0) } : []
        let at = max(evening, r.count == 2 ? r[0] * 60 + r[1] + afterReminder : 0)
        return at > latest ? nil : at
    }

    static func missed(_ s: Object, _ iso: String) -> [String] {
        if logged(s, iso) || excused(s, iso) { return [] }
        let ids = Schedule.routineIds(s, on: iso, today: iso)
        if ids.isEmpty { return [] }
        if Schedule.queueLiveOn(s, iso, iso) && logged(s, shift(iso, -1)) { return [] }
        return ids
    }

    /// The routines `iso` missed, or nil: not a missed day, or the 3rd missed day in a row since the
    /// last workout or later (it goes quiet until the next one).
    static func nudgeFor(_ s: Object, _ iso: String) -> [String]? {
        let ids = missed(s, iso)
        guard !ids.isEmpty else { return nil }
        let last = Schedule.workouts(s).compactMap { $0["d"]?.stringValue }.filter { $0 < iso }.max() ?? ""
        var misses = 0, d = shift(iso, -1)
        for _ in 0..<lookbackDays where d > last {
            if !missed(s, d).isEmpty { misses += 1; if misses >= maxMisses { return nil } }
            d = shift(d, -1)
        }
        return ids
    }

    /// A day's line: by date, so a day keeps its line and the next day gets the next one.
    static func line(_ iso: String, _ n: Int) -> Int {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents(year: p[0], month: p[1], day: p[2])
        c.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let days = Int((cal.date(from: c)!.timeIntervalSince1970 / 86400).rounded(.down))
        return ((days % n) + n) % n
    }

    /// Every reminder and nudge from `now` on: today's only when its time is still ahead.
    public static func notes(_ s: Object, now: Date) -> [Note] {
        guard let r = reminder(s), truthy(r["on"]) else { return [] }
        let time = r["time"]?.stringValue ?? "08:00"
        let hm = time.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        let routines = Schedule.routines(s)
        let name = { (id: String) in routines.first { $0["id"] == .string(id) }?["name"]?.stringValue }
        let today = Day.iso(now)
        let cal = Calendar(identifier: .gregorian)
        let ahead = { (iso: String, h: Int, m: Int) -> Bool in
            let p = iso.split(separator: "-").compactMap { Int($0) }
            return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: h, minute: m)).map { $0 > now } ?? false
        }
        var out: [Note] = []
        if hm.count == 2, let h = hm[0], let m = hm[1] {
            for offset in 0..<reminderDays {
                let iso = shift(today, offset)
                if logged(s, iso) || excused(s, iso) { continue }
                let found = Schedule.routineIds(s, on: iso, today: iso).compactMap { id in routines.first { $0["id"] == .string(id) } }
                guard !found.isEmpty, ahead(iso, h, m) else { continue }
                out.append(Note(id: 1000 + offset, day: iso, hour: h, minute: m, title: "Workout day",
                                body: "{0} is on the plan today. Let’s go!",
                                names: found.count <= 2 ? found.map { $0["name"]?.stringValue ?? "" } : [], count: found.count))
            }
        }
        if truthy(r["nudge"]), let at = nudgeMinute(time) {
            let c = copy[tone(r)]!
            for offset in 0..<nudgeDays {
                let iso = shift(today, offset)
                if offset == 0, let a = s["active"], a != .null { continue }
                guard let ids = nudgeFor(s, iso) else { continue }
                let names = ids.compactMap(name).filter { !$0.isEmpty }
                guard ahead(iso, at / 60, at % 60) else { continue }
                out.append(Note(id: 2000 + offset, day: iso, hour: at / 60, minute: at % 60, title: c.title,
                                body: c.lines[line(iso, c.lines.count)],
                                names: !names.isEmpty && names.count <= 2 ? names : [], count: ids.count))
            }
        }
        return out
    }
}
