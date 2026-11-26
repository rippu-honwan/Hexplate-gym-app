import Foundation

/// Pure, `nonisolated`, display-name-free AI Coach operation parser, portable semantic validator,
/// snapshot-anchored 15-day simulator, minimal Clone-and-Pin compiler, 15-day post-compile verifier,
/// and atomic live-document applier emitting `AIUndoRecord`.
public enum CoachOps {
    public typealias Object = [String: JSONValue]

    public static let maxBatchOps = 8
    public static let maxWindowDays = 14
    public static let maxIdLength = 64
    public static let maxSlotIndex = 49
    public static let minSets = 1
    public static let maxSets = 12
    public static let minReps = 1
    public static let maxReps = 100
    public static let maxReasonCodePoints = 160

    // MARK: - Portable Semantic Context (Shared with `shared/coach_ops_fixtures.json` & Stage 7b Python)

    public struct SemanticSlot: Codable, Equatable, Sendable {
        public let slotIndex: Int
        public let exerciseId: String
        public let mode: String

        public init(slotIndex: Int, exerciseId: String, mode: String) {
            self.slotIndex = slotIndex
            self.exerciseId = exerciseId
            self.mode = mode
        }
    }

    public struct SemanticDay: Codable, Equatable, Sendable {
        public let date: String
        public let routineId: String?
        public let locked: CoachContext.LockReason?
        public let isRest: Bool
        public let isQueueSession: Bool
        public let exercises: [SemanticSlot]

        public init(
            date: String,
            routineId: String?,
            locked: CoachContext.LockReason?,
            isRest: Bool,
            isQueueSession: Bool,
            exercises: [SemanticSlot]
        ) {
            self.date = date
            self.routineId = routineId
            self.locked = locked
            self.isRest = isRest
            self.isQueueSession = isQueueSession
            self.exercises = exercises
        }
    }

    public struct SemanticRoutineAlias: Codable, Equatable, Sendable {
        public let alias: String
        public let id: String

        public init(alias: String, id: String) {
            self.alias = alias
            self.id = id
        }
    }

    public struct SemanticExerciseAlias: Codable, Equatable, Sendable {
        public let alias: String
        public let id: String
        public let mode: String

        public init(alias: String, id: String, mode: String) {
            self.alias = alias
            self.id = id
            self.mode = mode
        }
    }

    public struct SemanticContext: Codable, Equatable, Sendable {
        public let today: String
        public let mode: String
        public let rotationOnDate: String?
        public let days: [SemanticDay]
        public let routineAliases: [SemanticRoutineAlias]
        public let exerciseAliases: [SemanticExerciseAlias]

        public init(
            today: String,
            mode: String,
            rotationOnDate: String?,
            days: [SemanticDay],
            routineAliases: [SemanticRoutineAlias],
            exerciseAliases: [SemanticExerciseAlias]
        ) {
            self.today = today
            self.mode = mode
            self.rotationOnDate = rotationOnDate
            self.days = days
            self.routineAliases = routineAliases
            self.exerciseAliases = exerciseAliases
        }
    }

    // MARK: - Operations & Errors

    public enum CollisionMode: String, Codable, Equatable, Sendable {
        case swap
        case replace
    }

    public enum Op: Equatable, Sendable {
        case moveDay(from: String, to: String, collision: CollisionMode, reason: String?)
        case skip(date: String, reason: String?)
        case swapExercise(
            date: String,
            routineId: String,
            slotIndex: Int,
            fromExerciseId: String,
            toExerciseId: String,
            sets: Int?,
            reps: Int?,
            reason: String?
        )
        case setSets(
            date: String,
            routineId: String,
            slotIndex: Int,
            exerciseId: String,
            sets: Int,
            reps: Int?,
            reason: String?
        )
        case add(
            date: String,
            routineId: String,
            exerciseId: String,
            sets: Int,
            reps: Int?,
            slotIndex: Int?,
            reason: String?
        )

        public var touchedDates: [String] {
            switch self {
            case .moveDay(let from, let to, _, _): [from, to]
            case .skip(let date, _): [date]
            case .swapExercise(let date, _, _, _, _, _, _, _): [date]
            case .setSets(let date, _, _, _, _, _, _): [date]
            case .add(let date, _, _, _, _, _, _): [date]
            }
        }

        public var reason: String? {
            switch self {
            case .moveDay(_, _, _, let r),
                 .skip(_, let r),
                 .swapExercise(_, _, _, _, _, _, _, let r),
                 .setSets(_, _, _, _, _, _, let r),
                 .add(_, _, _, _, _, _, let r):
                return r
            }
        }
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case tooManyOps(count: Int)
        case invalidSchema(String)
        case invalidDate(String)
        case dateOutOfWindow(date: String, today: String)
        case sameSourceAndTarget(date: String)
        case disallowedInRotationMode(detail: String)
        case lockedDate(date: String, reason: CoachContext.LockReason)
        case nothingToMove(date: String)
        case noRoutineOnDate(date: String)
        case unknownRoutine(String)
        case unknownExercise(String)
        case routineMismatch(date: String, expected: String, actual: String)
        case invalidSlotIndex(date: String, slotIndex: Int, count: Int)
        case exerciseMismatch(date: String, slotIndex: Int, expected: String, actual: String)
        case sameExerciseSwap(String)
        case invalidSets(Int)
        case invalidReps(Int)
        case repsNotApplicable(exerciseId: String, mode: String)
        case stalePlan(changedDates: [String])
        case todayShifted(expected: String, actual: String)
        case duplicateAcceptToken(String)
        case unexpectedSideEffect(dates: [String])

        /// Stable machine-readable error code shared across Swift tests and Stage 7b Python fixtures.
        public var code: String {
            switch self {
            case .tooManyOps: "too_many_ops"
            case .invalidSchema: "invalid_schema"
            case .invalidDate: "invalid_date"
            case .dateOutOfWindow: "date_out_of_window"
            case .sameSourceAndTarget: "same_source_and_target"
            case .disallowedInRotationMode: "disallowed_in_rotation_mode"
            case .lockedDate: "locked_date"
            case .nothingToMove: "nothing_to_move"
            case .noRoutineOnDate: "no_routine_on_date"
            case .unknownRoutine: "unknown_routine"
            case .unknownExercise: "unknown_exercise"
            case .routineMismatch: "routine_mismatch"
            case .invalidSlotIndex: "invalid_slot_index"
            case .exerciseMismatch: "exercise_mismatch"
            case .sameExerciseSwap: "same_exercise_swap"
            case .invalidSets: "invalid_sets"
            case .invalidReps: "invalid_reps"
            case .repsNotApplicable: "reps_not_applicable"
            case .stalePlan: "stale_plan"
            case .todayShifted: "today_shifted"
            case .duplicateAcceptToken: "duplicate_accept_token"
            case .unexpectedSideEffect: "unexpected_side_effect"
            }
        }
    }

