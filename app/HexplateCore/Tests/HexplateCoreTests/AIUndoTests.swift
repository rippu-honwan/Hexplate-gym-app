import XCTest
@testable import HexplateCore

final class AIUndoTests: XCTestCase {
    typealias Object = [String: JSONValue]

    private func makeClone(id: String, sets: Double = 2) -> Object {
        [
            "id": .string(id),
            "name": .string("Push"),
            "emoji": .string("figureStrength"),
            "ex": .array([.object(["id": .string("0025"), "sets": .number(sets), "reps": .number(8), "weight": .number(60)])]),
            "aiClone": .bool(true),
            "cloneOf": .string("push"),
            "ephemeralDate": .string("2026-11-25"),
        ]
    }

    private func baseDoc(ts: Double = 1_000) throws -> StateDocument {
        try StateDocument(root: [
            "unit": .string("kg"),
            "workouts": .array([]),
            "routines": .array([
                .object(["id": .string("push"), "name": .string("Push"), "ex": .array([.object(["id": .string("0025"), "sets": .number(4), "reps": .number(8), "weight": .number(60)])])]),
                .object(["id": .string("pull"), "name": .string("Pull"), "ex": .array([.object(["id": .string("0027"), "sets": .number(3), "reps": .number(10), "weight": .number(50)])])]),
            ]),
            "week": .object(["3": .array([.string("push")]), "4": .array([.string("pull")])]),
            "dayPlan": .object([:]),
            "_ts": .number(ts),
        ])
    }

    // T7: A no-op HexMerge round-trip keeps strippedMeta(clone) == snapshot so Undo removes it;
    // a modified clone fails safe into skippedCloneIds.
    func testNoOpHexMergeRoundTripPreservesCloneSnapshot() throws {
        var devA = try baseDoc()
        let clone = makeClone(id: "ai-2026-11-25-c1", sets: 2)
        devA.change(at: 2_000) { s in
            var rs = s["routines"]?.arrayValue ?? []
            rs.append(.object(clone))
            s["routines"] = .array(rs)
            s["dayPlan"] = .object(["2026-11-25": .string("ai-2026-11-25-c1")])
        }
        let record = AIUndoRecord(
            tokenId: "tok-1",
            acceptedAt: 2_000,
            acceptedDay: "2026-11-25",
            dayPlanDiffs: ["2026-11-25": DayPlanDiff(before: nil, after: .string("ai-2026-11-25-c1"))],
            createdClones: ["ai-2026-11-25-c1": AIUndo.strippedMeta(clone)]
        )

        // Round-trip through HexMerge with an older server copy.
        let server = try baseDoc(ts: 1_000).root
        let merged = try HexMerge.merge(devA.root, server, now: 3_000)
        let mergedClone = try XCTUnwrap(merged["routines"]?.arrayValue?.compactMap(\.object).first { $0["id"] == .string("ai-2026-11-25-c1") })
        XCTAssertEqual(AIUndo.strippedMeta(mergedClone), AIUndo.strippedMeta(clone))

        var undoDoc = try StateDocument(root: merged)
        var outcome: AIUndo.Outcome?
        undoDoc.change(at: 4_000) { s in
            outcome = AIUndo.apply(record, to: &s, today: "2026-11-25")
        }
        XCTAssertEqual(outcome?.status, .available)
        XCTAssertEqual(outcome?.restoredDates, ["2026-11-25"])
        XCTAssertEqual(outcome?.removedCloneIds, ["ai-2026-11-25-c1"])
        XCTAssertFalse((undoDoc.root["routines"]?.arrayValue ?? []).contains { $0.object?["id"] == .string("ai-2026-11-25-c1") })

        // If the clone's content was modified externally, Undo skips deleting it (fail-safe).
        var modified = merged
        var rs = modified["routines"]?.arrayValue ?? []
        if let idx = rs.firstIndex(where: { $0.object?["id"] == .string("ai-2026-11-25-c1") }), var obj = rs[idx].object {
            obj["ex"] = .array([.object(["id": .string("0025"), "sets": .number(5), "reps": .number(5)])])
            rs[idx] = .object(obj)
            modified["routines"] = .array(rs)
        }
        let modOutcome = AIUndo.apply(record, to: &modified, today: "2026-11-25")
        XCTAssertEqual(modOutcome.restoredDates, ["2026-11-25"])
        XCTAssertEqual(modOutcome.skippedCloneIds, ["ai-2026-11-25-c1"])
        XCTAssertTrue((modified["routines"]?.arrayValue ?? []).contains { $0.object?["id"] == .string("ai-2026-11-25-c1") })
    }

    // Accept -> Watch active event on touched date -> Undo blocked without mutating state.
    func testAcceptWatchActiveBlocksUndo() throws {
        var devA = try baseDoc()
        let clone = makeClone(id: "ai-2026-11-25-c1")
        devA.change(at: 2_000) { s in
            var rs = s["routines"]?.arrayValue ?? []
            rs.append(.object(clone))
            s["routines"] = .array(rs)
            s["dayPlan"] = .object(["2026-11-25": .string("ai-2026-11-25-c1")])
        }
        let record = AIUndoRecord(
            tokenId: "tok-2",
            acceptedAt: 2_000,
            acceptedDay: "2026-11-25",
            dayPlanDiffs: ["2026-11-25": DayPlanDiff(before: nil, after: .string("ai-2026-11-25-c1"))],
            createdClones: ["ai-2026-11-25-c1": AIUndo.strippedMeta(clone)]
        )

        let startAt = Day.noon("2026-11-25")
        let watchStart: Object = [
            "id": .string("ev1"),
            "type": .string("start"),
            "wid": .string("watch-1"),
            "routineIds": .array([.string("push")]),
            "at": .number(startAt),
        ]
        devA.change(at: 3_000) { s in
            _ = WatchLink.apply(watchStart, to: &s, today: "2026-11-25", now: startAt, newId: "n1", catalog: .builtIn)
        }

        let snapshotBeforeUndo = devA.root
        var root = devA.root
        let outcome = AIUndo.apply(record, to: &root, today: "2026-11-25")
        XCTAssertEqual(outcome.status, .blockedByActive)
        XCTAssertEqual(root, snapshotBeforeUndo)
    }

