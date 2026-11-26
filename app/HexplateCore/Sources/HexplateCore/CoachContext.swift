import CryptoKit
import Foundation

/// `@MainActor`-safe compact context builder for the stateless AI Coach (`/api/ai/coach`) and
/// deterministic per-day plan digest calculator shared with `CoachOps`.
public enum CoachContext {
    public typealias Object = [String: JSONValue]

    public static let planWindowDays = 14
    public static let recentWorkoutDays = 14
    public static let maxCandidateExercises = 30

    private static let syncMetaKeys: Set<String> = ["_ts", "_f", "_u"]

    // MARK: - Types

    public enum LockReason: String, Codable, Equatable, Sendable {
        case active
        case logged
        case multi
        case orphan
    }

    public struct RoutineAlias: Codable, Equatable, Sendable {
        public let alias: String
        public let id: String
        public let name: String

        public init(alias: String, id: String, name: String) {
            self.alias = alias
            self.id = id
            self.name = name
        }
    }

    public struct ExerciseAlias: Codable, Equatable, Sendable {
        public let alias: String
        public let id: String
        public let name: String
        public let target: String?
        public let equipment: String?
        public let mode: String

        public init(alias: String, id: String, name: String, target: String?, equipment: String?, mode: String) {
            self.alias = alias
            self.id = id
            self.name = name
            self.target = target
            self.equipment = equipment
            self.mode = mode
        }
    }

    public struct SlotSummary: Codable, Equatable, Sendable {
        public let slotIndex: Int
        public let alias: String
        public let exerciseId: String
        public let name: String
        public let mode: String
        public let sets: Int
        public let reps: Int?
        public let sec: Int?
        public let hasProgrammePct: Bool

        public init(
            slotIndex: Int,
            alias: String,
            exerciseId: String,
            name: String,
            mode: String,
            sets: Int,
            reps: Int?,
            sec: Int?,
            hasProgrammePct: Bool
        ) {
            self.slotIndex = slotIndex
            self.alias = alias
            self.exerciseId = exerciseId
            self.name = name
            self.mode = mode
            self.sets = sets
            self.reps = reps
            self.sec = sec
            self.hasProgrammePct = hasProgrammePct
        }
    }

    public struct DayPlanEntry: Codable, Equatable, Sendable {
        public let date: String
        public let weekday: String
        public let digest: String
        public let locked: LockReason?
        public let isRest: Bool
        public let isAIClone: Bool
        public let isQueueSession: Bool
        public let routineAlias: String?
        public let routineId: String?
        public let routineName: String?
        public let exercises: [SlotSummary]

        public init(
            date: String,
            weekday: String,
            digest: String,
            locked: LockReason?,
            isRest: Bool,
            isAIClone: Bool,
            isQueueSession: Bool,
            routineAlias: String?,
            routineId: String?,
            routineName: String?,
            exercises: [SlotSummary]
        ) {
            self.date = date
            self.weekday = weekday
            self.digest = digest
            self.locked = locked
            self.isRest = isRest
            self.isAIClone = isAIClone
            self.isQueueSession = isQueueSession
            self.routineAlias = routineAlias
            self.routineId = routineId
            self.routineName = routineName
            self.exercises = exercises
        }
    }

    public struct WorkoutSummary: Codable, Equatable, Sendable {
        public let date: String
        public let name: String
        public let routineId: String?
        public let setsDone: Int
        public let volume: Double
        public let topMuscles: [String]
    }

    public struct MuscleRecoveryEntry: Codable, Equatable, Sendable {
        public let slug: String
        public let fatigue: Double
        public let hoursToRecovered: Double
    }

    public struct RecoverySummary: Codable, Equatable, Sendable {
        public let globalAcute: Double
        public let globalChronic: Double
        public let globalRatio: Double?
        public let recoveringMuscles: [MuscleRecoveryEntry]
    }

    public struct ReadinessSnapshot: Codable, Equatable, Sendable {
        public let verdict: String
        public let score: Int
        public let sleepHours: Double?
        public let hrvMs: Double?
        public let hrvDeltaPct: Double?
        public let rhrBpm: Double?
        public let rhrDeltaBpm: Double?
        public let missingSignals: [String]
        public let calibratingSignals: [String]
        public let sleepProvisional: Bool
    }

    public struct NutritionGoalsSnapshot: Codable, Equatable, Sendable {
        public let kcal: Double?
        public let protein: Double?
        public let proteinIsDerived: Bool
        public let carbs: Double?
        public let fat: Double?
        public let proteinPerKg: Double
        public let weightKgUsed: Double?
    }