    // MARK: - Diff & Preview Models (Display-Name-Free; UI Resolves Names on @MainActor)

    public enum LoadSeed: Equatable, Sendable {
        case prefill(weight: Double, unit: String)
        case bodyweight
        case blank
    }

    public enum SlotChange: Equatable, Sendable {
        case swapped(
            slotIndex: Int,
            fromExerciseId: String,
            toExerciseId: String,
            sets: Int,
            reps: Int?,
            droppedProgrammePct: Double?,
            gainedProgrammePct: Double?,
            loadSeed: LoadSeed
        )
        case setsChanged(
            slotIndex: Int,
            exerciseId: String,
            beforeSets: Int,
            afterSets: Int,
            beforeReps: Int?,
            afterReps: Int?
        )
        case added(
            slotIndex: Int,
            exerciseId: String,
            sets: Int,
            reps: Int?,
            loadSeed: LoadSeed
        )
    }

    public struct DaySummary: Equatable, Sendable {
        public let isRest: Bool
        public let routineId: String?
        public let isAIClone: Bool
        public let exerciseCount: Int

        public init(isRest: Bool, routineId: String?, isAIClone: Bool, exerciseCount: Int) {
            self.isRest = isRest
            self.routineId = routineId
            self.isAIClone = isAIClone
            self.exerciseCount = exerciseCount
        }
    }

    public struct DayDiff: Equatable, Sendable, Identifiable {
        public var id: String { date }
        public let date: String
        public let before: DaySummary
        public let after: DaySummary
        public let slotChanges: [SlotChange]
        public let reasons: [String]
        public let programmeWeekChanged: Bool
    }

    public struct Preview: Equatable, Sendable {
        public let ops: [Op]
        public let today: String
        public let touchedDates: [String]
        public let expectedDigests: [String: String]
        public let dayDiffs: [DayDiff]
        public let compiledDayPlan: [String: JSONValue]
        public let createdClones: [String: Object]
        /// Internal expected final state per touched date for post-compile re-verification in `apply`.
        let expectedFinalStates: [String: ExpectedDayState]

        public var hasChanges: Bool {
            !compiledDayPlan.isEmpty
        }
    }

    struct ExpectedDayState: Equatable, Sendable {
        let isRest: Bool
        let canonicalRoutineId: String?
        let functionalEx: [Object]
    }

    // MARK: - Strict Date & Schema Parsing (`shared/coach_ops.schema.json` parity)

    /// Matches `^\d{4}-\d{2}-\d{2}$` strictly (rejecting `"2026-1-012"` or `"+026-11-26"`).
    public static func matchesISOPattern(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count == 10 else { return false }
        let dash = UInt8(ascii: "-")
        guard bytes[4] == dash, bytes[7] == dash else { return false }
        for idx in [0, 1, 2, 3, 5, 6, 8, 9] {
            let b = bytes[idx]
            if b < UInt8(ascii: "0") || b > UInt8(ascii: "9") { return false }
        }
        return true
    }

    /// Strict Gregorian calendar date validation: regex + `Day.date` round-trip (`Day.iso`).
    public static func isValidCalendarISO(_ s: String) -> Bool {
        guard matchesISOPattern(s), let d = Day.date(s) else { return false }
        return Day.iso(d) == s
    }

