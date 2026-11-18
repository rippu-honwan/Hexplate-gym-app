import XCTest
@testable import HexplateCore

/// The workout CSV against lib/export-csv.js (golden written by golden.sh), and daily backups.
final class ExportTests: XCTestCase {
    func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")))
    }

    func testCSVMatchesTheJavaScript() throws {
        let state = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: try fixture("history-state", "json")).object)
        let custom = (state["customEx"]?.arrayValue ?? []).compactMap { try? $0.decoded(as: Exercise.self) }
        let csv = Export.workoutsCSV(state, catalog: ExerciseCatalog.builtIn.adding(custom: custom))
        let golden = String(decoding: try fixture("history-golden", "csv"), as: UTF8.self)
        let a = csv.components(separatedBy: "\r\n"), b = golden.components(separatedBy: "\r\n")
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y) }
    }

    func testOneBackupADayKeepsSeven() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hexplate-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(directory: dir)
        try store.save(try StateDocument(data: Data(#"{"workouts":[]}"#.utf8)))
        for d in 1...9 { try store.autoBackup(today: String(format: "2026-10-%02d", d)) }
        XCTAssertFalse(try store.autoBackup(today: "2026-10-09"))
        XCTAssertEqual(store.backups().map(\.lastPathComponent).first, "auto-2026-10-09.json")
        XCTAssertEqual(store.backups().count, 7)
    }
}
