import XCTest
@testable import HexplateCore

/// Holds ActiveEdit to the original JavaScript. Cases: native/scripts/edit-cases.py; golden: golden.sh.
final class EditGoldenTests: XCTestCase {
    struct Golden: Decodable { let name: String; let result: JSONValue }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    func text(_ v: JSONValue) -> String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([JSONValue].self, from: try fixture("edit-cases")).compactMap(\.object)
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("edit-golden"))
        XCTAssertEqual(cases.count, golden.count)
        for (k, g) in zip(cases, golden) {
            if var rows = k["rows"]?.arrayValue {
                var steps: [JSONValue] = []
                for op in (k["ops"]?.arrayValue ?? []).compactMap(\.arrayValue) {
                    let i = Int(op[1].num), v = op.count > 2 ? op[2] : .null
                    switch op[0].stringValue {
                    case "failure": rows = SetEdit.toggleFailure(rows, i)
                    case "warmup": rows = SetEdit.makeWarmup(rows, i)
                    case "work": rows = SetEdit.makeWork(rows, i)
                    case "rest": rows = SetEdit.setRest(rows, i, v.numberValue)
                    case "note": rows = SetEdit.setNote(rows, i, v.stringValue ?? "")
                    case "copy": rows = SetEdit.copy(rows, i)
                    default: rows = SetEdit.remove(rows, i)
                    }
                    steps.append(.array(rows))
                }
                XCTAssertEqual(text(.array(steps)), text(g.result), g.name)
                continue
            }
            var a = try XCTUnwrap(k["active"]?.object)
            var steps: [JSONValue] = []
            for op in (k["ops"]?.arrayValue ?? []).compactMap(\.arrayValue) {
                let x = Int(op[1].num), y = op.count > 2 ? op[2] : .null
                switch op[0].stringValue {
                case "canMove": steps.append(.bool(ActiveEdit.canMove(a, x, Int(y.num)))); continue
                case "move": ActiveEdit.move(&a, x, Int(y.num))
                case "pair": ActiveEdit.pair(&a, x, Int(y.num))
                case "unpair": ActiveEdit.unpair(&a, x)
                case "remove": ActiveEdit.remove(&a, x)
                case "swap": ActiveEdit.swap(&a, x, with: y.object ?? [:], keepGroup: op[3] == .bool(true))
                default: ActiveEdit.setNoProg(&a, x, y == .bool(true))
                }
                steps.append(.object(a))
            }
            XCTAssertEqual(text(.array(steps)), text(g.result), g.name)
        }
    }
}