    /// Parses and validates raw JSON ops strictly against `shared/coach_ops.schema.json` rules
    /// (schema layer only — no calendar/window/context checks).
    public static func parseSchemaOps(_ rawOps: [JSONValue]) throws -> [Op] {
        guard rawOps.count <= maxBatchOps else {
            throw ValidationError.tooManyOps(count: rawOps.count)
        }
        var out: [Op] = []
        out.reserveCapacity(rawOps.count)
        for (idx, item) in rawOps.enumerated() {
            guard let obj = item.object else {
                throw ValidationError.invalidSchema("op[\(idx)] must be an object")
            }
            guard let type = obj["type"]?.stringValue else {
                throw ValidationError.invalidSchema("op[\(idx)] missing string type")
            }
            switch type {
            case "move_day":
                try assertAllowedKeys(obj, allowed: ["type", "from", "to", "collision", "reason"], idx: idx)
                let from = try requireISOPattern(obj["from"], field: "from", idx: idx)
                let to = try requireISOPattern(obj["to"], field: "to", idx: idx)
                guard let collStr = obj["collision"]?.stringValue,
                      let collision = CollisionMode(rawValue: collStr) else {
                    throw ValidationError.invalidSchema("op[\(idx)].collision must be swap or replace")
                }
                let reason = try parseOptionalReason(obj["reason"], idx: idx)
                out.append(.moveDay(from: from, to: to, collision: collision, reason: reason))

            case "skip":
                try assertAllowedKeys(obj, allowed: ["type", "date", "reason"], idx: idx)
                let date = try requireISOPattern(obj["date"], field: "date", idx: idx)
                let reason = try parseOptionalReason(obj["reason"], idx: idx)
                out.append(.skip(date: date, reason: reason))

            case "swap_exercise":
                try assertAllowedKeys(
                    obj,
                    allowed: ["type", "date", "routineId", "slotIndex", "fromExerciseId", "toExerciseId", "sets", "reps", "reason"],
                    idx: idx
                )
                let date = try requireISOPattern(obj["date"], field: "date", idx: idx)
                let routineId = try requireEntityId(obj["routineId"], field: "routineId", idx: idx)
                let slotIndex = try requireInteger(obj["slotIndex"], field: "slotIndex", min: 0, max: maxSlotIndex, idx: idx)
                let fromId = try requireEntityId(obj["fromExerciseId"], field: "fromExerciseId", idx: idx)
                let toId = try requireEntityId(obj["toExerciseId"], field: "toExerciseId", idx: idx)
                let sets = try parseOptionalInteger(obj["sets"], field: "sets", min: minSets, max: maxSets, idx: idx)
                let reps = try parseOptionalInteger(obj["reps"], field: "reps", min: minReps, max: maxReps, idx: idx)
                let reason = try parseOptionalReason(obj["reason"], idx: idx)
                out.append(.swapExercise(
                    date: date,
                    routineId: routineId,
                    slotIndex: slotIndex,
                    fromExerciseId: fromId,
                    toExerciseId: toId,
                    sets: sets,
                    reps: reps,
                    reason: reason
                ))

            case "set_sets":
                try assertAllowedKeys(
                    obj,
                    allowed: ["type", "date", "routineId", "slotIndex", "exerciseId", "sets", "reps", "reason"],
                    idx: idx
                )
                let date = try requireISOPattern(obj["date"], field: "date", idx: idx)
                let routineId = try requireEntityId(obj["routineId"], field: "routineId", idx: idx)
                let slotIndex = try requireInteger(obj["slotIndex"], field: "slotIndex", min: 0, max: maxSlotIndex, idx: idx)
                let exerciseId = try requireEntityId(obj["exerciseId"], field: "exerciseId", idx: idx)
                let sets = try requireInteger(obj["sets"], field: "sets", min: minSets, max: maxSets, idx: idx)
                let reps = try parseOptionalInteger(obj["reps"], field: "reps", min: minReps, max: maxReps, idx: idx)
                let reason = try parseOptionalReason(obj["reason"], idx: idx)
                out.append(.setSets(
                    date: date,
                    routineId: routineId,
                    slotIndex: slotIndex,
                    exerciseId: exerciseId,
                    sets: sets,
                    reps: reps,
                    reason: reason
                ))

            case "add":
                try assertAllowedKeys(
                    obj,
                    allowed: ["type", "date", "routineId", "exerciseId", "sets", "reps", "slotIndex", "reason"],
                    idx: idx
                )
                let date = try requireISOPattern(obj["date"], field: "date", idx: idx)
                let routineId = try requireEntityId(obj["routineId"], field: "routineId", idx: idx)
                let exerciseId = try requireEntityId(obj["exerciseId"], field: "exerciseId", idx: idx)
                let sets = try requireInteger(obj["sets"], field: "sets", min: minSets, max: maxSets, idx: idx)
                let reps = try parseOptionalInteger(obj["reps"], field: "reps", min: minReps, max: maxReps, idx: idx)
                let slotIndex = try parseOptionalInteger(obj["slotIndex"], field: "slotIndex", min: 0, max: maxSlotIndex, idx: idx)
                let reason = try parseOptionalReason(obj["reason"], idx: idx)
                out.append(.add(
                    date: date,
                    routineId: routineId,
                    exerciseId: exerciseId,
                    sets: sets,
                    reps: reps,
                    slotIndex: slotIndex,
                    reason: reason
                ))

            default:
                throw ValidationError.invalidSchema("op[\(idx)].type '\(type)' is unknown")
            }
        }
        return out
    }

    // MARK: - Portable Sequential Semantic Validator (Single Validation Path — Build Note 2)

    private struct MutableSemanticDay {
        var routineId: String?
        let locked: CoachContext.LockReason?
        var isRest: Bool
        var isQueueSession: Bool
        var exercises: [(exerciseId: String, mode: String)]
    }

