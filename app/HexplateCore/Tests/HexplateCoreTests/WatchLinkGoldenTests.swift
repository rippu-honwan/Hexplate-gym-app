import XCTest
@testable import HexplateCore

/// Holds WatchLink to lib/watch-sync.js (buildSnapshot, buildReady, patchSetIn).
/// Cases: app/scripts/watch-cases.py; golden: golden.sh.
final class WatchLinkGoldenTests: XCTestCase {
    struct Golden: Decodable { let name: String; let result: JSONValue }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    func text(_ v: JSONValue) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([JSONValue].self, from: try fixture("watch-cases")).compactMap(\.object)
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("watch-golden"))
        XCTAssertEqual(cases.count, golden.count)
        for (c, g) in zip(cases, golden) {
            var s = try XCTUnwrap(c["state"]?.object)
            let result: JSONValue
            if c["op"] == .string("snapshot") {
                var snap = WatchLink.snapshot(s, today: c["today"]?.stringValue ?? "", restEndsAt: nil, health: false, catalog: .builtIn)
                snap["settings"] = nil
                result = .object(snap)
            } else {
                let ref = try XCTUnwrap(c["ref"]?.object)
                let ok = WatchLink.patchSet(&s, wid: ref["wid"]?.stringValue ?? "", exId: ref["exId"]?.stringValue ?? "",
                                            entryIdx: Int(ref["entryIdx"]?.numberValue ?? 0), setIdx: Int(ref["setIdx"]?.numberValue ?? 0),
                                            side: ref["side"]?.stringValue, c["fields"]?.object ?? [:], ifNewer: c["ifNewer"]?.numberValue)
                result = .object(["ok": .bool(ok), "workouts": s["workouts"] ?? .null, "active": s["active"] ?? .null])
            }
            XCTAssertEqual(text(result), text(g.result), g.name)
        }
    }
}
