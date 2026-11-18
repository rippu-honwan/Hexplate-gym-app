import XCTest
@testable import HexplateCore

/// Holds LiveActivity to lib/live-activity.js (buildLiveActivity's state, nextExerciseTarget).
/// Cases: app/scripts/live-cases.py; golden: golden.sh.
final class LiveActivityGoldenTests: XCTestCase {
    struct Golden: Decodable { let name: String; let result: JSONValue }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    func text(_ v: JSONValue) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }
    func clock(_ v: JSONValue?) -> LiveActivity.Clock? {
        guard let o = v?.object, let end = o["endsAt"]?.numberValue, let total = o["total"]?.numberValue else { return nil }
        return .init(endsAt: end, total: total)
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([JSONValue].self, from: try fixture("live-cases")).compactMap(\.object)
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("live-golden"))
        XCTAssertEqual(cases.count, golden.count)
        for (c, g) in zip(cases, golden) {
            let s = try XCTUnwrap(c["state"]?.object)
            let result: JSONValue
            if c["op"] == .string("next") {
                result = LiveActivity.nextExerciseTarget(s["active"]?.object, from: Int(c["from"]?.numberValue ?? 0)).map { .number(Double($0)) } ?? .null
            } else {
                result = LiveActivity.state(s, rest: clock(c["timer"]), hold: clock(c["hold"]?.object?["work"]), catalog: .builtIn).map(JSONValue.object) ?? .null
            }
            XCTAssertEqual(text(result), text(g.result), g.name)
        }
    }
}