    /// Runs sequential all-or-nothing semantic validation against a portable `SemanticContext`.
    /// Called directly by `preview` AND by the shared `semantic` fixture test suite.
    public static func validateSemantic(_ ops: [Op], against context: SemanticContext) throws {
        guard ops.count <= maxBatchOps else {
            throw ValidationError.tooManyOps(count: ops.count)
        }
        guard isValidCalendarISO(context.today),
              let maxDate = Day.adding(maxWindowDays, to: context.today) else {
            throw ValidationError.invalidDate(context.today)
        }

        let validRoutines = Set(context.routineAliases.map(\.id))
        let exerciseModes = Dictionary(uniqueKeysWithValues: context.exerciseAliases.map { ($0.id, $0.mode) })

        var sim: [String: MutableSemanticDay] = [:]
        for d in context.days {
            sim[d.date] = MutableSemanticDay(
                routineId: d.routineId,
                locked: d.locked,
                isRest: d.isRest,
                isQueueSession: d.isQueueSession,
                exercises: d.exercises.sorted { $0.slotIndex < $1.slotIndex }.map { ($0.exerciseId, $0.mode) }
            )
        }

        func validateWindowDate(_ iso: String) throws {
            guard isValidCalendarISO(iso) else {
                throw ValidationError.invalidDate(iso)
            }
            guard iso >= context.today && iso <= maxDate else {
                throw ValidationError.dateOutOfWindow(date: iso, today: context.today)
            }
        }

        func dayState(_ iso: String) -> MutableSemanticDay {
            sim[iso] ?? MutableSemanticDay(routineId: nil, locked: nil, isRest: true, isQueueSession: false, exercises: [])
        }

        func assertUnlocked(_ iso: String) throws {
            if let reason = dayState(iso).locked {
                throw ValidationError.lockedDate(date: iso, reason: reason)
            }
        }

        func assertRotationDateAllowed(_ iso: String, state: MutableSemanticDay) throws {
            guard context.mode == "rotation" else { return }
            if state.isQueueSession || state.isRest {
                guard let onDate = context.rotationOnDate, iso == onDate else {
                    throw ValidationError.disallowedInRotationMode(
                        detail: "Rotation mode only allows queue-session edits on \(context.rotationOnDate ?? "none")."
                    )
                }
            }
        }

        for op in ops {
            switch op {
            case .moveDay(let from, let to, let collision, _):
                try validateWindowDate(from)
                try validateWindowDate(to)
                guard from != to else { throw ValidationError.sameSourceAndTarget(date: from) }
                if context.mode == "rotation" {
                    throw ValidationError.disallowedInRotationMode(detail: "move_day is disallowed in rotation mode.")
                }
                try assertUnlocked(from)
                try assertUnlocked(to)
                let src = dayState(from)
                let dst = dayState(to)
                guard !src.isRest, src.routineId != nil else {
                    throw ValidationError.nothingToMove(date: from)
                }
                switch collision {
                case .swap:
                    sim[to] = MutableSemanticDay(
                        routineId: src.routineId,
                        locked: dst.locked,
                        isRest: src.isRest,
                        isQueueSession: src.isQueueSession,
                        exercises: src.exercises
                    )
                    sim[from] = MutableSemanticDay(
                        routineId: dst.routineId,
                        locked: src.locked,
                        isRest: dst.isRest,
                        isQueueSession: dst.isQueueSession,
                        exercises: dst.exercises
                    )
                case .replace:
                    sim[to] = MutableSemanticDay(
                        routineId: src.routineId,
                        locked: dst.locked,
                        isRest: src.isRest,
                        isQueueSession: src.isQueueSession,
                        exercises: src.exercises
                    )
                    sim[from] = MutableSemanticDay(
                        routineId: nil,
                        locked: src.locked,
                        isRest: true,
                        isQueueSession: false,
                        exercises: []
                    )
                }

            case .skip(let date, _):
                try validateWindowDate(date)
                try assertUnlocked(date)
                let st = dayState(date)
                try assertRotationDateAllowed(date, state: st)
                guard !st.isRest, st.routineId != nil else {
                    throw ValidationError.noRoutineOnDate(date: date)
                }
                sim[date] = MutableSemanticDay(
                    routineId: nil,
                    locked: st.locked,
                    isRest: true,
                    isQueueSession: false,
                    exercises: []
                )

            case .swapExercise(let date, let routineId, let slotIndex, let fromEx, let toEx, let sets, let reps, _):
                try validateWindowDate(date)
                if let sets, !(minSets...maxSets).contains(sets) { throw ValidationError.invalidSets(sets) }
                if let reps, !(minReps...maxReps).contains(reps) { throw ValidationError.invalidReps(reps) }
                guard fromEx != toEx else { throw ValidationError.sameExerciseSwap(fromEx) }
                try assertUnlocked(date)
                var st = dayState(date)
                try assertRotationDateAllowed(date, state: st)
                guard validRoutines.contains(routineId) else { throw ValidationError.unknownRoutine(routineId) }
                guard let toMode = exerciseModes[toEx] else { throw ValidationError.unknownExercise(toEx) }
                guard !st.isRest, let actualRid = st.routineId else {
                    throw ValidationError.noRoutineOnDate(date: date)
                }
                guard actualRid == routineId else {
                    throw ValidationError.routineMismatch(date: date, expected: routineId, actual: actualRid)
                }
                guard slotIndex >= 0 && slotIndex < st.exercises.count else {
                    throw ValidationError.invalidSlotIndex(date: date, slotIndex: slotIndex, count: st.exercises.count)
                }
                let actualEx = st.exercises[slotIndex].exerciseId
                guard actualEx == fromEx else {
                    throw ValidationError.exerciseMismatch(date: date, slotIndex: slotIndex, expected: fromEx, actual: actualEx)
                }
                if reps != nil && toMode != "reps" {
                    throw ValidationError.repsNotApplicable(exerciseId: toEx, mode: toMode)
                }
                st.exercises[slotIndex] = (toEx, toMode)
                sim[date] = st

            case .setSets(let date, let routineId, let slotIndex, let exerciseId, let sets, let reps, _):
                try validateWindowDate(date)
                guard (minSets...maxSets).contains(sets) else { throw ValidationError.invalidSets(sets) }
                if let reps, !(minReps...maxReps).contains(reps) { throw ValidationError.invalidReps(reps) }
                try assertUnlocked(date)
                let st = dayState(date)
                try assertRotationDateAllowed(date, state: st)
                guard validRoutines.contains(routineId) else { throw ValidationError.unknownRoutine(routineId) }
                guard !st.isRest, let actualRid = st.routineId else {
                    throw ValidationError.noRoutineOnDate(date: date)
                }
                guard actualRid == routineId else {
                    throw ValidationError.routineMismatch(date: date, expected: routineId, actual: actualRid)
                }
                guard slotIndex >= 0 && slotIndex < st.exercises.count else {
                    throw ValidationError.invalidSlotIndex(date: date, slotIndex: slotIndex, count: st.exercises.count)
                }
                let slot = st.exercises[slotIndex]
                guard slot.exerciseId == exerciseId else {
                    throw ValidationError.exerciseMismatch(date: date, slotIndex: slotIndex, expected: exerciseId, actual: slot.exerciseId)
                }
                if reps != nil && slot.mode != "reps" {
                    throw ValidationError.repsNotApplicable(exerciseId: exerciseId, mode: slot.mode)
                }

            case .add(let date, let routineId, let exerciseId, let sets, let reps, let slotIndex, _):
                try validateWindowDate(date)
                guard (minSets...maxSets).contains(sets) else { throw ValidationError.invalidSets(sets) }
                if let reps, !(minReps...maxReps).contains(reps) { throw ValidationError.invalidReps(reps) }
                try assertUnlocked(date)
                var st = dayState(date)
                try assertRotationDateAllowed(date, state: st)
                guard validRoutines.contains(routineId) else { throw ValidationError.unknownRoutine(routineId) }
                guard let exMode = exerciseModes[exerciseId] else { throw ValidationError.unknownExercise(exerciseId) }
                guard !st.isRest, let actualRid = st.routineId else {
                    throw ValidationError.noRoutineOnDate(date: date)
                }
                guard actualRid == routineId else {
                    throw ValidationError.routineMismatch(date: date, expected: routineId, actual: actualRid)
                }
                if reps != nil && exMode != "reps" {
                    throw ValidationError.repsNotApplicable(exerciseId: exerciseId, mode: exMode)
                }
                let insertAt = slotIndex ?? st.exercises.count
                guard insertAt >= 0 && insertAt <= st.exercises.count && st.exercises.count <= maxSlotIndex else {
                    throw ValidationError.invalidSlotIndex(date: date, slotIndex: insertAt, count: st.exercises.count)
                }
                st.exercises.insert((exerciseId, exMode), at: insertAt)
                sim[date] = st
            }
        }
    }

    // MARK: - Snapshot-Anchored Preview & Minimal Clone-and-Pin Compiler

    private struct SimDay {
        let date: String
        let initialCanonicalId: String?
        let initialActiveId: String?
        let initialIsClone: Bool
        let initialFunctionalEx: [Object]
        let initialIsRest: Bool

        var canonicalId: String?
        var activeId: String?
        var isClone: Bool
        var ex: [Object]
        var isRest: Bool
        var modifiedExercises: Bool
        var movedFromDate: String?
        var slotChanges: [SlotChange]
        var reasons: [String]
        var programmeWeekChanged: Bool
    }

