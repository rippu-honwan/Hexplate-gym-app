import XCTest
@testable import HexplateCore

/// Holds Reminders to what openGym schedules for the same profiles (lib/mobile.js
/// buildReminderNotifications / buildNudgeNotifications). Golden file from app/scripts/golden.sh.
final class ReminderGoldenTests: XCTestCase {
    struct Case: Decodable { let name: String; let now: String; let state: JSONValue }
    struct Golden: Decodable {
        struct Note: Decodable, Equatable { let id: Int; let at: String; let title: String; let body: String }
        let name: String
        let notes: [Note]
    }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([Case].self, from: try fixture("reminder-cases"))
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("reminder-golden"))
        XCTAssertEqual(cases.count, golden.count)
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        for (c, g) in zip(cases, golden) {
            let now = try XCTUnwrap(f.date(from: c.now))
            let notes = Reminders.notes(c.state.object ?? [:], now: now).map {
                Golden.Note(id: $0.id, at: String(format: "%@ %02d:%02d", $0.day, $0.hour, $0.minute), title: $0.title, body: $0.english)
            }
            XCTAssertEqual(notes, g.notes, c.name)
        }
    }
}
