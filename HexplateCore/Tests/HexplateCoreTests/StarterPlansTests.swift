import XCTest
@testable import HexplateCore

final class StarterPlansTests: XCTestCase {
    func testLoadAddsOnceAndSchedules() throws {
        let plan = try XCTUnwrap(StarterPlans.all.first { $0.id == "ppl" })
        var s: [String: JSONValue] = ["routines": .array([]), "week": .object(["2": .array([.string("mine")])])]
        XCTAssertFalse(StarterPlans.takesOverDays(s, plan))
        var n = 0
        StarterPlans.load(&s, plan) { n += 1; return "r\(n)" }
        XCTAssertEqual(s["routines"]?.arrayValue?.count, 3)
        XCTAssertEqual(s["week"]?.object?["1"], .array([.string("r1")]))
        XCTAssertEqual(s["week"]?.object?["2"], .array([.string("mine")]))
        XCTAssertTrue(StarterPlans.takesOverDays(s, plan))
        // Loading it again reuses the same routines instead of adding copies.
        StarterPlans.load(&s, plan) { n += 1; return "r\(n)" }
        XCTAssertEqual(s["routines"]?.arrayValue?.count, 3)
        // Every exercise in every plan is in the catalogue.
        for p in StarterPlans.all { for r in p.routines { for e in r.ex { XCTAssertNotNil(ExerciseCatalog.builtIn[e.0], "\(p.id) \(e.0)") } } }
    }
}
