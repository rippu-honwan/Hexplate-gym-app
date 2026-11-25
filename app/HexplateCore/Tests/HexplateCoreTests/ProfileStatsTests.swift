import XCTest
@testable import HexplateCore

final class ProfileStatsTests: XCTestCase {
    private let catalog = ExerciseCatalog.builtIn

    private func workout(id: String?, day: String, start: Double? = nil, entries: [JSONValue] = []) -> JSONValue {
        var o: [String: JSONValue] = ["d": .string(day), "entries": .array(entries)]
        if let id { o["id"] = .string(id) }
        if let start { o["start"] = .number(start) }
        return .object(o)
    }

    private func entry(id: String, sets: [JSONValue]) -> JSONValue {
        .object(["id": .string(id), "sets": .array(sets)])
    }

    private func set(w: Double, r: Double, done: Bool = true, warmup: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["w": .number(w), "r": .number(r), "done": .bool(done)]
        if warmup { o["warmup"] = .bool(true) }
        return .object(o)
    }

    // MARK: - workoutsByDay

    func testWorkoutsByDaySortsChronologicallyDeduplicatesAndSkipsInvalid() {
        let state: [String: JSONValue] = [
            "workouts": .array([
                workout(id: "w-pm", day: "2026-11-20", start: 2_000_000),
                workout(id: "w-am", day: "2026-11-20", start: 1_000_000),
                workout(id: "w-am", day: "2026-11-20", start: 1_500_000), // duplicate id
                workout(id: "w-doc1", day: "2026-11-21"),
                workout(id: "w-doc2", day: "2026-11-21"),
                workout(id: "", day: "2026-11-22"),          // empty id -> skipped
                workout(id: nil, day: "2026-11-22"),         // missing id -> skipped
                workout(id: "w-bad", day: "2026-02-31"),     // invalid date -> skipped
            ]),
        ]

        let byDay = Stats.workoutsByDay(state)
        XCTAssertEqual(byDay["2026-11-20"], ["w-am", "w-pm"])
        XCTAssertEqual(byDay["2026-11-21"], ["w-doc1", "w-doc2"])
        XCTAssertNil(byDay["2026-11-22"])
        XCTAssertNil(byDay["2026-02-31"])
        XCTAssertEqual(byDay.count, 2)
    }

    // MARK: - lastWeekMuscleSets

    func testLastWeekMuscleSetsMondayAndSundayWeekStartsAndInvalidToday() throws {
        // 2026-11-25 is a Wednesday.
        // Monday start (weekStart = 1):
        //   current week: 2026-11-23 (Mon) ... 2026-11-29 (Sun)
        //   last week:    2026-11-16 (Mon) ... 2026-11-22 (Sun)
        // Sunday start (weekStart = 0):
        //   current week: 2026-11-22 (Sun) ... 2026-11-28 (Sat)
        //   last week:    2026-11-15 (Sun) ... 2026-11-21 (Sat)
        let custom = try JSONValue.object([
            "id": .string("c-chest"),
            "n": .string("chest iso"),
            "custom": .bool(true),
            "muscleWeights": .object(["chest": .number(1.0)]),
        ]).decoded(as: Exercise.self)
        let customCatalog = catalog.adding(custom: [custom])

        let workouts: JSONValue = .array([
            // 2026-11-15 (Sun): only in last week when weekStart == 0 (2 sets)
            workout(id: "w-sun15", day: "2026-11-15", entries: [entry(id: "c-chest", sets: [set(w: 50, r: 10), set(w: 50, r: 10)])]),
            // 2026-11-18 (Wed): in last week under both weekStart modes (3 sets)
            workout(id: "w-wed18", day: "2026-11-18", entries: [entry(id: "c-chest", sets: [set(w: 50, r: 10), set(w: 50, r: 10), set(w: 50, r: 10)])]),
            // 2026-11-22 (Sun): in last week when weekStart == 1, in current week when weekStart == 0 (4 sets)
            workout(id: "w-sun22", day: "2026-11-22", entries: [entry(id: "c-chest", sets: [set(w: 50, r: 10), set(w: 50, r: 10), set(w: 50, r: 10), set(w: 50, r: 10)])]),
            // 2026-11-25 (Wed): current week under both modes (excluded)
            workout(id: "w-wed25", day: "2026-11-25", entries: [entry(id: "c-chest", sets: [set(w: 50, r: 10)])]),
            // Malformed date (must never match even on invalid today)
            workout(id: "w-bad", day: "bad-date", entries: [entry(id: "c-chest", sets: [set(w: 50, r: 10)])]),
        ])

        let mondayState: [String: JSONValue] = [
            "weekStart": .number(1),
            "muscleTargets": .object(["chest": .array([.number(6), .number(12)])]),
            "workouts": workouts,
        ]
        let monChest = try XCTUnwrap(Stats.lastWeekMuscleSets(mondayState, today: "2026-11-25", catalog: customCatalog).first { $0.slug == "chest" })
        XCTAssertEqual(monChest.sets, 7) // Wed 18 (3) + Sun 22 (4)
        XCTAssertEqual(monChest.low, 6)
        XCTAssertEqual(monChest.high, 12)
        XCTAssertEqual(monChest.status, "in")

        let sundayState: [String: JSONValue] = ["weekStart": .number(0), "workouts": workouts]
        let sunChest = try XCTUnwrap(Stats.lastWeekMuscleSets(sundayState, today: "2026-11-25", catalog: customCatalog).first { $0.slug == "chest" })
        XCTAssertEqual(sunChest.sets, 5) // Sun 15 (2) + Wed 18 (3)

        let invalid = try XCTUnwrap(Stats.lastWeekMuscleSets(mondayState, today: "not-a-date", catalog: customCatalog).first { $0.slug == "chest" })
        XCTAssertEqual(invalid.sets, 0)
        XCTAssertEqual(invalid.low, 6)
    }

