import XCTest
@testable import HexplateCore

/// Holds RoutineOps to the original JavaScript (routines.js, history.js, superset-meta.js).
/// The golden file is written by native/scripts/golden.sh; never edit it by hand.
final class RoutineGoldenTests: XCTestCase {
    struct Golden: Decodable { let name: String; let result: JSONValue? }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    func text(_ v: JSONValue?) -> String { v.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "absent" }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([JSONValue].self, from: try fixture("routine-cases")).compactMap(\.object)
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("routine-golden"))
        XCTAssertEqual(cases.map { $0["name"] }, golden.map { .string($0.name) })
        XCTAssertGreaterThan(cases.count, 60)

        let custom = try JSONDecoder().decode(Exercise.self, from: Data(#"{"id":"cx-custom","n":"one arm custom thing","custom":true,"eq":"body weight","bp":"waist"}"#.utf8))
        let catalog = ExerciseCatalog.builtIn.adding(custom: [custom])
        let failed: JSONValue = .object(["error": .bool(true)])

        for (c, g) in zip(cases, golden) {
            let items = c["items"]?.arrayValue ?? []
            let index = { (k: String) in Int(c[k]?.numberValue ?? -1) }
            var result: JSONValue
            switch c["op"]?.stringValue {
            case "deleteRoutine":
                var s = try XCTUnwrap(c["state"]?.object)
                let before = s["dayPlan"]?.object ?? [:]
                RoutineOps.deleteRoutine(&s, id: try XCTUnwrap(c["id"]?.stringValue))
                let dropped = before.filter { s["dayPlan"]?.object?[$0.key] == nil }
                result = .object(["state": .object(s), "dropped": .object(dropped)])
            case "copyRoutine":
                var copy = RoutineOps.copyRoutine(try XCTUnwrap(c["routine"]?.object), newId: "new")
                XCTAssertEqual(copy["id"], .string("new"))
                copy["id"] = .null
                result = .object(copy)
            case "pair": result = RoutineOps.pairAdjacent(items, index("first"), index("second")).map(JSONValue.array) ?? failed
            case "unpair": result = RoutineOps.unpairSuperset(items, index("idx")).map(JSONValue.array) ?? failed
            case "cleanup":
                var ex = items
                RoutineOps.cleanupSupersets(&ex)
                result = .array(ex)
            case "picked": result = .object(RoutineOps.pickedConfig(id: try XCTUnwrap(c["id"]?.stringValue), catalog: catalog))
            case "exLine":
                let settings = ProfileSettings(["unit": try XCTUnwrap(c["unit"])])
                result = .string(RoutineOps.line(try XCTUnwrap(c["cfg"]?.object), catalog: catalog, settings: settings))
            default:
                XCTFail("unknown op in \(g.name)")
                continue
            }
            if result != g.result { XCTFail("\(g.name)\n  swift \(text(result))\n  js    \(text(g.result))") }
        }
    }

    func testNewIdsLookLikeTheOriginals() {
        let id = RoutineOps.newId(now: 1_794_594_775_901)
        XCTAssertTrue(id.hasPrefix(String(1_794_594_775_901, radix: 36)), id)   // the time in base 36, as uid() writes it
        XCTAssertEqual(id.count, 13)
        XCTAssertNotEqual(id, RoutineOps.newId(now: 1_794_594_775_901))
    }
}
