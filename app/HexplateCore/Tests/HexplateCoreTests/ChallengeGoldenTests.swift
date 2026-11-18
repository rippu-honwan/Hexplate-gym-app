import XCTest
@testable import HexplateCore

/// Holds Challenges and the week streak to openGym (lib/challenges.js, lib/challenge-copy.js,
/// lib/streak.js) for the same profiles. Golden file from app/scripts/golden.sh.
final class ChallengeGoldenTests: XCTestCase {
    struct Case: Decodable { let name: String; let state: JSONValue; let month: String; let today: String }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func pick(_ p: Challenges.Pick) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(p.id), "n": .number(p.n)]
        if let u = p.u { o["u"] = .string(u) }
        return .object(o)
    }

    func close(_ a: Double, _ b: JSONValue?, _ what: String) {
        XCTAssertEqual(a, b?.numberValue ?? .nan, accuracy: 1e-6, what)
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([Case].self, from: try fixture("challenge-cases"))
        let golden = try JSONDecoder().decode([JSONValue].self, from: try fixture("challenge-golden"))
        XCTAssertEqual(cases.count, golden.count)
        let num = Challenges.number(Locale(identifier: "en"))
        for (c, gv) in zip(cases, golden) {
            let g = try XCTUnwrap(gv.object), name = c.name
            let s = c.state.object ?? [:]
            let history = History(document: try StateDocument(data: JSONEncoder().encode(c.state)))
            let unit = s["unit"] == .string("lb") ? "lb" : "kg"

            let r = Challenges.Reader(s, history: history)
            let l = Challenges.level(r, c.month), gl = try XCTUnwrap(g["level"]?.object)
            XCTAssertEqual(l.fresh, gl["fresh"] == .bool(true), name)
            for (k, v) in [("workouts", l.workouts), ("perWeek", l.perWeek), ("weekRate", l.weekRate), ("volumeKg", l.volumeKg), ("prs", l.prs),
                           ("pullups", l.pullups), ("pushups", l.pushups), ("cardioMin", l.cardioMin), ("weighDays", l.weighDays), ("groups", l.groups)] {
                close(v, gl[k], "\(name) level \(k)")
            }
            XCTAssertEqual(.array(Challenges.pick(r, c.month).map(pick)), g["picked"], "\(name) picked")

            let m = Challenges.month(s, history: history, key: c.month), gm = try XCTUnwrap(g["month"]?.object)
            XCTAssertEqual(.array(m.picked.map(pick)), gm["picked"], "\(name) month")
            XCTAssertEqual(.array(m.done.map(JSONValue.string)), gm["done"], "\(name) done")
            XCTAssertEqual(m.stored, gm["stored"] == .bool(true), name)

            let progress = Challenges.progress(s, history: history, month: m)
            let gp = g["progress"]?.arrayValue ?? []
            XCTAssertEqual(progress.count, gp.count, name)
            for (p, q) in zip(progress, gp.compactMap(\.object)) {
                close(p.have, q["have"], "\(name) \(p.id) have")
                close(p.pct, q["pct"], "\(name) \(p.id) pct")
                XCTAssertEqual(p.done, q["done"] == .bool(true), "\(name) \(p.id) done")
                let pk = Challenges.Pick(id: p.id, n: p.n, u: p.u)
                XCTAssertEqual(Challenges.englishTitle(pk, unit: unit, num: num), q["title"]?.stringValue, "\(name) \(p.id) title")
                XCTAssertEqual(Challenges.count(p, unit: unit, num: num), q["count"]?.stringValue, "\(name) \(p.id) count")
            }
            let newly = Challenges.newlyDone(m, progress)
            XCTAssertEqual(.array(newly.map(JSONValue.string)), g["newly"], "\(name) newly")

            let cleaned = Challenges.json(Challenges.clean(s["challenges"])) ?? .null
            XCTAssertEqual(cleaned, g["cleaned"], "\(name) cleaned")
            var saved = s
            let wrote = Challenges.save(&saved, key: c.month, picked: m.picked, done: newly, now: 1000)
            XCTAssertEqual(wrote, g["saved"]?.object?["wrote"] == .bool(true), "\(name) wrote")
            XCTAssertEqual(saved["challenges"] ?? .null, g["saved"]?.object?["challenges"], "\(name) saved")

            let shelf = Challenges.shelf(s).map { JSONValue.object(["key": .string($0.key), "done": .number(Double($0.done)), "total": .number(Double($0.total)), "gold": .bool($0.gold)]) }
            XCTAssertEqual(.array(shelf), g["shelf"], "\(name) shelf")
            XCTAssertEqual(Challenges.on(s), g["on"] == .bool(true), name)

            let st = WidgetData.streak(s, today: c.today), gs = try XCTUnwrap(g["streak"]?.object)
            XCTAssertEqual([st.current, st.best, st.freezes, st.toNextFreeze], ["current", "best", "freezes", "toNextFreeze"].map { Int(gs[$0]?.numberValue ?? -1) }, name)
            XCTAssertEqual(.array(st.frozen.map(JSONValue.string)), gs["frozen"], "\(name) frozen")
            XCTAssertEqual(.array(st.badges.map { .number(Double($0)) }), gs["badges"], "\(name) badges")
            XCTAssertEqual(st.weekKey, gs["weekKey"]?.stringValue, name)
            for (key, done, planned) in [("celebration", 1, 2), ("celebrationNoPlan", 0, 0)] {
                let cel = WidgetData.celebration(s, st, done: done, planned: planned)
                let want = gs[key]?.object
                XCTAssertEqual(cel?.kind, want?["kind"]?.stringValue, "\(name) \(key)")
                XCTAssertEqual(cel.map { Double($0.weeks) }, want?["weeks"]?.numberValue, "\(name) \(key)")
                XCTAssertEqual(cel?.seen, want?["seen"], "\(name) \(key) seen")
            }
        }
    }
}
