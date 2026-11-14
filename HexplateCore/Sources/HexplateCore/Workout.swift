import Foundation

// Read-only views of a logged workout. Field names follow the openGym document
// (frontend/src/lib/workout-model.js, docs/dev/SET_TYPES.md); only what Hexplate reads is here.
// Reading is lenient the way the JavaScript is: a field of the wrong type reads as absent rather
// than making the whole workout unreadable.

extension KeyedDecodingContainer {
    /// A number, or a numeric string (imports wrote those); anything else is absent.
    func number(_ key: Key) -> Double? {
        if let v = try? decode(Double.self, forKey: key) { return v }
        if let s = try? decode(String.self, forKey: key) { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
    func string(_ key: Key) -> String? { try? decode(String.self, forKey: key) }
    func bool(_ key: Key) -> Bool? { try? decode(Bool.self, forKey: key) }
    /// JavaScript's `!= null`: the key is there with any value but null.
    func present(_ key: Key) -> Bool { contains(key) && (try? decodeNil(forKey: key)) == false }
}

public struct Workout: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    /// Local day of the session, `YYYY-MM-DD`.
    public let date: String
    /// Milliseconds since 1970.
    public let start: Double?
    public let end: Double?
    public let name: String?
    public let routineId: String?
    /// The body weight checked in for this session.
    public let bodyweight: Double?
    public let entries: [WorkoutEntry]
    /// False for a legacy record that only has its cached volume.
    public let hasEntries: Bool
    /// The volume cached when the workout was saved (`vol`).
    public let savedVolume: Double?
    /// How many personal records the session set.
    public let recordCount: Int

    enum CodingKeys: String, CodingKey {
        case id, date = "d", start, end, name, routineId, bodyweight = "bw", entries, vol, prs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        start = try? c.decode(Double.self, forKey: .start)
        end = try? c.decode(Double.self, forKey: .end)
        name = c.string(.name)
        routineId = c.string(.routineId)
        bodyweight = c.number(.bodyweight)
        let list = try? c.decode([WorkoutEntry].self, forKey: .entries)
        entries = list ?? []
        hasEntries = list != nil
        savedVolume = c.number(.vol)
        recordCount = (try? c.decode([JSONValue].self, forKey: .prs))?.count ?? 0
    }
}

/// One exercise within a workout.
public struct WorkoutEntry: Decodable, Equatable, Sendable {
    /// The exercise id (catalogue or custom), not unique within a workout.
    public let exerciseId: String
    /// The name saved with the entry, for an exercise that no longer exists.
    public let savedName: String?
    public let sets: [WorkoutSet]
    public let note: String?
    /// Entries sharing a group letter are done as a superset.
    public let supersetGroup: String?
    /// The plan the entry was logged against.
    public let target: Target?

    enum CodingKeys: String, CodingKey {
        case exerciseId = "id", savedName = "n", sets, note, supersetGroup = "sg", target
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exerciseId = try c.decode(String.self, forKey: .exerciseId)
        savedName = c.string(.savedName)
        sets = (try? c.decode([WorkoutSet].self, forKey: .sets)) ?? []
        note = c.string(.note)
        supersetGroup = c.string(.supersetGroup)
        target = try? c.decode(Target.self, forKey: .target)
    }
}

/// What a routine planned for an exercise, as far as reading a logged set back needs it.
public struct Target: Decodable, Equatable, Sendable {
    public let id: String?
    public let mode: String?
    public let unit: String?
    public let bodyweight: Bool?
    public let side: Bool
    /// "each", "total" or "as": what a dumbbell weight was entered as.
    public let dbLoad: String?
    public let intensifier: String?
    public let assisted: Bool?
    let hasCardioFields: Bool
    let hasTimeFields: Bool
    let hasRepFields: Bool

    enum CodingKeys: String, CodingKey {
        case id, mode, unit, bodyweight, side, dbLoad, intensifier, assisted
        case min, speed, sec, seconds, durationSec, r, reps, actualReps
    }
    enum ModeKey: String, CodingKey { case mode, type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        mode = c.string(.mode)
        unit = c.string(.unit)
        bodyweight = c.bool(.bodyweight)
        side = c.bool(.side) == true
        // A plain string, or a stamped map { mode, _ts } (lib/dumbbells.js dbLoadOf).
        let load = c.string(.dbLoad)
            ?? (try? c.nestedContainer(keyedBy: ModeKey.self, forKey: .dbLoad))?.string(.mode)
        dbLoad = load.flatMap { ["each", "total", "as"].contains($0) ? $0 : nil }
        intensifier = (try? c.nestedContainer(keyedBy: ModeKey.self, forKey: .intensifier))?.string(.type)
        assisted = c.bool(.assisted)
        hasCardioFields = c.present(.min) || c.present(.speed)
        hasTimeFields = c.present(.sec) || c.present(.seconds) || c.present(.durationSec)
        hasRepFields = c.present(.r) || c.present(.reps) || c.present(.actualReps)
    }
}

/// One logged row. A unilateral set carries a full row per side in `sides`.
public struct WorkoutSet: Decodable, Equatable, Sendable {
    public enum Kind: String, Sendable { case straight, dropset, restpause }

