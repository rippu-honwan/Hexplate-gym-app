import XCTest
@testable import HexplateCore

/// Holds SessionCopy to the original JavaScript (session-routines.js, session-repeat.js).
/// Cases: app/scripts/copy-cases.py; golden: golden.sh.
final class CopyGoldenTests: XCTestCase {
    struct Golden: Decodable { let name: String; let result: JSONValue }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    /// Sorted-keys JSON with superset tags renumbered by first appearance, as the golden script does.
    func text(_ v: JSONValue) -> String {
        var seen: [String: String] = [:]
        func tidy(_ v: JSONValue) -> JSONValue {
            switch v {
            case .array(let a): return .array(a.map(tidy))
            case .object(let o):
                var out: [String: JSONValue] = [:]
                for k in o.keys.sorted() {
                    if k == "sg", let s = o[k]?.stringValue {
                        if seen[s] == nil { seen[s] = "g\(seen.count)" }
                        out[k] = .string(seen[s]!)
                    } else { out[k] = tidy(o[k]!) }
                }
                return .object(out)
            default: return v
            }
        }
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(tidy(v))).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([JSONValue].self, from: try fixture("copy-cases")).compactMap(\.object)
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("copy-golden"))
        XCTAssertEqual(cases.count, golden.count)
        let c = ExerciseCatalog.builtIn
        for (k, g) in zip(cases, golden) {
            let w = try XCTUnwrap(k["w"]?.object)
            var s = try XCTUnwrap(k["state"]?.object); s["workouts"] = .array([.object(w)])
            let routines = (s["routines"]?.arrayValue ?? []).compactMap(\.object)
            var routine = SessionCopy.routine(from: w, name: w["name"]?.stringValue, routines: routines, catalog: c)
            routine?["id"] = nil
            let r = SessionCopy.repeatEntries(s, w, catalog: c) { c[$0] != nil }
            // The routine and the repeat are tidied as one document, like the golden script.
            let got: JSONValue = .object(["routine": routine.map(JSONValue.object) ?? .null,
                                          "repeat": .object(["entries": .array(r.entries), "skipped": .number(Double(r.skipped))])])
            XCTAssertEqual(text(got), text(g.result), g.name)
        }
    }
}
