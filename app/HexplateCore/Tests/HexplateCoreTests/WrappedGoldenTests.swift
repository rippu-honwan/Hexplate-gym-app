import XCTest
@testable import HexplateCore

/// Holds Wrapped to openGym's "Your year" (lib/wrapped.js, the card list of lib/wrapped-cards.js)
/// for the same profiles. Golden file from app/scripts/golden.sh.
final class WrappedGoldenTests: XCTestCase {
    struct Case: Decodable { let name: String; let state: JSONValue; let year: Int; let now: String }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func num(_ v: JSONValue?) -> Double? { v?.numberValue }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([Case].self, from: try fixture("wrapped-cases"))
        let golden = try JSONDecoder().decode([JSONValue].self, from: try fixture("wrapped-golden"))
        XCTAssertEqual(cases.count, golden.count)
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        for (c, gv) in zip(cases, golden) {
            let g = try XCTUnwrap(gv.object), name = c.name
            let s = c.state.object ?? [:]
            let now = try XCTUnwrap(f.date(from: c.now))
            let history = History(document: try StateDocument(data: JSONEncoder().encode(c.state)))
            let st = Wrapped.stats(s, history: history, year: c.year, now: now)
            XCTAssertEqual(Wrapped.cards(st), (g["cards"]?.arrayValue ?? []).compactMap(\.stringValue), "\(name) cards")
            XCTAssertEqual(Wrapped.personality(st), g["personality"]?.stringValue, "\(name) personality")
            XCTAssertEqual(Wrapped.years(s), (g["years"]?.arrayValue ?? []).compactMap { $0.numberValue.map(Int.init) }, name)
            XCTAssertEqual(Wrapped.seasonYear(now).map(Double.init), num(g["season"]), "\(name) season")
            XCTAssertEqual(Wrapped.homeCardYear(s, now: now).map(Double.init), num(g["home"]), "\(name) home")
            XCTAssertEqual(Wrapped.notifyAt(s, now: now).map { $0.timeIntervalSince1970 * 1000 }, num(g["notify"]), "\(name) notify")
            XCTAssertEqual(Wrapped.adding(s, "opened", year: c.year), g["withOpened"].map { v in
                // JSON drops a null phone the same way the JS spread keeps it: compare with phone as null.
                var o = v.object ?? [:]; o["phone"] = o["phone"] ?? .null; return .object(o)
            }, "\(name) withOpened")

            guard let st, let gs = g["stats"]?.object else { XCTAssertNil(st, name); XCTAssertEqual(g["stats"], .null, name); continue }
            func eq(_ a: Double, _ k: String, _ o: [String: JSONValue] = gs) { XCTAssertEqual(a, num(o[k]) ?? .nan, accuracy: 1e-9, "\(name) \(k)") }
            for (k, v) in [("workouts", st.workouts), ("days", st.days), ("timed", st.timed), ("sets", st.sets), ("distinctExercises", st.distinctExercises), ("prs", st.prs)] {
                eq(Double(v), k)
            }
            for (k, v) in [("perWeek", st.perWeek), ("ms", st.ms), ("avgMs", st.avgMs), ("volume", st.volume), ("volumeKg", st.volumeKg)] { eq(v, k) }
            XCTAssertEqual(st.unit, gs["unit"]?.stringValue, name)
            XCTAssertEqual(st.first, gs["first"]?.stringValue, name)
            let gk = gs["streak"]?.object ?? [:]
            XCTAssertEqual([JSONValue.number(Double(st.streak.weeks)), st.streak.from.map(JSONValue.string) ?? .null, st.streak.to.map(JSONValue.string) ?? .null],
                           [gk["weeks"] ?? .null, gk["from"] ?? .null, gk["to"] ?? .null], "\(name) streak")
            let gt = gs["topExercise"]?.object
            XCTAssertEqual(st.topExercise?.id, gt?["id"]?.stringValue, "\(name) top")
            XCTAssertEqual(st.topExercise.map { Double($0.sets) }, num(gt?["sets"]), "\(name) top sets")
            let gm = gs["topMuscle"]?.object
            XCTAssertEqual(st.topMuscle?.id, gm?["id"]?.stringValue, "\(name) muscle")
            if let m = st.topMuscle { eq(m.share, "share", gm ?? [:]) }
            let gl = gs["load"]?.object ?? [:]
            XCTAssertEqual(Set(st.load.filter { $0.value != 0 }.keys), Set(gl.filter { $0.value.numberValue != 0 }.keys), "\(name) load keys")
            for (k, v) in st.load { XCTAssertEqual(v, num(gl[k]) ?? 0, accuracy: 1e-9, "\(name) load \(k)") }
            let gb = gs["biggestPr"]?.object
            XCTAssertEqual(st.biggestPr?.id, gb?["id"]?.stringValue, "\(name) pr")
            XCTAssertEqual(st.biggestPr?.w, num(gb?["w"]), "\(name) pr w")
            XCTAssertEqual(st.biggestPr?.gain, num(gb?["gain"]), "\(name) pr gain")
            XCTAssertEqual(st.biggestPr?.prev, num(gb?["prev"]), "\(name) pr prev")
            XCTAssertEqual(st.favDay.map { [Double($0.day), Double($0.n)] }, gs["favDay"]?.object.map { [num($0["day"]) ?? -1, num($0["n"]) ?? -1] }, "\(name) favDay")
            XCTAssertEqual(st.daypart?.part, gs["daypart"]?.object?["part"]?.stringValue, "\(name) daypart")
            XCTAssertEqual(st.bestMonth.map { [Double($0.month), Double($0.n), $0.vol] }, gs["bestMonth"]?.object.map { [num($0["month"]) ?? -1, num($0["n"]) ?? -1, num($0["vol"]) ?? -1] }, "\(name) bestMonth")
            XCTAssertEqual(st.months.map(Double.init), (gs["months"]?.arrayValue ?? []).compactMap(\.numberValue), "\(name) months")
            let gbody = gs["body"]?.object
            XCTAssertEqual(st.body.map { [$0.from, $0.to, Double($0.n)] }, gbody.map { [num($0["from"]) ?? -1, num($0["to"]) ?? -1, num($0["n"]) ?? -1] }, "\(name) body")
            let gsh = gs["shares"]?.object ?? [:]
            for (k, v) in [("legs", st.shares.legs), ("upper", st.shares.upper), ("cardio", st.shares.cardio), ("early", st.shares.early), ("late", st.shares.late), ("weekend", st.shares.weekend)] {
                eq(v, k, gsh)
            }
            let cmp = Wrapped.comparison(st.volumeKg), gc = g["comparison"]?.object
            XCTAssertEqual(cmp?.key, gc?["key"]?.stringValue, "\(name) comparison")
            XCTAssertEqual(cmp?.count, num(gc?["count"]), "\(name) comparison count")
        }
    }
}
