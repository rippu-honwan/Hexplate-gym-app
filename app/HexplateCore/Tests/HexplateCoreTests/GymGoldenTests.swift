import XCTest
@testable import HexplateCore

/// Holds Gyms to openGym's lib/gym-inventory.js (syncGymInventory, switchGym). Golden file from app/scripts/golden.sh.
final class GymGoldenTests: XCTestCase {
    struct Case: Decodable { let name, op: String; let state: JSONValue; let prev: JSONValue?; let id: String?; let now: Double }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([Case].self, from: try fixture("gym-cases"))
        let golden = try JSONDecoder().decode([JSONValue].self, from: try fixture("gym-golden"))
        XCTAssertEqual(cases.count, golden.count)
        for (c, g) in zip(cases, golden) {
            var s = c.state.object ?? [:]
            var result: JSONValue = .null
            if c.op == "switch" { result = .bool(Gyms.switchTo(&s, .string(c.id ?? ""), now: c.now)) }
            else { Gyms.sync(&s, prev: c.prev?.object, now: c.now) }
            XCTAssertEqual(result, g.object?["result"] ?? .null, "\(c.name) result")
            XCTAssertEqual(JSONValue.object(s), g.object?["state"], c.name)
        }
    }

    func testAddEditRemove() {
        var s: [String: JSONValue] = ["plates": .object(["kg": .object(["20": .number(2)])])]
        let a = Gyms.add(&s, name: "Home", equipment: ["dumbbell"], now: 1)
        let b = Gyms.add(&s, name: "Big gym", equipment: [], now: 2)
        XCTAssertEqual(s["activeEquipId"], .string(a))
        Gyms.edit(&s, .string(b), name: "Big", equipment: ["barbell"])
        XCTAssertEqual(Gyms.label(Gyms.all(s)[1]), "Big")
        Gyms.sync(&s, prev: nil, now: 3)
        Gyms.remove(&s, .string(a), now: 4)
        XCTAssertEqual(s["activeEquipId"], .string(b))
        XCTAssertEqual(Gyms.all(s).count, 1)
        Gyms.remove(&s, .string(b), now: 5)
        XCTAssertEqual(s["activeEquipId"], .null)
        XCTAssertNil(s["invGym"])
    }
}
