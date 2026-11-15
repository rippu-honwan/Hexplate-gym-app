import XCTest
@testable import HexplateCore

/// Holds WorkoutEdit to the original JavaScript (session-edit.js). Cases:
/// native/scripts/workout-edit-cases.py; golden: golden.sh.
final class WorkoutEditGoldenTests: XCTestCase {
    struct Golden: Decodable { let name: String; let result: JSONValue }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    func text(_ v: JSONValue) -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    /// Sets or removes the value at `path` inside `v`.
    func apply(_ v: JSONValue, _ path: ArraySlice<JSONValue>, _ value: JSONValue?) -> JSONValue {
        guard let head = path.first else { return value ?? .null }
        switch v {
        case .object(var o):
            let k = head.stringValue ?? ""
            if path.count == 1 { o[k] = value } else { o[k] = apply(o[k] ?? .null, path.dropFirst(), value) }
            return .object(o)
        case .array(var a):
            let i = Int(head.num)
            if path.count == 1 { if let value { a[i] = value } else { a.remove(at: i) } } else { a[i] = apply(a[i], path.dropFirst(), value) }
            return .array(a)
        default: return v
        }
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([JSONValue].self, from: try fixture("workout-edit-cases")).compactMap(\.object)
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("workout-edit-golden"))
        XCTAssertEqual(cases.count, golden.count)
        for (k, g) in zip(cases, golden) {
            var s = try XCTUnwrap(k["state"]?.object)
            var failure: JSONValue = .null
            do {
                try WorkoutEdit.begin(&s, key: k["key"]?.stringValue ?? "")
                for op in (k["ops"]?.arrayValue ?? []).compactMap(\.arrayValue) {
                    let path = op[1].arrayValue ?? []
                    s["active"] = apply(s["active"] ?? .null, path[...], op[0] == .string("set") ? op[2] : nil)
                }
                try WorkoutEdit.save(&s, now: 1_800_000_000_000, catalog: .builtIn)
            } catch {
                failure = .string(error.localizedDescription)
            }
            let workouts = (s["workouts"]?.arrayValue ?? []).map { w -> JSONValue in var o = w.object ?? [:]; o["_ts"] = nil; return .object(o) }
            let result: JSONValue = .object(["error": failure, "workouts": .array(workouts), "exWeights": s["exWeights"] ?? .null, "active": s["active"] ?? .null])
            XCTAssertEqual(text(result), text(g.result), g.name)
        }
    }
}
