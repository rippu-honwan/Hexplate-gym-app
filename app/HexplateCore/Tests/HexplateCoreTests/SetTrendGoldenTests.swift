import XCTest
@testable import HexplateCore

/// Holds SetTrend to openGym's lib/set-trend.js setTrendsFor. Golden file from app/scripts/golden.sh.
final class SetTrendGoldenTests: XCTestCase {
    struct Case: Decodable { let name: String; let entry: JSONValue; let last: JSONValue?; let formula: String }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([Case].self, from: try fixture("trend-cases"))
        let golden = try JSONDecoder().decode([JSONValue].self, from: try fixture("trend-golden"))
        XCTAssertEqual(cases.count, golden.count)
        for (c, g) in zip(cases, golden) {
            let got = SetTrend.trends(c.entry.object ?? [:], last: c.last?.object, catalog: .builtIn, formula: c.formula)
            let want = g.object?["trends"]?.arrayValue ?? []
            XCTAssertEqual(got.count, want.count, c.name)
            for (a, b) in zip(got, want) {
                guard let a, let b = b.object else { XCTAssertNil(a, c.name); XCTAssertEqual(b, .null, c.name); continue }
                XCTAssertEqual(Double(a.dir), b["dir"]?.numberValue, "\(c.name) dir")
                XCTAssertEqual(a.by, b["by"]?.stringValue, "\(c.name) by")
                XCTAssertEqual(a.delta, b["delta"]?.numberValue ?? .nan, accuracy: 1e-9, "\(c.name) delta")
            }
        }
    }
}
