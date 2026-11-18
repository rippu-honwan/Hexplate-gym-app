import XCTest
@testable import HexplateCore

// The file cases mirror frontend/src/lib/mobile-state-file.test.js. Its fifth case (a plugin
// without a move operation) has no counterpart: FileManager always has one.
final class StateStoreTests: XCTestCase {
    var dir: URL!
    var store: StateStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "hexplate-\(UUID().uuidString)")
        store = StateStore(directory: dir.appending(path: "Hexplate"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func doc(ts: Int, marker: String = "x") throws -> StateDocument {
        try StateDocument(data: Data(#"{"workouts":[],"marker":"\#(marker)","_ts":\#(ts)}"#.utf8))
    }

    func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    func testNothingSavedYet() {
        XCTAssertNil(store.load())
    }

    func testLandsUnderItsOwnNameWithNoHalfFileBeside() throws {
        try store.save(try doc(ts: 1))
        XCTAssertEqual(names(store.directory), ["state.json"])
        XCTAssertEqual(store.load(), try doc(ts: 1))
    }

    func testEachSaveKeepsThePreviousCopy() throws {
        for ts in 1...3 { try store.save(try doc(ts: ts)) }
        XCTAssertEqual(names(store.directory), ["state.bak.json", "state.json"])
        XCTAssertEqual(store.load()?.timestamp, 3)
        let previous = try StateDocument(data: Data(contentsOf: store.directory.appending(path: "state.bak.json")))
        XCTAssertEqual(previous.timestamp, 2)
    }

    func testAMoveCutShortKeepsBothAndTheLaterOneIsRead() throws {
        try store.save(try doc(ts: 1))
        try doc(ts: 2).data().write(to: store.next)
        XCTAssertEqual(store.load()?.timestamp, 2)
    }

    func testAHalfWrittenMainFileIsNotTheEnd() throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(#"{"workouts":[],"_ts":"#.utf8).write(to: store.main)
        try doc(ts: 1).data().write(to: store.next)
        XCTAssertEqual(store.load()?.timestamp, 1)
    }

    func testAHalfWrittenNextFileIsIgnored() throws {
        try store.save(try doc(ts: 1))
        try Data(#"{"workouts":["#.utf8).write(to: store.next)
        XCTAssertEqual(store.load()?.timestamp, 1)
    }

    func testAnOlderLeftoverNeverWinsOverTheMainFile() throws {
        try store.save(try doc(ts: 5))
        try doc(ts: 2).data().write(to: store.next)
        XCTAssertEqual(store.load()?.timestamp, 5)
    }

    func testReplaceBacksUpWhatItReplaces() throws {
        XCTAssertNil(try store.replace(with: try doc(ts: 1, marker: "first")))   // nothing to back up
        let backup = try XCTUnwrap(try store.replace(with: try doc(ts: 2, marker: "second")))
        XCTAssertEqual(try StateDocument(data: Data(contentsOf: backup)), try doc(ts: 1, marker: "first"))
        XCTAssertEqual(store.load(), try doc(ts: 2, marker: "second"))
    }

    func testLegacyFileIsReadAndLeftExactlyAsItWas() throws {
        let documents = dir.appending(path: "Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let file = documents.appending(path: "opengym-state.json")
        let bytes = try fixtureData()
        try bytes.write(to: file)

        let legacy = try XCTUnwrap(LegacyState.load(documents: documents))
        try store.replace(with: legacy)

        XCTAssertEqual(store.load(), legacy)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(names(documents), ["opengym-state.json"])
    }

    func testNoLegacyFile() {
        XCTAssertNil(LegacyState.load(documents: dir))
    }
}
