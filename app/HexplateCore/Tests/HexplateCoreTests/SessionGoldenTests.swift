import XCTest
@testable import HexplateCore

/// Holds Session to the original JavaScript (session-start.js, progression.js, finish-workout.js).
/// Cases come from app/scripts/session-cases.py, the golden file from golden.sh.
final class SessionGoldenTests: XCTestCase {
    struct Golden: Decodable { let name: String; let result: JSONValue }

    func fixture(_ name: String) throws -> Data {
        // HEXPLATE_SESSION_DIR: check other cases (e.g. a real state) without committing them.
        if let dir = ProcessInfo.processInfo.environment["HEXPLATE_SESSION_DIR"] { return try Data(contentsOf: URL(fileURLWithPath: dir + "/" + name + ".json")) }
        return try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    func text(_ v: JSONValue) -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([JSONValue].self, from: try fixture("session-cases")).compactMap(\.object)
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("session-golden"))
        XCTAssertEqual(cases.count, golden.count)
        let catalog = ExerciseCatalog.builtIn
        var dump: [JSONValue] = []
        defer { if let path = ProcessInfo.processInfo.environment["HEXPLATE_DUMP"] { try? JSONEncoder().encode(JSONValue.array(dump)).write(to: URL(fileURLWithPath: path)) } }
        for (c, g) in zip(cases, golden) {
            let result: JSONValue
            if c["op"] == .string("start") {
                let s = try XCTUnwrap(c["state"]?.object)
                let routine = try XCTUnwrap(s["routines"]?.arrayValue?.first?.object)
                result = .array(Session.entries(s, routine: routine, catalog: catalog))
            } else {
                let active = try XCTUnwrap(c["active"]?.object)
                let end = Session.sessionEnd(active, now: c["now"]?.numberValue ?? 0)
                result = .object(Session.completedWorkout(active, end: end, prs: [], catalog: catalog))
            }
            dump.append(result)
            XCTAssertEqual(text(result), text(g.result), g.name)
        }
    }
}
