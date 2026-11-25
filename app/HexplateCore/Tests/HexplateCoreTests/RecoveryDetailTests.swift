import XCTest
@testable import HexplateCore

final class RecoveryDetailTests: XCTestCase {
    typealias Object = [String: JSONValue]

    private let catalog = ExerciseCatalog.builtIn
    private let dayMs = 86_400_000.0

    private func makeWorkout(id: String, day: String, startMs: Double, exerciseId: String, sets: Int) -> Object {
        let setRows: [JSONValue] = (0..<sets).map { _ in
            .object(["w": .number(100), "r": .number(8), "done": .bool(true), "rir": .number(1)])
        }
        return [
            "id": .string(id),
            "d": .string(day),
            "start": .number(startMs),
            "entries": .array([
                .object([
                    "id": .string(exerciseId),
                    "sets": .array(setRows),
                ]),
            ]),
        ]
    }

    private func exerciseId(for muscle: String) -> String {
        catalog.all.first { (catalog.muscleWeights(of: $0)[muscle] ?? 0) >= 0.9 }!.id
    }

    func testLoadSummaryMatchesFatigueMapAndHoursToRecovered() {
        let benchId = exerciseId(for: "chest")
        let now = Day.noon("2026-11-26")
        let workouts = [
            makeWorkout(id: "w1", day: "2026-11-25", startMs: now - 12 * 3_600_000, exerciseId: benchId, sets: 10),
        ]

        let baselineFatigue = Recovery.fatigue(workouts, now: now, unit: "kg", bodyweightKg: 75, catalog: catalog)
        let summary = Recovery.loadSummary(workouts, now: now, unit: "kg", bodyweightKg: 75, catalog: catalog)

        XCTAssertEqual(summary.fatigueMap.count, baselineFatigue.count)
        for (slug, expected) in baselineFatigue {
            let actual = summary.muscles[slug]?.fatigue ?? -1
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "Mismatch for \(slug)")
        }

        let chest = try? XCTUnwrap(summary.muscles["chest"])
        XCTAssertNotNil(chest)
        guard let chest else { return }
        XCTAssertGreaterThan(chest.fatigue, 0.5)
        XCTAssertEqual(chest.lastSessionSets, 10.0, accuracy: 0.01)
        XCTAssertGreaterThan(chest.hoursToRecovered, 0)

        // Advance `now` by closed-form `hoursToRecovered`: fatigue must land right at 0.5.
        let futureNow = now + chest.hoursToRecovered * 3_600_000.0
        let futureSummary = Recovery.loadSummary(workouts, now: futureNow, unit: "kg", bodyweightKg: 75, catalog: catalog)
        XCTAssertEqual(futureSummary.muscles["chest"]?.fatigue ?? 0, 0.5, accuracy: 1e-5)
        XCTAssertEqual(futureSummary.muscles["chest"]?.hoursToRecovered ?? -1, 0.0, accuracy: 1e-4)

        // Untrained muscle must have zero fatigue, zero lastSessionSets, and zero hoursToRecovered.
        let calves = summary.muscles["calves"]
        XCTAssertEqual(calves?.fatigue, 0)
        XCTAssertEqual(calves?.lastSessionSets, 0)
        XCTAssertEqual(calves?.hoursToRecovered, 0)
    }

    func testGlobalLoadRatioSuppressedForNoviceAndComputedWhenEstablished() {
        let squatId = exerciseId(for: "quadriceps")
        let now = Day.noon("2026-11-26")

        // Single small workout -> chronic < 4.0 -> ratio must be nil (no false ACWR spike).
        let noviceWorkouts = [
            makeWorkout(id: "w1", day: "2026-11-25", startMs: now - dayMs, exerciseId: squatId, sets: 2),
        ]
        let noviceSummary = Recovery.loadSummary(noviceWorkouts, now: now, unit: "kg", bodyweightKg: 75, catalog: catalog)
        XCTAssertGreaterThan(noviceSummary.global.acute, 0)
        XCTAssertLessThan(noviceSummary.global.chronic, 4.0)
        XCTAssertNil(noviceSummary.global.ratio)

        // Steady weekly training over 4 weeks + a heavy recent week -> chronic >= 4.0 -> exact ratio.
        var established: [Object] = []
        for dayOffset in [25, 22, 18, 15, 11, 8, 4, 2, 1] {
            let ts = now - Double(dayOffset) * dayMs
            established.append(makeWorkout(
                id: "w-\(dayOffset)",
                day: Day.iso(Date(timeIntervalSince1970: ts / 1000)),
                startMs: ts,
                exerciseId: squatId,
                sets: 6
            ))
        }
        let estSummary = Recovery.loadSummary(established, now: now, unit: "kg", bodyweightKg: 75, catalog: catalog)
        XCTAssertGreaterThanOrEqual(estSummary.global.chronic, 4.0)
        guard let ratio = estSummary.global.ratio else {
            return XCTFail("Expected non-nil ratio for established chronic load")
        }
        XCTAssertEqual(ratio, estSummary.global.acute / estSummary.global.chronic, accuracy: 1e-9)
    }

    func testPlannedMuscleLoadResolvesDayPlanPin() {
        let benchId = exerciseId(for: "chest")
        let root: Object = [
            "routines": .array([
                .object([
                    "id": .string("r-push"),
                    "name": .string("Push"),
                    "ex": .array([
                        .object(["id": .string(benchId), "sets": .number(4)]),
                    ]),
                ]),
            ]),
            "week": .object([:]),
            "dayPlan": .object(["2026-11-26": .string("r-push")]),
        ]

        let planned = Recovery.plannedMuscleLoad(root, on: "2026-11-26", today: "2026-11-26", catalog: catalog)
        XCTAssertEqual(planned["chest"] ?? 0, 4.0, accuracy: 0.01)

        let restDay = Recovery.plannedMuscleLoad(root, on: "2026-11-27", today: "2026-11-26", catalog: catalog)
        XCTAssertTrue(restDay.isEmpty)
    }
}