    public struct NutritionSnapshot: Codable, Equatable, Sendable {
        public let hexplate: Nutrition.Macros
        /// `nil` when Apple Health is off, unavailable, or locked (never coerced to zero).
        public let external: Nutrition.Macros?
        public let total: Nutrition.Macros
        public let goals: NutritionGoalsSnapshot
    }

    public struct ProgrammeSummary: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let week: Int
        public let weeks: Int
        public let cycle: Int
        public let deload: Bool
        public let paused: Bool
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public let today: String
        public let timezone: String
        public let unit: String
        public let scheduleMode: String
        public let allowedOps: [String]
        public let rotationOnDate: String?
        public let rotationNote: String?
        public let activeProgramme: ProgrammeSummary?
        public let recentWorkouts: [WorkoutSummary]
        public let recovery: RecoverySummary
        public let readiness: ReadinessSnapshot?
        public let todayNutrition: NutritionSnapshot
        public let plan: [DayPlanEntry]
        public let routineAliases: [RoutineAlias]
        public let exerciseAliases: [ExerciseAlias]

        public var aliasToRoutineId: [String: String] {
            Dictionary(uniqueKeysWithValues: routineAliases.map { ($0.alias, $0.id) })
        }

        public var aliasToExerciseId: [String: String] {
            Dictionary(uniqueKeysWithValues: exerciseAliases.map { ($0.alias, $0.id) })
        }

        public func day(for date: String) -> DayPlanEntry? {
            plan.first { $0.date == date }
        }

        /// Portable semantic context shared with `CoachOps.validateSemantic` and Stage 7b server validation.
        public var semanticContext: CoachOps.SemanticContext {
            CoachOps.SemanticContext(
                today: today,
                mode: scheduleMode,
                rotationOnDate: rotationOnDate,
                days: plan.map { d in
                    CoachOps.SemanticDay(
                        date: d.date,
                        routineId: d.routineId,
                        locked: d.locked,
                        isRest: d.isRest,
                        isQueueSession: d.isQueueSession,
                        exercises: d.exercises.map { s in
                            CoachOps.SemanticSlot(
                                slotIndex: s.slotIndex,
                                exerciseId: s.exerciseId,
                                mode: s.mode
                            )
                        }
                    )
                },
                routineAliases: routineAliases.map { CoachOps.SemanticRoutineAlias(alias: $0.alias, id: $0.id) },
                exerciseAliases: exerciseAliases.map { CoachOps.SemanticExerciseAlias(alias: $0.alias, id: $0.id, mode: $0.mode) }
            )
        }

