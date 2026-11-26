import XCTest
@testable import HexplateCore

@MainActor
final class CoachContextTests: XCTestCase {
    typealias Object = [String: JSONValue]

    private let catalog = ExerciseCatalog.builtIn

    private func exerciseId(matching predicate: (Exercise) -> Bool) -> String {
        catalog.all.first(where: predicate)!.id
    }

    func testBuildSnapshotIncludesTimezoneNutritionNilExternalIsRestAndRecentWorkouts() throws {
        let benchId = exerciseId { ($0.equipment == "barbell") && (catalog.primaryMuscle(of: $0) == "chest") }
        let today = "2026-11-26" // Thursday (weekday 4)
        let root: Object = [
            "unit": .string("kg"),
            "routines": .array([
                .object([
                    "id": .string("r-push"),
                    "name": .string("Push"),
                    "ex": .array([
                        .object(["id": .string(benchId), "sets": .number(4), "reps": .number(8)]),
                    ]),
                ]),
                .object([
                    "id": .string("r-empty"),
                    "name": .string("Empty Template"),
                    "ex": .array([]),
                ]),
            ]),
            "week": .object([
                "4": .array([.string("r-push")]),
                "5": .array([.string("r-empty")]),
            ]),
            "dayPlan": .object([:]),
            "workouts": .array([
                .object([
                    "id": .string("w1"),
                    "d": .string("2026-11-24"),
                    "start": .number(Day.noon("2026-11-24")),
                    "name": .string("Push"),
                    "routineId": .string("r-push"),
                    "entries": .array([
                        .object([
                            "id": .string(benchId),
                            "sets": .array([
                                .object(["w": .number(80), "r": .number(8), "done": .bool(true)]),
                            ]),
                        ]),
                    ]),
                ]),
                // Older than 14 days -> excluded from recentWorkouts
                .object([
                    "id": .string("w-old"),
                    "d": .string("2026-11-01"),
                    "start": .number(Day.noon("2026-11-01")),
                    "name": .string("Old"),
                    "entries": .array([]),
                ]),
            ]),
            "meals": .object([
                "m1": .object([
                    "id": .string("m1"),
                    "date": .string(today),
                    "name": .string("Lunch"),
                    "kcal": .number(600),
                    "protein": .number(45),
                    "source": .string("manual"),
                    "_ts": .number(1000),
                ]),
            ]),
        ]

        let snap = CoachContext.build(
            root: root,
            today: today,
            timezone: "Asia/Tokyo",
            readiness: nil,
            readinessSignals: nil,
            liveExternalNutrition: nil,
            catalog: catalog
        )

        XCTAssertEqual(snap.today, today)
        XCTAssertEqual(snap.timezone, "Asia/Tokyo")
        XCTAssertEqual(snap.scheduleMode, "week")
        XCTAssertEqual(snap.allowedOps, ["move_day", "skip", "swap_exercise", "set_sets", "add"])
        XCTAssertEqual(snap.plan.count, 15) // today ... today + 14d inclusive
        XCTAssertNil(snap.todayNutrition.external)
        XCTAssertEqual(snap.todayNutrition.hexplate.kcal, 600)
        XCTAssertEqual(snap.recentWorkouts.count, 1)
        XCTAssertEqual(snap.recentWorkouts.first?.date, "2026-11-24")

        // Day with non-empty routine is not rest; day with empty-ex routine counts as rest (N3).
        XCTAssertEqual(snap.day(for: "2026-11-26")?.isRest, false)
        XCTAssertEqual(snap.day(for: "2026-11-26")?.routineAlias, "R1")
        XCTAssertEqual(snap.day(for: "2026-11-27")?.isRest, true)

        // Byte-stable deterministic JSON encoding (Build Note 6).
        let json1 = try snap.encodedJSON()
        let json2 = try snap.encodedJSON()
        XCTAssertEqual(json1, json2)
    }