    public struct Drop: Decodable, Equatable, Sendable {
        public let weight: Double?
        public let reps: Double?
        enum CodingKeys: String, CodingKey { case w, r }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            weight = c.number(.w)
            reps = c.number(.r)
        }
    }
    public struct Cluster: Decodable, Equatable, Sendable {
        public let reps: Double?
        public let restSec: Double?
        enum CodingKeys: String, CodingKey { case r, restSec }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reps = c.number(.r)
            restSec = c.number(.restSec)
        }
    }
    public struct HeartRate: Decodable, Equatable, Sendable {
        public let avg: Double?
        public let max: Double?
        enum CodingKeys: String, CodingKey { case avg, max }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            avg = c.number(.avg)
            max = c.number(.max)
        }
    }

    public let weight: Double?
    /// For a rest-pause set this is the total over all clusters.
    public let reps: Double?
    /// Timed exercises log seconds instead of reps.
    public let seconds: Double?
    /// Cardio logs minutes and a speed in km/h.
    public let minutes: Double?
    public let speed: Double?
    public let incline: Double?
    public let done: Bool
    public let isWarmup: Bool
    public let kind: Kind
    /// Extra work on top of the main set (drop set only).
    public let drops: [Drop]
    /// The breakdown of `reps` (rest-pause only), never extra volume.
    public let clusters: [Cluster]
    /// Per-side rows of a unilateral set, keyed "L" and "R".
    public let sides: [String: WorkoutSet]
    public let rir: Double?
    public let rpe: Double?
    /// Taken to failure. Never true for a warm-up.
    public let failure: Bool
    public let heartRate: HeartRate?
    /// Milliseconds since 1970.
    public let completedAt: Double?
    let mode: String?
    let unit: String?
    let hasCardioFields: Bool
    let hasTimeFields: Bool
    let hasRepFields: Bool

    enum CodingKeys: String, CodingKey {
        case w, r, sec, min, speed, incline, done, phase, warmup, type, drops, clusters, sides
        case rir, rpe, failure, hr, at, mode, unit, seconds, durationSec, reps, actualReps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weight = c.number(.w)
        reps = c.number(.r)
        seconds = c.number(.sec)
        minutes = c.number(.min)
        speed = c.number(.speed)
        incline = c.number(.incline)
        done = c.bool(.done) == true
        // An explicit phase wins over the legacy warmup boolean (workout-model.js phaseForSet).
        if c.present(.phase), c.string(.phase) != "" {
            let token = c.string(.phase)?.trimmingCharacters(in: .whitespaces).lowercased()
            isWarmup = ["warmup", "warm-up", "warm_up"].contains(token)
        } else {
            isWarmup = c.bool(.warmup) == true
        }
        // The extras only count on a row of their own type (dropsOf / clustersOf).
        kind = c.string(.type).flatMap(Kind.init) ?? .straight
        drops = kind == .dropset ? (try? c.decode([Drop].self, forKey: .drops)) ?? [] : []
        clusters = kind == .restpause ? (try? c.decode([Cluster].self, forKey: .clusters)) ?? [] : []
        sides = (try? c.decode([String: WorkoutSet].self, forKey: .sides)) ?? [:]
        rir = c.number(.rir)
        rpe = c.number(.rpe)
        failure = c.bool(.failure) == true && !isWarmup
        heartRate = try? c.decode(HeartRate.self, forKey: .hr)
        completedAt = c.number(.at)
        mode = c.string(.mode)
        unit = c.string(.unit)
        hasCardioFields = c.present(.min) || c.present(.speed)
        hasTimeFields = c.present(.sec) || c.present(.seconds) || c.present(.durationSec)
        hasRepFields = c.present(.r) || c.present(.reps) || c.present(.actualReps)
    }

    /// Logged per side: both sides are there (workout-model.js isSideSet).
    public var perSide: (left: WorkoutSet, right: WorkoutSet)? {
        guard let l = sides["L"], let r = sides["R"] else { return nil }
        return (l, r)
    }

    /// Includes a completed side even when its partner is still unchecked.
    public var hasCompletedWork: Bool {
        if let (l, r) = perSide { return l.done || r.done }
        return done
    }
}
