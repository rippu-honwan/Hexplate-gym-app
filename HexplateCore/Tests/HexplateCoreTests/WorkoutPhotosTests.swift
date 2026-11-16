import XCTest
@testable import HexplateCore

final class WorkoutPhotosTests: XCTestCase {
    func ref(_ c: Character, size: Double = 10) -> [String: JSONValue] {
        ["kind": .string("image"), "hash": .string(String(repeating: c, count: 64)), "mime": .string("image/jpeg"),
         "size": .number(size), "width": .number(4), "height": .number(3), "at": .number(1)]
    }

    func testAddRemoveAndCap() {
        var list: [JSONValue] = [.object(["id": .string("w1"), "d": .string("2026-10-01")])]
        XCTAssertEqual(WorkoutPhotos.add(&list, key: "w9", ref("a"), now: 5), .gone)
        XCTAssertEqual(WorkoutPhotos.add(&list, key: "w1", ref("a", size: 0), now: 5), .invalid)
        XCTAssertEqual(WorkoutPhotos.add(&list, key: "w1", ref("a"), now: 5), .added)
        XCTAssertEqual(list[0].object?["_ts"], .number(5))
        XCTAssertEqual(WorkoutPhotos.add(&list, key: "w1", ref("a"), now: 6), .dup)
        for c in "bcdef" { XCTAssertEqual(WorkoutPhotos.add(&list, key: "w1", ref(c), now: 6), .added) }
        XCTAssertEqual(WorkoutPhotos.add(&list, key: "w1", ref("0"), now: 7), .full)
        XCTAssertEqual(WorkoutPhotos.of(list[0].object).count, 6)
        XCTAssertTrue(WorkoutPhotos.remove(&list, key: "w1", hash: String(repeating: "a", count: 64), now: 8))
        XCTAssertFalse(WorkoutPhotos.remove(&list, key: "w1", hash: String(repeating: "a", count: 64), now: 9))
        XCTAssertEqual(list[0].object?["_ts"], .number(8))
        // A replaced day's photos move to the new record, after its own and once each.
        var w: [String: JSONValue] = ["media": .array([.object(ref("b"))])]
        WorkoutPhotos.merge(into: &w, from: ["media": .array([.object(ref("b")), .object(ref("c")), .object(ref("c"))])])
        XCTAssertEqual(w["media"]?.arrayValue?.count, 2)
    }
}