    func testLockPrecedenceActiveLoggedMultiOrphan() {
        let benchId = exerciseId { catalog.primaryMuscle(of: $0) == "chest" }
        let today = "2026-11-26" // Thu
        let root: Object = [
            "routines": .array([
                .object(["id": .string("r1"), "name": .string("Push"), "ex": .array([.object(["id": .string(benchId), "sets": .number(3)])])]),
                .object(["id": .string("r2"), "name": .string("Pull"), "ex": .array([.object(["id": .string(benchId), "sets": .number(3)])])]),
                .object([
                    "id": .string("ai-2026-11-29-x"),
                    "name": .string("Deleted Parent"),
                    "ex": .array([.object(["id": .string(benchId), "sets": .number(3)])]),
                    "aiClone": .bool(true),
                    "cloneOf": .string("r-deleted"),
                    "ephemeralDate": .string("2026-11-29"),
                ]),
            ]),
            "week": .object([
                "4": .array([.string("r1"), .string("r2")]), // active + logged + multi -> active wins
                "5": .array([.string("r1"), .string("r2")]), // logged + multi -> logged wins
                "6": .array([.string("r1"), .string("r2")]), // multi only -> multi
            ]),
            "dayPlan": .object([
                "2026-11-29": .string("ai-2026-11-29-x"), // orphan clone -> orphan
            ]),
            "active": .object(["d": .string("2026-11-26"), "id": .string("a1")]),
            "workouts": .array([
                .object(["id": .string("w1"), "d": .string("2026-11-26"), "entries": .array([])]),
                .object(["id": .string("w2"), "d": .string("2026-11-27"), "entries": .array([])]),
            ]),
        ]

        let snap = CoachContext.build(
            root: root,
            today: today,
            timezone: "UTC",
            readiness: nil,
            readinessSignals: nil,
            liveExternalNutrition: nil,
            catalog: catalog
        )

        XCTAssertEqual(snap.day(for: "2026-11-26")?.locked, .active)
        XCTAssertEqual(snap.day(for: "2026-11-27")?.locked, .logged)
        XCTAssertEqual(snap.day(for: "2026-11-28")?.locked, .multi)
        XCTAssertEqual(snap.day(for: "2026-11-29")?.locked, .orphan)

        // Deleting a clone's parent routine changes its resolved canonical ID and invalidates dayDigest (N2).
        var withParent = root
        var routinesWithParent = root["routines"]?.arrayValue ?? []
        routinesWithParent.append(.object([
            "id": .string("r-deleted"),
            "name": .string("Original Parent"),
            "ex": .array([.object(["id": .string(benchId), "sets": .number(3)])]),
        ]))
        withParent["routines"] = .array(routinesWithParent)
        XCTAssertNotEqual(
            CoachContext.dayDigest(withParent, date: "2026-11-29", today: today),
            CoachContext.dayDigest(root, date: "2026-11-29", today: today)
        )
    }