    /// Validates `ops` against `snapshot` and `root`, simulates all 15 days sequentially, compiles
    /// minimal `dayPlan` pins + `aiClone` routines, and runs 15-day post-compile verification.
    public static func preview(
        ops: [Op],
        snapshot: CoachContext.Snapshot,
        root: Object,
        today: String,
        catalog: ExerciseCatalog,
        cloneToken: (Int) -> String = { _ in RoutineOps.newId() }
    ) throws -> Preview {
        // 1. Snapshot-anchored day and staleness guards (R2).
        guard snapshot.today == today else {
            throw ValidationError.todayShifted(expected: snapshot.today, actual: today)
        }
        // Single validation path (Build Note 2): run portable semantic validator first.
        try validateSemantic(ops, against: snapshot.semanticContext)

        let touchedSet = Set(ops.flatMap(\.touchedDates))
        let touchedDates = touchedSet.sorted()

        var expectedDigests: [String: String] = [:]
        var staleDates: [String] = []
        for date in touchedDates {
            guard let snapDay = snapshot.day(for: date) else {
                throw ValidationError.dateOutOfWindow(date: date, today: today)
            }
            expectedDigests[date] = snapDay.digest
            let liveDigest = CoachContext.dayDigest(root, date: date, today: today)
            if liveDigest != snapDay.digest {
                staleDates.append(date)
            }
        }
        if !staleDates.isEmpty {
            throw ValidationError.stalePlan(changedDates: staleDates)
        }

        // 2. Build root-level mutable simulation over the 15-day window.
        let windowDates: [String] = (0...maxWindowDays).compactMap { Day.adding($0, to: today) }
        let allRoutines = (root["routines"]?.arrayValue ?? []).compactMap(\.object)
        let routinesById = Dictionary(allRoutines.compactMap { r in
            r["id"]?.stringValue.map { ($0, r) }
        }, uniquingKeysWith: { first, _ in first })

        var sim: [String: SimDay] = [:]
        for date in windowDates {
            let ids = Schedule.routineIds(root, on: date, today: today)
            if ids.count == 1, let rid = ids.first, let rObj = routinesById[rid] {
                let ex = CoachContext.functionalEx(of: rObj)
                let canonicalId = Schedule.canonical(root, rid)
                let isClone = RoutineOps.isAIClone(rObj)
                let isRest = ex.isEmpty
                sim[date] = SimDay(
                    date: date,
                    initialCanonicalId: canonicalId,
                    initialActiveId: rid,
                    initialIsClone: isClone,
                    initialFunctionalEx: ex,
                    initialIsRest: isRest,
                    canonicalId: canonicalId,
                    activeId: rid,
                    isClone: isClone,
                    ex: ex,
                    isRest: isRest,
                    modifiedExercises: false,
                    movedFromDate: nil,
                    slotChanges: [],
                    reasons: [],
                    programmeWeekChanged: false
                )
            } else {
                sim[date] = SimDay(
                    date: date,
                    initialCanonicalId: nil,
                    initialActiveId: nil,
                    initialIsClone: false,
                    initialFunctionalEx: [],
                    initialIsRest: true,
                    canonicalId: nil,
                    activeId: nil,
                    isClone: false,
                    ex: [],
                    isRest: true,
                    modifiedExercises: false,
                    movedFromDate: nil,
                    slotChanges: [],
                    reasons: [],
                    programmeWeekChanged: false
                )
            }
        }

        // 3. Apply ops sequentially against root-level exercise slots.
        for op in ops {
            switch op {
            case .moveDay(let from, let to, let collision, let reason):
                guard var src = sim[from], var dst = sim[to] else { continue }
                let movedCanonical = src.canonicalId
                let movedActive = src.activeId
                let movedIsClone = src.isClone
                let movedEx = src.ex
                let movedIsRest = src.isRest
                let movedMod = src.modifiedExercises
                let weekChanged = movedCanonical.map {
                    programmeChangedBetween(root: root, canonicalRid: $0, ex: movedEx, from: from, to: to)
                } ?? false

                let prevDstCanonical = dst.canonicalId
                let prevDstActive = dst.activeId
                let prevDstIsClone = dst.isClone
                let prevDstEx = dst.ex
                let prevDstIsRest = dst.isRest
                let prevDstMod = dst.modifiedExercises

                dst.canonicalId = movedCanonical
                dst.activeId = movedActive
                dst.isClone = movedIsClone
                dst.ex = movedEx
                dst.isRest = movedIsRest
                dst.modifiedExercises = movedMod
                dst.movedFromDate = from
                if weekChanged { dst.programmeWeekChanged = true }
                if let reason, !reason.isEmpty { dst.reasons.append(reason) }

                switch collision {
                case .swap:
                    let backWeekChanged = prevDstCanonical.map {
                        programmeChangedBetween(root: root, canonicalRid: $0, ex: prevDstEx, from: to, to: from)
                    } ?? false
                    src.canonicalId = prevDstCanonical
                    src.activeId = prevDstActive
                    src.isClone = prevDstIsClone
                    src.ex = prevDstEx
                    src.isRest = prevDstIsRest
                    src.modifiedExercises = prevDstMod
                    src.movedFromDate = prevDstCanonical != nil ? to : nil
                    if backWeekChanged { src.programmeWeekChanged = true }
                case .replace:
                    src.canonicalId = nil
                    src.activeId = nil
                    src.isClone = false
                    src.ex = []
                    src.isRest = true
                    src.modifiedExercises = false
                    src.movedFromDate = nil
                }
                if let reason, !reason.isEmpty { src.reasons.append(reason) }
                sim[from] = src
                sim[to] = dst

            case .skip(let date, let reason):
                guard var day = sim[date] else { continue }
                day.canonicalId = nil
                day.activeId = nil
                day.isClone = false
                day.ex = []
                day.isRest = true
                day.modifiedExercises = false
                day.movedFromDate = nil
                if let reason, !reason.isEmpty { day.reasons.append(reason) }
                sim[date] = day

            case .swapExercise(let date, let routineId, let slotIndex, let fromEx, let toEx, let setsOverride, let repsOverride, let reason):
                guard var day = sim[date], slotIndex < day.ex.count else { continue }
                let oldSlot = day.ex[slotIndex]
                let oldMode = RoutineOps.mode(oldSlot, catalog: catalog)
                let oldSets = max(1, Int((oldSlot["sets"]?.numberValue ?? 3).rounded()))

                var newSlot = RoutineOps.pickedConfig(id: toEx, catalog: catalog)
                newSlot["id"] = .string(toEx)
                let newMode = RoutineOps.mode(newSlot, catalog: catalog)
                let finalSets = setsOverride ?? oldSets
                newSlot["sets"] = .number(Double(finalSets))

                let finalReps: Int?
                if newMode == "reps" {
                    if let repsOverride {
                        newSlot["reps"] = .number(Double(repsOverride))
                        finalReps = repsOverride
                    } else if oldMode == "reps", let prevReps = oldSlot["reps"]?.numberValue {
                        newSlot["reps"] = .number(prevReps)
                        finalReps = Int(prevReps.rounded())
                    } else {
                        finalReps = newSlot["reps"]?.numberValue.map { Int($0.rounded()) }
                    }
                } else {
                    newSlot["reps"] = nil
                    finalReps = nil
                }

                // Carry mode-agnostic superset and per-slot rest metadata (R5).
                for key in ["sg", "sgName", "sgRest", "rest", "restSec"] {
                    if let val = oldSlot[key], val != .null {
                        newSlot[key] = val
                    }
                }

                var exValues = day.ex.map(JSONValue.object)
                exValues[slotIndex] = .object(newSlot)
                RoutineOps.cleanupSupersets(&exValues)
                day.ex = exValues.compactMap(\.object).map(CoachContext.strippedSlot)
                day.modifiedExercises = true
                if let reason, !reason.isEmpty { day.reasons.append(reason) }

                let droppedPct = Programmes.slot(root, rid: routineId, exId: fromEx, iso: date)?.pct
                let gainedPct = Programmes.slot(root, rid: routineId, exId: toEx, iso: date)?.pct
                let seed = computeLoadSeed(
                    root: root,
                    canonicalRid: routineId,
                    simulatedEx: day.ex,
                    slotIndex: slotIndex,
                    exerciseId: toEx,
                    date: date,
                    catalog: catalog
                )
                day.slotChanges.append(.swapped(
                    slotIndex: slotIndex,
                    fromExerciseId: fromEx,
                    toExerciseId: toEx,
                    sets: finalSets,
                    reps: finalReps,
                    droppedProgrammePct: droppedPct,
                    gainedProgrammePct: gainedPct,
                    loadSeed: seed
                ))
                sim[date] = day

            case .setSets(let date, _, let slotIndex, let exerciseId, let sets, let repsOverride, let reason):
                guard var day = sim[date], slotIndex < day.ex.count else { continue }
                var slot = day.ex[slotIndex]
                let beforeSets = max(1, Int((slot["sets"]?.numberValue ?? 3).rounded()))
                let beforeReps = slot["reps"]?.numberValue.map { Int($0.rounded()) }
                slot["sets"] = .number(Double(sets))
                if let repsOverride {
                    slot["reps"] = .number(Double(repsOverride))
                }
                day.ex[slotIndex] = CoachContext.strippedSlot(slot)
                day.modifiedExercises = true
                if let reason, !reason.isEmpty { day.reasons.append(reason) }
                let afterReps = slot["reps"]?.numberValue.map { Int($0.rounded()) }
                day.slotChanges.append(.setsChanged(
                    slotIndex: slotIndex,
                    exerciseId: exerciseId,
                    beforeSets: beforeSets,
                    afterSets: sets,
                    beforeReps: beforeReps,
                    afterReps: afterReps
                ))
                sim[date] = day

            case .add(let date, let routineId, let exerciseId, let sets, let repsOverride, let slotIndex, let reason):
                guard var day = sim[date] else { continue }
                var newSlot = RoutineOps.pickedConfig(id: exerciseId, catalog: catalog)
                newSlot["id"] = .string(exerciseId)
                newSlot["sets"] = .number(Double(sets))
                let mode = RoutineOps.mode(newSlot, catalog: catalog)
                let finalReps: Int?
                if mode == "reps" {
                    if let repsOverride {
                        newSlot["reps"] = .number(Double(repsOverride))
                        finalReps = repsOverride
                    } else {
                        finalReps = newSlot["reps"]?.numberValue.map { Int($0.rounded()) }
                    }
                } else {
                    newSlot["reps"] = nil
                    finalReps = nil
                }

                let insertAt = slotIndex ?? day.ex.count
                var exValues = day.ex.map(JSONValue.object)
                exValues.insert(.object(newSlot), at: insertAt)
                RoutineOps.cleanupSupersets(&exValues)
                day.ex = exValues.compactMap(\.object).map(CoachContext.strippedSlot)
                day.modifiedExercises = true
                if let reason, !reason.isEmpty { day.reasons.append(reason) }

                let seed = computeLoadSeed(
                    root: root,
                    canonicalRid: routineId,
                    simulatedEx: day.ex,
                    slotIndex: insertAt,
                    exerciseId: exerciseId,
                    date: date,
                    catalog: catalog
                )
                day.slotChanges.append(.added(
                    slotIndex: insertAt,
                    exerciseId: exerciseId,
                    sets: sets,
                    reps: finalReps,
                    loadSeed: seed
                ))
                sim[date] = day
            }
        }

        // 4. Minimal Clone-and-Pin compilation (R6): only emit writes where final != initial.
        var existingIds = Set(allRoutines.compactMap { $0["id"]?.stringValue })
        var compiledDayPlan: [String: JSONValue] = [:]
        var createdClones: [String: Object] = [:]
        var dayDiffs: [DayDiff] = []
        var expectedFinalStates: [String: ExpectedDayState] = [:]
        var mintIndex = 0

        for date in touchedDates {
            guard let day = sim[date] else { continue }
            let changed = (day.isRest != day.initialIsRest)
                || (day.canonicalId != day.initialCanonicalId)
                || (day.ex != day.initialFunctionalEx)
            guard changed else { continue }

            expectedFinalStates[date] = ExpectedDayState(
                isRest: day.isRest,
                canonicalRoutineId: day.canonicalId,
                functionalEx: day.ex
            )

            let afterIsClone: Bool
            if day.isRest || day.canonicalId == nil {
                compiledDayPlan[date] = .string(Schedule.rest)
                afterIsClone = false
            } else if let canonicalId = day.canonicalId, let parent = routinesById[canonicalId] {
                let parentFunctionalEx = CoachContext.functionalEx(of: parent)
                let needsClone = (day.ex != parentFunctionalEx)
                if needsClone {
                    var candidateId: String
                    repeat {
                        let tok = cloneToken(mintIndex)
                        mintIndex += 1
                        candidateId = "ai-\(date)-\(tok)"
                    } while existingIds.contains(candidateId)
                    existingIds.insert(candidateId)

                    var clone = AIUndo.strippedMeta(parent)
                    clone["id"] = .string(candidateId)
                    clone["name"] = parent["name"] ?? .string("")
                    clone["ex"] = .array(day.ex.map(JSONValue.object))
                    clone["aiClone"] = .bool(true)
                    clone["cloneOf"] = .string(canonicalId)
                    clone["ephemeralDate"] = .string(date)

                    createdClones[candidateId] = clone
                    compiledDayPlan[date] = .string(candidateId)
                    afterIsClone = true
                } else {
                    compiledDayPlan[date] = .string(canonicalId)
                    afterIsClone = false
                }
            } else {
                continue
            }

            dayDiffs.append(DayDiff(
                date: date,
                before: DaySummary(
                    isRest: day.initialIsRest,
                    routineId: day.initialCanonicalId,
                    isAIClone: day.initialIsClone,
                    exerciseCount: day.initialFunctionalEx.count
                ),
                after: DaySummary(
                    isRest: day.isRest,
                    routineId: day.canonicalId,
                    isAIClone: afterIsClone,
                    exerciseCount: day.ex.count
                ),
                slotChanges: day.slotChanges,
                reasons: day.reasons,
                programmeWeekChanged: day.programmeWeekChanged
            ))
        }

        let effectiveTouched = compiledDayPlan.keys.sorted()
        let effectiveExpectedDigests = expectedDigests.filter { compiledDayPlan[$0.key] != nil }

        // 5. 15-day post-compile verification (R6).
        if !compiledDayPlan.isEmpty {
            try verifyPostCompile(
                baseRoot: root,
                compiledDayPlan: compiledDayPlan,
                createdClones: createdClones,
                expectedFinalStates: expectedFinalStates,
                today: today
            )
        }

        return Preview(
            ops: ops,
            today: today,
            touchedDates: effectiveTouched,
            expectedDigests: effectiveExpectedDigests,
            dayDiffs: dayDiffs,
            compiledDayPlan: compiledDayPlan,
            createdClones: createdClones,
            expectedFinalStates: expectedFinalStates
        )
    }

