import XCTest
@testable import HexplateCore

final class ExerciseNoteTests: XCTestCase {
    func testPinnedAndStandingNotes() throws {
        let json = #"""
        {"exNotes": {"0025": "  seat 4 ", "0043": {"text": "wide", "_ts": 1}, "0027": " "},
         "workouts": [
          {"id": "a", "d": "2026-10-01", "entries": [{"id": "0025", "note": "old pin", "notePin": true}]},
          {"id": "b", "d": "2026-10-03", "entries": [{"id": "0025", "note": "not pinned"}]},
          {"id": "c", "d": "2026-10-05", "entries": [{"id": "0025", "note": "new pin", "notePin": true}]}],
         "active": {"editingWorkoutId": "c"}}
        """#
        var s = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).object)
        XCTAssertEqual(ActiveEdit.standingNote(s, "0025"), "seat 4")
        XCTAssertEqual(ActiveEdit.standingNote(s, "0043"), "wide")
        XCTAssertNil(ActiveEdit.standingNote(s, "0027"))
        // Editing c: its own pin is skipped, b is not pinned, so a's.
        XCTAssertEqual(ActiveEdit.pinnedNote(s, "0025")?.note, "old pin")
        s["active"] = .null
        XCTAssertEqual(ActiveEdit.pinnedNote(s, "0025")?.day, "2026-10-05")
        XCTAssertNil(ActiveEdit.pinnedNote(s, "0043"))
    }
}