    // Accept -> sync merge modifying one touched day -> Undo -> sync merge propagates dayPlan nil
    // deletion and deleted.routines while preserving the externally edited date.
    func testAcceptSyncMergePartialSkipUndoSyncMerge() throws {
        let base = try baseDoc(ts: 1_000)
        var devA = base
        var devB = base

        let clone = makeClone(id: "ai-2026-11-25-c1")
        devA.change(at: 2_000) { s in
            var rs = s["routines"]?.arrayValue ?? []
            rs.append(.object(clone))
            s["routines"] = .array(rs)
            s["dayPlan"] = .object([
                "2026-11-25": .string("ai-2026-11-25-c1"),
                "2026-11-26": .string("rest"),
            ])
        }
        let record = AIUndoRecord(
            tokenId: "tok-3",
            acceptedAt: 2_000,
            acceptedDay: "2026-11-25",
            dayPlanDiffs: [
                "2026-11-25": DayPlanDiff(before: nil, after: .string("ai-2026-11-25-c1")),
                "2026-11-26": DayPlanDiff(before: nil, after: .string("rest")),
            ],
            createdClones: ["ai-2026-11-25-c1": AIUndo.strippedMeta(clone)]
        )

        // Device B syncs A's accepted state, then user on B manually changes 2026-11-26 to "pull".
        devB = try StateDocument(root: try HexMerge.merge(devB.root, devA.root, now: 2_500))
        devB.change(at: 3_000) { s in
            var plan = s["dayPlan"]?.object ?? [:]
            plan["2026-11-26"] = .string("pull")
            s["dayPlan"] = .object(plan)
        }

        // Device A merges B's edit, then user taps Undo on A.
        var devAMerged = try StateDocument(root: try HexMerge.merge(devA.root, devB.root, now: 3_500))
        var outcome: AIUndo.Outcome?
        devAMerged.change(at: 4_000) { s in
            outcome = AIUndo.apply(record, to: &s, today: "2026-11-25")
        }

        XCTAssertEqual(outcome?.status, .available)
        XCTAssertEqual(outcome?.restoredDates, ["2026-11-25"])
        XCTAssertEqual(outcome?.skippedDates, ["2026-11-26"])
        XCTAssertEqual(outcome?.removedCloneIds, ["ai-2026-11-25-c1"])
        XCTAssertNil(devAMerged.root["dayPlan"]?.object?["2026-11-25"])
        XCTAssertEqual(devAMerged.root["dayPlan"]?.object?["2026-11-26"], .string("pull"))

        // Sync back to B: 2026-11-25 deletion and clone deletion both propagate to B, while B's
        // manual 2026-11-26 edit survives.
        let finalB = try HexMerge.merge(devB.root, devAMerged.root, now: 5_000)
        XCTAssertNil(finalB["dayPlan"]?.object?["2026-11-25"])
        XCTAssertEqual(finalB["dayPlan"]?.object?["2026-11-26"], .string("pull"))
        XCTAssertFalse((finalB["routines"]?.arrayValue ?? []).contains { $0.object?["id"] == .string("ai-2026-11-25-c1") })
    }

    func testUndoIdempotentWhenCloneAlreadyRemovedAndExpiryRules() throws {
        let clone = makeClone(id: "ai-2026-11-25-c1")
        let record = AIUndoRecord(
            tokenId: "tok-4",
            acceptedAt: 2_000,
            acceptedDay: "2026-11-25",
            dayPlanDiffs: ["2026-11-25": DayPlanDiff(before: nil, after: .string("ai-2026-11-25-c1"))],
            createdClones: ["ai-2026-11-25-c1": AIUndo.strippedMeta(clone)]
        )

        // Codable round-trip.
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(AIUndoRecord.self, from: encoded)
        XCTAssertEqual(decoded, record)

        // Clone already removed on another device -> counted in removedCloneIds (idempotent).
        var root = try baseDoc().root
        root["dayPlan"] = .object(["2026-11-25": .string("ai-2026-11-25-c1")])
        let outcome = AIUndo.apply(record, to: &root, today: "2026-11-25")
        XCTAssertEqual(outcome.status, .available)
        XCTAssertEqual(outcome.restoredDates, ["2026-11-25"])
        XCTAssertEqual(outcome.removedCloneIds, ["ai-2026-11-25-c1"])
        XCTAssertTrue(outcome.skippedCloneIds.isEmpty)

        // End-of-day expiry.
        XCTAssertEqual(AIUndo.status(of: record, in: root, today: "2026-11-26"), .expired)

        // Logged workout on a touched date blocks Undo.
        root["workouts"] = .array([.object(["id": .string("w1"), "d": .string("2026-11-25"), "entries": .array([])])])
        XCTAssertEqual(AIUndo.status(of: record, in: root, today: "2026-11-25"), .blockedByLoggedWorkout)
    }
}
