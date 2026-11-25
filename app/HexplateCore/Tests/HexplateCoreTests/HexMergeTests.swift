import XCTest
@testable import HexplateCore

final class HexMergeTests: XCTestCase {
    typealias Object = [String: JSONValue]

    private func baseDoc(ts: Double = 1_000, meals: Object? = nil) -> Object {
        var doc: Object = [
            "unit": .string("kg"),
            "workouts": .array([]),
            "routines": .array([]),
            "week": .object([:]),
            "dayPlan": .object([:]),
            "bodyweight": .array([]),
            "measurements": .array([]),
            "customEx": .array([]),
            "_ts": .number(ts),
        ]
        if let meals { doc["meals"] = .object(meals) }
        return doc
    }

    private func meal(id: String, name: String, kcal: Double, ts: Double? = nil) -> JSONValue {
        var o: Object = [
            "id": .string(id),
            "date": .string("2026-11-25"),
            "time": .string("12:00"),
            "name": .string(name),
            "kcal": .number(kcal),
            "protein": .number(40),
            "carbs": .number(50),
            "fat": .number(15),
            "source": .string("manual"),
        ]
        if let ts { o["_ts"] = .number(ts) }
        return .object(o)
    }

    private func tombstone(ts: Double) -> JSONValue {
        .object(["deleted": .bool(true), "_ts": .number(ts)])
    }

    // T1: Push-after-failed-push invariant — merged top-level _ts is strictly greater than both
    // inputs without inflating any entry-level _ts.
    func testFinalizeAdvancesTopLevelTimestampWithoutInflatingEntries() throws {
        let local = baseDoc(ts: 5_000, meals: ["m1": meal(id: "m1", name: "Chicken", kcal: 500, ts: 4_000)])
        var server = baseDoc(ts: 5_000, meals: ["m2": meal(id: "m2", name: "Oats", kcal: 350, ts: 4_500)])
        server["workouts"] = .array([.object(["id": .string("w1"), "d": .string("2026-11-25"), "start": .number(3_000), "_ts": .number(3_500), "entries": .array([])])])

        let merged = try HexMerge.merge(local, server, now: 10_000)

        let mergedTs = try XCTUnwrap(merged["_ts"]?.numberValue)
        XCTAssertGreaterThan(mergedTs, 5_000)
        // Entry-level stamps remain untouched.
        XCTAssertEqual(merged["meals"]?.object?["m1"]?.object?["_ts"], .number(4_000))
        XCTAssertEqual(merged["meals"]?.object?["m2"]?.object?["_ts"], .number(4_500))
        XCTAssertEqual(merged["workouts"]?.arrayValue?.first?.object?["_ts"], .number(3_500))
    }

