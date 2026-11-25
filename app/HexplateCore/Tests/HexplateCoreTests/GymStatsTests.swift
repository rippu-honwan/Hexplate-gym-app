import XCTest
@testable import HexplateCore

final class GymStatsTests: XCTestCase {
    private let catalog = ExerciseCatalog.builtIn

    private func workout(id: String, day: String, entries: [JSONValue]?, vol: Double? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "d": .string(day)]
        if let entries { o["entries"] = .array(entries) }
        if let vol { o["vol"] = .number(vol) }
        return .object(o)
    }

    private func entry(id: String, sets: [JSONValue], target: [String: JSONValue]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "sets": .array(sets)]
        if let target { o["target"] = .object(target) }
        return .object(o)
    }

    private func workSet(w: Double, r: Double, done: Bool = true, warmup: Bool = false, phase: String? = nil, drops: [(Double, Double)] = []) -> JSONValue {
        var o: [String: JSONValue] = ["w": .number(w), "r": .number(r), "done": .bool(done)]
        if warmup { o["warmup"] = .bool(true) }
        if let phase { o["phase"] = .string(phase) }
        if !drops.isEmpty {
            o["type"] = .string("dropset")
            o["drops"] = .array(drops.map { .object(["w": .number($0.0), "r": .number($0.1)]) })
        }
        return .object(o)
    }

    // MARK: - dailyVolumeSummary

    func testEmptyHistoryPeriodCalendarDaysAndZeros() {
        let state: [String: JSONValue] = ["workouts": .array([])]
        let today = "2026-11-25"

        let week = Stats.dailyVolumeSummary(state, period: .week, today: today, catalog: catalog)
        XCTAssertEqual(week.from, "2026-11-19")
        XCTAssertEqual(week.to, today)
        XCTAssertEqual(week.calendarDays, 7)
        XCTAssertEqual(week.totalVolume, 0)
        XCTAssertEqual(week.totalSets, 0)
        XCTAssertEqual(week.avgDailyVolume, 0)
        XCTAssertEqual(week.avgDailySets, 0)

        XCTAssertEqual(Stats.dailyVolumeSummary(state, period: .month, today: today, catalog: catalog).calendarDays, 30)
        XCTAssertEqual(Stats.dailyVolumeSummary(state, period: .sixMonths, today: today, catalog: catalog).calendarDays, 180)
        XCTAssertEqual(Stats.dailyVolumeSummary(state, period: .year, today: today, catalog: catalog).calendarDays, 365)
    }

    func testDailyVolumeSummaryInclusiveBoundariesAndSameDayAggregation() {
        // Range 2026-11-19 ... 2026-11-25 (7 calendar days)
        let state: [String: JSONValue] = [
            "workouts": .array([
                // Excluded: day before from
                workout(id: "w-before", day: "2026-11-18", entries: [entry(id: "0025", sets: [workSet(w: 100, r: 10)])]),
                // Included: exact from boundary (100 * 10 = 1000, 1 set)
                workout(id: "w-start", day: "2026-11-19", entries: [entry(id: "0025", sets: [workSet(w: 100, r: 10)])]),
                // Included: two sessions on same day (500 + 600 = 1100, 3 sets)
                workout(id: "w-mid1", day: "2026-11-22", entries: [entry(id: "0025", sets: [workSet(w: 50, r: 10)])]),
                workout(id: "w-mid2", day: "2026-11-22", entries: [entry(id: "0025", sets: [workSet(w: 60, r: 5), workSet(w: 60, r: 5)])]),
                // Included: exact to boundary (700, 1 set)
                workout(id: "w-end", day: "2026-11-25", entries: [entry(id: "0025", sets: [workSet(w: 70, r: 10)])]),
                // Excluded: day after to
                workout(id: "w-after", day: "2026-11-26", entries: [entry(id: "0025", sets: [workSet(w: 100, r: 10)])]),
            ])
        ]

        let summary = Stats.dailyVolumeSummary(state, from: "2026-11-19", to: "2026-11-25", catalog: catalog)
        XCTAssertEqual(summary.calendarDays, 7)
        XCTAssertEqual(summary.totalVolume, 2800)
        XCTAssertEqual(summary.totalSets, 5)
        XCTAssertEqual(summary.avgDailyVolume, 400)
        XCTAssertEqual(summary.avgDailySets, 0.7) // 5 / 7 = 0.714... -> 0.7
    }

    func testDailyVolumeSummaryWarmupsDropsDumbbellsBodyweightAndLegacyVolume() {
        let pullUpId = catalog.all.first { $0.name.lowercased() == "pull-up" }?.id ?? "0652"
        let baseWorkouts: JSONValue = .array([
            // Warmup (excluded from workSets; volume controlled by volumeWarmups), drop set (100*5 + 60*5 = 800), dbLoad "each" (2 * 20 * 10 = 400)
            workout(id: "w1", day: "2026-11-20", entries: [
                entry(id: "0025", sets: [
                    workSet(w: 40, r: 10, warmup: true),
                    workSet(w: 40, r: 10, phase: "warm-up"),
                    workSet(w: 100, r: 5, drops: [(60, 5)]),
                    workSet(w: 100, r: 5, done: false),
                ]),
                entry(id: "0289", sets: [workSet(w: 20, r: 10)], target: ["dbLoad": .string("each")]),
            ]),
            // Bodyweight pull-up (10 reps at 80 kg bodyweight from earlier weigh-in)
            workout(id: "w2", day: "2026-11-21", entries: [
                entry(id: pullUpId, sets: [workSet(w: 0, r: 10)]),
            ]),
            // Legacy workout without entries (savedVolume fallback = 1500, 0 work sets)
            workout(id: "w3", day: "2026-11-22", entries: nil, vol: 1500),
        ])

        let defaultState: [String: JSONValue] = [
            "workouts": baseWorkouts,
            // Weigh-in before range start verifies allWeighIns lookup matches Report.data
            "bodyweight": .array([.object(["d": .string("2026-10-01"), "w": .number(80)])]),
        ]
        let defaultSummary = Stats.dailyVolumeSummary(defaultState, from: "2026-11-19", to: "2026-11-25", catalog: catalog)
        // Volume: 800 + 400 + 0 (bw off) + 1500 = 2700; Sets: 1 (bench work) + 1 (db) + 1 (pull-up) = 3
        XCTAssertEqual(defaultSummary.totalVolume, 2700)
        XCTAssertEqual(defaultSummary.totalSets, 3)

        var withSettings = defaultState
        withSettings["volumeWarmups"] = .bool(true)
        withSettings["volumeBodyweight"] = .bool(true)
        let settingsSummary = Stats.dailyVolumeSummary(withSettings, from: "2026-11-19", to: "2026-11-25", catalog: catalog)
        // Warmups add 400 + 400 = 800; pull-up adds 80 * 10 = 800 -> 2700 + 1600 = 4300; totalSets stays 3 (work sets only)
        XCTAssertEqual(settingsSummary.totalVolume, 4300)
        XCTAssertEqual(settingsSummary.totalSets, 3)
    }

    func testDailyVolumeSummaryInvalidOrInvertedDatesReturnZeroSafely() {
        let state: [String: JSONValue] = [
            "workouts": .array([
                workout(id: "w1", day: "2026-11-20", entries: [entry(id: "0025", sets: [workSet(w: 100, r: 10)])]),
            ])
        ]
        let inverted = Stats.dailyVolumeSummary(state, from: "2026-11-25", to: "2026-11-19", catalog: catalog)
        XCTAssertEqual(inverted.calendarDays, 0)
        XCTAssertEqual(inverted.totalVolume, 0)
        XCTAssertEqual(inverted.avgDailyVolume, 0)
        XCTAssertEqual(inverted.avgDailySets, 0)

        let invalid = Stats.dailyVolumeSummary(state, from: "not-a-date", to: "2026-11-25", catalog: catalog)
        XCTAssertEqual(invalid.calendarDays, 0)
        XCTAssertFalse(invalid.avgDailyVolume.isNaN)

        let invalidToday = Stats.dailyVolumeSummary(state, period: .week, today: "2026-02-31", catalog: catalog)
        XCTAssertEqual(invalidToday.calendarDays, 0)
        XCTAssertEqual(invalidToday.totalVolume, 0)
    }

    // MARK: - trainingBalanceRadar

    func testTrainingBalanceRadarAxisOrderAndDefaultFourWeekTargets() {
        let axes = Stats.trainingBalanceRadar(["workouts": .array([])], today: "2026-11-25", catalog: catalog)
        XCTAssertEqual(axes.map(\.id), ["Chest", "Back", "Shoulders", "Arms", "Legs", "Core"])
        XCTAssertEqual(axes.map(\.target), [40, 40, 32, 56, 104, 24])
        XCTAssertEqual(axes.map(\.sets), [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(axes.map(\.pct), [0, 0, 0, 0, 0, 0])
    }

    func testTrainingBalanceRadarRolling28DayWindowAndCompoundWeights() {
        // today = 2026-11-25 -> inclusive 28-day window is 2026-10-29 ... 2026-11-25
        let benchWeights = catalog["0025"].map { catalog.muscleWeights(of: $0) } ?? [:]
        XCTAssertGreaterThan(benchWeights["chest"] ?? 0, 0)

        let state: [String: JSONValue] = [
            "workouts": .array([
                // Excluded: 28 days before today (2026-10-28)
                workout(id: "w-old", day: "2026-10-28", entries: [entry(id: "0025", sets: [workSet(w: 100, r: 8), workSet(w: 100, r: 8)])]),
                // Included: exact start boundary (2026-10-29) -> 2 work sets + 1 warmup (ignored)
                workout(id: "w-start", day: "2026-10-29", entries: [
                    entry(id: "0025", sets: [
                        workSet(w: 60, r: 10, warmup: true),
                        workSet(w: 100, r: 8),
                        workSet(w: 100, r: 8),
                    ])
                ]),
                // Included: exact end boundary (2026-11-25) -> 2 work sets
                workout(id: "w-end", day: "2026-11-25", entries: [
                    entry(id: "0025", sets: [workSet(w: 100, r: 8), workSet(w: 100, r: 8)])
                ]),
                // Excluded: future day (2026-11-26)
                workout(id: "w-future", day: "2026-11-26", entries: [entry(id: "0025", sets: [workSet(w: 100, r: 8)])]),
            ])
        ]

        let axes = Stats.trainingBalanceRadar(state, today: "2026-11-25", catalog: catalog)
        let byId = Dictionary(uniqueKeysWithValues: axes.map { ($0.id, $0) })

        let expectedChestSets = Stats.round1((benchWeights["chest"] ?? 0) * 4)
        let expectedChestPct = Stats.round1(((benchWeights["chest"] ?? 0) * 4 / 40.0) * 100)
        XCTAssertEqual(byId["Chest"]?.sets, expectedChestSets)
        XCTAssertEqual(byId["Chest"]?.pct, expectedChestPct)

        let expectedShouldersSets = Stats.round1((benchWeights["deltoids"] ?? 0) * 4)
        XCTAssertEqual(byId["Shoulders"]?.sets, expectedShouldersSets)

        let expectedArmsSets = Stats.round1(((benchWeights["biceps"] ?? 0) + (benchWeights["triceps"] ?? 0)) * 4)
        XCTAssertEqual(byId["Arms"]?.sets, expectedArmsSets)
    }

    func testTrainingBalanceRadarCustomExerciseOverridesZeroTargetAndUnclampedPct() throws {
        let customJSON: JSONValue = .object([
            "id": .string("custom-chest"),
            "n": .string("custom chest press"),
            "custom": .bool(true),
            "muscleWeights": .object(["chest": .number(1.0), "abs": .number(0.5)]),
        ])
        let customEx = try customJSON.decoded(as: Exercise.self)
        let customCatalog = catalog.adding(custom: [customEx])

        // 50 completed work sets on chest -> 50 / (4 * 10) = 125% (unclamped);
        // Custom muscleTargets: abs lowTarget = 0 -> div-by-zero guard yields pct == 0;
        // Custom muscleTargets: chest = [8, 16] -> 4w target = 32 -> 50 / 32 = 156.3%
        let sets = (0..<50).map { _ in workSet(w: 60, r: 10) }
        let state: [String: JSONValue] = [
            "muscleTargets": .object([
                "chest": .array([.number(8), .number(16)]),
                "abs": .array([.number(0), .number(10)]),
            ]),
            "workouts": .array([
                workout(id: "w1", day: "2026-11-20", entries: [entry(id: "custom-chest", sets: sets)]),
            ]),
        ]

        let axes = Stats.trainingBalanceRadar(state, today: "2026-11-25", catalog: customCatalog)
        let byId = Dictionary(uniqueKeysWithValues: axes.map { ($0.id, $0) })

        XCTAssertEqual(byId["Chest"]?.target, 32)
        XCTAssertEqual(byId["Chest"]?.sets, 50)
        XCTAssertEqual(byId["Chest"]?.pct, 156.3) // unclamped > 100%

        XCTAssertEqual(byId["Core"]?.target, 0)
        XCTAssertEqual(byId["Core"]?.sets, 25)
        XCTAssertEqual(byId["Core"]?.pct, 0) // div-by-zero guard
        XCTAssertFalse(byId["Core"]!.pct.isNaN)
        XCTAssertFalse(byId["Core"]!.pct.isInfinite)

        let invalid = Stats.trainingBalanceRadar(state, today: "bad-date", catalog: customCatalog)
        XCTAssertEqual(invalid.count, 6)
        XCTAssertEqual(invalid.map(\.sets), [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(invalid.map(\.pct), [0, 0, 0, 0, 0, 0])
    }

    // MARK: - Unilateral set parity pin (dailyVolumeSummary vs trainingBalanceRadar)

    func testUnilateralRowCountsOncePerSideInSummaryAndOncePerRowInRadar() throws {
        let customJSON: JSONValue = .object([
            "id": .string("custom-uni"),
            "n": .string("single-arm curl"),
            "custom": .bool(true),
            "muscleWeights": .object(["biceps": .number(1.0)]),
        ])
        let customEx = try customJSON.decoded(as: Exercise.self)
        let customCatalog = catalog.adding(custom: [customEx])

        let sideRow: JSONValue = .object([
            "done": .bool(true),
            "sides": .object([
                "L": .object(["w": .number(15), "r": .number(10), "done": .bool(true)]),
                "R": .object(["w": .number(15), "r": .number(10), "done": .bool(true)]),
            ]),
        ])
        let state: [String: JSONValue] = [
            "workouts": .array([
                workout(id: "w-uni", day: "2026-11-25", entries: [entry(id: "custom-uni", sets: [sideRow])]),
            ]),
        ]

        // Summary delegates to Report.workSets -> counts each completed side (L + R = 2 sets), volume = 150 + 150 = 300
        let summary = Stats.dailyVolumeSummary(state, from: "2026-11-25", to: "2026-11-25", catalog: customCatalog)
        XCTAssertEqual(summary.totalVolume, 300)
        XCTAssertEqual(summary.totalSets, 2)

        // Radar delegates to Report.muscleLoad -> top-level done == true counts 1 row -> 1.0 effective set on Arms
        let axes = Stats.trainingBalanceRadar(state, today: "2026-11-25", catalog: customCatalog)
        let arms = try XCTUnwrap(axes.first { $0.id == "Arms" })
        XCTAssertEqual(arms.sets, 1.0)
    }
}
