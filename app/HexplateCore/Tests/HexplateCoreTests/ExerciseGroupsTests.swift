import XCTest
@testable import HexplateCore

final class ExerciseGroupsTests: XCTestCase {
    let c = ExerciseCatalog.builtIn

    func testPopularIdsExistAndAreUnique() {
        XCTAssertEqual(Set(ExerciseGroups.popular).count, ExerciseGroups.popular.count)
        for id in ExerciseGroups.popular { XCTAssertNotNil(c[id], id) }
    }

    func testGroupsOfKnownExercises() {
        let cases: [(String, String, String)] = [
            ("0025", "Barbell", "Chest"), ("0043", "Barbell", "Quadriceps"), ("2330", "Machine", "Lats"),
            ("0652", "None", "Lats"), ("0549", "Kettlebell", "Glutes"), ("0597", "Machine", "Abductors"),
            ("1080", "Suspension Band", "Upper Back"), ("4847", "Plate", "Shoulders"), ("1503", "Resistance Band", "Upper Back"),
            ("0489", "None", "Lower Back"), ("1403", "None", "Neck"), ("0685", "None", "Cardio"), ("0028", "Barbell", "Full Body"), ("0032", "Barbell", "Glutes"),
        ]
        for (id, eq, muscle) in cases {
            let ex = c[id]!
            XCTAssertEqual(ExerciseGroups.equipment(of: ex), eq, id)
            XCTAssertEqual(ExerciseGroups.muscle(of: ex, catalog: c), muscle, id)
        }
    }

    func testEveryExerciseLandsInAListedGroup() {
        let muscles = Set(ExerciseGroups.muscles.flatMap(\.groups)), equipment = Set(ExerciseGroups.equipment)
        for ex in c.all {
            XCTAssertTrue(muscles.contains(ExerciseGroups.muscle(of: ex, catalog: c)), ex.id)
            XCTAssertTrue(equipment.contains(ExerciseGroups.equipment(of: ex)), ex.id)
        }
        // Full Body and Other are real groups, not a dumping ground.
        let other = c.all.filter { ExerciseGroups.muscle(of: $0, catalog: c) == "Other" }.count
        XCTAssertLessThan(other, 100)
    }

    func testSplitPutsStaplesFirstInListOrder() {
        let list = ["0047", "9999", "0025"].compactMap { c[$0] } + [c["0662"]!]
        let s = ExerciseGroups.split(list)
        XCTAssertEqual(s.popular.map(\.id), ["0025", "0047", "0662"])
        XCTAssertTrue(s.rest.allSatisfy { !ExerciseGroups.popular.contains($0.id) })
    }
}
