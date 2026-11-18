import XCTest
@testable import HexplateCore

/// SyncMerge runs the bundled JS: this holds the bundle (and the trip through JavaScriptCore) to
/// what frontend/src/lib/sync-merge.js gives under Node. Cases: app/scripts/merge-cases.mjs;
/// golden: golden.sh.
final class MergeGoldenTests: XCTestCase {
    typealias Object = [String: JSONValue]

    func fixture(_ name: String) throws -> [Object] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: url)).compactMap(\.object)
    }

    func testMatchesTheJavaScript() throws {
        let cases = try fixture("merge-cases"), golden = try fixture("merge-golden")
        XCTAssertEqual(cases.count, golden.count)
        for (c, g) in zip(cases, golden) {
            let local = try XCTUnwrap(c["local"]?.object), server = try XCTUnwrap(c["server"]?.object)
            let merged = try SyncMerge.merge(local, server)
            let name = g["name"]?.stringValue ?? ""
            XCTAssertEqual(JSONValue.object(merged), g["merged"], name)
            XCTAssertEqual(Double(try SyncMerge.changes(merged, since: local)), g["here"]?.numberValue, name)
            XCTAssertEqual(Double(try SyncMerge.changes(merged, since: server)), g["there"]?.numberValue, name)
        }
    }

    func testPlan() {
        let base = SyncPlan.Base(rev: 5, wid: "w5", ts: 100)
        let s = { (wid: String, wids: [String]) -> Object in ["_wid": .string(wid), "_wids": .array(wids.map(JSONValue.string))] }
        XCTAssertEqual(SyncPlan.decide(base: base, localTs: 100, rev: 5, server: s("w5", [])), .upToDate)
        XCTAssertEqual(SyncPlan.decide(base: base, localTs: 150, rev: 5, server: s("w5", [])), .push)
        XCTAssertEqual(SyncPlan.decide(base: base, localTs: 100, rev: 6, server: s("w6", ["w4", "w5"])), .adopt)
        XCTAssertEqual(SyncPlan.decide(base: base, localTs: 150, rev: 6, server: s("w6", ["w5"])), .merge)
        // The server went back in time: never taken as it is.
        XCTAssertEqual(SyncPlan.decide(base: base, localTs: 100, rev: 6, server: s("x6", ["x5"])), .merge)
        XCTAssertEqual(SyncPlan.decide(base: nil, localTs: 100, rev: 6, server: s("w6", [])), .merge)
        XCTAssertEqual(SyncPlan.decide(base: base, localTs: 100, rev: 0, server: nil), .push)
    }
}
