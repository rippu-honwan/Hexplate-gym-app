import XCTest
@testable import HexplateCore

final class CoachOpsTests: XCTestCase {
    typealias Object = [String: JSONValue]

    private let catalog = ExerciseCatalog.builtIn

    private func exerciseId(matching predicate: (Exercise) -> Bool) -> String {
        catalog.all.first(where: predicate)!.id
    }

    private func sharedURL(_ filename: String) throws -> URL {
        // #filePath -> .../app/HexplateCore/Tests/HexplateCoreTests/CoachOpsTests.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // HexplateCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // HexplateCore
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repo root
        let url = repoRoot.appending(path: "shared/\(filename)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "CoachOpsTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing required shared fixture file at \(url.path)"]
            )
        }
        return url
    }

    // MARK: - Shared Two-Layer Schema & Semantic Fixtures (R3, N6)

    func testSharedSchemaAndSemanticFixturesMatchExactly() throws {
        // Verify canonical schema JSON itself is valid JSON on disk.
        let schemaData = try Data(contentsOf: sharedURL("coach_ops.schema.json"))
        let schemaObj = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        XCTAssertEqual(schemaObj?["$schema"] as? String, "https://json-schema.org/draft/2020-12/schema")

        let fixtureData = try Data(contentsOf: sharedURL("coach_ops_fixtures.json"))
        let rootVal = try JSONDecoder().decode(JSONValue.self, from: fixtureData)
        let fixtureObj = try XCTUnwrap(rootVal.object)

        // Layer 1: Schema fixtures (must match Draft 2020-12 1:1).
        let schemaCases = try XCTUnwrap(fixtureObj["schema"]?.arrayValue)
        XCTAssertGreaterThanOrEqual(schemaCases.count, 20)
        for item in schemaCases {
            let obj = try XCTUnwrap(item.object)
            let name = try XCTUnwrap(obj["name"]?.stringValue)
            let expect = try XCTUnwrap(obj["expect"]?.stringValue)
            let rawOps = try XCTUnwrap(obj["ops"]?.arrayValue)

            if expect == "valid" {
                do {
                    _ = try CoachOps.parseSchemaOps(rawOps)
                } catch {
                    XCTFail("Schema fixture '\(name)' expected valid, threw: \(error)")
                }
            } else {
                XCTAssertThrowsError(try CoachOps.parseSchemaOps(rawOps), "Schema fixture '\(name)' expected invalid")
            }
        }

        // Layer 2: Portable semantic fixtures (exact error codes).
        let semanticCases = try XCTUnwrap(fixtureObj["semantic"]?.arrayValue)
        XCTAssertGreaterThanOrEqual(semanticCases.count, 18)
        for item in semanticCases {
            let obj = try XCTUnwrap(item.object)
            let name = try XCTUnwrap(obj["name"]?.stringValue)
            let rawOps = try XCTUnwrap(obj["ops"]?.arrayValue)
            let ctxData = try JSONEncoder().encode(try XCTUnwrap(obj["context"]))
            let ctx = try JSONDecoder().decode(CoachOps.SemanticContext.self, from: ctxData)
            let expectObj = try XCTUnwrap(obj["expect"]?.object)

            let ops = try CoachOps.parseSchemaOps(rawOps)
            if expectObj["ok"] == .bool(true) {
                do {
                    try CoachOps.validateSemantic(ops, against: ctx)
                } catch {
                    XCTFail("Semantic fixture '\(name)' expected ok, threw: \(error)")
                }
            } else {
                let wantCode = try XCTUnwrap(expectObj["error"]?.stringValue)
                do {
                    try CoachOps.validateSemantic(ops, against: ctx)
                    XCTFail("Semantic fixture '\(name)' expected error '\(wantCode)' but succeeded")
                } catch let err as CoachOps.ValidationError {
                    XCTAssertEqual(err.code, wantCode, "Semantic fixture '\(name)' error code mismatch")
                } catch {
                    XCTFail("Semantic fixture '\(name)' threw non-ValidationError: \(error)")
                }
            }
        }
    }

    // MARK: - Week Mode, Chained Ops, Minimal Compile & Net-Zero (R6)

    @MainActor
    func testWeekModeMoveDayChainedSetSetsAndMinimalNetZeroCompile() throws {
        let benchId = exerciseId { $0.equipment == "barbell" && catalog.primaryMuscle(of: $0) == "chest" }
        let rowId = exerciseId { $0.equipment == "barbell" && catalog.primaryMuscle(of: $0) == "upper-back" }
        let today = "2026-11-26" // Thu (4)

        let root: Object = [
            "unit": .string("kg"),
            "routines": .array([
                .object(["id": .string("r-push"), "name": .string("Push"), "emoji": .string("flame"), "ex": .array([
                    .object(["id": .string(benchId), "sets": .number(3), "reps": .number(8), "mode": .string("reps")]),
                ])]),
                .object(["id": .string("r-pull"), "name": .string("Pull"), "emoji": .string("bolt"), "ex": .array([
                    .object(["id": .string(rowId), "sets": .number(3), "reps": .number(10), "mode": .string("reps")]),
                ])]),
            ]),
            "week": .object([
                "4": .array([.string("r-push")]), // 2026-11-26
                "5": .array([.string("r-pull")]), // 2026-11-27
            ]),
            "dayPlan": .object([:]),
        ]

        let snap = CoachContext.build(
            root: root, today: today, timezone: "Asia/Tokyo",
            readiness: nil, readinessSignals: nil, liveExternalNutrition: nil, catalog: catalog
        )

        // Move Thu Push -> Sat (2026-11-28, rest) and change sets to 5 on Sat sequentially.
        let ops: [CoachOps.Op] = [
            .moveDay(from: "2026-11-26", to: "2026-11-28", collision: .replace, reason: "Busy Thursday"),
            .setSets(date: "2026-11-28", routineId: "r-push", slotIndex: 0, exerciseId: benchId, sets: 5, reps: 6, reason: "Extra volume"),
        ]
        let preview = try CoachOps.preview(ops: ops, snapshot: snap, root: root, today: today, catalog: catalog) { "tok\($0)" }
        XCTAssertTrue(preview.hasChanges)
        XCTAssertEqual(preview.touchedDates, ["2026-11-26", "2026-11-28"])
        XCTAssertEqual(preview.compiledDayPlan["2026-11-26"], .string(Schedule.rest))
        XCTAssertEqual(preview.compiledDayPlan["2026-11-28"], .string("ai-2026-11-28-tok0"))

        let clone = try XCTUnwrap(preview.createdClones["ai-2026-11-28-tok0"])
        XCTAssertEqual(clone["name"], .string("Push")) // Exact parent name preserved (1e)
        XCTAssertEqual(clone["aiClone"], .bool(true))
        XCTAssertEqual(clone["cloneOf"], .string("r-push"))
        XCTAssertEqual(clone["ephemeralDate"], .string("2026-11-28"))

        // Net-zero cancelling batch: swap Thu <-> Fri then swap Fri <-> Thu -> zero writes, apply returns nil (R6).
        let cancelOps: [CoachOps.Op] = [
            .moveDay(from: "2026-11-26", to: "2026-11-27", collision: .swap, reason: nil),
            .moveDay(from: "2026-11-27", to: "2026-11-26", collision: .swap, reason: nil),
        ]
        let cancelPreview = try CoachOps.preview(ops: cancelOps, snapshot: snap, root: root, today: today, catalog: catalog)
        XCTAssertFalse(cancelPreview.hasChanges)
        XCTAssertTrue(cancelPreview.compiledDayPlan.isEmpty)
        XCTAssertTrue(cancelPreview.createdClones.isEmpty)
        var copyRoot = root
        var tokens: [String: String] = [:]
        let undo = try CoachOps.apply(cancelPreview, to: &copyRoot, currentToday: today, acceptToken: "t0", acceptedAt: 1000, appliedTokens: &tokens)
        XCTAssertNil(undo)
        XCTAssertEqual(copyRoot, root)
    }

    // MARK: - Rotation Mode Rules & Weekday-Own Routine (R1, Build Note 4)

    @MainActor
    func testRotationClonePinPreservesQueueViewForbidsRedatingAndAllowsWeekdayOwn() throws {
        let benchId = exerciseId { $0.equipment == "barbell" && catalog.primaryMuscle(of: $0) == "chest" }
        let rowId = exerciseId { $0.equipment == "barbell" && catalog.primaryMuscle(of: $0) == "upper-back" }
        let absId = exerciseId { catalog.primaryMuscle(of: $0) == "abs" && !$0.isHold }
        let today = "2026-11-26" // Thu (4)

        var root: Object = [
            "scheduleMode": .string("rotation"),
            "routines": .array([
                .object(["id": .string("rA"), "name": .string("Push A"), "ex": .array([.object(["id": .string(benchId), "sets": .number(3), "reps": .number(8), "mode": .string("reps")])])]),
                .object(["id": .string("rB"), "name": .string("Pull B"), "ex": .array([.object(["id": .string(rowId), "sets": .number(3), "reps": .number(10), "mode": .string("reps")])])]),
                .object(["id": .string("rCore"), "name": .string("Core"), "ex": .array([.object(["id": .string(absId), "sets": .number(3), "reps": .number(15), "mode": .string("reps")])])]),
            ]),
            "rotation": .object(["id": .string("rot1"), "sequence": .array([.string("rA"), .string("rB")])]),
            "queue": .object([
                "ids": .array([.string("rA"), .string("rB")]),
                "startsOn": .string(today),
                "since": .number(Day.noon(today) - 1000),
                "rotationId": .string("rot1"),
            ]),
            // Weekday-own non-queued routine on Friday (5 -> 2026-11-27)
            "week": .object(["5": .array([.string("rCore")])]),
            "dayPlan": .object([:]),
        ]

        let snap = CoachContext.build(
            root: root, today: today, timezone: "UTC",
            readiness: nil, readinessSignals: nil, liveExternalNutrition: nil, catalog: catalog
        )
        XCTAssertEqual(snap.rotationOnDate, today)
        XCTAssertEqual(snap.day(for: "2026-11-27")?.isQueueSession, false)
        XCTAssertEqual(snap.day(for: "2026-11-27")?.routineId, "rCore")

        // 1. Editing queue session on `on` date pins clone(A) on `today`, keeping A "next" and B "later" in queueView.
        let onOps: [CoachOps.Op] = [
            .setSets(date: today, routineId: "rA", slotIndex: 0, exerciseId: benchId, sets: 4, reps: nil, reason: nil),
        ]
        let onPreview = try CoachOps.preview(ops: onOps, snapshot: snap, root: root, today: today, catalog: catalog) { "r\($0)" }
        var tokens: [String: String] = [:]
        var appliedRoot = root
        let undo = try CoachOps.apply(onPreview, to: &appliedRoot, currentToday: today, acceptToken: "rot-a", acceptedAt: 1000, appliedTokens: &tokens)
        XCTAssertNotNil(undo)
        let qv = try XCTUnwrap(Schedule.queueView(appliedRoot, today: today))
        XCTAssertEqual(qv.items.first { $0.id == "rA" }?.state, "next")
        XCTAssertEqual(qv.items.first { $0.id == "rB" }?.state, "later")

        // 2. Any move_day in rotation mode is rejected.
        XCTAssertThrowsError(try CoachOps.preview(
            ops: [.moveDay(from: today, to: "2026-11-28", collision: .replace, reason: nil)],
            snapshot: snap, root: root, today: today, catalog: catalog
        )) { err in
            XCTAssertEqual((err as? CoachOps.ValidationError)?.code, "disallowed_in_rotation_mode")
        }

        // 3. Weekday-own routine (non-queue session) on a rotation date passes post-compile verification (Build Note 4).
        let coreOps: [CoachOps.Op] = [
            .setSets(date: "2026-11-27", routineId: "rCore", slotIndex: 0, exerciseId: absId, sets: 4, reps: nil, reason: nil),
        ]
        let corePreview = try CoachOps.preview(ops: coreOps, snapshot: snap, root: root, today: today, catalog: catalog) { "c\($0)" }
        XCTAssertTrue(corePreview.hasChanges)
        var coreTokens: [String: String] = [:]
        _ = try CoachOps.apply(corePreview, to: &root, currentToday: today, acceptToken: "core-1", acceptedAt: 1000, appliedTokens: &coreTokens)
        XCTAssertEqual(Schedule.routineIds(root, on: today, today: today), ["rA"]) // untouched queue day unchanged
        XCTAssertEqual(Schedule.canonical(root, Schedule.routineIds(root, on: "2026-11-27", today: today)[0]), "rCore")
    }

    // MARK: - Snapshot-Anchored Staleness Across HexMerge (R2)

    @MainActor
    func testSnapshotAnchoredStaleCheckRejectsRemoteHexMergeBeforePreview() throws {
        let benchId = exerciseId { $0.equipment == "barbell" && catalog.primaryMuscle(of: $0) == "chest" }
        let today = "2026-11-26"

        var localDoc = try StateDocument(data: Data(#"{"unit":"kg","workouts":[],"routines":[],"week":{},"dayPlan":{},"bodyweight":[],"measurements":[],"customEx":[]}"#.utf8))
        localDoc.change(at: 10_000) { s in
            s["routines"] = .array([
                .object(["id": .string("r1"), "name": .string("Push"), "ex": .array([.object(["id": .string(benchId), "sets": .number(3), "reps": .number(8), "mode": .string("reps")])])]),
            ])
            s["week"] = .object(["4": .array([.string("r1")])])
        }

        // Build snapshot BEFORE remote sync arrives.
        let snap = CoachContext.build(
            root: localDoc.root, today: today, timezone: "UTC",
            readiness: nil, readinessSignals: nil, liveExternalNutrition: nil, catalog: catalog
        )

        // Remote device skips today while LLM call is in flight; HexMerge merges it into local.
        var remoteDoc = localDoc
        remoteDoc.change(at: 20_000) { s in
            s["dayPlan"] = .object([today: .string(Schedule.rest)])
        }
        let merged = try HexMerge.merge(localDoc.root, remoteDoc.root, now: 20_000)

        XCTAssertThrowsError(try CoachOps.preview(
            ops: [.setSets(date: today, routineId: "r1", slotIndex: 0, exerciseId: benchId, sets: 5, reps: nil, reason: nil)],
            snapshot: snap, root: merged, today: today, catalog: catalog
        )) { err in
            XCTAssertEqual((err as? CoachOps.ValidationError)?.code, "stale_plan")
        }
    }

    // MARK: - Mode-Aware Ops, Session-Engine LoadSeed, Programme %1RM & Week Change (R5, N4, Build Note 5)

    @MainActor
    func testModeAwareSwapSessionEngineLoadSeedAndProgrammeDiffs() throws {
        let benchId = exerciseId { $0.equipment == "barbell" && catalog.primaryMuscle(of: $0) == "chest" && !$0.isHold }
        let dbBenchId = exerciseId { $0.equipment == "dumbbell" && catalog.primaryMuscle(of: $0) == "chest" && !$0.isHold && $0.id != benchId }
        let holdId = exerciseId { $0.isHold }
        let bwId = exerciseId { $0.isBodyweightEquipment && !$0.isHold && !$0.isCardio }
        let today = "2026-11-26" // Thu (Week 1), 2026-12-01 is Tue (Week 2)

        let root: Object = [
            "unit": .string("kg"),
            "exUnit": .object([dbBenchId: .string("lb")]), // Build Note 5: per-exercise unit override
            "routines": .array([
                .object([
                    "id": .string("r-push"),
                    "name": .string("Push"),
                    "ex": .array([
                        .object(["id": .string(benchId), "sets": .number(4), "reps": .number(6), "mode": .string("reps"), "sg": .string("sg1"), "restSec": .number(120)]),
                        .object(["id": .string(bwId), "sets": .number(3), "reps": .number(12), "mode": .string("reps"), "sg": .string("sg1")]),
                    ]),
                ]),
            ]),
            "week": .object(["4": .array([.string("r-push")])]),
            "programmes": .object([
                "p1": .object([
                    "id": .string("p1"),
                    "name": .string("Strength"),
                    "at": .number(1000),
                    "weeks": .array([
                        .object(["t": .object([
                            "r-push:\(benchId)": .object(["pct": .number(80)]),
                            dbBenchId: .object(["pct": .number(75)]),
                        ])]),
                        .object(["deload": .bool(true), "t": .object([
                            "r-push:\(benchId)": .object(["pct": .number(60)]),
                        ])]),
                    ]),
                    "days": .object(["4": .array([.string("r-push")])]),
                ]),
            ]),
            "programme": .object([
                "id": .string("p1"),
                "startedOn": .string("2026-11-23"), // Monday of Week 1
                "cycle": .number(1),
                "bump": .number(0),
            ]),
            // Prior logged workout giving dbBenchId a 1RM / last weight so Session.entries prefills > 0.
            "workouts": .array([
                .object([
                    "id": .string("w-prev"),
                    "d": .string("2026-11-20"),
                    "start": .number(Day.noon("2026-11-20")),
                    "routineId": .string("r-push"),
                    "entries": .array([
                        .object([
                            "id": .string(dbBenchId),
                            "sets": .array([
                                .object(["w": .number(50), "r": .number(8), "done": .bool(true)]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            // Unrelated active session on another day MUST NOT corrupt LoadSeed programme week (R5).
            "active": .object(["d": .string("2026-11-25"), "id": .string("act-old")]),
            "dayPlan": .object([:]),
        ]

        // Build snapshot with dbBenchId & holdId guaranteed in alias table by placing them in a helper routine or direct build.
        var buildRoot = root
        if var list = buildRoot["routines"]?.arrayValue {
            list.append(.object([
                "id": .string("r-pool"),
                "name": .string("Pool"),
                "ex": .array([
                    .object(["id": .string(dbBenchId), "sets": .number(3), "reps": .number(10)]),
                    .object(["id": .string(holdId), "sets": .number(3), "sec": .number(45), "mode": .string("time")]),
                ]),
            ]))
            buildRoot["routines"] = .array(list)
        }

        let snap = CoachContext.build(
            root: buildRoot, today: today, timezone: "UTC",
            readiness: nil, readinessSignals: nil, liveExternalNutrition: nil, catalog: catalog
        )

        // 1. Swap bench -> dbBench: detects BOTH dropped (80%) and gained (75%) Programme %1RM, prefill uses `lb` exUnit!
        let swapOps: [CoachOps.Op] = [
            .swapExercise(date: today, routineId: "r-push", slotIndex: 0, fromExerciseId: benchId, toExerciseId: dbBenchId, sets: 4, reps: 8, reason: "Shoulder friendly"),
        ]
        let swapPreview = try CoachOps.preview(ops: swapOps, snapshot: snap, root: buildRoot, today: today, catalog: catalog) { "s\($0)" }
        let diff = try XCTUnwrap(swapPreview.dayDiffs.first)
        if case .swapped(_, _, _, _, _, let dropped, let gained, let seed) = diff.slotChanges.first {
            XCTAssertEqual(dropped, 80)
            XCTAssertEqual(gained, 75)
            if case .prefill(let weight, let unit) = seed {
                XCTAssertGreaterThan(weight, 0)
                XCTAssertEqual(unit, "lb")
            } else {
                XCTFail("Expected .prefill load seed, got \(seed)")
            }
        } else {
            XCTFail("Expected swapped slot change")
        }

        // Verify superset metadata & restSec carried over cleanly.
        let clone = try XCTUnwrap(swapPreview.createdClones["ai-2026-11-26-s0"])
        let slot0 = try XCTUnwrap(clone["ex"]?.arrayValue?.first?.object)
        XCTAssertEqual(slot0["sg"], .string("sg1"))
        XCTAssertEqual(slot0["restSec"], .number(120))

        // 2. Swap reps -> time hold without reps succeeds and drops `reps` field; with reps throws reps_not_applicable.
        let holdSwapNoReps: [CoachOps.Op] = [
            .swapExercise(date: today, routineId: "r-push", slotIndex: 0, fromExerciseId: benchId, toExerciseId: holdId, sets: 3, reps: nil, reason: nil),
        ]
        let holdPreview = try CoachOps.preview(ops: holdSwapNoReps, snapshot: snap, root: buildRoot, today: today, catalog: catalog) { "h\($0)" }
        let holdSlot = try XCTUnwrap(holdPreview.createdClones["ai-2026-11-26-h0"]?["ex"]?.arrayValue?.first?.object)
        XCTAssertNil(holdSlot["reps"])
        XCTAssertNotNil(holdSlot["sec"])

        XCTAssertThrowsError(try CoachOps.preview(
            ops: [.swapExercise(date: today, routineId: "r-push", slotIndex: 0, fromExerciseId: benchId, toExerciseId: holdId, sets: 3, reps: 10, reason: nil)],
            snapshot: snap, root: buildRoot, today: today, catalog: catalog
        )) { err in
            XCTAssertEqual((err as? CoachOps.ValidationError)?.code, "reps_not_applicable")
        }

        // 3. move_day across Programme Week 1 -> Week 2 (deload) flags programmeWeekChanged (N4).
        let movePreview = try CoachOps.preview(
            ops: [.moveDay(from: "2026-11-26", to: "2026-12-01", collision: .replace, reason: nil)],
            snapshot: snap, root: buildRoot, today: today, catalog: catalog
        )
        XCTAssertEqual(movePreview.dayDiffs.first { $0.date == "2026-12-01" }?.programmeWeekChanged, true)

        // 4. Unchanged slot on aiClone still receives Programme `<rid>:<exId>` target inside `Session.begin`.
        let setSetsPreview = try CoachOps.preview(
            ops: [.setSets(date: today, routineId: "r-push", slotIndex: 1, exerciseId: bwId, sets: 4, reps: nil, reason: nil)],
            snapshot: snap, root: buildRoot, today: today, catalog: catalog
        ) { "p\($0)" }
        var liveRoot = buildRoot
        liveRoot["active"] = nil
        var tokens: [String: String] = [:]
        _ = try CoachOps.apply(setSetsPreview, to: &liveRoot, currentToday: today, acceptToken: "prog-1", acceptedAt: 1000, appliedTokens: &tokens)
        let cloneId = try XCTUnwrap(liveRoot["dayPlan"]?.object?[today]?.stringValue)
        let started = Session.begin(liveRoot, routineIds: [cloneId], bodyweight: 75, id: "s1", now: Day.noon(today), day: today, catalog: catalog, today: today)
        let firstEntry = try XCTUnwrap(started["entries"]?.arrayValue?.first?.object)
        XCTAssertEqual(firstEntry["plan"]?.object?["kind"], .string("programme"))
        XCTAssertEqual(firstEntry["plan"]?.object?["prog"]?.object?["pct"], .number(80))
    }

    // MARK: - Clone-of-Clone, Midnight Drift, Bounded Idempotency & Merge-Undo-Merge (R6, N5)

    @MainActor
    func testCloneOfCloneMidnightIdempotencyAndEndToEndMergeUndoMerge() throws {
        let benchId = exerciseId { $0.equipment == "barbell" && catalog.primaryMuscle(of: $0) == "chest" }
        let today = "2026-11-26"

        var doc = try StateDocument(data: Data(#"{"unit":"kg","workouts":[],"routines":[],"week":{},"dayPlan":{},"bodyweight":[],"measurements":[],"customEx":[]}"#.utf8))
        doc.change(at: 10_000) { s in
            s["routines"] = .array([
                .object(["id": .string("r1"), "name": .string("Push"), "ex": .array([
                    .object(["id": .string(benchId), "sets": .number(3), "reps": .number(8), "mode": .string("reps")]),
                ])]),
            ])
            s["week"] = .object(["4": .array([.string("r1")])])
        }

        // First AI edit: 3 -> 4 sets.
        let snap1 = CoachContext.build(
            root: doc.root, today: today, timezone: "UTC",
            readiness: nil, readinessSignals: nil, liveExternalNutrition: nil, catalog: catalog
        )
        let preview1 = try CoachOps.preview(
            ops: [.setSets(date: today, routineId: "r1", slotIndex: 0, exerciseId: benchId, sets: 4, reps: nil, reason: nil)],
            snapshot: snap1, root: doc.root, today: today, catalog: catalog
        ) { "v1-\($0)" }

        // Midnight drift aborts with zero mutation.
        var midnightRoot = doc.root
        var tokens: [String: String] = ["stale-yesterday": "2026-11-25"]
        XCTAssertThrowsError(try CoachOps.apply(preview1, to: &midnightRoot, currentToday: "2026-11-27", acceptToken: "acc-1", acceptedAt: 11_000, appliedTokens: &tokens)) { err in
            XCTAssertEqual((err as? CoachOps.ValidationError)?.code, "today_shifted")
        }
        XCTAssertEqual(midnightRoot, doc.root)
        // Stale prior-day token was pruned (N5).
        XCTAssertNil(tokens["stale-yesterday"])

        // Apply cleanly inside StateDocument.change.
        var undo1: AIUndoRecord?
        doc.change(at: 12_000) { s in
            undo1 = try? CoachOps.apply(preview1, to: &s, currentToday: today, acceptToken: "acc-1", acceptedAt: 12_000, appliedTokens: &tokens)
        }
        let record1 = try XCTUnwrap(undo1)

        // Duplicate acceptToken is rejected.
        var dupRoot = doc.root
        XCTAssertThrowsError(try CoachOps.apply(preview1, to: &dupRoot, currentToday: today, acceptToken: "acc-1", acceptedAt: 12_500, appliedTokens: &tokens)) { err in
            XCTAssertEqual((err as? CoachOps.ValidationError)?.code, "duplicate_accept_token")
        }

        // Second AI edit on top of the existing aiClone: new clone's `cloneOf` must still be canonical "r1" (R6)!
        let snap2 = CoachContext.build(
            root: doc.root, today: today, timezone: "UTC",
            readiness: nil, readinessSignals: nil, liveExternalNutrition: nil, catalog: catalog
        )
        XCTAssertEqual(snap2.day(for: today)?.isAIClone, true)
        let preview2 = try CoachOps.preview(
            ops: [.setSets(date: today, routineId: "r1", slotIndex: 0, exerciseId: benchId, sets: 5, reps: nil, reason: nil)],
            snapshot: snap2, root: doc.root, today: today, catalog: catalog
        ) { "v2-\($0)" }
        let clone2 = try XCTUnwrap(preview2.createdClones["ai-2026-11-26-v2-0"])
        XCTAssertEqual(clone2["cloneOf"], .string("r1"))
        XCTAssertEqual(clone2["name"], .string("Push"))

        // Full Merge -> Undo -> Merge round-trip on record1 (verifies dayPlan[iso] = nil deletion merge & clone cleanup).
        let serverCopy = try HexMerge.merge(doc.root, doc.root, now: 12_000)
        var afterMerge = try StateDocument(data: JSONEncoder().encode(JSONValue.object(serverCopy)))
        var outcome: AIUndo.Outcome?
        afterMerge.change(at: 15_000) { s in
            outcome = AIUndo.apply(record1, to: &s, today: today)
        }
        XCTAssertEqual(outcome?.status, .available)
        XCTAssertEqual(outcome?.restoredDates, [today])
        XCTAssertEqual(outcome?.removedCloneIds, ["ai-2026-11-26-v1-0"])

        let finalMerged = try HexMerge.merge(afterMerge.root, serverCopy, now: 16_000)
        XCTAssertNil(finalMerged["dayPlan"]?.object?[today])
        let remainingClone = (finalMerged["routines"]?.arrayValue ?? []).first { $0.object?["id"] == .string("ai-2026-11-26-v1-0") }
        XCTAssertNil(remainingClone)
    }
}
