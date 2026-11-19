import Foundation

/// One profile: the openGym state document (the same JSON as `state-<uid>.json` on a server and
/// as "Export backup (JSON)" in the Capacitor app). The document itself is what gets stored; the
/// typed models are views onto the parts Hexplate reads.
public struct StateDocument: Equatable, Sendable {
    public private(set) var root: [String: JSONValue]

    public enum ReadError: Error, Equatable {
        case notJSON
        case notAnObject
        case missingWorkouts
    }

    /// Checks that `data` is a state document before accepting it. Nothing is repaired or dropped.
    public init(data: Data) throws(ReadError) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw .notJSON }
        guard case .object(let object) = value else { throw .notAnObject }
        guard case .array = object["workouts"] else { throw .missingWorkouts }
        root = object
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        // ponytail: sorted keys for stable output; JavaScript keeps insertion order, which no
        // reader of this document depends on.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(root))
    }

    /// Makes a change to the document and stamps it for sync, the way the Capacitor app's store
    /// does on every update (SyncStamps). A change that changes nothing leaves the document as it was.
    public mutating func change(at wall: Double = (Date().timeIntervalSince1970 * 1000).rounded(), _ mutate: (inout [String: JSONValue]) -> Void) {
        let prev = root
        mutate(&root)
        Gyms.sync(&root, prev: prev, now: wall)   // the active gym's inventory and its copy in step
        guard root != prev else { return }
        root["_ts"] = .number(SyncStamps.stampChange(prev: prev, next: &root, wall: wall))
    }

    /// Sets one top-level key. Everything else stays as it is.
    public mutating func set(_ key: String, to value: JSONValue) {
        root[key] = value
    }

    /// When the document was last changed (`_ts`, milliseconds), 0 when it carries no stamp.
    public var timestamp: Double { root["_ts"]?.numberValue ?? 0 }

    /// The logged workouts in document order. A workout that cannot be read is counted, not
    /// dropped silently, and stays in the document either way.
    public func workouts() -> (items: [Workout], unreadable: Int) {
        let raw = root["workouts"]?.arrayValue ?? []
        let items = raw.compactMap { try? $0.decoded(as: Workout.self) }
        return (items, raw.count - items.count)
    }

    public var summary: Summary {
        let (items, unreadable) = workouts()
        let dates = items.map(\.date).sorted()
        return Summary(
            workoutCount: items.count,
            unreadableWorkouts: unreadable,
            routineCount: root["routines"]?.arrayValue?.count ?? 0,
            firstDate: dates.first,
            lastDate: dates.last
        )
    }

    public struct Summary: Equatable, Sendable {
        public let workoutCount: Int
        public let unreadableWorkouts: Int
        public let routineCount: Int
        /// `YYYY-MM-DD`, as stored.
        public let firstDate: String?
        public let lastDate: String?
    }
}
