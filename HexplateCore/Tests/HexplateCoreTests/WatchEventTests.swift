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
        // A new tick asks the phone for its rest (else the watch drops its own); the same tick again does not.
        XCTAssertEqual(WatchLink.apply(tick, to: &s, today: "2026-11-15", now: 0, newId: "n", catalog: .builtIn), .tick(entryIdx: 0, at: 1794700100000))
        XCTAssertEqual(WatchLink.apply(tick, to: &s, today: "2026-11-15", now: 0, newId: "n", catalog: .builtIn), .none)
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

    /// Started on the watch, then on the phone before the watch's start arrived: the phone's workout
    /// takes the watch's id and the watch's sets land in it. Another routine stays apart.
    func testPhoneAdoptsTheWatchStartOfTheSameWorkout() throws {
        let t = 1794700000000.0
        let base = try object(#"{"unit":"kg","routines":[{"id":"r1","name":"Upper","ex":[{"id":"0025","sets":2,"reps":8,"weight":60}]},{"id":"r2","name":"Lower","ex":[{"id":"0025","sets":2,"reps":8,"weight":60}]}],"workouts":[],"bodyweight":[]}"#)
        var s = base
        s["active"] = .object(Session.begin(s, routineIds: ["r1"], bodyweight: nil, id: "mk1", now: t, day: Day.iso(t), catalog: .builtIn))
        let other = s
        let start = try object(#"{"id":"e1","type":"start","wid":"watch-A","routineIds":["r1"],"at":1794699880000}"#)
        XCTAssertEqual(WatchLink.apply(start, to: &s, today: Day.iso(t), now: t, newId: "n", catalog: .builtIn), .none)
        XCTAssertEqual(s["active"]?.object?["id"], .string("watch-A"))
        let tick = try object(#"{"id":"e2","type":"setDone","wid":"watch-A","exId":"0025","entryIdx":0,"setIdx":0,"w":60,"r":8,"at":1794700100000}"#)
        XCTAssertEqual(WatchLink.apply(tick, to: &s, today: Day.iso(t), now: t, newId: "n", catalog: .builtIn), .tick(entryIdx: 0, at: 1794700100000))
        XCTAssertEqual(s["active"]?.object?["entries"]?.arrayValue?[0].object?["sets"]?.arrayValue?[0].object?["done"], .bool(true))

        // Another routine, or a start an hour away: two workouts, as before.
        for ev in [#"{"id":"e3","type":"start","wid":"watch-B","routineIds":["r2"],"at":1794699880000}"#,
                   #"{"id":"e4","type":"start","wid":"watch-C","routineIds":["r1"],"at":1794696000000}"#] {
            var o = other
            _ = WatchLink.apply(try object(ev), to: &o, today: Day.iso(t), now: t, newId: "n", catalog: .builtIn)
            XCTAssertEqual(o["active"]?.object?["id"], .string("mk1"))
        }
    }
}