    // MARK: - BodyData.weekAverage

    func testBodyDataWeekAverageWeekStartsFutureExclusionAndNoPreviousWeek() throws {
        // 2026-11-25 (Wed):
        // Monday weekStart: this week 11-23..11-29, last week 11-16..11-22
        // Sunday weekStart: this week 11-22..11-28, last week 11-15..11-21
        let readings: JSONValue = .array([
            .object(["d": .string("2026-11-15"), "w": .number(76.0)]), // Sun (last week for Sun start)
            .object(["d": .string("2026-11-18"), "w": .number(75.0)]), // Wed (last week for both)
            .object(["d": .string("2026-11-22"), "w": .number(74.0)]), // Sun (last week for Mon, this week for Sun)
            .object(["d": .string("2026-11-24"), "w": .number(73.0)]), // Tue (this week for both)
            .object(["d": .string("2026-11-25"), "w": .number(73.5)]), // Wed (this week for both)
            .object(["d": .string("2026-11-26"), "w": .number(99.0)]), // Future -> ignored
        ])

        let monAvg = try XCTUnwrap(BodyData.weekAverage(["weekStart": .number(1), "bodyweight": readings], today: "2026-11-25"))
        // This week (Mon start): avg(73.0, 73.5) = 73.25; Last week: avg(75.0, 74.0) = 74.5 -> delta = -1.25
        XCTAssertEqual(monAvg.avg, 73.25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(monAvg.delta), -1.25, accuracy: 1e-9)

        let sunAvg = try XCTUnwrap(BodyData.weekAverage(["weekStart": .number(0), "bodyweight": readings], today: "2026-11-25"))
        // This week (Sun start): avg(74.0, 73.0, 73.5) = 73.5; Last week: avg(76.0, 75.0) = 75.5 -> delta = -2.0
        XCTAssertEqual(sunAvg.avg, 73.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(sunAvg.delta), -2.0, accuracy: 1e-9)

        // No previous-week readings -> delta is nil
        let noPrev = try XCTUnwrap(BodyData.weekAverage([
            "weekStart": .number(1),
            "bodyweight": .array([.object(["d": .string("2026-11-25"), "w": .number(72.0)])]),
        ], today: "2026-11-25"))
        XCTAssertEqual(noPrev.avg, 72.0, accuracy: 1e-9)
        XCTAssertNil(noPrev.delta)

        // Empty current week & invalid today -> nil
        XCTAssertNil(BodyData.weekAverage([
            "weekStart": .number(1),
            "bodyweight": .array([.object(["d": .string("2026-11-18"), "w": .number(75.0)])]),
        ], today: "2026-11-25"))
        XCTAssertNil(BodyData.weekAverage(["bodyweight": readings], today: "2026-02-31"))
    }

    // MARK: - allOneRepMaxSeries parity (Opus R1)