    // T3 (R2): StateDocument(root: merged) + doc.change { _ in } applies a remote activeEquipId
    // gym switch without restamping unrelated entries, and is a strict no-op when gyms match and
    // active is nil.
    func testTakeMergedCopyPatternAppliesRemoteGymSwitchWithoutInflatingEntries() throws {
        let gymA: JSONValue = .object([
            "id": .string("gymA"),
            "name": .string("Home"),
            "plates": .object(["kg": .object(["items": .array([.number(20)]), "_ts": .number(1_000)])]),
            "dumbbells": .object([:]),
            "barDefaults": .object([:]),
            "stackWeights": .object([:]),
            "_ts": .number(1_000),
        ])
        let gymB: JSONValue = .object([
            "id": .string("gymB"),
            "name": .string("Commercial"),
            "plates": .object(["kg": .object(["items": .array([.number(25), .number(20)]), "_ts": .number(2_000)])]),
            "dumbbells": .object([:]),
            "barDefaults": .object([:]),
            "stackWeights": .object([:]),
            "_ts": .number(2_000),
        ])

        // Case 1: remote switch activeEquipId -> gymB while invGym is still gymA.
        var merged = baseDoc(ts: 6_000, meals: ["m1": meal(id: "m1", name: "Bowl", kcal: 600, ts: 4_200)])
        merged["workouts"] = .array([.object(["id": .string("w1"), "d": .string("2026-11-24"), "start": .number(2_000), "_ts": .number(2_500), "entries": .array([])])])
        merged["routines"] = .array([.object(["id": .string("r1"), "name": .string("Push"), "ex": .array([]), "_ts": .number(2_600)])])
        merged["edited"] = .object(["nutritionGoals": .number(3_100)])
        merged["deleted"] = .object(["routines": .object(["old": .number(3_200)])])
        merged["equipProfiles"] = .array([gymA, gymB])
        merged["activeEquipId"] = .string("gymB")
        merged["invGym"] = .string("gymA")
        merged["plates"] = .object(["kg": .object(["items": .array([.number(20)]), "_ts": .number(1_000)])])

        var doc = try StateDocument(root: merged)
        doc.change(at: 7_000) { _ in }

        // Top-level inventory switched to gymB and invGym updated.
        XCTAssertEqual(doc.root["invGym"], .string("gymB"))
        XCTAssertEqual(
            doc.root["plates"]?.object?["kg"]?.object?["items"],
            .array([.number(25), .number(20)])
        )
        // Entry-level stamps on meals, workouts, routines, edited, and deleted stayed intact.
        XCTAssertEqual(doc.root["meals"]?.object?["m1"]?.object?["_ts"], .number(4_200))
        XCTAssertEqual(doc.root["workouts"]?.arrayValue?.first?.object?["_ts"], .number(2_500))
        XCTAssertEqual(doc.root["routines"]?.arrayValue?.first?.object?["_ts"], .number(2_600))
        XCTAssertEqual(doc.root["edited"]?.object?["nutritionGoals"], .number(3_100))
        XCTAssertEqual(doc.root["deleted"]?.object?["routines"]?.object?["old"], .number(3_200))

        // Case 2: strict no-op when gyms are already in sync and active == nil.
        var steady = baseDoc(ts: 8_000, meals: ["m1": meal(id: "m1", name: "Bowl", kcal: 600, ts: 4_200)])
        steady["equipProfiles"] = .array([gymA])
        steady["activeEquipId"] = .string("gymA")
        steady["invGym"] = .string("gymA")
        steady["plates"] = .object(["kg": .object(["items": .array([.number(20)]), "_ts": .number(1_000)])])
        var steadyDoc = try StateDocument(root: steady)
        let beforeRoot = steadyDoc.root
        steadyDoc.change(at: 9_000) { _ in }
        XCTAssertEqual(steadyDoc.root, beforeRoot)
        XCTAssertEqual(steadyDoc.root["_ts"], .number(8_000))
    }

    // T4 (R3): Both sync.js `kn` reset branches mirrored in HexMerge.mergeMeals.
    func testResetBranchesForMeals() throws {
        let m1 = meal(id: "m1", name: "Old 1", kcal: 400, ts: 1_000)
        let m2 = meal(id: "m2", name: "Old 2", kcal: 500, ts: 2_000)
        let m3 = meal(id: "m3", name: "After Reset", kcal: 600, ts: 6_000)

        // Branch 1: winning side carries `resetIds` object -> drops ONLY listed meal IDs (no time filter).
        var selectiveWinner = baseDoc(ts: 5_500, meals: [:])
        selectiveWinner["resetAt"] = .number(5_000)
        selectiveWinner["resetIds"] = .object(["meals": .array([.string("m1")])])
        let losingCopy = baseDoc(ts: 4_000, meals: ["m1": m1, "m2": m2, "m3": m3])

        let selectiveMerged = try HexMerge.merge(selectiveWinner, losingCopy, now: 10_000)
        let selectiveMeals = try XCTUnwrap(selectiveMerged["meals"]?.object)
        XCTAssertNil(selectiveMeals["m1"])
        XCTAssertEqual(selectiveMeals["m2"], m2)
        XCTAssertEqual(selectiveMeals["m3"], m3)

        // Branch 1b: selective resetIds without a `meals` key drops no meals.
        var otherSelective = baseDoc(ts: 5_500, meals: [:])
        otherSelective["resetAt"] = .number(5_000)
        otherSelective["resetIds"] = .object(["workouts": .array([.string("w1")])])
        let keptAll = try HexMerge.merge(otherSelective, losingCopy, now: 10_000)
        XCTAssertEqual(keptAll["meals"]?.object?.count, 3)

        // Branch 2: winning side has `resetAt` and NO `resetIds` -> drops losing entries with _ts <= resetAt.
        var fullResetWinner = baseDoc(ts: 5_500, meals: [:])
        fullResetWinner["resetAt"] = .number(5_000)
        let fullMerged = try HexMerge.merge(fullResetWinner, losingCopy, now: 10_000)
        let fullMeals = try XCTUnwrap(fullMerged["meals"]?.object)
        XCTAssertNil(fullMeals["m1"])
        XCTAssertNil(fullMeals["m2"])
        XCTAssertEqual(fullMeals["m3"], m3)
    }