    // MARK: - Atomic Live Apply

    /// Atomically applies `preview` to live document `root` inside `model.change`.
    /// Returns `nil` with zero writes for net-zero/empty previews; otherwise returns an `AIUndoRecord`
    /// compatible with Stage 0's `AIUndo.apply`.
    public static func apply(
        _ preview: Preview,
        to root: inout Object,
        currentToday: String,
        acceptToken: String,
        acceptedAt: Double,
        appliedTokens: inout [String: String]
    ) throws -> AIUndoRecord? {
        // Bound `appliedTokens` to today's tokens (N5).
        appliedTokens = appliedTokens.filter { $0.value == currentToday }

        if !preview.hasChanges {
            return nil
        }

        guard appliedTokens[acceptToken] == nil else {
            throw ValidationError.duplicateAcceptToken(acceptToken)
        }
        guard currentToday == preview.today else {
            throw ValidationError.todayShifted(expected: preview.today, actual: currentToday)
        }

        var staleDates: [String] = []
        for date in preview.touchedDates {
            if root["active"]?.object?["d"] == .string(date) {
                throw ValidationError.lockedDate(date: date, reason: .active)
            }
            let liveDigest = CoachContext.dayDigest(root, date: date, today: currentToday)
            if liveDigest != preview.expectedDigests[date] {
                staleDates.append(date)
            }
        }
        if !staleDates.isEmpty {
            throw ValidationError.stalePlan(changedDates: staleDates)
        }

        // Re-run 15-day post-compile verification against the live document before mutating (R6).
        try verifyPostCompile(
            baseRoot: root,
            compiledDayPlan: preview.compiledDayPlan,
            createdClones: preview.createdClones,
            expectedFinalStates: preview.expectedFinalStates,
            today: currentToday
        )

        var dayPlan = root["dayPlan"]?.object ?? [:]
        var dayPlanDiffs: [String: DayPlanDiff] = [:]
        for date in preview.touchedDates {
            guard let nextVal = preview.compiledDayPlan[date] else { continue }
            dayPlanDiffs[date] = DayPlanDiff(before: dayPlan[date], after: nextVal)
            dayPlan[date] = nextVal
        }
        root["dayPlan"] = .object(dayPlan)

        if !preview.createdClones.isEmpty {
            var routines = root["routines"]?.arrayValue ?? []
            for cloneId in preview.createdClones.keys.sorted() {
                if let clone = preview.createdClones[cloneId] {
                    routines.append(.object(clone))
                }
            }
            root["routines"] = .array(routines)
        }

        appliedTokens[acceptToken] = currentToday

        let strippedClones = preview.createdClones.mapValues { AIUndo.strippedMeta($0) }
        return AIUndoRecord(
            tokenId: acceptToken,
            acceptedAt: acceptedAt,
            acceptedDay: currentToday,
            dayPlanDiffs: dayPlanDiffs,
            createdClones: strippedClones
        )
    }

