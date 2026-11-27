import XCTest
@testable import HexplateCore

final class NutritionTests: XCTestCase {
    typealias Object = [String: JSONValue]

    private func emptyDoc(unit: String = "kg") throws -> StateDocument {
        let json = """
        {"unit":"\(unit)","workouts":[],"routines":[],"week":{},"dayPlan":{},"bodyweight":[],"measurements":[],"customEx":[]}
        """
        return try StateDocument(data: Data(json.utf8))
    }

    func testMealCRUDValidationAndSorting() throws {
        var doc = try emptyDoc()
        doc.change(at: 1_000) { s in
            XCTAssertFalse(Nutrition.upsertMeal(&s, Nutrition.Meal(id: "", date: "2026-11-25", name: "Bad")))
            XCTAssertFalse(Nutrition.upsertMeal(&s, Nutrition.Meal(id: "m0", date: "2026-99-99", name: "Bad date")))

            XCTAssertTrue(Nutrition.upsertMeal(&s, Nutrition.Meal(
                id: "m2", date: "2026-11-25", time: "18:30", name: "  Dinner  ",
                kcal: 700, protein: 50, carbs: -10, fat: 0
            )))
            XCTAssertTrue(Nutrition.upsertMeal(&s, Nutrition.Meal(
                id: "m1", date: "2026-11-25", time: "8:05", name: "Breakfast",
                kcal: 420, protein: 32, carbs: 45, fat: 12
            )))
            XCTAssertTrue(Nutrition.upsertMeal(&s, Nutrition.Meal(
                id: "m3", date: "2026-11-24", time: nil, name: "Yesterday",
                kcal: 550, protein: 40
            )))
        }

        let all = Nutrition.meals(doc.root)
        XCTAssertEqual(all.map(\.id), ["m3", "m1", "m2"])
        XCTAssertEqual(all[1].time, "08:05")
        XCTAssertEqual(all[2].name, "Dinner")
        XCTAssertNil(all[2].carbs)
        XCTAssertNil(all[2].fat)
        XCTAssertGreaterThan(all[1].ts, 0)

        let today = Nutrition.meals(doc.root, on: "2026-11-25")
        XCTAssertEqual(today.map(\.id), ["m1", "m2"])
        XCTAssertEqual(Nutrition.meals(doc.root, on: "not-a-date"), [])
    }

    func testDeleteMealPreservesPhotoIdOnTombstoneAndReferencedPhotoIds() throws {
        var doc = try emptyDoc()
        doc.change(at: 1_000) { s in
            Nutrition.upsertMeal(&s, Nutrition.Meal(id: "p1", date: "2026-11-25", name: "Photo Meal", kcal: 500, source: .photo, photoId: "photo-aaa"))
            Nutrition.upsertMeal(&s, Nutrition.Meal(id: "p2", date: "2026-11-25", name: "Live Photo", kcal: 600, source: .photo, photoId: "photo-bbb"))
            Nutrition.upsertMeal(&s, Nutrition.Meal(id: "m1", date: "2026-11-25", name: "Manual", kcal: 300))
        }

        doc.change(at: 2_000) { s in
            XCTAssertTrue(Nutrition.deleteMeal(&s, id: "p1"))
            XCTAssertFalse(Nutrition.deleteMeal(&s, id: "p1"))
            XCTAssertTrue(Nutrition.deleteMeal(&s, id: "m1"))
            XCTAssertFalse(Nutrition.deleteMeal(&s, id: "missing"))
        }

        XCTAssertEqual(Nutrition.meals(doc.root).map(\.id), ["p2"])
        let tombstones = Nutrition.tombstonedMeals(doc.root)
        XCTAssertEqual(tombstones.count, 2)
        let p1Tomb = try XCTUnwrap(tombstones.first { $0.id == "p1" })
        XCTAssertEqual(p1Tomb.photoId, "photo-aaa")
        XCTAssertEqual(p1Tomb.ts, 2_000)
        // Both live and retained-tombstone photoIds stay protected against orphan GC.
        XCTAssertEqual(Nutrition.referencedPhotoIds(doc.root), Set(["photo-aaa", "photo-bbb"]))
    }