    // 2-device and 3-copy (A, B, Server) interleaved meals edit + inline delete + fast/slow clock skew.
    func testThreeCopyInterleavedMealsAndClockSkewConvergence() throws {
        let baseWall = 1_795_500_000_000.0
        var serverDoc = try StateDocument(root: baseDoc(ts: baseWall))
        serverDoc.change(at: baseWall + 1_000) { s in
            s["meals"] = .object([
                "m1": meal(id: "m1", name: "Eggs", kcal: 300),
                "m2": meal(id: "m2", name: "Rice", kcal: 400),
            ])
        }

        // Device A has a +1 hour fast clock; edits m1 and adds m3.
        var devA = serverDoc
        devA.change(at: baseWall + 3_600_000) { s in
            var meals = s["meals"]?.object ?? [:]
            meals["m1"] = meal(id: "m1", name: "Eggs + Toast", kcal: 480)
            meals["m3"] = meal(id: "m3", name: "Shake", kcal: 250)
            s["meals"] = .object(meals)
        }

        // Device B has a normal clock; deletes m2 (inline tombstone) and adds m4.
        var devB = serverDoc
        devB.change(at: baseWall + 2_000) { s in
            var meals = s["meals"]?.object ?? [:]
            meals["m2"] = .object(["deleted": .bool(true)])
            meals["m4"] = meal(id: "m4", name: "Salmon", kcal: 550)
            s["meals"] = .object(meals)
        }

        // Merge in two different gossip orders and verify identical meal convergence.
        let order1AS = try HexMerge.merge(devA.root, serverDoc.root, now: baseWall + 4_000_000)
        let order1Final = try HexMerge.merge(devB.root, order1AS, now: baseWall + 4_000_000)

        let order2BS = try HexMerge.merge(devB.root, serverDoc.root, now: baseWall + 4_000_000)
        let order2Final = try HexMerge.merge(devA.root, order2BS, now: baseWall + 4_000_000)

        XCTAssertEqual(order1Final["meals"], order2Final["meals"])
        let converged = try XCTUnwrap(order1Final["meals"]?.object)
        XCTAssertEqual(converged["m1"]?.object?["name"], .string("Eggs + Toast"))
        XCTAssertEqual(converged["m2"]?.object?["deleted"], .bool(true))
        XCTAssertEqual(converged["m3"]?.object?["name"], .string("Shake"))
        XCTAssertEqual(converged["m4"]?.object?["name"], .string("Salmon"))

        // Slow-clock Device B adopts converged state and edits m1 with a stale wall clock:
        // HexStamps bumps wall above highestMealTs(prev) so B's subsequent edit wins on merge.
        var devBAfter = try StateDocument(root: order1Final)
        devBAfter.change(at: baseWall + 5_000) { s in
            var meals = s["meals"]?.object ?? [:]
            meals["m1"] = meal(id: "m1", name: "Eggs + Avocado", kcal: 520)
            s["meals"] = .object(meals)
        }
        let m1After = try XCTUnwrap(devBAfter.root["meals"]?.object?["m1"]?.object)
        let fastTs = try XCTUnwrap(converged["m1"]?.object?["_ts"]?.numberValue)
        XCTAssertGreaterThan(m1After["_ts"]?.numberValue ?? 0, fastTs)

        let backToA = try HexMerge.merge(devA.root, devBAfter.root, now: baseWall + 4_000_000)
        XCTAssertEqual(backToA["meals"]?.object?["m1"]?.object?["name"], .string("Eggs + Avocado"))
    }

    func testCommutativeTieBreakAndNinetyDayTombstonePruning() throws {
        let now = 1_800_000_000_000.0
        let tieTs = now - 1_000
        let staleTs = now - HexMerge.mealTombstoneTTLMs - 1_000
        let freshTs = now - HexMerge.mealTombstoneTTLMs + 60_000

        let a = baseDoc(ts: now - 10, meals: [
            "tieDel": meal(id: "tieDel", name: "Live", kcal: 300, ts: tieTs),
            "tieLive": meal(id: "tieLive", name: "Alpha", kcal: 300, ts: tieTs),
            "oldDel": tombstone(ts: staleTs),
            "freshDel": tombstone(ts: freshTs),
        ])
        let b = baseDoc(ts: now - 10, meals: [
            "tieDel": tombstone(ts: tieTs),
            "tieLive": meal(id: "tieLive", name: "Beta", kcal: 300, ts: tieTs),
        ])

        let ab = try HexMerge.merge(a, b, now: now)
        let ba = try HexMerge.merge(b, a, now: now)
        XCTAssertEqual(ab["meals"], ba["meals"])

        let meals = try XCTUnwrap(ab["meals"]?.object)
        XCTAssertEqual(meals["tieDel"]?.object?["deleted"], .bool(true))
        XCTAssertNotNil(meals["tieLive"]?.object?["name"])
        XCTAssertNil(meals["oldDel"])
        XCTAssertEqual(meals["freshDel"]?.object?["deleted"], .bool(true))
    }