    func testEquipmentFilterOnVsOffAndDeterministicCandidateRanking() {
        let pushupId = exerciseId { $0.equipment == "body weight" && catalog.primaryMuscle(of: $0) == "chest" && !$0.isCardio && $0.accessories.isEmpty }
        let today = "2026-11-26"
        var root: Object = [
            "routines": .array([
                .object([
                    "id": .string("r1"),
                    "name": .string("Chest"),
                    "ex": .array([.object(["id": .string(pushupId), "sets": .number(3)])]),
                ]),
            ]),
            "week": .object(["4": .array([.string("r1")])]),
            "equipProfiles": .array([
                .object([
                    "id": .string("gym-home"),
                    "name": .string("Home"),
                    "equipment": .array([.string("dumbbell")]),
                    "accV": .number(2),
                ]),
            ]),
            "activeEquipId": .string("gym-home"),
            "equipFilterOn": .bool(true),
        ]

        let filteredSnap = CoachContext.build(
            root: root, today: today, timezone: "UTC",
            readiness: nil, readinessSignals: nil, liveExternalNutrition: nil, catalog: catalog
        )
        let filteredCandidates = filteredSnap.exerciseAliases.filter { $0.id != pushupId }
        XCTAssertLessThanOrEqual(filteredCandidates.count, CoachContext.maxCandidateExercises)
        XCTAssertFalse(filteredCandidates.isEmpty)
        let activeEq = ExerciseCatalog.equipment(of: ExerciseCatalog.activeProfile(root))
        for cand in filteredCandidates {
            if let ex = catalog[cand.id] {
                XCTAssertTrue(catalog.isAvailable(ex, with: activeEq), "Candidate \(ex.id) violates active gym equipment filter")
                XCTAssertFalse(ex.isCardio, "Cardio should not be suggested when plan has no cardio")
            }
        }

        // Turning equipFilterOn off removes equipment restriction (barbell/cable/machine candidates appear).
        root["equipFilterOn"] = .bool(false)
        let unfilteredSnap = CoachContext.build(
            root: root, today: today, timezone: "UTC",
            readiness: nil, readinessSignals: nil, liveExternalNutrition: nil, catalog: catalog
        )
        let unfilteredCandidates = unfilteredSnap.exerciseAliases.filter { $0.id != pushupId }
        XCTAssertLessThanOrEqual(unfilteredCandidates.count, CoachContext.maxCandidateExercises)
        XCTAssertTrue(unfilteredCandidates.contains { $0.equipment != nil && $0.equipment != "dumbbell" && $0.equipment != "body weight" })

        // Determinism check: building twice yields identical alias order.
        let unfilteredSnap2 = CoachContext.build(
            root: root, today: today, timezone: "UTC",
            readiness: nil, readinessSignals: nil, liveExternalNutrition: nil, catalog: catalog
        )
        XCTAssertEqual(unfilteredSnap.exerciseAliases, unfilteredSnap2.exerciseAliases)
    }

    func testRotationOnDateNoteAndDayDigestSensitivity() {
        let benchId = exerciseId { catalog.primaryMuscle(of: $0) == "chest" }
        let rowId = exerciseId { catalog.primaryMuscle(of: $0) == "upper-back" }
        let today = "2026-11-26"
        var root: Object = [
            "scheduleMode": .string("rotation"),
            "routines": .array([
                .object(["id": .string("rA"), "name": .string("A"), "ex": .array([.object(["id": .string(benchId), "sets": .number(3)])])]),
                .object(["id": .string("rB"), "name": .string("B"), "ex": .array([.object(["id": .string(rowId), "sets": .number(3)])])]),
            ]),
            "rotation": .object(["id": .string("rot1"), "sequence": .array([.string("rA"), .string("rB")])]),
            "queue": .object([
                "ids": .array([.string("rA"), .string("rB")]),
                "startsOn": .string(today),
                "since": .number(Day.noon(today) - 1000),
                "rotationId": .string("rot1"),
            ]),
            "dayPlan": .object([:]),
        ]

        let snap = CoachContext.build(
            root: root, today: today, timezone: "UTC",
            readiness: nil, readinessSignals: nil, liveExternalNutrition: nil, catalog: catalog
        )
        XCTAssertEqual(snap.scheduleMode, "rotation")
        XCTAssertFalse(snap.allowedOps.contains("move_day"))
        XCTAssertEqual(snap.rotationOnDate, today)
        XCTAssertNotNil(snap.rotationNote)
        XCTAssertEqual(snap.day(for: today)?.isQueueSession, true)

        let d0 = CoachContext.dayDigest(root, date: today, today: today)
        // Mutating dayPlan changes digest.
        root["dayPlan"] = .object([today: .string("rest")])
        let d1 = CoachContext.dayDigest(root, date: today, today: today)
        XCTAssertNotEqual(d0, d1)

        // Restoring dayPlan and mutating active changes digest.
        root["dayPlan"] = .object([:])
        root["active"] = .object(["d": .string(today)])
        let d2 = CoachContext.dayDigest(root, date: today, today: today)
        XCTAssertNotEqual(d0, d2)
    }
}
