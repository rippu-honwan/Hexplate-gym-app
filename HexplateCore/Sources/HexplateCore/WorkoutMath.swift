import Foundation

/// Numbers read back from a logged workout. Ported from frontend/src/lib/history.js,
/// workout-model.js, dumbbells.js and bw-load.js; HistoryGoldenTests holds it to their output.
public enum WorkoutMath {
    // MARK: Sets and time

    /// Completed sets; a unilateral set counts once per side (history.js setsDone).
    public static func setsDone(_ w: Workout) -> Int {
        w.entries.reduce(0) { n, e in
            n + e.sets.reduce(0) { m, s in
                if let (l, r) = s.perSide { return m + (l.done ? 1 : 0) + (r.done ? 1 : 0) }
                return m + (s.done ? 1 : 0)
            }
        }
    }

    /// Milliseconds from start to end, 0 when either is missing (history.js workoutDuration).
    public static func duration(_ w: Workout) -> Double {
        guard let start = w.start, let end = w.end else { return 0 }
        return max(0, end - start)
    }

    // MARK: Volume

    /// Weight × reps of what was completed, each side on its own, drops included
    /// (workout-model.js completedVolumeOf). A rest-pause row's reps already hold its bursts.
    static func completedVolume(_ s: WorkoutSet, load: (Double) -> Double = { $0 }) -> Double {
        if let (l, r) = s.perSide { return completedVolume(l, load: load) + completedVolume(r, load: load) }
        guard s.done else { return 0 }
        let drops = s.drops.reduce(0) { $0 + load($1.weight ?? 0) * ($1.reps ?? 0) }
        return load(s.weight ?? 0) * (s.reps ?? 0) + drops
    }

    /// The volume a screen shows for one session (history.js sessionVolume).
    public static func volume(_ w: Workout, settings: ProfileSettings, catalog: ExerciseCatalog, weighIns: [WeighIn]) -> Double {
        guard w.hasEntries else { return max(0, w.savedVolume ?? 0) }
        let bodyweight = settings.countBodyweight ? self.bodyweight(for: w, weighIns: weighIns) : 0
        var v = 0.0
        for e in w.entries {
            let factor = volumeFactor(e, catalog: catalog)
            let body = bodyweight > 0 ? bodyLoad(catalog[e.exerciseId]) : nil
            let own = bodyweight * (body?.share ?? 0)
            for s in e.sets where settings.countWarmups || !s.isWarmup {
                if let body, mode(of: s, target: e.target) == "reps" {
                    v += body.assisted
                        ? completedVolume(s) { max(0, own - $0) }
                        : completedVolume(s) * factor + completedVolume(s) { _ in own }
                } else {
                    v += completedVolume(s) * factor
                }
            }
        }
        return max(0, v)
    }

    /// What one logged kilo is worth: 2 for a weight entered per bell on two bells (dumbbells.js).
    static func volumeFactor(_ e: WorkoutEntry, catalog: ExerciseCatalog) -> Double {
        e.target?.dbLoad == "each" ? Double(bells(target: e.target, exercise: catalog[e.exerciseId])) : 1
    }

    static func bells(target: Target?, exercise: Exercise?) -> Int {
        target?.side == true || exercise?.isOneArm == true ? 1 : 2
    }

    // MARK: Mode

    private static let modes = ["reps", "time", "cardio"]

