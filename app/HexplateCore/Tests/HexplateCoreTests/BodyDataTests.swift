import XCTest
@testable import HexplateCore

final class BodyDataTests: XCTestCase {
    typealias Object = [String: JSONValue]

    func testTrunkFieldsSaveReadAndPrefixFiveInvariance() {
        // StatsView reads `compositionFields.prefix(5)`: keep those five slots intact.
        XCTAssertEqual(
            BodyData.compositionFields.prefix(5).map(\.id),
            ["bodyFat", "scale-fatMass", "scale-visceral", "scale-muscleMass", "scale-muscle"]
        )
        XCTAssertTrue(BodyData.compositionFields.contains { $0.id == "scale-fatTrunk" && $0.unit == "%" })
        XCTAssertTrue(BodyData.compositionFields.contains { $0.id == "scale-muscleTrunk" && $0.unit == "kg" })

        var s: Object = [:]
        BodyData.saveMeasurements(
            &s,
            day: "2026-11-25",
            at: 1_000,
            [
                "bodyFat": 16.4,
                "scale-fatTrunk": 17.8,
                "scale-muscleTrunk": 25.2,
                "scale-muscleArmL": 3.1,
                "scale-muscleArmR": 3.4,
            ],
            fields: BodyData.compositionFields
        )

        let vals = BodyData.values(s, day: "2026-11-25")
        XCTAssertEqual(vals["bodyFat"], 16.4)
        XCTAssertEqual(vals["scale-fatTrunk"], 17.8)
        XCTAssertEqual(vals["scale-muscleTrunk"], 25.2)
        XCTAssertEqual(vals["scale-muscleArmL"], 3.1)
        XCTAssertEqual(vals["scale-muscleArmR"], 3.4)
    }

    func testScanHistoryIgnoresTapeOnlyJoinsWeightAndSortsChronologically() {
        var s: Object = [:]
        BodyData.addWeighIn(&s, day: "2026-11-20", time: "07:30", weight: 70.5, at: 1_000, id: "w1")
        BodyData.addWeighIn(&s, day: "2026-11-10", time: "07:30", weight: 71.2, at: 500, id: "w0")

        // Tape-only measurement day must be excluded from scanHistory.
        BodyData.saveMeasurements(&s, day: "2026-11-15", at: 800, ["waist": 80.5], fields: BodyData.tapeFields)
        BodyData.saveMeasurements(
            &s,
            day: "2026-11-20",
            at: 1_000,
            ["bodyFat": 15.8, "scale-muscleMass": 56.4, "scale-muscleTrunk": 25.0],
            fields: BodyData.compositionFields
        )
        BodyData.saveMeasurements(
            &s,
            day: "2026-11-10",
            at: 500,
            ["bodyFat": 16.9, "scale-muscleMass": 55.8],
            fields: BodyData.compositionFields
        )

        let scans = BodyData.scanHistory(s)
        XCTAssertEqual(scans.map(\.day), ["2026-11-10", "2026-11-20"])
        XCTAssertEqual(scans[0].weight, 71.2)
        XCTAssertEqual(scans[0].bodyFat, 16.9)
        XCTAssertFalse(scans[0].hasSegmentalMuscle)
        XCTAssertEqual(scans[1].weight, 70.5)
        XCTAssertEqual(scans[1].muscleTrunk, 25.0)
        XCTAssertTrue(scans[1].hasSegmentalMuscle)
    }

    func testAnatomicalSidePolarityFrontAndBack() {
        // Front view: facing viewer -> viewer-left (x < midX) is person's anatomical RIGHT.
        XCTAssertEqual(BodyData.anatomicalSide(subpathMidX: 200, boxMidX: 363.5, isFront: true), .right)
        XCTAssertEqual(BodyData.anatomicalSide(subpathMidX: 520, boxMidX: 363.5, isFront: true), .left)

        // Back view: facing away -> viewer-left (x < midX) is person's anatomical LEFT.
        XCTAssertEqual(BodyData.anatomicalSide(subpathMidX: 900, boxMidX: 1081.5, isFront: false), .left)
        XCTAssertEqual(BodyData.anatomicalSide(subpathMidX: 1250, boxMidX: 1081.5, isFront: false), .right)
    }

