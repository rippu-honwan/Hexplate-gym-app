import XCTest
@testable import HexplateCore

/// Holds Backfill to the original JavaScript (backfill.js and the past branch of doFinishWorkout).
/// Cases: app/scripts/backfill-cases.py; golden: golden.sh.
final class BackfillGoldenTests: XCTestCase {
    struct Golden: Decodable { let name: String; let result: JSONValue }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    /// Sorted-keys JSON without stamps or empty top weights, as the golden script writes it.
    func text(_ v: JSONValue) -> String {
        func strip(_ v: JSONValue) -> JSONValue {
            switch v {
            case .array(let a): return .array(a.map(strip))
            case .object(let o): return .object(o.filter { $0.key != "_ts" && !($0.key == "topW" && $0.value == .null) }.mapValues(strip))
            default: return v
            }
        }
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(strip(v))).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([JSONValue].self, from: try fixture("backfill-cases")).compactMap(\.object)
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("backfill-golden"))
        XCTAssertEqual(cases.count, golden.count)
        let c = ExerciseCatalog.builtIn
        for (k, g) in zip(cases, golden) {
            var s = try XCTUnwrap(k["state"]?.object)
            let begun = Backfill.begin(s, iso: k["iso"]?.stringValue ?? "", start: k["start"]?.num ?? 0, durationMin: max(1, Int(k["dur"]?.num ?? 0)),
                                       routineIds: (k["routineIds"]?.arrayValue ?? []).compactMap(\.stringValue),
                                       replaceId: k["replaceId"]?.stringValue, id: "new", catalog: c)
            var a = begun
            if let note = k["note"] { a["note"] = note }
            a["entries"] = .array(Backfill.markAllDone(a["entries"]?.arrayValue ?? []))
            s["active"] = .object(a)
            _ = Backfill.finish(&s, now: 1, catalog: c)
            XCTAssertNil(s["active"])
            XCTAssertEqual(text(.object(["begun": .object(begun), "workouts": s["workouts"] ?? .null])), text(g.result), g.name)
        }
    }
}