        /// Byte-stable JSON encoding (`.sortedKeys` + `.withoutEscapingSlashes`).
        public func encodedJSON() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }
    }

    // MARK: - Pure Nonisolated Helpers

    /// Strips sync metadata (`_ts`, `_f`, `_u`) from an exercise slot dictionary.
    public nonisolated static func strippedSlot(_ slot: Object) -> Object {
        slot.filter { !syncMetaKeys.contains($0.key) }
    }

    /// Functional exercise array of a routine (stripped of sync metadata).
    public nonisolated static func functionalEx(of routine: Object?) -> [Object] {
        (routine?["ex"]?.arrayValue ?? []).compactMap(\.object).map(strippedSlot)
    }

    /// Deterministic 16-hex-char SHA-256 digest of a day's effective plan and lock state.
    /// Single source of truth used by `CoachContext.build`, `CoachOps.preview`, and `CoachOps.apply`.
    public nonisolated static func dayDigest(_ root: Object, date: String, today: String) -> String {
        let mode = Schedule.scheduleMode(root)
        let resolvedIds = Schedule.routineIds(root, on: date, today: today)
        let allRoutines = (root["routines"]?.arrayValue ?? []).compactMap(\.object)
        let byId = Dictionary(allRoutines.compactMap { r in
            r["id"]?.stringValue.map { ($0, r) }
        }, uniquingKeysWith: { first, _ in first })

        let resolvedEx: [JSONValue] = resolvedIds.map { rid in
            let slots = functionalEx(of: byId[rid]).map(JSONValue.object)
            return .array(slots)
        }

        let isLogged = (root["workouts"]?.arrayValue ?? []).contains { $0.object?["d"] == .string(date) }
        let isActive = root["active"]?.object?["d"] == .string(date)

        let queueState: JSONValue
        if mode == "rotation", let q = Schedule.queue(root) {
            queueState = .object([
                "ids": .array(q.ids.map(JSONValue.string)),
                "remaining": .array(Schedule.queueRemaining(root).map(JSONValue.string)),
                "startsOn": .string(q.startsOn),
            ])
        } else {
            queueState = .null
        }

        let canonicalIds = resolvedIds.map { Schedule.canonical(root, $0) }
        let payload = JSONValue.object([
            "canonicalIds": .array(canonicalIds.map(JSONValue.string)),
            "isActive": .bool(isActive),
            "isLogged": .bool(isLogged),
            "queue": queueState,
            "rawDayPlan": root["dayPlan"]?.object?[date] ?? .null,
            "resolvedEx": .array(resolvedEx),
            "resolvedIds": .array(resolvedIds.map(JSONValue.string)),
            "scheduleMode": .string(mode),
        ])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = (try? encoder.encode(payload)) ?? Data()
        let digest = SHA256.hash(data: bytes)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Evaluates the lock status of `date` in `root` using strict precedence `active > logged > multi > orphan`.
    public nonisolated static func lockReason(_ root: Object, on date: String, today: String) -> LockReason? {
        if root["active"]?.object?["d"] == .string(date) { return .active }
        if (root["workouts"]?.arrayValue ?? []).contains(where: { $0.object?["d"] == .string(date) }) {
            return .logged
        }
        let ids = Schedule.routineIds(root, on: date, today: today)
        if ids.count > 1 { return .multi }
        if let single = ids.first {
            let routines = (root["routines"]?.arrayValue ?? []).compactMap(\.object)
            if let r = routines.first(where: { $0["id"] == .string(single) }),
               RoutineOps.isAIClone(r),
               Schedule.canonical(root, single) == single {
                return .orphan
            }
        }
        return nil
    }

    // MARK: - @MainActor Context Builder

    /// Builds a compact AI Coach context snapshot on `@MainActor` (ensuring `ExerciseNames.style`
    /// and `Exercise.displayName` are never read off the main actor).
    @MainActor
    public static func build(
        root: Object,
        today: String,
        timezone: String,
        readiness: Readiness.Result?,
        readinessSignals: Readiness.HealthSignals?,
        liveExternalNutrition: Nutrition.Macros?,
        catalog: ExerciseCatalog,
        now: Double? = nil
    ) -> Snapshot {
        let effectiveNow = now ?? (Day.noon(today).isFinite ? Day.noon(today) : Date().timeIntervalSince1970 * 1000)
        let settings = ProfileSettings(root)
        let scheduleMode = Schedule.scheduleMode(root)
        let allowedOps = scheduleMode == "rotation"
            ? ["skip", "swap_exercise", "set_sets", "add"]
            : ["move_day", "skip", "swap_exercise", "set_sets", "add"]

        let allRoutines = (root["routines"]?.arrayValue ?? []).compactMap(\.object)
        let routinesById = Dictionary(allRoutines.compactMap { r in
            r["id"]?.stringValue.map { ($0, r) }
        }, uniquingKeysWith: { first, _ in first })

        // 1. Routine alias table (R1...Rn for non-clone routines in document order).
        var routineAliases: [RoutineAlias] = []
        var routineIdToAlias: [String: String] = [:]
        for r in allRoutines where !RoutineOps.isAIClone(r) {
            guard let id = r["id"]?.stringValue, !id.isEmpty else { continue }
            let alias = "R\(routineAliases.count + 1)"
            let name = r["name"]?.stringValue ?? ""
            routineAliases.append(RoutineAlias(alias: alias, id: id, name: name))
            routineIdToAlias[id] = alias
        }

        // 2. Collect exercises already present in user routines / 15-day plan.
        let windowDates: [String] = (0...planWindowDays).compactMap { Day.adding($0, to: today) }
        var planExerciseOrder: [String] = []
        var planExerciseSet = Set<String>()
        var planHasCardio = false
        var planMuscleDemand: [String: Double] = [:]

        func registerPlanExercise(_ exId: String) {
            guard !exId.isEmpty else { return }
            if planExerciseSet.insert(exId).inserted {
                planExerciseOrder.append(exId)
            }
            if let ex = catalog[exId] {
                if ex.isCardio { planHasCardio = true }
                for (slug, w) in catalog.muscleWeights(of: ex) where w > 0 {
                    planMuscleDemand[slug, default: 0] += w
                }
            }
        }

        for r in allRoutines where !RoutineOps.isAIClone(r) {
            for slot in (r["ex"]?.arrayValue ?? []).compactMap(\.object) {
                if let exId = slot["id"]?.stringValue { registerPlanExercise(exId) }
            }
        }
        for d in windowDates {
            for rid in Schedule.routineIds(root, on: d, today: today) {
                for slot in (routinesById[rid]?["ex"]?.arrayValue ?? []).compactMap(\.object) {
                    if let exId = slot["id"]?.stringValue { registerPlanExercise(exId) }
                }
            }
        }

        // 3. Build exercise alias table: current plan exercises + up to 30 deterministic candidates
        // filtered via the real `ExerciseCatalog.activeProfile` / `equipment(of:)` / `isAvailable`.
        let activeEquipment: [String]? = ExerciseCatalog.activeProfile(root).map {
            ExerciseCatalog.equipment(of: $0)
        }

        var scoredCandidates: [(ex: Exercise, score: Double)] = []
        for ex in catalog.all {
            if planExerciseSet.contains(ex.id) { continue }
            if ex.isCardio && !planHasCardio { continue }
            if let activeEquipment, !catalog.isAvailable(ex, with: activeEquipment) { continue }

            let weights = catalog.muscleWeights(of: ex)
            var overlap = 0.0
            if planMuscleDemand.isEmpty {
                overlap = weights.values.reduce(0, +)
            } else {
                if let primary = catalog.primaryMuscle(of: ex), let demand = planMuscleDemand[primary] {
                    overlap += demand * 2.0
                }
                for (slug, w) in weights where w > 0 {
                    if let demand = planMuscleDemand[slug] {
                        overlap += w * demand
                    }
                }
            }
            if overlap > 0 {
                scoredCandidates.append((ex, overlap))
            }
        }
        scoredCandidates.sort { a, b in
            if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
            return a.ex.id < b.ex.id
        }

        var exerciseAliases: [ExerciseAlias] = []
        var exerciseIdToAlias: [String: String] = [:]

        func appendExerciseAlias(id: String, catalogEx: Exercise?) {
            guard exerciseIdToAlias[id] == nil else { return }
            let alias = "E\(exerciseAliases.count + 1)"
            let name = catalogEx?.displayName ?? id
            let target = catalogEx.flatMap { catalog.primaryMuscle(of: $0) } ?? catalogEx?.target
            let mode: String
            if let ex = catalogEx {
                if ex.isHold { mode = "time" }
                else if ex.isCardio { mode = "cardio" }
                else { mode = "reps" }
            } else {
                mode = "reps"
            }
            exerciseAliases.append(ExerciseAlias(
                alias: alias,
                id: id,
                name: name,
                target: target,
                equipment: catalogEx?.equipment,
                mode: mode
            ))
            exerciseIdToAlias[id] = alias
        }

        for exId in planExerciseOrder {
            appendExerciseAlias(id: exId, catalogEx: catalog[exId])
        }
        for candidate in scoredCandidates.prefix(maxCandidateExercises) {
            appendExerciseAlias(id: candidate.ex.id, catalogEx: candidate.ex)
        }

        // 4. Resolve 15-day plan (today ... today + 14d).
        let queue = Schedule.queue(root)
        let queueIdSet = Set(queue?.ids ?? [])
        let queueRemaining = Schedule.queueRemaining(root)
        let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

        var plan: [DayPlanEntry] = []
        for date in windowDates {
            let ids = Schedule.routineIds(root, on: date, today: today)
            let locked = lockReason(root, on: date, today: today)
            let digest = dayDigest(root, date: date, today: today)
            let weekdayIdx = Day.weekday(date) ?? 0
            let weekday = weekdayNames[max(0, min(6, weekdayIdx))]

            let nonEmptyIds = ids.filter { !(routinesById[$0]?["ex"]?.arrayValue ?? []).isEmpty }
            let isRest = nonEmptyIds.isEmpty

            if ids.count == 1, let rawId = ids.first, let routineObj = routinesById[rawId] {
                let canonicalId = Schedule.canonical(root, rawId)
                let isClone = RoutineOps.isAIClone(routineObj)
                let isQueueSession = (scheduleMode == "rotation") && queueIdSet.contains(canonicalId)
                let rawSlots = (routineObj["ex"]?.arrayValue ?? []).compactMap(\.object)

                let slots: [SlotSummary] = rawSlots.enumerated().map { idx, cfg in
                    let exId = cfg["id"]?.stringValue ?? ""
                    let alias = exerciseIdToAlias[exId] ?? exId
                    let exName = catalog[exId]?.displayName ?? cfg["name"]?.stringValue ?? exId
                    let slotMode = RoutineOps.mode(cfg, catalog: catalog)
                    let sets = max(1, Int((cfg["sets"]?.numberValue ?? 3).rounded()))
                    let reps: Int? = slotMode == "reps" ? cfg["reps"]?.numberValue.map { Int($0.rounded()) } : nil
                    let sec: Int? = slotMode == "time" ? cfg["sec"]?.numberValue.map { Int($0.rounded()) } : nil
                    let hasPct = Programmes.slot(root, rid: canonicalId, exId: exId, iso: date)?.pct != nil
                    return SlotSummary(
                        slotIndex: idx,
                        alias: alias,
                        exerciseId: exId,
                        name: exName,
                        mode: slotMode,
                        sets: sets,
                        reps: reps,
                        sec: sec,
                        hasProgrammePct: hasPct
                    )
                }

                plan.append(DayPlanEntry(
                    date: date,
                    weekday: weekday,
                    digest: digest,
                    locked: locked,
                    isRest: isRest,
                    isAIClone: isClone,
                    isQueueSession: isQueueSession,
                    routineAlias: routineIdToAlias[canonicalId],
                    routineId: canonicalId,
                    routineName: routineObj["name"]?.stringValue ?? "",
                    exercises: slots
                ))
            } else {
                // Rest day or multi-routine day (locked == .multi when ids.count > 1).
                let firstCanonical = ids.first.map { Schedule.canonical(root, $0) }
                let firstName = ids.compactMap { routinesById[$0]?["name"]?.stringValue }.joined(separator: " + ")
                plan.append(DayPlanEntry(
                    date: date,
                    weekday: weekday,
                    digest: digest,
                    locked: locked,
                    isRest: isRest,
                    isAIClone: false,
                    isQueueSession: false,
                    routineAlias: firstCanonical.flatMap { routineIdToAlias[$0] },
                    routineId: firstCanonical,
                    routineName: firstName.isEmpty ? nil : firstName,
                    exercises: []
                ))
            }
        }

        // 5. Rotation on-date & v1 limitation note (R1).
        var rotationOnDate: String? = nil
        var rotationNote: String? = nil
        if scheduleMode == "rotation" {
            rotationNote = "Rotation mode v1: move_day is unavailable, and queue-session edits apply only to the current next session date (future queue sessions cannot be re-dated)."
            if let q = queue, !queueRemaining.isEmpty {
                let on = today > q.startsOn ? today : q.startsOn
                if let entry = plan.first(where: { $0.date == on }),
                   entry.locked == nil,
                   entry.isQueueSession,
                   !entry.isRest {
                    rotationOnDate = on
                }
            }
        }

        // 6. Active Programme summary.
        let activeProgramme: ProgrammeSummary? = Programmes.status(root, today: today).flatMap { st in
            guard !st.done else { return nil }
            let id = st.programme["id"]?.stringValue ?? ""
            let name = st.programme["name"]?.stringValue ?? "Programme"
            let deload = st.current?["deload"] == .bool(true)
            return ProgrammeSummary(
                id: id,
                name: name,
                week: st.week,
                weeks: st.weeks,
                cycle: st.cycle,
                deload: deload,
                paused: st.paused
            )
        }

        // 7. Recent 14-day workouts summary (newest first).
        let minWorkoutDate = Day.adding(-(recentWorkoutDays - 1), to: today) ?? today
        let rawWeighIns: [JSONValue] = root["bodyweight"]?.arrayValue ?? []
        let weighIns: [WeighIn] = rawWeighIns.compactMap { try? $0.decoded(as: WeighIn.self) }
        let rawWorkouts: [JSONValue] = root["workouts"]?.arrayValue ?? []
        let allWorkouts: [Workout] = rawWorkouts.compactMap { try? $0.decoded(as: Workout.self) }
        let recentFiltered: [Workout] = allWorkouts.filter { $0.date >= minWorkoutDate && $0.date <= today }
        let decodedWorkouts: [Workout] = recentFiltered.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            return (a.start ?? 0) > (b.start ?? 0)
        }

        let recentWorkouts: [WorkoutSummary] = decodedWorkouts.map { w in
            var muscleSets: [String: Double] = [:]
            for e in w.entries {
                let doneCount = Double(e.sets.filter { $0.done && !$0.isWarmup }.count)
                guard doneCount > 0, let ex = catalog[e.exerciseId] else { continue }
                for (slug, wt) in catalog.muscleWeights(of: ex) where wt > 0 {
                    muscleSets[slug, default: 0] += doneCount * wt
                }
            }
            let topMuscles = muscleSets
                .sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
                .prefix(3)
                .map(\.key)
            return WorkoutSummary(
                date: w.date,
                name: w.name ?? "Workout",
                routineId: w.routineId,
                setsDone: WorkoutMath.setsDone(w),
                volume: (WorkoutMath.volume(w, settings: settings, catalog: catalog, weighIns: weighIns) * 10).rounded() / 10,
                topMuscles: topMuscles
            )
        }

        // 8. Recovery load summary.
        let load = Recovery.loadSummary(root, now: effectiveNow, catalog: catalog)
        let recoveringMuscles = load.muscles
            .filter { $0.value.fatigue > 0.35 }
            .sorted { a, b in
                if abs(a.value.fatigue - b.value.fatigue) > 1e-6 { return a.value.fatigue > b.value.fatigue }
                return a.key < b.key
            }
            .map { slug, detail in
                MuscleRecoveryEntry(
                    slug: slug,
                    fatigue: (detail.fatigue * 100).rounded() / 100,
                    hoursToRecovered: (detail.hoursToRecovered * 10).rounded() / 10
                )
            }
        let recoverySummary = RecoverySummary(
            globalAcute: (load.global.acute * 10).rounded() / 10,
            globalChronic: (load.global.chronic * 10).rounded() / 10,
            globalRatio: load.global.ratio.map { ($0 * 100).rounded() / 100 },
            recoveringMuscles: recoveringMuscles
        )

        // 9. Optional Readiness snapshot.
        let readinessSnapshot: ReadinessSnapshot? = readiness.map { res in
            let verdictText: String = switch res.verdict {
            case .good: "good"
            case .light: "light"
            case .rest: "rest"
            }
            func sigText(_ s: Readiness.SignalKind) -> String {
                switch s {
                case .sleep: "sleep"
                case .hrv: "hrv"
                case .rhr: "rhr"
                }
            }
            return ReadinessSnapshot(
                verdict: verdictText,
                score: res.score,
                sleepHours: readinessSignals?.sleep.map { ($0.totalHours * 10).rounded() / 10 },
                hrvMs: readinessSignals?.hrv?.latestMs.map { ($0 * 10).rounded() / 10 },
                hrvDeltaPct: readinessSignals?.hrv?.deltaPct.map { ($0 * 1000).rounded() / 1000 },
                rhrBpm: readinessSignals?.rhr?.latestBpm.map { ($0 * 10).rounded() / 10 },
                rhrDeltaBpm: readinessSignals?.rhr?.deltaBpm.map { ($0 * 10).rounded() / 10 },
                missingSignals: res.missingSignals.map(sigText),
                calibratingSignals: res.calibratingSignals.map(sigText),
                sleepProvisional: res.sleepProvisional
            )
        }

        // 10. Today nutrition snapshot (external stays `nil` when HealthKit off/unavailable).
        let dayTotals = Nutrition.dailyTotals(root, day: today, external: liveExternalNutrition)
        let goals = Nutrition.effectiveGoals(root)
        let nutritionSnapshot = NutritionSnapshot(
            hexplate: dayTotals.hexplate,
            external: liveExternalNutrition,
            total: dayTotals.total,
            goals: NutritionGoalsSnapshot(
                kcal: goals.kcal,
                protein: goals.protein,
                proteinIsDerived: goals.proteinIsDerived,
                carbs: goals.carbs,
                fat: goals.fat,
                proteinPerKg: goals.proteinPerKg,
                weightKgUsed: goals.weightKgUsed
            )
        )

        return Snapshot(
            today: today,
            timezone: timezone,
            unit: settings.unit,
            scheduleMode: scheduleMode,
            allowedOps: allowedOps,
            rotationOnDate: rotationOnDate,
            rotationNote: rotationNote,
            activeProgramme: activeProgramme,
            recentWorkouts: recentWorkouts,
            recovery: recoverySummary,
            readiness: readinessSnapshot,
            todayNutrition: nutritionSnapshot,
            plan: plan,
            routineAliases: routineAliases,
            exerciseAliases: exerciseAliases
        )
    }
}
