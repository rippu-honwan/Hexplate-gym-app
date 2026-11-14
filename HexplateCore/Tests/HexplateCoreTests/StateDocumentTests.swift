import XCTest
@testable import HexplateCore

func fixtureData() throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "sample-state", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Compares two JSON texts with Foundation's own parser, independent of `JSONValue`.
func assertSameJSON(_ a: Data, _ b: Data, file: StaticString = #filePath, line: UInt = #line) throws {
    let x = try JSONSerialization.jsonObject(with: a) as? NSDictionary
    let y = try JSONSerialization.jsonObject(with: b) as? NSDictionary
    XCTAssertNotNil(x, file: file, line: line)
    XCTAssertEqual(x, y, file: file, line: line)
}

final class StateDocumentTests: XCTestCase {
    func testRoundTripKeepsEveryKeyAndValue() throws {
        let original = try fixtureData()
        let written = try StateDocument(data: original).data()
        try assertSameJSON(original, written)
        // Reading the written copy again changes nothing either.
        XCTAssertEqual(try StateDocument(data: written), try StateDocument(data: original))
    }

    func testRoundTripKeepsTypesFoundationCannotTellApart() throws {
        let text = String(decoding: try StateDocument(data: try fixtureData()).data(), as: UTF8.self)
        XCTAssertTrue(text.contains(#""sound":true"#))            // a Bool stays a Bool, not 1
        XCTAssertTrue(text.contains(#""targetW":null"#))          // null is kept, not dropped
        XCTAssertTrue(text.contains(#""restSec":120,"#))          // whole numbers stay whole
        XCTAssertTrue(text.contains("1767603900000.594"))         // fractional timestamps survive
        XCTAssertTrue(text.contains(#""someFutureSetting""#))     // unknown keys are kept
    }

    func testRejectsWhatIsNotAStateDocument() {
        func error(_ json: String) -> StateDocument.ReadError? {
            do { _ = try StateDocument(data: Data(json.utf8)); return nil } catch { return error }
        }
        XCTAssertEqual(error("{\"workouts\": ["), .notJSON)
        XCTAssertEqual(error(""), .notJSON)
        XCTAssertEqual(error("[1, 2]"), .notAnObject)
        XCTAssertEqual(error("\"text\""), .notAnObject)
        XCTAssertEqual(error("{\"routines\": []}"), .missingWorkouts)
        XCTAssertEqual(error("{\"workouts\": {}}"), .missingWorkouts)
        XCTAssertNil(error("{\"workouts\": []}"))
    }

    func testSummary() throws {
        let summary = try StateDocument(data: try fixtureData()).summary
        XCTAssertEqual(summary, .init(workoutCount: 2, unreadableWorkouts: 0, routineCount: 2, firstDate: "2026-01-05", lastDate: "2026-01-07"))
    }

    func testAnUnreadableWorkoutIsCountedAndKept() throws {
        let json = #"{"workouts":[{"id":"ok","d":"2026-02-01","entries":[]},{"d":"2026-02-02"},"junk"],"_ts":5}"#
        let doc = try StateDocument(data: Data(json.utf8))
        XCTAssertEqual(doc.workouts().items.map(\.id), ["ok"])
        XCTAssertEqual(doc.workouts().unreadable, 2)
        try assertSameJSON(Data(json.utf8), try doc.data())
    }

    func testWorkoutFields() throws {
        let w = try XCTUnwrap(try StateDocument(data: try fixtureData()).workouts().items.first)
        XCTAssertEqual(w.id, "w1")
        XCTAssertEqual(w.date, "2026-01-05")
        XCTAssertEqual(w.name, "Upper A")
        XCTAssertEqual(w.routineId, "r1")
        XCTAssertEqual(w.bodyweight, 72.4)
        XCTAssertEqual(w.duration, 3900)
        XCTAssertEqual(w.entries.map(\.exerciseId), ["0025", "0652", "1454", "custom-plank"])
        XCTAssertEqual(w.entries.map(\.supersetGroup), [nil, "a", "a", nil])
        XCTAssertEqual(w.entries[0].note, "felt strong")
    }

    func testSetShapes() throws {
        let entries = try XCTUnwrap(try StateDocument(data: try fixtureData()).workouts().items.first).entries
        let bench = entries[0].sets

        // Warm-ups: the phase field, and the legacy boolean.
        XCTAssertEqual(bench.map(\.isWarmup), [true, true, false, false, false, false])

        // A plain set with effort and a fractional timestamp.
        XCTAssertEqual(bench[2].weight, 60)
        XCTAssertEqual(bench[2].reps, 8)
        XCTAssertEqual(bench[2].rir, 2)
        XCTAssertEqual(bench[2].rpe, 8)
        XCTAssertEqual(bench[2].completedAt, 1767603900000.594)
        XCTAssertEqual(bench[2].kind, .straight)

        // Drop set: the drops are extra work on top of the main set.
        XCTAssertEqual(bench[3].kind, .dropset)
        XCTAssertEqual(bench[3].drops.map(\.w), [50, 40])
        XCTAssertEqual(bench[3].drops.map(\.r), [5, 6])

        // Rest-pause: the clusters break down the row's own reps (SET_TYPES.md).
        XCTAssertEqual(bench[4].kind, .restpause)
        XCTAssertEqual(bench[4].clusters.compactMap(\.r).reduce(0, +), bench[4].reps)
        XCTAssertEqual(bench[4].clusters.first?.restSec, 15)

        XCTAssertEqual(bench.map(\.done), [true, true, true, true, true, false])

        // Unilateral: per-side values.
        let split = entries[2].sets[0]
        XCTAssertEqual(split.sides["L"]?.r, 6)
        XCTAssertEqual(split.sides["R"]?.w, 20)
        XCTAssertEqual(split.sides["R"]?.done, true)

        // Timed: seconds instead of reps; an explicit phase wins over the legacy boolean.
        let plank = entries[3].sets
        XCTAssertEqual(plank.map(\.seconds), [45, 60])
        XCTAssertNil(plank[0].reps)
        XCTAssertFalse(plank[1].isWarmup)
    }

    /// Runs against the developer's own data folder when it is there (never committed).
    func testRealProfileRoundTrips() throws {
        let data = URL(filePath: #filePath).appending(path: "../../../../../data").standardized
        let files = ((try? FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("state-") && $0.pathExtension == "json" }
        try XCTSkipIf(files.isEmpty, "no local data folder")
        for file in files {
            let original = try Data(contentsOf: file)
            let doc = try StateDocument(data: original)
            try assertSameJSON(original, try doc.data())
            XCTAssertEqual(doc.workouts().unreadable, 0)
            XCTAssertEqual(doc.workouts().items.count, doc.root["workouts"]?.arrayValue?.count)
        }
    }
}