    // MARK: - Internal Helpers

    private static func verifyPostCompile(
        baseRoot: Object,
        compiledDayPlan: [String: JSONValue],
        createdClones: [String: Object],
        expectedFinalStates: [String: ExpectedDayState],
        today: String
    ) throws {
        let windowDates = (0...maxWindowDays).compactMap { Day.adding($0, to: today) }

        func resolveDayState(_ s: Object, date: String) -> (ids: [String], canonicalIds: [String], functionalEx: [[Object]]) {
            let ids = Schedule.routineIds(s, on: date, today: today)
            let routines = (s["routines"]?.arrayValue ?? []).compactMap(\.object)
            let byId = Dictionary(routines.compactMap { r in
                r["id"]?.stringValue.map { ($0, r) }
            }, uniquingKeysWith: { first, _ in first })
            let canonicals = ids.map { Schedule.canonical(s, $0) }
            let exLists = ids.map { CoachContext.functionalEx(of: byId[$0]) }
            return (ids, canonicals, exLists)
        }

        var beforeByDate: [String: (ids: [String], canonicalIds: [String], functionalEx: [[Object]])] = [:]
        for d in windowDates {
            beforeByDate[d] = resolveDayState(baseRoot, date: d)
        }

        var testRoot = baseRoot
        var dp = testRoot["dayPlan"]?.object ?? [:]
        for (date, val) in compiledDayPlan {
            dp[date] = val
        }
        testRoot["dayPlan"] = .object(dp)
        if !createdClones.isEmpty {
            var routines = testRoot["routines"]?.arrayValue ?? []
            for id in createdClones.keys.sorted() {
                if let clone = createdClones[id] {
                    routines.append(.object(clone))
                }
            }
            testRoot["routines"] = .array(routines)
        }

        var badDates: [String] = []
        for d in windowDates {
            let after = resolveDayState(testRoot, date: d)
            if let expected = expectedFinalStates[d] {
                if expected.isRest {
                    let afterNonEmpty = after.functionalEx.contains { !$0.isEmpty }
                    if afterNonEmpty { badDates.append(d) }
                } else {
                    guard after.canonicalIds.count == 1,
                          after.canonicalIds[0] == expected.canonicalRoutineId,
                          after.functionalEx.count == 1,
                          after.functionalEx[0] == expected.functionalEx else {
                        badDates.append(d)
                        continue
                    }
                }
            } else if let before = beforeByDate[d] {
                if after.ids != before.ids || after.functionalEx != before.functionalEx {
                    badDates.append(d)
                }
            }
        }

        if !badDates.isEmpty {
            throw ValidationError.unexpectedSideEffect(dates: badDates)
        }
    }

