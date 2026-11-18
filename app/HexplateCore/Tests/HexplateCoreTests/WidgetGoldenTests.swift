import XCTest
@testable import HexplateCore

/// Holds WidgetData to the original JavaScript (widgets.js buildWidgetSnapshot, streak.js), on its
/// numbers and structure. Cases: native/scripts/widget-cases.py; golden: golden.sh.
final class WidgetGoldenTests: XCTestCase {
    struct Golden: Decodable { let name: String; let result: JSONValue }
    static let words: Set<String> = ["weekday", "labels", "line", "bestLine", "monthLine", "currentText", "goalText", "nowText", "prevText", "value", "challenges", "level", "accent", "ink"]

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    func text(_ v: JSONValue) -> String {
        func strip(_ v: JSONValue) -> JSONValue {
            switch v {
            case .array(let a): return .array(a.map(strip))
            case .object(let o): return .object(o.filter { !Self.words.contains($0.key) }.mapValues(strip))
            default: return v
            }
        }
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(strip(v))).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([JSONValue].self, from: try fixture("widget-cases")).compactMap(\.object)
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("widget-golden"))
        XCTAssertEqual(cases.count, golden.count)
        for (k, g) in zip(cases, golden) {
            let s = try XCTUnwrap(k["state"]?.object)
            let history = History(document: try StateDocument(data: JSONEncoder().encode(JSONValue.object(s))))
            let snap = WidgetData.snapshot(s, history: history, today: k["today"]?.stringValue ?? "", catalog: .builtIn)
            XCTAssertEqual(text(.object(snap)), text(g.result), g.name)
        }
    }
}
