import Foundation

/// A single `dayPlan[iso]` transition recorded at AI Coach Accept time.
/// `nil` represents an absent key in `dayPlan`.
public struct DayPlanDiff: Codable, Equatable, Sendable {
    public let before: JSONValue?
    public let after: JSONValue?

    public init(before: JSONValue?, after: JSONValue?) {
        self.before = before
        self.after = after
    }
}

/// Device-local undo record capturing an accepted AI Coach batch.
/// Never persisted inside `state.json`; stored locally by the app (Stage 7a).
public struct AIUndoRecord: Codable, Equatable, Sendable {
    public let tokenId: String
    public let acceptedAt: Double
    /// Local calendar date (`YYYY-MM-DD`) when the batch was accepted.
    public let acceptedDay: String
    /// Per-date `dayPlan` transitions keyed by `YYYY-MM-DD`.
    public let dayPlanDiffs: [String: DayPlanDiff]
    /// Ephemeral `aiClone` routines created by this batch, keyed by clone ID, storing functional
    /// routine content stripped of sync metadata (`_ts`, `_f`, `_u`).
    public let createdClones: [String: [String: JSONValue]]

    public var touchedDates: Set<String> { Set(dayPlanDiffs.keys) }
    public var createdCloneIds: Set<String> { Set(createdClones.keys) }

    public init(
        tokenId: String,
        acceptedAt: Double,
        acceptedDay: String,
        dayPlanDiffs: [String: DayPlanDiff],
        createdClones: [String: [String: JSONValue]]
    ) {
        self.tokenId = tokenId
        self.acceptedAt = acceptedAt
        self.acceptedDay = acceptedDay
        self.dayPlanDiffs = dayPlanDiffs
        self.createdClones = createdClones
    }
}

/// Pure, value-comparing undo engine for AI Coach plan changes.
public enum AIUndo {
    public typealias Object = [String: JSONValue]

    public enum Status: Equatable, Sendable {
        case available
        case expired
        case blockedByActive
        case blockedByLoggedWorkout
    }

    public struct Outcome: Equatable, Sendable {
        public let status: Status
        public let restoredDates: [String]
        public let skippedDates: [String]
        public let removedCloneIds: [String]
        public let skippedCloneIds: [String]

        public init(
            status: Status,
            restoredDates: [String],
            skippedDates: [String],
            removedCloneIds: [String],
            skippedCloneIds: [String]
        ) {
            self.status = status
            self.restoredDates = restoredDates
            self.skippedDates = skippedDates
            self.removedCloneIds = removedCloneIds
            self.skippedCloneIds = skippedCloneIds
        }
    }

    private static let syncMetaKeys: Set<String> = ["_ts", "_f", "_u"]

    /// Strips sync-stamping metadata (`_ts`, `_f`, `_u`) so clone content can be compared across
    /// local stamping and sync merges.
    public static func strippedMeta(_ routine: Object) -> Object {
        routine.filter { !syncMetaKeys.contains($0.key) }
    }

    /// Evaluates whether `record` may currently be undone against live document `s`.
    public static func status(of record: AIUndoRecord, in s: Object, today: String) -> Status {
        if today > record.acceptedDay { return .expired }
        let touched = record.touchedDates
        if let activeDay = s["active"]?.object?["d"]?.stringValue, touched.contains(activeDay) {
            return .blockedByActive
        }
        let loggedOnTouched = (s["workouts"]?.arrayValue ?? []).contains { v in
            guard let d = v.object?["d"]?.stringValue else { return false }
            return touched.contains(d)
        }
        if loggedOnTouched { return .blockedByLoggedWorkout }
        return .available
    }

    /// Applies `record` in two phases against live document `s`:
    /// 1. Restore each `dayPlan[iso]` only if its current value still equals `diff.after`.
    /// 2. Remove each created `aiClone` only if unreferenced in the post-restore document and still
    ///    equal to its recorded snapshot (ignoring `_ts`, `_f`, `_u`). Clones already removed by
    ///    sync or GC are reported in `removedCloneIds` to keep Undo idempotent.
    public static func apply(_ record: AIUndoRecord, to s: inout Object, today: String) -> Outcome {
        let st = status(of: record, in: s, today: today)
        guard st == .available else {
            return Outcome(status: st, restoredDates: [], skippedDates: [], removedCloneIds: [], skippedCloneIds: [])
        }

        // Phase 1: restore dayPlan entries first.
        var plan = s["dayPlan"]?.object ?? [:]
        var planTouched = false
        var restoredDates: [String] = []
        var skippedDates: [String] = []

        for iso in record.dayPlanDiffs.keys.sorted() {
            guard let diff = record.dayPlanDiffs[iso] else { continue }
            if plan[iso] == diff.after {
                plan[iso] = diff.before
                planTouched = true
                restoredDates.append(iso)
            } else {
                skippedDates.append(iso)
            }
        }
        if planTouched {
            s["dayPlan"] = .object(plan)
        }

        // Phase 2: prune created clones against the post-restore document.
        let referenced = RoutineOps.referencedRoutineIds(in: s)
        var routines = s["routines"]?.arrayValue ?? []
        var routinesTouched = false
        var removedCloneIds: [String] = []
        var skippedCloneIds: [String] = []

        for cloneId in record.createdClones.keys.sorted() {
            guard let snapshot = record.createdClones[cloneId] else { continue }
            guard let idx = routines.firstIndex(where: { $0.object?["id"]?.stringValue == cloneId }) else {
                // Already removed on another device or by GC: treat as removed for idempotency.
                removedCloneIds.append(cloneId)
                continue
            }
            if !referenced.contains(cloneId),
               let current = routines[idx].object,
               strippedMeta(current) == strippedMeta(snapshot) {
                routines.remove(at: idx)
                routinesTouched = true
                removedCloneIds.append(cloneId)
            } else {
                skippedCloneIds.append(cloneId)
            }
        }
        if routinesTouched {
            s["routines"] = .array(routines)
        }

        return Outcome(
            status: .available,
            restoredDates: restoredDates,
            skippedDates: skippedDates,
            removedCloneIds: removedCloneIds,
            skippedCloneIds: skippedCloneIds
        )
    }
}
