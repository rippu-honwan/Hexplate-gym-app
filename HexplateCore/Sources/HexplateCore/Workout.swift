import Foundation

// Read-only views of a logged workout. Field names follow the openGym document
// (frontend/src/lib/workout-model.js, docs/dev/SET_TYPES.md); only what Hexplate reads is here.

public struct Workout: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    /// Local day of the session, `YYYY-MM-DD`.
    public let date: String
    /// Milliseconds since 1970.
    public let start: Double?
    public let end: Double?
    public let name: String?
    public let routineId: String?
    public let bodyweight: Double?
    public let entries: [WorkoutEntry]

    enum CodingKeys: String, CodingKey {
        case id, date = "d", start, end, name, routineId, bodyweight = "bw", entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(String.self, forKey: .date)
        start = try c.decodeIfPresent(Double.self, forKey: .start)
        end = try c.decodeIfPresent(Double.self, forKey: .end)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        routineId = try c.decodeIfPresent(String.self, forKey: .routineId)
        bodyweight = try c.decodeIfPresent(Double.self, forKey: .bodyweight)
        entries = try c.decodeIfPresent([WorkoutEntry].self, forKey: .entries) ?? []
    }

    public var duration: TimeInterval? {
        guard let start, let end, end >= start else { return nil }
        return (end - start) / 1000
    }
}

/// One exercise within a workout.
public struct WorkoutEntry: Decodable, Equatable, Sendable {
    /// The exercise id (catalogue or custom), not unique within a workout.
    public let exerciseId: String
    public let sets: [WorkoutSet]
    public let note: String?
    /// Entries sharing a group letter are done as a superset.
    public let supersetGroup: String?

    enum CodingKeys: String, CodingKey {
        case exerciseId = "id", sets, note, supersetGroup = "sg"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exerciseId = try c.decode(String.self, forKey: .exerciseId)
        sets = try c.decodeIfPresent([WorkoutSet].self, forKey: .sets) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
        supersetGroup = try c.decodeIfPresent(String.self, forKey: .supersetGroup)
    }
}

public struct WorkoutSet: Decodable, Equatable, Sendable {
    public enum Kind: String, Sendable { case straight, dropset, restpause }

    public struct Drop: Decodable, Equatable, Sendable {
        public let w: Double?
        public let r: Double?
    }
    public struct Cluster: Decodable, Equatable, Sendable {
        public let r: Double?
        public let restSec: Double?
    }
    public struct Side: Decodable, Equatable, Sendable {
        public let w: Double?
        public let r: Double?
        public let done: Bool?
    }

    public let weight: Double?
    /// For a rest-pause set this is the total over all clusters.
    public let reps: Double?
    /// Timed exercises log seconds instead of reps.
    public let seconds: Double?
    public let done: Bool
    public let isWarmup: Bool
    public let kind: Kind
    /// Extra work on top of the main set (drop set only).
    public let drops: [Drop]
    /// The breakdown of `reps` (rest-pause only), never extra volume.
    public let clusters: [Cluster]
    /// Per-side values for unilateral exercises, keyed "L" and "R".
    public let sides: [String: Side]
    public let rir: Double?
    public let rpe: Double?
    /// Milliseconds since 1970.
    public let completedAt: Double?

    enum CodingKeys: String, CodingKey {
        case w, r, sec, done, phase, warmup, type, drops, clusters, sides, rir, rpe, at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weight = try c.decodeIfPresent(Double.self, forKey: .w)
        reps = try c.decodeIfPresent(Double.self, forKey: .r)
        seconds = try c.decodeIfPresent(Double.self, forKey: .sec)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        // An explicit phase wins over the legacy warmup boolean (workout-model.js phaseForSet).
        if let phase = try c.decodeIfPresent(String.self, forKey: .phase), phase == "warmup" || phase == "work" {
            isWarmup = phase == "warmup"
        } else {
            isWarmup = (try c.decodeIfPresent(Bool.self, forKey: .warmup)) == true
        }
        kind = (try c.decodeIfPresent(String.self, forKey: .type)).flatMap(Kind.init) ?? .straight
        drops = try c.decodeIfPresent([Drop].self, forKey: .drops) ?? []
        clusters = try c.decodeIfPresent([Cluster].self, forKey: .clusters) ?? []
        sides = try c.decodeIfPresent([String: Side].self, forKey: .sides) ?? [:]
        rir = try c.decodeIfPresent(Double.self, forKey: .rir)
        rpe = try c.decodeIfPresent(Double.self, forKey: .rpe)
        completedAt = try c.decodeIfPresent(Double.self, forKey: .at)
    }
}
