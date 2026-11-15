import XCTest
@testable import HexplateCore

/// Watch events applied to the document (the flow of watch-sync.js applyEach).
final class WatchEventTests: XCTestCase {
    func object(_ json: String) throws -> [String: JSONValue] {
        try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).object)
    }

    func testStartTickFinish() throws {
        var s = try object(#"{"unit":"kg","routines":[{"id":"r1","name":"Upper","ex":[{"id":"0025","sets":2,"reps":8,"weight":60}]}],"workouts":[],"bodyweight":[]}"#)
        let start = try object(#"{"id":"e1","type":"start","wid":"wx","routineIds":["r1"],"at":1794700000000,"bw":71.5}"#)
        XCTAssertEqual(WatchLink.apply(start, to: &s, today: "2026-11-15", now: 0, newId: "n", catalog: .builtIn), .none)
        XCTAssertEqual(s["active"]?.object?["id"], .string("wx"))
        XCTAssertEqual(s["active"]?.object?["bw"], .number(71.5))

        let tick = try object(#"{"id":"e2","type":"setDone","wid":"wx","exId":"0025","entryIdx":0,"setIdx":1,"w":62.5,"r":7,"at":1794700100000,"hr":{"avg":120.4,"max":140},"rir":2.3}"#)
        _ = WatchLink.apply(tick, to: &s, today: "2026-11-15", now: 0, newId: "n", catalog: .builtIn)
        let set = s["active"]?.object?["entries"]?.arrayValue?[0].object?["sets"]?.arrayValue?[1].object
        XCTAssertEqual(set?["done"], .bool(true))
        XCTAssertEqual(set?["w"], .number(62.5))
        XCTAssertEqual(set?["hr"], .object(["avg": .number(120), "max": .number(140)]))
        XCTAssertEqual(set?["rir"], .number(2.5))

        let weigh = try object(#"{"id":"e3","type":"weighIn","w":71.2,"at":1794700200000}"#)
        _ = WatchLink.apply(weigh, to: &s, today: "2026-11-15", now: 0, newId: "n", catalog: .builtIn)
        XCTAssertEqual(BodyData.weights(s).last?.weight, 71.2)

        XCTAssertEqual(WatchLink.apply(try object(#"{"id":"e4","type":"rest","wid":"wx","endsAt":5}"#), to: &s, today: "", now: 0, newId: "n", catalog: .builtIn), .rest(endsAt: 5))
        XCTAssertEqual(WatchLink.apply(try object(#"{"id":"e5","type":"finish","wid":"other"}"#), to: &s, today: "", now: 0, newId: "n", catalog: .builtIn), .none)
        XCTAssertEqual(WatchLink.apply(try object(#"{"id":"e6","type":"finish","wid":"wx"}"#), to: &s, today: "", now: 0, newId: "n", catalog: .builtIn), .finish)
    }
}