    func testEffectiveGoalsDynamicProteinKgAndLbAndExplicitOverride() throws {
        // No bodyweight logged -> derived protein is nil.
        let empty = try emptyDoc(unit: "kg")
        let gEmpty = Nutrition.effectiveGoals(empty.root)
        XCTAssertNil(gEmpty.protein)
        XCTAssertFalse(gEmpty.proteinIsDerived)
        XCTAssertEqual(gEmpty.proteinPerKg, 2.0)

        // kg profile: 70.0 kg * 2.0 = 140 g.
        var kgDoc = try emptyDoc(unit: "kg")
        kgDoc.change(at: 1_000) { s in
            BodyData.addWeighIn(&s, day: "2026-11-25", time: "08:00", weight: 70.0, at: 1_000, id: "w1")
        }
        let gKg = Nutrition.effectiveGoals(kgDoc.root)
        XCTAssertEqual(gKg.protein, 140)
        XCTAssertTrue(gKg.proteinIsDerived)
        XCTAssertEqual(try XCTUnwrap(gKg.weightKgUsed), 70.0, accuracy: 0.001)

        // lb profile: 154.3 lb * 0.45359237 ≈ 69.989 kg * 2.2 ≈ 154 g.
        var lbDoc = try emptyDoc(unit: "lb")
        lbDoc.change(at: 1_000) { s in
            BodyData.addWeighIn(&s, day: "2026-11-25", time: "08:00", weight: 154.3, at: 1_000, id: "w1")
            Nutrition.setGoals(&s, Nutrition.Goals(kcal: 2_300, proteinPerKg: 2.2))
        }
        let gLb = Nutrition.effectiveGoals(lbDoc.root)
        XCTAssertEqual(gLb.kcal, 2_300)
        XCTAssertEqual(gLb.protein, 154)
        XCTAssertTrue(gLb.proteinIsDerived)
        XCTAssertEqual(gLb.proteinPerKg, 2.2)

        // Explicit protein override beats derived protein.
        lbDoc.change(at: 2_000) { s in
            Nutrition.setGoals(&s, Nutrition.Goals(kcal: 2_300, protein: 175, carbs: 250, fat: 65, proteinPerKg: 2.2))
        }
        let gExplicit = Nutrition.effectiveGoals(lbDoc.root)
        XCTAssertEqual(gExplicit.protein, 175)
        XCTAssertFalse(gExplicit.proteinIsDerived)
        XCTAssertEqual(gExplicit.carbs, 250)
        XCTAssertEqual(gExplicit.fat, 65)
    }

    func testGoalsResetWritesEmptyObjectAndConvergesAcrossHexMerge() throws {
        // Device B sets goals at t = 1_000.
        var deviceB = try emptyDoc()
        deviceB.change(at: 1_000) { s in
            Nutrition.setGoals(&s, Nutrition.Goals(kcal: 2_400, protein: 180, carbs: 260, fat: 70))
        }

        // Device A starts from B's state, then resets to defaults at t = 2_000 (writes `{}`).
        var deviceA = deviceB
        deviceA.change(at: 2_000) { s in
            Nutrition.setGoals(&s, Nutrition.Goals())
        }
        XCTAssertEqual(deviceA.root["nutritionGoals"], .object([:]))
        XCTAssertEqual(deviceA.root["edited"]?.object?["nutritionGoals"], .number(2_000))

        // Merging in either order converges on empty goals `{}`.
        let mergedAB = try HexMerge.merge(deviceA.root, deviceB.root, now: 3_000)
        let mergedBA = try HexMerge.merge(deviceB.root, deviceA.root, now: 3_000)
        XCTAssertEqual(Nutrition.goals(mergedAB), Nutrition.Goals())
        XCTAssertEqual(Nutrition.goals(mergedBA), Nutrition.Goals())
        XCTAssertEqual(mergedAB["nutritionGoals"], .object([:]))
        XCTAssertEqual(mergedBA["nutritionGoals"], .object([:]))
    }

