import XCTest
@testable import HexplateCore

final class ExerciseRecordsTests: XCTestCase {
    typealias Object = [String: JSONValue]

    func set(_ w: Double, _ r: Double, done: Bool = true, warm: Bool = false) -> JSONValue {
        var o: Object = ["w": .number(w), "r": .number(r), "done": .bool(done)]
        if warm { o["phase"] = .string("warmup") }
        return .object(o)
    }

    func testMetricsCountTickedWorkRowsOnly() {
        let side: JSONValue = .object(["sides": .object(["L": .object(["w": .number(10), "r": .number(10), "done": .bool(true)]), "R": .object(["w": .number(10), "r": .number(8), "done": .bool(true)])])])
        let e: Object = ["id": .string("0025"), "sets": .array([set(20, 10, warm: true), set(60, 8), set(70, 5), set(80, 3, done: false), side])]
        let m = ExerciseRecords.metrics([e])
        XCTAssertEqual(m.heaviest, 70)
        XCTAssertEqual(m.bestSet, 480)                       // 60 × 8 beats 70 × 5 and the side set's 180
        XCTAssertEqual(m.session, 480 + 350 + 180)
        XCTAssertEqual(m.best1RM, 81.7)   // Epley 70 × 5, rounded as the app shows it, beats 60 × 8 (76)
        XCTAssertEqual(m.top?.w, 70)
    }

    func testHistoryIsOldestFirstAndSkipsEmptySessions() {
        let w = { (d: String, id: String, sets: [JSONValue]) -> JSONValue in
            .object(["id": .string(id), "d": .string(d), "entries": .array([.object(["id": .string("0025"), "sets": .array(sets)])])])
        }
        let s: Object = ["workouts": .array([w("2026-11-10", "b", [set(60, 5)]), w("2026-11-01", "a", [set(50, 5)]), w("2026-11-12", "c", [set(60, 5, done: false)])])]
        XCTAssertEqual(ExerciseRecords.history(s, exerciseId: "0025").map(\.workoutId), ["a", "b"])
    }

    func testProgressAndMuscles() {
        let e: Object = ["id": .string("0025"), "sets": .array([set(20, 10, warm: true), set(60, 8), set(60, 8, done: false)])]
        XCTAssertTrue(ExerciseRecords.progress([e]) == (1, 2))
        let levels = ExerciseRecords.sessionMuscles([e], catalog: .builtIn)
        XCTAssertEqual(levels.values.max(), 1)
        XCTAssertNotNil(levels["chest"])
    }
}
