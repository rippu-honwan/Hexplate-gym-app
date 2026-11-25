import XCTest
@testable import HexplateCore

final class CloneAndPinTests: XCTestCase {
    typealias Object = [String: JSONValue]

    private func routine(id: String, name: String, ex: [Object], cloneOf: String? = nil, ephemeralDate: String? = nil) -> JSONValue {
        var r: Object = [
            "id": .string(id),
            "name": .string(name),
            "emoji": .string("figureStrength"),
            "ex": .array(ex.map(JSONValue.object)),
        ]
        if let cloneOf {
            r["aiClone"] = .bool(true)
            r["cloneOf"] = .string(cloneOf)
        }
        if let ephemeralDate {
            r["ephemeralDate"] = .string(ephemeralDate)
        }
        return .object(r)
    }

    private func slot(_ exId: String, sets: Double, reps: Double, weight: Double = 60) -> Object {
        ["id": .string(exId), "sets": .number(sets), "reps": .number(reps), "weight": .number(weight)]
    }

    // 1a: Session.begin on an aiClone applies parent <rid>:<exId> Programme target + last-time
    // pre-fill and records canonical parentId on active.routineIds and entry.rid.
    func testSessionBeginAppliesProgrammeTargetAndLastTimeOnAIClone() throws {
        let state: Object = [
            "unit": .string("kg"),
            "startFrom": .string("last"),
            "routines": .array([
                routine(id: "push", name: "Push", ex: [
                    slot("0025", sets: 4, reps: 5, weight: 80),
                    slot("0027", sets: 3, reps: 10, weight: 40),
                ]),
                routine(
                    id: "ai-2026-11-25-p1",
                    name: "Push",
                    ex: [
                        slot("0025", sets: 3, reps: 5, weight: 80),
                        slot("0027", sets: 2, reps: 10, weight: 40),
                    ],
                    cloneOf: "push",
                    ephemeralDate: "2026-11-25"
                ),
            ]),
            "week": .object(["3": .array([.string("push")])]),
            "dayPlan": .object(["2026-11-25": .string("ai-2026-11-25-p1")]),
            "programmes": .object([
                "prog1": .object([
                    "id": .string("prog1"),
                    "name": .string("Strength Block"),
                    "at": .number(1_000),
                    "days": .object(["3": .array([.string("push")])]),
                    "weeks": .array([
                        .object(["t": .object(["push:0025": .object(["pct": .number(80)])])]),
                    ]),
                ]),
            ]),
            "programme": .object([
                "id": .string("prog1"),
                "startedOn": .string("2026-11-23"),
                "cycle": .number(1),
                "bump": .number(0),
            ]),
            "workouts": .array([
                .object([
                    "id": .string("w1"),
                    "d": .string("2026-11-18"),
                    "start": .number(1_794_900_000_000),
                    "routineIds": .array([.string("push")]),
                    "routineId": .string("push"),
                    "name": .string("Push"),
                    "entries": .array([
                        .object([
                            "id": .string("0025"),
                            "rid": .string("push"),
                            "sets": .array([.object(["w": .number(100), "r": .number(5), "done": .bool(true)])]),
                        ]),
                        .object([
                            "id": .string("0027"),
                            "rid": .string("push"),
                            "sets": .array([
                                .object(["w": .number(47.5), "r": .number(10), "done": .bool(true)]),
                                .object(["w": .number(47.5), "r": .number(10), "done": .bool(true)]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ]

        let active = Session.begin(
            state,
            routineIds: ["ai-2026-11-25-p1"],
            bodyweight: 75,
            id: "s1",
            now: 1_795_500_000_000,
            day: "2026-11-25",
            catalog: .builtIn,
            today: "2026-11-25"
        )

        XCTAssertEqual(active["routineIds"], .array([.string("push")]))
        XCTAssertEqual(active["name"], .string("Push"))
        let entries = try XCTUnwrap(active["entries"]?.arrayValue?.compactMap(\.object))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0]["rid"], .string("push"))
        XCTAssertEqual(entries[0]["plan"]?.object?["kind"], .string("programme"))
        XCTAssertEqual(entries[0]["sets"]?.arrayValue?.count, 3) // clone's 3 sets, not parent's 4
        // 100 kg x 5 -> e1RM 116.7, 80% = 93.36 snapped to 2.5 kg step -> 92.5 kg (distinct from
        // the slot's default 80 kg, proving the parent <rid>:<exId> Programme target applied).
        let benchWeight = try XCTUnwrap(entries[0]["sets"]?.arrayValue?.first?.object?["w"]?.numberValue)
        XCTAssertEqual(benchWeight, 92.5, accuracy: 0.01)

        // Second exercise carries parent's last-time weight (47.5 + progression step) with clone's 2 sets.
        XCTAssertEqual(entries[1]["rid"], .string("push"))
        XCTAssertEqual(entries[1]["sets"]?.arrayValue?.count, 2)
        let rowWeight = try XCTUnwrap(entries[1]["sets"]?.arrayValue?.first?.object?["w"]?.numberValue)
        XCTAssertGreaterThanOrEqual(rowWeight, 47.5)
    }

    // T2 (R1): Explicit Session.begin([parent]) on a clone-pinned day runs the PARENT's exercises,
    // while WatchLink.apply `start` resolves through Schedule.resolvePin to the clone's exercises.
    func testExplicitParentStartUsesParentWhileWatchStartResolvesClonePin() throws {
        var state: Object = [
            "unit": .string("kg"),
            "routines": .array([
                routine(id: "push", name: "Push", ex: [slot("0025", sets: 4, reps: 8, weight: 80)]),
                routine(id: "pull", name: "Pull", ex: [slot("0027", sets: 3, reps: 10, weight: 50)]),
                routine(
                    id: "ai-2026-11-25-x",
                    name: "Push",
                    ex: [slot("0025", sets: 2, reps: 12, weight: 60)],
                    cloneOf: "push",
                    ephemeralDate: "2026-11-25"
                ),
            ]),
            "week": .object(["3": .array([.string("push")])]),
            "dayPlan": .object(["2026-11-25": .string("ai-2026-11-25-x")]),
            "workouts": .array([]),
        ]

        // 1. Explicit parent start (RoutineEditorView / Backfill): keeps parent's 4 sets @ 80 kg.
        let explicit = Session.begin(state, routineIds: ["push"], bodyweight: nil, id: "e1", now: 1_000, day: "2026-11-25", catalog: .builtIn)
        let explicitSets = try XCTUnwrap(explicit["entries"]?.arrayValue?.first?.object?["sets"]?.arrayValue)
        XCTAssertEqual(explicitSets.count, 4)
        XCTAssertEqual(explicitSets.first?.object?["w"], .number(80))

        // 2. WatchLink.ready: today has canonical parent ID with clone's 2 sets; others hides clone and parent.
        let ready = try XCTUnwrap(WatchLink.ready(state, today: "2026-11-25", catalog: .builtIn).object)
        let todayReady = try XCTUnwrap(ready["today"]?.object)
        XCTAssertEqual(todayReady["routineIds"], .array([.string("push")]))
        XCTAssertEqual(todayReady["entries"]?.arrayValue?.first?.object?["sets"]?.arrayValue?.count, 2)
        let others = try XCTUnwrap(ready["others"]?.arrayValue?.compactMap(\.object))
        XCTAssertEqual(others.map { $0["routineIds"] }, [.array([.string("pull")])])

        // 3. Watch start event carrying canonical ["push"] resolves through dayPlan["2026-11-25"] clone pin.
        let startAt = Day.noon("2026-11-25")
        let watchStart: Object = [
            "id": .string("ev1"),
            "type": .string("start"),
            "wid": .string("watch-1"),
            "routineIds": .array([.string("push")]),
            "at": .number(startAt),
        ]
        _ = WatchLink.apply(watchStart, to: &state, today: "2026-11-25", now: startAt, newId: "n1", catalog: .builtIn)
        let active = try XCTUnwrap(state["active"]?.object)
        XCTAssertEqual(active["routineIds"], .array([.string("push")]))
        let watchSets = try XCTUnwrap(active["entries"]?.arrayValue?.first?.object?["sets"]?.arrayValue)
        XCTAssertEqual(watchSets.count, 2)
        XCTAssertEqual(watchSets.first?.object?["w"], .number(60))
    }

    func testWatchAdoptsCloneStartedOnPhone() throws {
        let startAt = Day.noon("2026-11-25")
        var state: Object = [
            "unit": .string("kg"),
            "routines": .array([
                routine(id: "push", name: "Push", ex: [slot("0025", sets: 4, reps: 8, weight: 80)]),
                routine(id: "ai-2026-11-25-x", name: "Push", ex: [slot("0025", sets: 2, reps: 8, weight: 70)], cloneOf: "push", ephemeralDate: "2026-11-25"),
            ]),
            "dayPlan": .object(["2026-11-25": .string("ai-2026-11-25-x")]),
            "workouts": .array([]),
        ]
        state["active"] = .object(Session.begin(state, routineIds: ["ai-2026-11-25-x"], bodyweight: nil, id: "phone-1", now: startAt, day: "2026-11-25", catalog: .builtIn))
        let watchStart: Object = [
            "id": .string("ev1"),
            "type": .string("start"),
            "wid": .string("watch-9"),
            "routineIds": .array([.string("push")]),
            "at": .number(startAt + 30_000),
        ]
        _ = WatchLink.apply(watchStart, to: &state, today: "2026-11-25", now: startAt + 30_000, newId: "n", catalog: .builtIn)
        XCTAssertEqual(state["active"]?.object?["id"], .string("watch-9"))
    }

    // T5 (R4): RoutineOps.copyRoutine strips aiClone, cloneOf, and ephemeralDate.
    func testCopyRoutineStripsAICloneMarkers() {
        let clone = routine(
            id: "ai-2026-11-25-x",
            name: "Push",
            ex: [slot("0025", sets: 2, reps: 8)],
            cloneOf: "push",
            ephemeralDate: "2026-11-25"
        ).object!
        let copy = RoutineOps.copyRoutine(clone, newId: "user-copy-1")
        XCTAssertEqual(copy["id"], .string("user-copy-1"))
        XCTAssertEqual(copy["name"], .string("Push (Copy)"))
        XCTAssertNil(copy["aiClone"])
        XCTAssertNil(copy["cloneOf"])
        XCTAssertNil(copy["ephemeralDate"])
        XCTAssertFalse(RoutineOps.isAIClone(copy))
    }

    // T6 (R5): Orphan clone after concurrent delete of parent P on Device A + Accept clone on Device B.
    func testOrphanCloneAfterConcurrentDeleteAndAcceptMerge() throws {
        let base = try StateDocument(root: [
            "unit": .string("kg"),
            "workouts": .array([]),
            "routines": .array([
                routine(id: "P", name: "Push", ex: [slot("0025", sets: 4, reps: 8)]),
                routine(id: "Q", name: "Pull", ex: [slot("0027", sets: 3, reps: 10)]),
            ]),
            "week": .object(["3": .array([.string("P")])]),
            "dayPlan": .object([:]),
            "_ts": .number(1_000),
        ])

        var devA = base
        var devB = base

        // Device A deletes parent P (1d cascade).
        devA.change(at: 2_000) { s in
            RoutineOps.deleteRoutine(&s, id: "P")
        }
        // Device B concurrently accepts an aiClone of P pinned on 2026-11-25.
        devB.change(at: 2_500) { s in
            var rs = s["routines"]?.arrayValue ?? []
            rs.append(routine(id: "ai-2026-11-25-p", name: "Push", ex: [slot("0025", sets: 2, reps: 8)], cloneOf: "P", ephemeralDate: "2026-11-25"))
            s["routines"] = .array(rs)
            s["dayPlan"] = .object(["2026-11-25": .string("ai-2026-11-25-p")])
        }

        var merged = try HexMerge.merge(devA.root, devB.root, now: 3_000)
        // Parent P is gone; B's clone survived as an orphan.
        XCTAssertFalse((merged["routines"]?.arrayValue ?? []).contains { $0.object?["id"] == .string("P") })
        XCTAssertTrue((merged["routines"]?.arrayValue ?? []).contains { $0.object?["id"] == .string("ai-2026-11-25-p") })

        // Canonical and Session.begin treat the orphan as itself (never writing under deleted "P").
        XCTAssertEqual(Schedule.canonical(merged, "ai-2026-11-25-p"), "ai-2026-11-25-p")
        let session = Session.begin(merged, routineIds: ["ai-2026-11-25-p"], bodyweight: nil, id: "s1", now: 4_000, day: "2026-11-25", catalog: .builtIn)
        XCTAssertEqual(session["routineIds"], .array([.string("ai-2026-11-25-p")]))

        // GC retains orphan on its own day (2026-11-25) and prunes + clears dayPlan pin on 2026-11-26.
        RoutineOps.pruneExpiredClones(&merged, today: "2026-11-25")
        XCTAssertTrue((merged["routines"]?.arrayValue ?? []).contains { $0.object?["id"] == .string("ai-2026-11-25-p") })
        XCTAssertEqual(merged["dayPlan"]?.object?["2026-11-25"], .string("ai-2026-11-25-p"))

        RoutineOps.pruneExpiredClones(&merged, today: "2026-11-26")
        XCTAssertFalse((merged["routines"]?.arrayValue ?? []).contains { $0.object?["id"] == .string("ai-2026-11-25-p") })
        XCTAssertNil(merged["dayPlan"]?.object?["2026-11-25"])
    }

    // T8: Shared hand-written Swift/Python parity fixture.
    func testSharedCloneScheduleParityFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "clone-schedule-cases", withExtension: "json", subdirectory: "Fixtures"))
        let root = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).object)
        let cases = try XCTUnwrap(root["cases"]?.arrayValue?.compactMap(\.object))
        XCTAssertGreaterThanOrEqual(cases.count, 5)

        for c in cases {
            let name = c["name"]?.stringValue ?? ""
            let today = try XCTUnwrap(c["today"]?.stringValue, name)
            let state = try XCTUnwrap(c["state"]?.object, name)
            for (rawId, expectedCanonical) in c["canonical"]?.object ?? [:] {
                XCTAssertEqual(Schedule.canonical(state, rawId), expectedCanonical.stringValue, "\(name): canonical(\(rawId))")
            }
            for day in c["days"]?.arrayValue?.compactMap(\.object) ?? [] {
                let iso = try XCTUnwrap(day["iso"]?.stringValue, name)
                let want = (day["ids"]?.arrayValue ?? []).compactMap(\.stringValue)
                XCTAssertEqual(Schedule.routineIds(state, on: iso, today: today), want, "\(name): routineIds(\(iso))")
            }
        }
    }

    // 1c: Rotation queueView preview and sweepPins with aiClone pins.
    func testRotationQueueViewAndSweepPinsWithClone() throws {
        var state: Object = [
            "scheduleMode": .string("rotation"),
            "routines": .array([
                routine(id: "A", name: "Push", ex: [slot("0025", sets: 3, reps: 8)]),
                routine(id: "B", name: "Pull", ex: [slot("0027", sets: 3, reps: 10)]),
                routine(id: "ai-2026-11-26-a", name: "Push", ex: [slot("0025", sets: 2, reps: 8)], cloneOf: "A", ephemeralDate: "2026-11-26"),
            ]),
            "rotation": .object(["id": .string("rot1"), "sequence": .array([.string("A"), .string("B")])]),
            "queue": .object(["ids": .array([.string("A"), .string("B")]), "since": .number(1_000), "startsOn": .string("2026-11-25"), "rotationId": .string("rot1")]),
            "dayPlan": .object(["2026-11-26": .string("ai-2026-11-26-a")]),
            "workouts": .array([]),
        ]

        let view = try XCTUnwrap(Schedule.queueView(state, today: "2026-11-25"))
        XCTAssertEqual(view.items.first(where: { $0.id == "A" })?.state, "pinned")
        XCTAssertEqual(view.items.first(where: { $0.id == "A" })?.on, "2026-11-26")
        XCTAssertEqual(view.items.first(where: { $0.id == "B" })?.state, "next")

        // Stopping the pass sweeps aiClone pins for queued routines too.
        Schedule.stopPass(&state, today: "2026-11-25")
        XCTAssertNil(state["dayPlan"]?.object?["2026-11-26"])
    }

    // 1d: deleteRoutine cascade and pruneExpiredClones (30d + invalid/missing date).
    func testDeleteRoutineCascadeAndPruneExpiredClones() {
        var state: Object = [
            "routines": .array([
                routine(id: "push", name: "Push", ex: [slot("0025", sets: 3, reps: 8)]),
                routine(id: "pull", name: "Pull", ex: [slot("0027", sets: 3, reps: 10)]),
                routine(id: "ai-push-1", name: "Push", ex: [slot("0025", sets: 2, reps: 8)], cloneOf: "push", ephemeralDate: "2026-11-25"),
                routine(id: "ai-pull-old", name: "Pull", ex: [slot("0027", sets: 2, reps: 10)], cloneOf: "pull", ephemeralDate: "2026-10-01"),
                routine(id: "ai-pull-pinned-old", name: "Pull", ex: [slot("0027", sets: 2, reps: 10)], cloneOf: "pull", ephemeralDate: "2026-10-01"),
                routine(id: "ai-pull-pinned-future", name: "Pull", ex: [slot("0027", sets: 2, reps: 10)], cloneOf: "pull", ephemeralDate: "2026-10-01"),
                routine(id: "ai-pull-recent", name: "Pull", ex: [slot("0027", sets: 2, reps: 10)], cloneOf: "pull", ephemeralDate: "2026-11-20"),
                routine(id: "ai-pull-bad-date", name: "Pull", ex: [slot("0027", sets: 2, reps: 10)], cloneOf: "pull", ephemeralDate: "not-a-date"),
            ]),
            "week": .object(["1": .array([.string("push")])]),
            "dayPlan": .object([
                "2026-11-25": .string("ai-push-1"),
                "2026-10-01": .string("ai-pull-pinned-old"),
                "2026-11-30": .string("ai-pull-pinned-future"),
            ]),
            "workouts": .array([]),
        ]

        RoutineOps.deleteRoutine(&state, id: "push")
        let afterDelete = Set((state["routines"]?.arrayValue ?? []).compactMap { $0.object?["id"]?.stringValue })
        XCTAssertFalse(afterDelete.contains("push"))
        XCTAssertFalse(afterDelete.contains("ai-push-1"))
        XCTAssertNil(state["dayPlan"]?.object?["2026-11-25"])

        RoutineOps.pruneExpiredClones(&state, today: "2026-11-25")
        let afterPrune = Set((state["routines"]?.arrayValue ?? []).compactMap { $0.object?["id"]?.stringValue })
        XCTAssertFalse(afterPrune.contains("ai-pull-old"))
        XCTAssertFalse(afterPrune.contains("ai-pull-bad-date"))
        // Past dayPlan pin does not keep an expired (>30d) clone alive; both clone and pin are cleaned up.
        XCTAssertFalse(afterPrune.contains("ai-pull-pinned-old"))
        XCTAssertNil(state["dayPlan"]?.object?["2026-10-01"])
        // Future dayPlan pin (iso >= today) keeps the clone alive even if its ephemeralDate is old.
        XCTAssertTrue(afterPrune.contains("ai-pull-pinned-future"))
        XCTAssertEqual(state["dayPlan"]?.object?["2026-11-30"], .string("ai-pull-pinned-future"))
        XCTAssertTrue(afterPrune.contains("ai-pull-recent"))     // within 30d window
    }

    func testWidgetDataMarksFinishedCloneDayDone() throws {
        let state: Object = [
            "unit": .string("kg"),
            "routines": .array([
                routine(id: "push", name: "Push", ex: [slot("0025", sets: 3, reps: 8)]),
                routine(id: "ai-2026-11-25-p", name: "Push", ex: [slot("0025", sets: 2, reps: 8)], cloneOf: "push", ephemeralDate: "2026-11-25"),
            ]),
            "week": .object(["3": .array([.string("push")])]),
            "dayPlan": .object(["2026-11-25": .string("ai-2026-11-25-p")]),
            "workouts": .array([
                .object([
                    "id": .string("w1"),
                    "d": .string("2026-11-25"),
                    "start": .number(1_795_500_000_000),
                    "end": .number(1_795_503_600_000),
                    "routineIds": .array([.string("push")]),
                    "routineId": .string("push"),
                    "name": .string("Push"),
                    "entries": .array([]),
                ]),
            ]),
        ]
        let doc = try StateDocument(root: state)
        let snap = WidgetData.snapshot(state, history: History(document: doc), today: "2026-11-25", catalog: .builtIn)
        let todayEntry = try XCTUnwrap(snap["days"]?.arrayValue?.first?.object)
        XCTAssertEqual(todayEntry["done"], .bool(true))
    }
}
