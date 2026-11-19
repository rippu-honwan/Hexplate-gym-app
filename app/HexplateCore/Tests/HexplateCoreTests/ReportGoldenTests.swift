import XCTest
@testable import HexplateCore

/// Holds Report to openGym's lib/report.js reportData. Golden file from app/scripts/golden.sh.
final class ReportGoldenTests: XCTestCase {
    struct Cases: Decodable {
        struct Case: Decodable { let name: String; let state: Int; let range: String; let from: String?; let to: String?; let today: String }
        let states: [JSONValue]; let cases: [Case]
    }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    /// Swift's report in the golden file's shape.
    func json(_ r: Report.Data) -> JSONValue {
        let n = { (v: Double?) in v.map(JSONValue.number) ?? .null }
        let i = { (v: Int) in JSONValue.number(Double(v)) }
        func totals(_ t: Report.Totals) -> JSONValue {
            .object(["workouts": i(t.workouts), "volume": .number(t.volume), "sets": i(t.sets), "ms": .number(t.ms), "prs": i(t.prs), "days": i(t.days),
                     "bwStart": n(t.bwStart), "bwEnd": n(t.bwEnd), "bwChange": n(t.bwChange)])
        }
        return .object([
            "range": .object(["from": .string(r.range.from), "to": .string(r.range.to), "days": i(r.range.days)]),
            "totals": totals(r.totals), "prev": totals(r.prev), "perWeek": .number(r.perWeek),
            "buckets": .object(["unit": .string(r.bucketUnit), "buckets": .array(r.buckets.map {
                .object(["key": .string($0.key), "from": .string($0.from), "volume": .number($0.volume), "sets": i($0.sets), "workouts": i($0.workouts)]) })]),
            "calendar": .array(r.calendar.map { .object(["d": .string($0.d), "n": i($0.n), "volume": .number($0.volume), "level": i($0.level)]) }),
            "muscles": .object(["worked": .array(r.worked.map { .object(["slug": .string($0.slug), "sets": .number($0.sets)]) }),
                                "missed": .array(r.missed.map(JSONValue.string))]),
            "lifts": .array(r.lifts.map { .object(["id": .string($0.id), "ys": .array($0.points.map { .number($0.estimate) }), "best": n($0.best?.estimate), "change": n($0.change)]) }),
            "prs": .array(r.prs.map { .object(["id": .string($0.id), "d": .string($0.d), "est": n($0.best?.estimate)]) }),
            "bodyweight": .array(r.bodyweight.map { .object(["d": .string($0.d), "w": .number($0.w)]) }),
            "streak": .object(["weeks": r.streak.weeks.map(i) ?? .null, "longestWeeks": i(r.streak.longestWeeks), "longestDays": i(r.streak.longestDays),
                               "activeDays": i(r.streak.activeDays), "restDays": i(r.streak.restDays)]),
        ])
    }

    func same(_ a: JSONValue?, _ b: JSONValue?, _ path: String) {
        switch (a, b) {
        case (.number(let x)?, .number(let y)?): XCTAssertEqual(x, y, accuracy: 1e-6, path)
        case (.object(let x)?, .object(let y)?):
            XCTAssertEqual(Set(x.keys), Set(y.keys), path)
            for k in x.keys { same(x[k], y[k], "\(path).\(k)") }
        case (.array(let x)?, .array(let y)?):
            XCTAssertEqual(x.count, y.count, "\(path) count")
            for (k, (p, q)) in zip(x, y).enumerated() { same(p, q, "\(path)[\(k)]") }
        default: XCTAssertEqual(a ?? .null, b ?? .null, path)
        }
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode(Cases.self, from: try fixture("report-cases"))
        let golden = try JSONDecoder().decode([JSONValue].self, from: try fixture("report-golden"))
        XCTAssertEqual(cases.cases.count, golden.count)
        for (c, g) in zip(cases.cases, golden) {
            let s = cases.states[c.state].object ?? [:]
            let r = Report.data(s, catalog: .builtIn, kind: c.range, from: c.from, to: c.to, today: c.today)
            var want = g.object ?? [:]
            want["name"] = nil
            same(json(r), .object(want), c.name)
        }
    }
}
