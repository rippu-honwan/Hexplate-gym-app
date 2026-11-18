import XCTest
@testable import HexplateCore

/// Holds Programmes to the original JavaScript (programmes.js, session-start.js programmePlan).
/// Cases: app/scripts/programme-cases.py; golden: golden.sh.
final class ProgrammeGoldenTests: XCTestCase {
    struct Golden: Decodable { let name: String; let result: JSONValue }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    func text(_ v: JSONValue) -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([JSONValue].self, from: try fixture("programme-cases")).compactMap(\.object)
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("programme-golden"))
        XCTAssertEqual(cases.count, golden.count)
        let c = ExerciseCatalog.builtIn, now = 1_800_000_000_000.0
        for (k, g) in zip(cases, golden) {
            var s = try XCTUnwrap(k["state"]?.object)
            func plan() -> [String: JSONValue] {
                ["programme": s["programme"] ?? .null, "week": s["week"] ?? .null, "scheduleMode": s["scheduleMode"] ?? .null,
                 "rotation": s["rotation"] ?? .null, "queue": s["queue"] ?? .null]
            }
            var steps: [JSONValue] = []
            for op in (k["ops"]?.arrayValue ?? []).compactMap(\.arrayValue) {
                let a = op.count > 1 ? op[1] : .null, b = op.count > 2 ? op[2] : .null, d = op.count > 3 ? op[3] : .null
                let id = a.stringValue ?? "", day = b.stringValue ?? ""
                var r: JSONValue = .null
                switch op[0].stringValue {
                case "list": r = .array(Programmes.all(s).map(JSONValue.object))
                case "resize": r = .array(Programmes.resizeWeeks(Programmes.byId(s, id)?["weeks"]?.arrayValue ?? [], Int(b.num)))
                case "step": r = .object(Programmes.stepWeek(Programmes.byId(s, id)?["weeks"]?.arrayValue?[Int(b.num)]))
                case "schedule": r = .object(Programmes.currentSchedule(s))
                case "start":
                    let ok = Programmes.start(&s, id, today: day, now: now) { "rot" }
                    r = .object(plan().merging(["ok": .bool(ok)]) { $1 })
                case "pause": Programmes.pause(&s, today: id); r = .object(plan())
                case "resume": Programmes.resume(&s, today: id); r = .object(plan())
                case "again": Programmes.again(&s, today: id, bump: b.num); r = .object(plan())
                case "end": Programmes.end(&s, today: id, now: now); r = .object(plan())
                case "delete":
                    Programmes.delete(&s, id, today: day, now: now)
                    r = .object(plan().merging(["programmes": .array((s["programmes"]?.object ?? [:]).keys.sorted().map(JSONValue.string))]) { $1 })
                case "status":
                    if let st = Programmes.status(s, today: id) {
                        r = .object(["week": .number(Double(st.week)), "weeks": .number(Double(st.weeks)), "done": .bool(st.done), "paused": .bool(st.paused),
                                     "cycle": .number(Double(st.cycle)), "current": st.current.map(JSONValue.object) ?? .null,
                                     "chip": Programmes.chip(s, today: id).map(JSONValue.string) ?? .null])
                    }
                case "slot":
                    if let x = Programmes.slot(s, rid: id, exId: day, iso: d.stringValue ?? "") {
                        r = .object(["pct": x.pct.map(JSONValue.number) ?? .null, "rpe": x.rpe.map(JSONValue.number) ?? .null, "deload": .bool(x.deload),
                                     "week": .number(Double(x.week)), "weeks": .number(Double(x.weeks))])
                    }
                default:
                    let routine = try XCTUnwrap(s["routines"]?.arrayValue?.compactMap(\.object).first { $0["id"]?.stringValue == id })
                    r = .array(Session.entries(s, routine: routine, catalog: c, today: day))
                }
                steps.append(r)
            }
            XCTAssertEqual(text(.array(steps)), text(g.result), g.name)
        }
    }
}