    func testAllOneRepMaxSeriesMatchesOneRepMaxSeriesSortedThroughToday() {
        // Out-of-order workouts (backfilled earlier workout stored later) + multi-entry workout + future workout
        let state: [String: JSONValue] = [
            "workouts": .array([
                workout(id: "w-nov", day: "2026-11-20", entries: [
                    entry(id: "0025", sets: [set(w: 100, r: 5)]),
                    entry(id: "0025", sets: [set(w: 105, r: 5)]), // second entry same workout -> higher wins
                ]),
                workout(id: "w-backfill", day: "2026-10-10", entries: [
                    entry(id: "0025", sets: [set(w: 90, r: 5)]),
                ]),
                workout(id: "w-future", day: "2026-11-26", entries: [
                    entry(id: "0025", sets: [set(w: 150, r: 5)]),
                ]),
                workout(id: "w-bad", day: "invalid", entries: [
                    entry(id: "0025", sets: [set(w: 200, r: 5)]),
                ]),
            ]),
        ]

        let singlePass = Stats.allOneRepMaxSeries(state, through: "2026-11-25", catalog: catalog)["0025"] ?? []
        let expected = Stats.oneRepMaxSeries(state, "0025", catalog: catalog)
            .enumerated()
            .filter { Report.valid($0.element.day).map { $0 <= "2026-11-25" } ?? false }
            .sorted { a, b in a.element.day != b.element.day ? a.element.day < b.element.day : a.offset < b.offset }
            .map(\.element)

        XCTAssertEqual(singlePass, expected)
        XCTAssertEqual(singlePass.map(\.day), ["2026-10-10", "2026-11-20"])
    }

    // MARK: - groupRMProgress

    func testGroupRMProgressEmptyAndInvalidToday() {
        let empty = Stats.groupRMProgress(["workouts": .array([])], today: "2026-11-25", catalog: catalog)
        XCTAssertEqual(empty.map(\.id), ["Chest", "Back", "Shoulders", "Legs", "Overall"])
        XCTAssertTrue(empty.allSatisfy { $0.exerciseId == nil && $0.current == nil && $0.change4w == nil && $0.changeFromFirst == nil })

        let invalid = Stats.groupRMProgress(["workouts": .array([])], today: "bad", catalog: catalog)
        XCTAssertEqual(invalid.map(\.id), ["Chest", "Back", "Shoulders", "Legs", "Overall"])
        XCTAssertTrue(invalid.allSatisfy { $0.current == nil })
    }

