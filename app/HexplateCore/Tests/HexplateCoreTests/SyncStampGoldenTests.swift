import XCTest
@testable import HexplateCore

/// Holds SyncStamps to what the original store does to the same change (sync-merge.js
/// stampChange). The golden file is written by app/scripts/golden.sh; never edit it by hand.
final class SyncStampGoldenTests: XCTestCase {
    struct Case: Decodable { let name: String; let prev: JSONValue; let next: JSONValue; let wall: Double }
    struct Golden: Decodable { let name: String; let next: JSONValue }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([Case].self, from: try fixture("stamp-cases"))
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("stamp-golden"))
        XCTAssertEqual(cases.map(\.name), golden.map(\.name))
        XCTAssertGreaterThan(cases.count, 15)

        for (c, g) in zip(cases, golden) {
            var next = try XCTUnwrap(c.next.object)
            next["_ts"] = .number(SyncStamps.stampChange(prev: try XCTUnwrap(c.prev.object), next: &next, wall: c.wall))
            let expected = try XCTUnwrap(g.next.object)
            for key in Set(next.keys).union(expected.keys).sorted() where next[key] != expected[key] {
                XCTFail("\(c.name): \(key)\n  swift \(describe(next[key]))\n  js    \(describe(expected[key]))")
            }
        }
    }

    private func describe(_ v: JSONValue?) -> String {
        guard let v, let data = try? JSONEncoder().encode(v) else { return "absent" }
        return String(decoding: data, as: UTF8.self)
    }
}
