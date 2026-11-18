import XCTest
@testable import HexplateCore

/// Holds the CSV export to openGym's over date ranges (lib/export-csv.js workoutsCSV, bodyCSV,
/// csvCounts). Golden file from app/scripts/golden.sh.
final class CSVGoldenTests: XCTestCase {
    struct Case: Decodable { let name: String; let state: JSONValue; let from: String?; let to: String? }
    struct Golden: Decodable {
        struct Counts: Decodable { let workouts, sets, weighIns, measurements: Int }
        let name: String, workouts: String, body: String, counts: Counts
    }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([Case].self, from: try fixture("csv-cases"))
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("csv-golden"))
        XCTAssertEqual(cases.count, golden.count)
        for (c, g) in zip(cases, golden) {
            let s = c.state.object ?? [:]
            let catalog = ExerciseCatalog.builtIn.adding(custom: (s["customEx"]?.arrayValue ?? []).compactMap { try? $0.decoded(as: Exercise.self) })
            XCTAssertEqual(Export.workoutsCSV(s, catalog: catalog, from: c.from, to: c.to), g.workouts, c.name)
            XCTAssertEqual(Export.bodyCSV(s, from: c.from, to: c.to), g.body, c.name)
            let n = Export.counts(s, catalog: catalog, from: c.from, to: c.to)
            XCTAssertEqual([n.workouts, n.sets, n.weighIns, n.measurements], [g.counts.workouts, g.counts.sets, g.counts.weighIns, g.counts.measurements], c.name)
        }
    }
}