    func testBundledBodyPathsSplitCleanlyIntoLeftAndRight() throws {
        struct RawView: Decodable {
            let vb: String
            let p: [String: [String]]
        }

        let url = try XCTUnwrap(ExerciseCatalog.bodyPathsURL)
        let raw = try JSONDecoder().decode([String: [String: RawView]].self, from: Data(contentsOf: url))
        let bilateralSlugs = Set(BodyData.armSlugs + BodyData.legSlugs)

        for sex in ["male", "female"] {
            let views = try XCTUnwrap(raw[sex])
            for sideName in ["front", "back"] {
                let view = try XCTUnwrap(views[sideName])
                let vb = view.vb.split(separator: " ").compactMap { Double($0) }
                XCTAssertEqual(vb.count, 4)
                let boxMidX = vb[0] + vb[2] / 2
                let isFront = sideName == "front"

                for slug in bilateralSlugs {
                    guard let paths = view.p[slug] else { continue }
                    var leftCount = 0
                    var rightCount = 0
                    for d in paths {
                        // Extract initial move-to X coordinate to check side split across boxMidX.
                        guard let m = d.firstMatch(of: /^\s*[Mm]\s*([+-]?\d*\.?\d+)/),
                              let x = Double(m.1) else {
                            XCTFail("Unparseable SVG subpath for \(sex).\(sideName).\(slug)")
                            continue
                        }
                        if BodyData.anatomicalSide(subpathMidX: x, boxMidX: boxMidX, isFront: isFront) == .left {
                            leftCount += 1
                        } else {
                            rightCount += 1
                        }
                    }
                    XCTAssertGreaterThan(leftCount, 0, "\(sex).\(sideName).\(slug) missing anatomical left subpath")
                    XCTAssertGreaterThan(rightCount, 0, "\(sex).\(sideName).\(slug) missing anatomical right subpath")
                    XCTAssertEqual(leftCount, rightCount, "\(sex).\(sideName).\(slug) should split symmetrically")
                }
            }
        }
    }

    func testSegmentShadingRoutesTrunkToLevelsAndNormalizesLimbPairs() throws {
        let scan = BodyData.Scan(
            day: "2026-11-25",
            weight: 70.0,
            bodyFat: 16.0,
            fatMass: 11.2,
            visceralFat: 6.0,
            muscleMass: 55.0,
            skeletalMuscle: 32.0,
            boneMass: 3.1,
            bodyWater: 41.0,
            smi: 8.1,
            bmi: 22.8,
            bmr: 1680,
            fatArmL: 15.0,
            fatArmR: 15.0,
            fatTrunk: 20.0,
            fatLegL: 14.0,
            fatLegR: 14.5,
            muscleArmL: 3.0,
            muscleArmR: 3.3333, // ~10% stronger right arm vs ~25 kg trunk
            muscleTrunk: 25.0,
            muscleLegL: 9.0,
            muscleLegR: 9.0
        )

        let muscle = BodyData.segmentShading(for: scan, metric: .muscle)
        // Trunk slugs go strictly to `levels`, never `sideLevels`.
        for slug in BodyData.trunkSlugs {
            XCTAssertNotNil(muscle.levels[slug])
            XCTAssertNil(muscle.sideLevels[BodyData.PartSide(slug: slug, side: .left)])
            XCTAssertNil(muscle.sideLevels[BodyData.PartSide(slug: slug, side: .right)])
        }
        // Bilateral arms: right arm = 1.0, left arm ~0.86 (visible contrast despite 25 kg trunk).
        let armL = try XCTUnwrap(muscle.sideLevels[BodyData.PartSide(slug: "biceps", side: .left)])
        let armR = try XCTUnwrap(muscle.sideLevels[BodyData.PartSide(slug: "biceps", side: .right)])
        XCTAssertEqual(armR, 1.0, accuracy: 0.001)
        XCTAssertEqual(armL, 0.86, accuracy: 0.01)
        // Balanced legs both render at 1.0.
        XCTAssertEqual(try XCTUnwrap(muscle.sideLevels[BodyData.PartSide(slug: "quadriceps", side: .left)]), 1.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(muscle.sideLevels[BodyData.PartSide(slug: "quadriceps", side: .right)]), 1.0, accuracy: 0.001)

        let fat = BodyData.segmentShading(for: scan, metric: .fat)
        // Trunk has highest fat % (20%) -> 1.0 in `levels`; left leg lowest (14%) -> 0.30 in `sideLevels`.
        XCTAssertEqual(try XCTUnwrap(fat.levels["abs"]), 1.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fat.sideLevels[BodyData.PartSide(slug: "quadriceps", side: .left)]), 0.30, accuracy: 0.001)
    }
}