    /// Computes initial load seed by running `Session.entries` on a simulation copy of `root` with
    /// `active` removed, canonical parent ID, and `today: date` (R5 & Build Note 5).
    private static func computeLoadSeed(
        root: Object,
        canonicalRid: String,
        simulatedEx: [Object],
        slotIndex: Int,
        exerciseId: String,
        date: String,
        catalog: ExerciseCatalog
    ) -> LoadSeed {
        var simRoot = root
        simRoot["active"] = nil

        let routines = (root["routines"]?.arrayValue ?? []).compactMap(\.object)
        var simRoutine = routines.first(where: { $0["id"] == .string(canonicalRid) }) ?? ["id": .string(canonicalRid)]
        simRoutine["id"] = .string(canonicalRid)
        simRoutine["ex"] = .array(simulatedEx.map(JSONValue.object))

        let entries = Session.entries(simRoot, routine: simRoutine, catalog: catalog, today: date)
        guard slotIndex < entries.count, let entry = entries[slotIndex].object else {
            return catalog[exerciseId]?.isBodyweightEquipment == true ? .bodyweight : .blank
        }

        let rows = (entry["sets"]?.arrayValue ?? []).compactMap(\.object)
        let firstWork = rows.first { !Recovery.isWarmupRow($0) }
        let weight = firstWork?["w"]?.numberValue ?? 0
        if weight > 0 {
            let unit = resolvedExerciseUnit(root, exerciseId: exerciseId)
            return .prefill(weight: weight, unit: unit)
        }
        if let cfg = simulatedEx[safe: slotIndex], RoutineOps.isBodyweight(cfg, catalog: catalog) {
            return .bodyweight
        }
        if catalog[exerciseId]?.isBodyweightEquipment == true {
            return .bodyweight
        }
        return .blank
    }

    private static func resolvedExerciseUnit(_ root: Object, exerciseId: String) -> String {
        if let raw = root["exUnit"]?.object?[exerciseId] {
            let candidate = raw.stringValue
                ?? raw.object?["v"]?.stringValue
                ?? raw.object?["u"]?.stringValue
                ?? raw.object?["unit"]?.stringValue
            if candidate == "lb" || candidate == "kg" {
                return candidate!
            }
        }
        return root["unit"] == .string("lb") ? "lb" : "kg"
    }

    private static func programmeChangedBetween(
        root: Object,
        canonicalRid: String,
        ex: [Object],
        from: String,
        to: String
    ) -> Bool {
        guard Programmes.status(root, today: from) != nil || Programmes.status(root, today: to) != nil else {
            return false
        }
        for slot in ex {
            guard let exId = slot["id"]?.stringValue else { continue }
            let a = Programmes.slot(root, rid: canonicalRid, exId: exId, iso: from)
            let b = Programmes.slot(root, rid: canonicalRid, exId: exId, iso: to)
            if a?.week != b?.week || a?.pct != b?.pct || a?.deload != b?.deload {
                return true
            }
        }
        return false
    }

    // MARK: - Strict JSON Field Parsers

    private static func assertAllowedKeys(_ obj: Object, allowed: Set<String>, idx: Int) throws {
        for key in obj.keys where !allowed.contains(key) {
            throw ValidationError.invalidSchema("op[\(idx)] contains unknown key '\(key)'")
        }
    }

    private static func requireISOPattern(_ val: JSONValue?, field: String, idx: Int) throws -> String {
        guard let s = val?.stringValue, matchesISOPattern(s) else {
            throw ValidationError.invalidSchema("op[\(idx)].\(field) must match YYYY-MM-DD")
        }
        return s
    }

    private static func requireEntityId(_ val: JSONValue?, field: String, idx: Int) throws -> String {
        guard let s = val?.stringValue else {
            throw ValidationError.invalidSchema("op[\(idx)].\(field) must be a string")
        }
        let len = s.unicodeScalars.count
        guard len >= 1 && len <= maxIdLength else {
            throw ValidationError.invalidSchema("op[\(idx)].\(field) length must be 1...\(maxIdLength)")
        }
        return s
    }

    private static func requireInteger(_ val: JSONValue?, field: String, min: Int, max: Int, idx: Int) throws -> Int {
        guard case .number(let d)? = val,
              d.isFinite,
              d.rounded(.towardZero) == d else {
            throw ValidationError.invalidSchema("op[\(idx)].\(field) must be an integer")
        }
        guard d >= Double(min) && d <= Double(max) else {
            throw ValidationError.invalidSchema("op[\(idx)].\(field)=\(d) out of range \(min)...\(max)")
        }
        return Int(d)
    }

    private static func parseOptionalInteger(_ val: JSONValue?, field: String, min: Int, max: Int, idx: Int) throws -> Int? {
        guard let val else { return nil }
        return try requireInteger(val, field: field, min: min, max: max, idx: idx)
    }

    private static func parseOptionalReason(_ val: JSONValue?, idx: Int) throws -> String? {
        guard let val else { return nil }
        guard let s = val.stringValue else {
            throw ValidationError.invalidSchema("op[\(idx)].reason must be a string")
        }
        guard s.unicodeScalars.count <= maxReasonCodePoints else {
            throw ValidationError.invalidSchema("op[\(idx)].reason exceeds \(maxReasonCodePoints) code points")
        }
        return s
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
