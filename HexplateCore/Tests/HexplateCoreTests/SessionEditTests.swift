import XCTest
@testable import HexplateCore

/// The live-session edits (values worked out from workout-model.js by hand).
final class SessionEditTests: XCTestCase {
    func row(_ json: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }

    func testEdits() throws {
        let side = try row(#"{"w":6,"r":12,"done":false,"sides":{"L":{"w":6,"r":6,"done":false},"R":{"w":6,"r":6,"done":false}}}"#)
        let left = Session.settingDone(side, true, side: "L", at: 5)
        XCTAssertEqual(left.object?["done"], .bool(false))
        XCTAssertEqual(Session.settingDone(left, true, side: "R", at: 6).object?["done"], .bool(true))

        let drop = Session.addingDrop(try row(#"{"w":60,"r":8,"done":true}"#), step: 2.5)
        XCTAssertEqual(drop.object?["drops"], .array([.object(["w": .number(47.5), "r": .number(8)])]))
        XCTAssertEqual(Session.addingCluster(drop, restSec: 15).object?["clusters"], .array([.object(["r": .number(4), "restSec": .number(15)])]))

        let warm = Session.addingWarmup([try row(#"{"w":60,"r":5,"done":false}"#)], step: 5, floor: 20)
        XCTAssertEqual(warm.count, 2)
        XCTAssertEqual(warm[0].object?["w"], .number(30))
        XCTAssertTrue(Session.isWarmup(warm[0]))

        let history = try row(#"{"workouts":[{"entries":[{"id":"0025","sets":[{"w":50,"r":8,"done":true}]}]}]}"#).object!
        let active = try row(#"{"entries":[{"id":"0025","sets":[{"w":52.5,"r":8,"done":true}]},{"id":"0043","sets":[{"w":60,"r":5,"done":false}]}]}"#).object!
        XCTAssertEqual(Session.records(active, in: history, catalog: .builtIn), ["0025"])
    }
}