    func testStateDocumentMealStampingAutoTombstoneAndNoEditedMeals() throws {
        var doc = try StateDocument(root: baseDoc(ts: 1_000))
        doc.change(at: 2_000) { s in
            s["meals"] = .object([
                "m1": meal(id: "m1", name: "Chicken", kcal: 500),
                "m2": meal(id: "m2", name: "Salad", kcal: 200),
            ])
        }
        XCTAssertNil(doc.root["edited"]?.object?["meals"])
        XCTAssertEqual(doc.root["meals"]?.object?["m1"]?.object?["_ts"], .number(2_000))
        XCTAssertEqual(doc.root["meals"]?.object?["m2"]?.object?["_ts"], .number(2_000))

        // Edit m1 only; m2 keeps its original _ts.
        doc.change(at: 3_000) { s in
            var meals = s["meals"]?.object ?? [:]
            meals["m1"] = meal(id: "m1", name: "Chicken XL", kcal: 650)
            s["meals"] = .object(meals)
        }
        XCTAssertNil(doc.root["edited"]?.object?["meals"])
        XCTAssertEqual(doc.root["meals"]?.object?["m1"]?.object?["_ts"], .number(3_000))
        XCTAssertEqual(doc.root["meals"]?.object?["m2"]?.object?["_ts"], .number(2_000))

        // Raw removal of live m2 auto-creates an inline tombstone.
        doc.change(at: 4_000) { s in
            var meals = s["meals"]?.object ?? [:]
            meals["m2"] = nil
            s["meals"] = .object(meals)
        }
        XCTAssertEqual(doc.root["meals"]?.object?["m2"], .object(["deleted": .bool(true), "_ts": .number(4_000)]))

        // Removing an already-tombstoned entry (GC) stays removed without recreating a tombstone.
        doc.change(at: 5_000) { s in
            var meals = s["meals"]?.object ?? [:]
            meals["m2"] = nil
            s["meals"] = .object(meals)
        }
        XCTAssertNil(doc.root["meals"]?.object?["m2"])
    }

    func testNutritionGoalsWholeKeyLWWAndDayPlanNilDeletionMerge() throws {
        var devA = try StateDocument(root: baseDoc(ts: 1_000))
        devA.change(at: 2_000) { s in
            s["nutritionGoals"] = .object(["kcal": .number(2200), "proteinPerKg": .number(2.0)])
            s["dayPlan"] = .object(["2026-11-25": .string("rest")])
        }
        var devB = devA

        // A updates nutritionGoals earlier; B updates nutritionGoals later.
        devA.change(at: 3_000) { s in
            s["nutritionGoals"] = .object(["kcal": .number(2400)])
            // A also deletes dayPlan["2026-11-25"] later below.
        }
        devB.change(at: 4_000) { s in
            s["nutritionGoals"] = .object(["kcal": .number(2600), "proteinPerKg": .number(2.2)])
        }
        devA.change(at: 5_000) { s in
            var plan = s["dayPlan"]?.object ?? [:]
            plan["2026-11-25"] = nil
            s["dayPlan"] = .object(plan)
        }

        let merged = try HexMerge.merge(devA.root, devB.root, now: 10_000)
        XCTAssertEqual(merged["nutritionGoals"], .object(["kcal": .number(2600), "proteinPerKg": .number(2.2)]))
        XCTAssertNil(merged["dayPlan"]?.object?["2026-11-25"])
    }

    func testHexMergeChangesCountsMealDiffs() throws {
        let a = baseDoc(ts: 1_000, meals: [
            "m1": meal(id: "m1", name: "Chicken", kcal: 500, ts: 1_000),
            "m2": meal(id: "m2", name: "Rice", kcal: 300, ts: 1_000),
        ])
        let b = baseDoc(ts: 2_000, meals: [
            "m1": meal(id: "m1", name: "Chicken", kcal: 550, ts: 2_000), // edited
            "m2": tombstone(ts: 2_000),                                 // deleted
            "m3": meal(id: "m3", name: "Yogurt", kcal: 150, ts: 2_000), // added
        ])
        XCTAssertEqual(try HexMerge.changes(b, since: a), 3)
        XCTAssertEqual(try HexMerge.changes(a, since: a), 0)
    }
}