    func testDailyTotalsAndGapAwareDailySeries() throws {
        var doc = try emptyDoc()
        doc.change(at: 1_000) { s in
            Nutrition.upsertMeal(&s, Nutrition.Meal(id: "m1", date: "2026-11-20", name: "A", kcal: 500, protein: 40, carbs: 50, fat: 15))
            Nutrition.upsertMeal(&s, Nutrition.Meal(id: "m2", date: "2026-11-21", name: "B", kcal: 600, protein: 45, carbs: 60, fat: 18))
            // Gap on 2026-11-22 and 2026-11-23.
            Nutrition.upsertMeal(&s, Nutrition.Meal(id: "m3", date: "2026-11-24", name: "C", kcal: 700, protein: 55, carbs: 70, fat: 20))
            // Outside 1W ending 2026-11-25 (1W = 2026-11-19...2026-11-25), inside 1M.
            Nutrition.upsertMeal(&s, Nutrition.Meal(id: "m0", date: "2026-11-10", name: "Old", kcal: 400, protein: 30))
        }

        // Unavailable HealthKit preserves external == nil.
        let unavailableTotals = Nutrition.dailyTotals(doc.root, day: "2026-11-24", external: nil)
        XCTAssertNil(unavailableTotals.external)
        XCTAssertEqual(unavailableTotals.total.kcal, 700)

        let noHealthSeries = Nutrition.dailySeries(doc.root, period: .week, today: "2026-11-25", externalByDay: nil)
        XCTAssertEqual(noHealthSeries.map(\.day), ["2026-11-20", "2026-11-21", "2026-11-24"])
        XCTAssertEqual(noHealthSeries.map(\.run), [0, 0, 1])
        XCTAssertTrue(noHealthSeries.allSatisfy { $0.external == nil })

        // With external HealthKit on 2026-11-25 (consecutive to 11-24) and combined on 11-24.
        let ext: [String: Nutrition.Macros] = [
            "2026-11-24": Nutrition.Macros(kcal: 200, protein: 20, carbs: 10, fat: 5),
            "2026-11-25": Nutrition.Macros(kcal: 350, protein: 30, carbs: 25, fat: 10),
        ]
        let withHealth = Nutrition.dailySeries(doc.root, period: .week, today: "2026-11-25", externalByDay: ext)
        XCTAssertEqual(withHealth.map(\.day), ["2026-11-20", "2026-11-21", "2026-11-24", "2026-11-25"])
        XCTAssertEqual(withHealth.map(\.run), [0, 0, 1, 1])
        XCTAssertEqual(withHealth[2].total.kcal, 900)
        XCTAssertEqual(withHealth[3].mealCount, 0)
        XCTAssertEqual(withHealth[3].total.protein, 30)

        let monthSeries = Nutrition.dailySeries(doc.root, period: .month, today: "2026-11-25", externalByDay: nil)
        XCTAssertEqual(monthSeries.first?.day, "2026-11-10")
        XCTAssertEqual(Nutrition.dailySeries(doc.root, period: .week, today: "bad", externalByDay: nil), [])
    }

    func testHealthSyncOpCoalesceAndSyncIdRules() {
        XCTAssertEqual(Nutrition.Nutrient.kcal.syncId(mealId: "abc"), "hexplate.meal.abc.kcal")
        XCTAssertEqual(Nutrition.Nutrient.protein.syncId(mealId: "abc"), "hexplate.meal.abc.protein")
        XCTAssertTrue(Nutrition.Nutrient.isHexplateSyncId("hexplate.meal.abc.fat"))
        XCTAssertFalse(Nutrition.Nutrient.isHexplateSyncId("com.other.meal.1"))
        XCTAssertFalse(Nutrition.Nutrient.isHexplateSyncId(nil))

        let m1v1 = Nutrition.Meal(id: "m1", date: "2026-11-25", name: "V1", kcal: 400, ts: 1_000)
        let m1v2 = Nutrition.Meal(id: "m1", date: "2026-11-25", name: "V2", kcal: 500, ts: 2_000)
        let m2 = Nutrition.Meal(id: "m2", date: "2026-11-25", name: "Other", kcal: 300, ts: 1_500)

        var ops: [Nutrition.HealthSyncOp] = []
        ops = Nutrition.HealthSyncOp.coalesce(ops, adding: .upsert(m1v1))
        ops = Nutrition.HealthSyncOp.coalesce(ops, adding: .upsert(m2))
        // Newer edit replaces older upsert.
        ops = Nutrition.HealthSyncOp.coalesce(ops, adding: .upsert(m1v2))
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(ops.first { $0.mealId == "m1" }?.meal?.name, "V2")
        // Stale older op is ignored.
        ops = Nutrition.HealthSyncOp.coalesce(ops, adding: .upsert(m1v1))
        XCTAssertEqual(ops.first { $0.mealId == "m1" }?.ts, 2_000)
        // Delete wins equal-ts tie.
        ops = Nutrition.HealthSyncOp.coalesce(ops, adding: .delete(mealId: "m1", ts: 2_000))
        XCTAssertEqual(ops.first { $0.mealId == "m1" }?.kind, .delete)
    }

