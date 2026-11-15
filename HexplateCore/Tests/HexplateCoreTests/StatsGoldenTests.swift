import XCTest
@testable import HexplateCore

/// Holds Stats and Body to the original JavaScript (onerm.js, strength-level.js,
/// muscle-targets.js, weigh-ins.js). Cases: native/scripts/stats-cases.py; golden: golden.sh.
final class StatsGoldenTests: XCTestCase {
    struct Golden: Decodable { let name: String; let result: JSONValue }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    func text(_ v: JSONValue) -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }
    let ids = ["0043", "0025", "0289", "0027", "0031", "0662", "0017", "0334"]

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([JSONValue].self, from: try fixture("stats-cases")).compactMap(\.object)
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("stats-golden"))
        XCTAssertEqual(cases.count, golden.count)
        let c = ExerciseCatalog.builtIn
        let num = { (v: Double?) in v.map(JSONValue.number) ?? .null }
        for (k, g) in zip(cases, golden) {
            let result: JSONValue
            switch k["op"]?.stringValue {
            case "stats":
                let s = try XCTUnwrap(k["state"]?.object)
                let today = k["today"]?.stringValue ?? ""
                var series: [String: JSONValue] = [:], best: [String: JSONValue] = [:]
                for id in ids {
                    series[id] = .array(Stats.oneRepMaxSeries(s, id, catalog: c).map { .object(["d": .string($0.day), "y": .number($0.estimate), "w": .number($0.weight), "r": .number($0.reps)]) })
                    best[id] = num(Stats.bestOneRepMax(s, id, catalog: c)?.estimate)
                }
                let levels: [JSONValue] = Stats.strengthLevels(s, catalog: c, year: 2026).map { l in
                    let next: JSONValue = l.level < 4 ? .object(["level": .number(Double(l.level + 1)), "name": .string(["beginner", "novice", "intermediate", "advanced", "elite"][l.level + 1]),
                                                                  "ratio": .number(l.thresholds[l.level + 1]), "weight": num(l.nextWeight)]) : .null
                    return .object(["lift": .string(l.lift), "id": .string(l.id), "level": .number(Double(l.level)), "ratio": .number(l.ratio), "e1rm": .number(l.oneRepMax),
                                    "bw": .number(l.bodyweight), "next": next, "thresholds": .array(l.thresholds.map(JSONValue.number))])
                }
                let muscles: [JSONValue] = Stats.weeklyMuscleSets(s, today: today, catalog: c).map {
                    .object(["slug": .string($0.slug), "sets": .number($0.sets), "lo": .number($0.low), "hi": .number($0.high), "status": .string($0.status)])
                }
                result = .object(["series": .object(series), "best": .object(best), "levels": .array(levels), "muscles": .array(muscles)])
            case "estimate":
                result = .array((k["rows"]?.arrayValue ?? []).map { r in
                    let a = r.arrayValue ?? []
                    return num(Stats.estimate1RM(a[0].num, a[1].num, formula: a[2].stringValue ?? "", rir: a[3].numberValue))
                })
            default:
                var s = try XCTUnwrap(k["state"]?.object)
                for a in (k["adds"]?.arrayValue ?? []).compactMap(\.object) {
                    BodyData.addWeighIn(&s, day: a["d"]?.stringValue ?? "", time: a["at"]?.stringValue, weight: a["w"]?.num ?? 0, at: a["t"]?.num ?? 0, id: a["id"]?.stringValue ?? "")
                }
                result = s["bodyweight"] ?? .array([])
            }
            XCTAssertEqual(text(result), text(g.result), g.name)
        }
    }
}
