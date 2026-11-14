import XCTest
@testable import HexplateCore

/// Holds the Swift port to what the original JavaScript produces for the same history.
/// The golden file is written by native/scripts/golden.sh from frontend/src/lib; regenerate it
/// there, never edit it by hand.
final class HistoryGoldenTests: XCTestCase {
    struct Golden: Decodable {
        struct Row: Decodable { let label: String; let hr: String; let warmup: Bool }
        struct Entry: Decodable { let id: String; let name: String; let sets: [Row] }
        let id: String
        let setsDone: Int
        let durationMs: Double
        let durationText: String
        let volume: Double
        let volumeText: String
        let entries: [Entry]
    }

    /// The same history under other settings, as golden.test.mjs VARIANTS.
    static let variants: [String: [String: JSONValue]] = [
        "asStored": [:],
        "countWarmups": ["volumeWarmups": .bool(true)],
        "countBodyweight": ["volumeBodyweight": .bool(true)],
        "twoDecimals": ["wdec": .number(2)],
    ]

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func testMatchesTheJavaScript() throws {
        let golden = try JSONDecoder().decode([String: [Golden]].self, from: try fixture("history-golden"))
        XCTAssertEqual(Set(golden.keys), Set(Self.variants.keys))

        for (variant, patch) in Self.variants {
            var doc = try StateDocument(data: try fixture("history-state"))
            for (key, value) in patch { doc.set(key, to: value) }
            let history = History(document: doc)
            let workouts = doc.workouts().items   // document order, as the golden file
            let expected = try XCTUnwrap(golden[variant])
            XCTAssertEqual(workouts.map(\.id), expected.map(\.id), variant)

            for (w, g) in zip(workouts, expected) {
                let at = "\(variant) \(w.id)"
                XCTAssertEqual(history.setsDone(w), g.setsDone, at)
                XCTAssertEqual(WorkoutMath.duration(w), g.durationMs, at)
                XCTAssertEqual(history.durationText(w) ?? "", g.durationText, at)
                XCTAssertEqual(history.volume(w), g.volume, accuracy: 1e-9, at)
                XCTAssertEqual(history.volumeText(w), g.volumeText, at)
                XCTAssertEqual(w.entries.map(\.exerciseId), g.entries.map(\.id), at)

                for (i, (e, ge)) in zip(w.entries, g.entries).enumerated() {
                    let here = "\(at) entry \(i) \(e.exerciseId)"
                    XCTAssertEqual(history.name(of: e), ge.name, here)
                    let rows = history.rows(of: e)
                    XCTAssertEqual(rows.map(\.label), ge.sets.map(\.label), here)
                    XCTAssertEqual(rows.map(\.isWarmup), ge.sets.map(\.warmup), here)
                    let hr = e.sets.filter(\.hasCompletedWork).map(SetLabel.heartRate)
                    XCTAssertEqual(hr, ge.sets.map(\.hr), here)
                }
            }
        }
    }

    func testTheCatalogueIsBundled() {
        XCTAssertEqual(ExerciseCatalog.builtIn["0025"]?.displayName, "Barbell Bench Press")
        XCTAssertEqual(ExerciseCatalog.builtIn["1019"]?.id, "3841")   // a drawing's id finds its exercise
    }

    // views/History.jsx historyRows: newest day first, and within a day the one stored later first.
    func testNewestFirst() throws {
        let history = History(document: try StateDocument(data: try fixture("history-state")))
        XCTAssertEqual(history.workouts.map(\.id), ["wC", "wD", "wB", "wA"])
    }

    func testSupersetsStayTogether() throws {
        let history = History(document: try StateDocument(data: try fixture("history-state")))
        let wA = try XCTUnwrap(history.workouts.last)
        XCTAssertEqual(history.units(of: wA), [[0], [1], [2, 3], [4], [5], [6], [7], [8], [9], [10], [11]])
    }

    // history.js sessionVolume: a legacy record without entries only has its cached number.
    func testALegacyWorkoutKeepsItsCachedVolume() throws {
        let json = #"{"workouts":[{"id":"old","d":"2025-01-01","name":"Imported","vol":1234.5,"prs":["a"]}]}"#
        let history = History(document: try StateDocument(data: Data(json.utf8)))
        let w = try XCTUnwrap(history.workouts.first)
        XCTAssertEqual(history.volumeText(w), "1,234.5 kg")
        XCTAssertEqual(history.setsDone(w), 0)
        XCTAssertNil(history.durationText(w))
        XCTAssertEqual(w.recordCount, 1)
    }

    func testNumberText() {
        XCTAssertEqual(Format.number(62.25), "62.3")          // Math.round: halves go up
        XCTAssertEqual(Format.number(62.25, decimals: 2), "62.25")
        XCTAssertEqual(Format.number(-0.03), "0")             // never "-0"
        XCTAssertEqual(Format.number(7535), "7,535")
        XCTAssertEqual(Format.seconds(95), "1:35")
        XCTAssertEqual(Format.capWords("dumbbell one arm bent-over row (rack support)"), "Dumbbell One Arm Bent-Over Row (Rack Support)")
    }

    /// Against the developer's own data (never committed): every workout's volume, as Hexplate
    /// counts it, next to the number the Capacitor app cached when the workout was saved.
    func testRealProfileVolumes() throws {
        let data = URL(filePath: #filePath).appending(path: "../../../../../data").standardized
        let files = ((try? FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("state-") && $0.pathExtension == "json" }
        try XCTSkipIf(files.isEmpty, "no local data folder")
        for file in files {
            let history = History(document: try StateDocument(data: try Data(contentsOf: file)))
            for w in history.workouts {
                let diff = abs(history.volume(w) - (w.savedVolume ?? .nan))
                if !(diff < 0.001) { print("VOLUME DIFF \(file.lastPathComponent) \(w.date) counted \(history.volume(w)) saved \(w.savedVolume ?? .nan)") }
                for e in w.entries where history.catalog[e.exerciseId] == nil { print("UNKNOWN EXERCISE \(e.exerciseId) in \(w.date)") }
            }
        }
    }
}