    private static func explicitMode(_ mode: String?, unit: String?) -> String? {
        let token = mode?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if modes.contains(token) { return token }
        switch unit?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "rep", "reps", "repetition", "repetitions": return "reps"
        case "sec", "secs", "second", "seconds": return "time"
        case "min", "mins", "minute", "minutes": return "cardio"
        default: return nil
        }
    }

    private static func inferredMode(mode: String?, unit: String?, cardio: Bool, time: Bool, reps: Bool) -> String? {
        if let explicit = explicitMode(mode, unit: unit) { return explicit }
        if mode?.trimmingCharacters(in: .whitespaces).lowercased() == "amrap" { return "reps" }
        return cardio ? "cardio" : time ? "time" : reps ? "reps" : nil
    }

    /// One row's mode: the row's own, the target's, then the row's fields (workout-model.js modeForSet).
    static func mode(of s: WorkoutSet, target t: Target?) -> String {
        explicitMode(s.mode, unit: s.unit)
            ?? t.flatMap { inferredMode(mode: $0.mode, unit: $0.unit, cardio: $0.hasCardioFields, time: $0.hasTimeFields, reps: $0.hasRepFields) }
            ?? inferredMode(mode: s.mode, unit: s.unit, cardio: s.hasCardioFields, time: s.hasTimeFields, reps: s.hasRepFields)
            ?? "reps"
    }

    // MARK: Body weight in volume (bw-load.js)

    private static let skip = #"stretch|form check|scapular|\bhold\b|\bassist(ed)?\b|\bbench\b|\bfloor\b|\bwall\b|reverse (push|dip)|handstand|\bpike\b"#
    private static let patterns: [(String, Double)] = [
        (#"\b(pull[- ]?ups?|chin[- ]?ups?|muscle[- ]?ups?)\b"#, 1),
        (#"\bdips?\b"#, 1),
        (#"push[- ]?ups?.*\bknees?\b|\bknees?\b.*push[- ]?ups?"#, 0.49),
        (#"\bincline\b.*push[- ]?ups?"#, 0.41),
        (#"\bdecline\b.*push[- ]?ups?"#, 0.74),
        (#"push[- ]?ups?"#, 0.64),
    ]
    private static let bodyEquipment = ["body weight", "weighted", "suspension trainer", "rope"]

    /// The share of body weight one rep moves, and whether the logged weight is taken off it.
    static func bodyLoad(_ ex: Exercise?) -> (share: Double, assisted: Bool)? {
        guard let ex, !ex.isCardio else { return nil }
        let assisted = ex.isAssisted
        if !assisted && (!bodyEquipment.contains(ex.equipment ?? "") || ex.name.matches(skip)) { return nil }
        let plain = assisted
            ? ex.name.replacingOccurrences(of: #"\bassist(ed)?\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            : ex.name
        if assisted && plain.matches(skip) { return nil }
        guard let hit = patterns.first(where: { plain.matches($0.0) }) else { return nil }
        return (hit.1, assisted)
    }

    /// The body weight a session was done at: its own check-in, else the weigh-in nearest its start.
    // ponytail: a day with several timed weigh-ins (`ins`) sits at noon here, not at the time of
    // the reading its value comes from (bodyweight.js weighInAt); port that with the Body screen.
    static func bodyweight(for w: Workout, weighIns: [WeighIn]) -> Double {
        if let own = w.bodyweight, own > 0 { return own }
        let pts = weighIns.filter { $0.weight > 0 }.map { (t: $0.time, w: $0.weight) }.sorted { $0.t < $1.t }
        guard let last = pts.last else { return 0 }
        let at = w.start ?? Day.noon(w.date)
        guard at.isFinite else { return last.w }
        var lo = 0, hi = pts.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if pts[mid].t < at { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, at - pts[lo - 1].t <= pts[lo].t - at { return pts[lo - 1].w }
        return pts[lo].w
    }
}

/// One day's body weight from the document's `bodyweight` list.
public struct WeighIn: Decodable, Equatable, Sendable {
    public let date: String
    public let weight: Double
    let typedAt: Double?

    enum CodingKeys: String, CodingKey { case d, w, t }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .d)
        weight = c.number(.w) ?? 0
        typedAt = c.number(.t)
    }

    /// Where the weigh-in sits on a time axis: when it was typed if that was on its own day,
    /// else noon of the day it is for.
    var time: Double {
        if let t = typedAt, t > 0, Day.iso(t) == date { return t }
        return Day.noon(date)
    }
}

/// Calendar days as the document stores them: `YYYY-MM-DD` in the device's time zone.
public enum Day {
    /// Noon of that day in milliseconds, NaN for a string that is not a date.
    static func noon(_ iso: String) -> Double {
        date(iso).map { $0.timeIntervalSince1970 * 1000 } ?? .nan
    }

    /// Noon of that day, so the date stays on its day whatever is formatted from it.
    public static func date(_ iso: String) -> Date? {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard iso.count == 10, p.count == 3 else { return nil }
        let c = DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)
        guard c.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: c)
    }

    static func iso(_ ms: Double) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static var calendar: Calendar { Calendar(identifier: .gregorian) }
}
