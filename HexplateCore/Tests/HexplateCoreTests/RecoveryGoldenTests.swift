import XCTest
@testable import HexplateCore

/// Holds Recovery to the original JavaScript (recovery.js, recovery-hint.js).
/// Cases: native/scripts/recovery-cases.py; golden: golden.sh.
final class RecoveryGoldenTests: XCTestCase {
    struct Golden: Decodable { let name: String; let result: JSONValue }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    func text(_ v: JSONValue) -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([JSONValue].self, from: try fixture("recovery-cases")).compactMap(\.object)
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("recovery-golden"))
        XCTAssertEqual(cases.count, golden.count)
        let c = ExerciseCatalog.builtIn
        for (k, g) in zip(cases, golden) {
            let today = k["today"]?.stringValue ?? ""
            let now = Day.noon(today) + (k["hours"]?.num ?? 0) * 3_600_000
            let bw = k["bodyweightKg"]?.numberValue
            let result: JSONValue
            if k["op"] == .string("fatigue") {
                let ws = (k["workouts"]?.arrayValue ?? []).compactMap(\.object)
                let f = Recovery.fatigue(ws, now: now, unit: k["unit"]?.stringValue, bodyweightKg: bw, catalog: c)
                result = .object(f.mapValues { .number(($0 * 1e6).rounded() / 1e6) })
            } else {
                let s = try XCTUnwrap(k["state"]?.object)
                let ws = (s["workouts"]?.arrayValue ?? []).compactMap(\.object)
                let f = Recovery.fatigue(ws, now: now, unit: s["unit"]?.stringValue, bodyweightKg: bw, catalog: c)
                if let h = Recovery.hint(s, now: now, today: today, fatigue: f, catalog: c) {
                    var o: [String: JSONValue] = ["kind": .string(h.kind)]
                    if let r = h.region { o["region"] = .string(r); o["day"] = h.day.map(JSONValue.string) ?? .null }
                    if let r = h.routine { o["routine"] = .string(r) }
                    if let gr = h.group { o["group"] = .string(gr); o["days"] = h.days.map { .number(Double($0)) } ?? .null }
                    let t = Recovery.text(h, today: today)
                    result = .object(["hint": .object(o), "text": .array([.string(t.0), .string(t.1)])])
                } else {
                    result = .object(["hint": .null, "text": .null])
                }
            }
            XCTAssertEqual(text(result), text(g.result), g.name)
        }
    }
}