    func testRecentRepairPlanWithPushedLedgerAndPruning() throws {
        var doc = try emptyDoc()
        doc.change(at: 1_000) { s in
            // Inside 14-day window ending 2026-11-25 (cutoff 2026-11-12).
            Nutrition.upsertMeal(&s, Nutrition.Meal(id: "recent1", date: "2026-11-25", name: "Today", kcal: 500))
            Nutrition.upsertMeal(&s, Nutrition.Meal(id: "recent2", date: "2026-11-12", name: "Boundary", kcal: 400))
            // Outside 14-day window.
            Nutrition.upsertMeal(&s, Nutrition.Meal(id: "old1", date: "2026-11-11", name: "Too old", kcal: 400))
            Nutrition.upsertMeal(&s, Nutrition.Meal(id: "gone1", date: "2026-11-20", name: "To delete", kcal: 300))
        }
        doc.change(at: 2_000) { s in
            Nutrition.deleteMeal(&s, id: "gone1")
        }

        // Empty ledger emits recent1, recent2, and tombstone gone1 (skips old1).
        let plan1 = Nutrition.recentRepairPlan(doc.root, today: "2026-11-25", days: 14, pushed: [:])
        XCTAssertEqual(Set(plan1.map(\.mealId)), Set(["recent1", "recent2", "gone1"]))
        XCTAssertEqual(plan1.first { $0.mealId == "gone1" }?.kind, .delete)

        // Once all confirmed pushed at their exact ts, repair emits nothing.
        var ledger: [String: Nutrition.PushedEntry] = [
            "recent1": Nutrition.PushedEntry(kind: .upsert, ts: 1_000),
            "recent2": Nutrition.PushedEntry(kind: .upsert, ts: 1_000),
            "gone1": Nutrition.PushedEntry(kind: .delete, ts: 2_000),
            "aged-out": Nutrition.PushedEntry(kind: .delete, ts: 500),
        ]
        let plan2 = Nutrition.recentRepairPlan(doc.root, today: "2026-11-25", days: 14, pushed: ledger)
        XCTAssertTrue(plan2.isEmpty)

        // Editing recent1 advances its _ts -> repair emits ONLY recent1.
        doc.change(at: 3_000) { s in
            Nutrition.upsertMeal(&s, Nutrition.Meal(id: "recent1", date: "2026-11-25", name: "Today Edited", kcal: 550))
        }
        let plan3 = Nutrition.recentRepairPlan(doc.root, today: "2026-11-25", days: 14, pushed: ledger)
        XCTAssertEqual(plan3.map(\.mealId), ["recent1"])
        XCTAssertEqual(plan3.first?.ts, 3_000)

        // Pruning drops entries no longer in s["meals"].
        ledger = Nutrition.prunedPushedLedger(ledger, against: doc.root)
        XCTAssertNil(ledger["aged-out"])
        XCTAssertNotNil(ledger["gone1"])
    }

    func testReconcileAfterFlushPreservesMidFlushOps() {
        let m1v1 = Nutrition.Meal(id: "m1", date: "2026-11-25", name: "Lunch", kcal: 500, ts: 1_000)
        let m1v2 = Nutrition.Meal(id: "m1", date: "2026-11-25", name: "Lunch Edited", kcal: 620, ts: 2_000)
        let m2 = Nutrition.Meal(id: "m2", date: "2026-11-25", name: "Snack", kcal: 200, ts: 1_500)
        let m3 = Nutrition.Meal(id: "m3", date: "2026-11-25", name: "Dinner", kcal: 700, ts: 1_200)

        // Case 1: m1 v1 succeeded, but m1 v2 edit and new m2 arrived mid-flush -> both survive.
        let batch1: [Nutrition.HealthSyncOp] = [.upsert(m1v1)]
        let current1: [Nutrition.HealthSyncOp] = [.upsert(m1v2), .upsert(m2)]
        let after1 = Nutrition.HealthSyncOp.reconcileAfterFlush(batch: batch1, failed: [], current: current1)
        XCTAssertEqual(after1.count, 2)
        XCTAssertEqual(after1.first { $0.mealId == "m1" }?.meal?.name, "Lunch Edited")
        XCTAssertEqual(after1.first { $0.mealId == "m2" }?.meal?.name, "Snack")

        // Case 2: m1 v1 failed, m3 succeeded, and mid-flush m1 was deleted at newer ts -> delete supersedes failed m1, m3 dropped.
        let batch2: [Nutrition.HealthSyncOp] = [.upsert(m1v1), .upsert(m3)]
        let failed2: [Nutrition.HealthSyncOp] = [.upsert(m1v1)]
        let current2: [Nutrition.HealthSyncOp] = [.delete(mealId: "m1", ts: 2_500), .upsert(m3)]
        let after2 = Nutrition.HealthSyncOp.reconcileAfterFlush(batch: batch2, failed: failed2, current: current2)
        XCTAssertEqual(after2, [.delete(mealId: "m1", ts: 2_500)])

        // Case 3: all batch ops succeeded and nothing arrived mid-flush -> empty outbox.
        let after3 = Nutrition.HealthSyncOp.reconcileAfterFlush(batch: batch2, failed: [], current: batch2)
        XCTAssertTrue(after3.isEmpty)

        // Case 4: failed op with no mid-flush changes is kept once (no duplication).
        let after4 = Nutrition.HealthSyncOp.reconcileAfterFlush(batch: batch1, failed: batch1, current: batch1)
        XCTAssertEqual(after4, batch1)
    }