    func testGroupRMProgressRecencySelectionFallbackBackfillAndOverallMatchedSums() throws {
        // today = 2026-11-25 -> cutoff4w = 2026-10-28, recentCutoff (12w) = 2026-09-02.
        // Using 1-rep sets so estimate1RM(w, 1) == w exactly (clean exact assertions).
        //
        // 1. Chest: 3 old 2025 flat bench ("0025") sessions vs 2 recent incline bench ("0047") sessions
        //    -> 12-week recency selects "0047" (first: 80 on 2026-10-20, 4w base: 80 on 2026-10-20, now: 100 on 2026-11-20)
        //    -> current 100, 4w +20 (+25%), first +20 (+25%).
        // 2. Back: no barbell row ("0027"), fallback to lat pulldown ("0007", primaryMuscle = "upper-back")
        //    started AFTER cutoff4w (first: 70 on 2026-11-05, now: 80 on 2026-11-22)
        //    -> current 80, 4w = nil, first +10 (+14.3%).
        // 3. Shoulders: single session of OHP ("1162") on 2026-11-10 (60)
        //    -> current 60, 4w = nil, first = nil (only 1 session).
        // 4. Legs: Squat ("0043") with out-of-order backfill (first: 100 on 2026-08-01 backfilled last,
        //    4w base: 140 on 2026-10-28 exact cutoff, now: 130 on 2026-11-24 — negative 4w regression!)
        //    -> current 130, 4w -10 (-7.1%), first +30 (+30%).
        // 5. Overall:
        //    - current: 100 + 80 + 60 + 130 = 370
        //    - change4w (Chest + Legs ONLY, groupCount == 2): (100+130) vs (80+140) = 230 vs 220 -> +10 (+4.5%)
        //    - changeFromFirst (Chest + Back + Legs ONLY, groupCount == 3): (100+80+130) vs (80+70+100) = 310 vs 250 -> +60 (+24%)
        let state: [String: JSONValue] = [
            "workouts": .array([
                // Old flat bench sessions (before 12w window)
                workout(id: "old1", day: "2025-05-01", entries: [entry(id: "0025", sets: [set(w: 110, r: 1)])]),
                workout(id: "old2", day: "2025-05-08", entries: [entry(id: "0025", sets: [set(w: 110, r: 1)])]),
                workout(id: "old3", day: "2025-05-15", entries: [entry(id: "0025", sets: [set(w: 110, r: 1)])]),
                // Recent incline bench ("0047")
                workout(id: "inc1", day: "2026-10-20", entries: [entry(id: "0047", sets: [set(w: 80, r: 1)])]),
                workout(id: "inc2", day: "2026-11-20", entries: [entry(id: "0047", sets: [set(w: 100, r: 1)])]),
                // Back fallback ("0007" alternate lateral pulldown, primary = upper-back)
                workout(id: "lat1", day: "2026-11-05", entries: [entry(id: "0007", sets: [set(w: 70, r: 1)])]),
                workout(id: "lat2", day: "2026-11-22", entries: [entry(id: "0007", sets: [set(w: 80, r: 1)])]),
                // Shoulders single session ("1162")
                workout(id: "ohp1", day: "2026-11-10", entries: [entry(id: "1162", sets: [set(w: 60, r: 1)])]),
                // Legs ("0043") stored out of chronological order + future ignored
                workout(id: "sq-now", day: "2026-11-24", entries: [entry(id: "0043", sets: [set(w: 130, r: 1)])]),
                workout(id: "sq-4w", day: "2026-10-28", entries: [entry(id: "0043", sets: [set(w: 140, r: 1)])]),
                workout(id: "sq-first", day: "2026-08-01", entries: [entry(id: "0043", sets: [set(w: 100, r: 1)])]),
                workout(id: "sq-future", day: "2026-12-01", entries: [entry(id: "0043", sets: [set(w: 200, r: 1)])]),
            ]),
        ]

        let results = Stats.groupRMProgress(state, today: "2026-11-25", catalog: catalog)
        let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })

        let chest = try XCTUnwrap(byId["Chest"])
        XCTAssertEqual(chest.exerciseId, "0047")
        XCTAssertEqual(chest.current, 100)
        XCTAssertEqual(chest.change4w, Stats.RMDelta(current: 100, baseline: 80, delta: 20, pct: 25, groupCount: 1))
        XCTAssertEqual(chest.changeFromFirst, Stats.RMDelta(current: 100, baseline: 80, delta: 20, pct: 25, groupCount: 1))

        let back = try XCTUnwrap(byId["Back"])
        XCTAssertEqual(back.exerciseId, "0007")
        XCTAssertEqual(back.current, 80)
        XCTAssertNil(back.change4w)
        XCTAssertEqual(back.changeFromFirst, Stats.RMDelta(current: 80, baseline: 70, delta: 10, pct: 14.3, groupCount: 1))

        let shoulders = try XCTUnwrap(byId["Shoulders"])
        XCTAssertEqual(shoulders.exerciseId, "1162")
        XCTAssertEqual(shoulders.current, 60)
        XCTAssertNil(shoulders.change4w)
        XCTAssertNil(shoulders.changeFromFirst)

        let legs = try XCTUnwrap(byId["Legs"])
        XCTAssertEqual(legs.exerciseId, "0043")
        XCTAssertEqual(legs.current, 130)
        XCTAssertEqual(legs.change4w, Stats.RMDelta(current: 130, baseline: 140, delta: -10, pct: -7.1, groupCount: 1))
        XCTAssertEqual(legs.changeFromFirst, Stats.RMDelta(current: 130, baseline: 100, delta: 30, pct: 30, groupCount: 1))

        let overall = try XCTUnwrap(byId["Overall"])
        XCTAssertNil(overall.exerciseId)
        XCTAssertEqual(overall.current, 370)
        XCTAssertEqual(overall.change4w, Stats.RMDelta(current: 230, baseline: 220, delta: 10, pct: 4.5, groupCount: 2))
        XCTAssertEqual(overall.changeFromFirst, Stats.RMDelta(current: 310, baseline: 250, delta: 60, pct: 24, groupCount: 3))
    }

    func testGroupRMProgressZeroChangeWhenNotTrainedInLastFourWeeksAndTieBreak() throws {
        // Both "0025" and "0047" have 1 session on 2026-10-01 (before cutoff4w) -> standard order picks "0025"
        // No session since 2026-10-01 -> 4w change is 0 (0%), changeFromFirst is nil (1 session)
        let state: [String: JSONValue] = [
            "workouts": .array([
                workout(id: "w1", day: "2026-10-01", entries: [
                    entry(id: "0047", sets: [set(w: 90, r: 1)]),
                    entry(id: "0025", sets: [set(w: 100, r: 1)]),
                ]),
            ]),
        ]

        let results = Stats.groupRMProgress(state, today: "2026-11-25", catalog: catalog)
        let chest = try XCTUnwrap(results.first { $0.id == "Chest" })
        XCTAssertEqual(chest.exerciseId, "0025")
        XCTAssertEqual(chest.current, 100)
        XCTAssertEqual(chest.change4w, Stats.RMDelta(current: 100, baseline: 100, delta: 0, pct: 0, groupCount: 1))
        XCTAssertNil(chest.changeFromFirst)
    }
}