    func testMealTypePersistenceZeroChurnUnknownHandlingAndHexMerge() throws {
        // Hour-based meal type suggestion boundaries.
        XCTAssertEqual(Nutrition.MealType.suggested(forHour: 5), .breakfast)
        XCTAssertEqual(Nutrition.MealType.suggested(forHour: 10), .breakfast)
        XCTAssertEqual(Nutrition.MealType.suggested(forHour: 11), .lunch)
        XCTAssertEqual(Nutrition.MealType.suggested(forHour: 13), .lunch)
        XCTAssertEqual(Nutrition.MealType.suggested(forHour: 14), .afternoonTea)
        XCTAssertEqual(Nutrition.MealType.suggested(forHour: 16), .afternoonTea)
        XCTAssertEqual(Nutrition.MealType.suggested(forHour: 17), .dinner)
        XCTAssertEqual(Nutrition.MealType.suggested(forHour: 20), .dinner)
        XCTAssertEqual(Nutrition.MealType.suggested(forHour: 21), .lateNight)
        XCTAssertEqual(Nutrition.MealType.suggested(forHour: 2), .lateNight)

        // Meal without mealType omits "mealType" key completely and does not restamp on unchanged re-upsert.
        var doc = try emptyDoc()
        let plain = Nutrition.Meal(id: "m-plain", date: "2026-11-27", time: "08:30", name: "Oats", kcal: 320, protein: 24)
        doc.change(at: 1_000) { s in
            Nutrition.upsertMeal(&s, plain)
        }
        let rawPlain = try XCTUnwrap(doc.root["meals"]?.object?["m-plain"]?.object)
        XCTAssertNil(rawPlain["mealType"], "nil mealType must be omitted to avoid churning legacy entries")
        XCTAssertEqual(rawPlain["_ts"], .number(1_000))

        doc.change(at: 2_000) { s in
            Nutrition.upsertMeal(&s, plain)
        }
        XCTAssertEqual(doc.root["meals"]?.object?["m-plain"]?.object?["_ts"], .number(1_000))

        // Unknown raw mealType parses safely as nil.
        var unknownDoc = doc
        unknownDoc.change(at: 2_500) { s in
            var map = s["meals"]?.object ?? [:]
            var obj = map["m-plain"]?.object ?? [:]
            obj["mealType"] = .string("future_slot")
            map["m-plain"] = .object(obj)
            s["meals"] = .object(map)
        }
        XCTAssertNil(Nutrition.meal(unknownDoc.root, id: "m-plain")?.mealType)

        // Typed meal persists and survives HexMerge across two devices.
        var devA = try emptyDoc()
        devA.change(at: 3_000) { s in
            Nutrition.upsertMeal(&s, Nutrition.Meal(
                id: "m-bf",
                date: "2026-11-27",
                time: "08:15",
                mealType: .breakfast,
                name: "Protein & Chicken",
                kcal: 340,
                protein: 56
            ))
        }
        var devB = try emptyDoc()
        devB.change(at: 3_500) { s in
            Nutrition.upsertMeal(&s, Nutrition.Meal(
                id: "m-tea",
                date: "2026-11-27",
                time: "15:00",
                mealType: .afternoonTea,
                name: "Yogurt",
                kcal: 150,
                protein: 15
            ))
        }

        let merged = try HexMerge.merge(devA.root, devB.root, now: 4_000)
        XCTAssertEqual(Nutrition.meal(merged, id: "m-bf")?.mealType, .breakfast)
        XCTAssertEqual(Nutrition.meal(merged, id: "m-tea")?.mealType, .afternoonTea)
    }
}
