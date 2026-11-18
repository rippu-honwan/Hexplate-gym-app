import XCTest
@testable import HexplateCore

/// Holds Schedule to what the original JavaScript reads and does for the same plans
/// (queue.js, rotation.js, week-left.js, history.js). The golden file is written by
/// app/scripts/golden.sh; never edit it by hand.
final class ScheduleGoldenTests: XCTestCase {
    typealias Object = [String: JSONValue]
    struct Case: Decodable { let name: String; let state: JSONValue; let today: String; let now: Double; let ops: [[JSONValue]] }
    struct Golden: Decodable {
        struct Step: Decodable { let op: String?; let result: JSONValue?; let plan: JSONValue?; let reads: JSONValue }
        let name: String
        let steps: [Step]
    }

    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }

    func strings(_ ids: [String]) -> JSONValue { .array(ids.map(JSONValue.string)) }

    /// Everything a screen reads of the schedule, in the golden file's shape.
    func reads(_ s: Object, _ today: String) -> JSONValue {
        let days = (0..<14).compactMap { Day.adding($0 - 3, to: today) }.map { iso in
            JSONValue.object(["iso": .string(iso), "ids": strings(Schedule.routineIds(s, on: iso, today: today))])
        }
        let next = Schedule.nextTrainingDay(s, after: today, today: today)
        let view = Schedule.queueView(s, today: today)
        let tally = Schedule.weekTally(s, today: today)
        let left = Schedule.workoutsLeft(s, today: today)
        return .object([
            "mode": .string(Schedule.scheduleMode(s)),
            "rotationIds": strings(Schedule.rotationIds(s)),
            "sequence": strings(Schedule.sequence(s)),
            "recovery": .bool(Schedule.queueRecovery(s)),
            "days": .array(days),
            "next": next.map { .object(["iso": .string($0.iso), "ids": strings($0.routineIds)]) } ?? .null,
            "view": view.map { v in
                .object([
                    "label": .string(v.label),
                    "items": .array(v.items.map { item in
                        var o: Object = ["id": .string(item.id), "name": .string(item.name), "state": .string(item.state)]
                        o["on"] = item.on.map(JSONValue.string)
                        return .object(o)
                    }),
                    "remaining": strings(v.remaining), "complete": .bool(v.complete),
                    "startsOn": .string(v.startsOn), "waiting": .bool(v.waiting),
                ])
            } ?? .null,
            "done": strings(Schedule.queueDone(s)),
            "tally": .object(["done": .number(Double(tally.done)), "planned": .number(Double(tally.planned))]),
            "left": left.map { .object(["left": .number(Double($0.left)), "of": .number(Double($0.of)), "done": .number(Double($0.done))]) } ?? .null,
        ])
    }

    func plan(_ s: Object) -> JSONValue {
        .object(["scheduleMode": s["scheduleMode"] ?? .null, "rotation": s["rotation"] ?? .null, "queue": s["queue"] ?? .null, "dayPlan": s["dayPlan"] ?? .object([:])])
    }

    func diff(_ a: JSONValue, _ b: JSONValue, _ at: String) {
        guard a != b else { return }
        if let x = a.object, let y = b.object {
            for k in Set(x.keys).union(y.keys).sorted() where x[k] != y[k] {
                XCTFail("\(at) \(k)\n  swift \(text(x[k]))\n  js    \(text(y[k]))")
            }
        } else {
            XCTFail("\(at)\n  swift \(text(a))\n  js    \(text(b))")
        }
    }
    func text(_ v: JSONValue?) -> String { v.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? "absent" }

    func testMatchesTheJavaScript() throws {
        let cases = try JSONDecoder().decode([Case].self, from: try fixture("schedule-cases"))
        let golden = try JSONDecoder().decode([Golden].self, from: try fixture("schedule-golden"))
        XCTAssertEqual(cases.map(\.name), golden.map(\.name))
        XCTAssertGreaterThan(cases.count, 30)

        for (c, g) in zip(cases, golden) {
            var s = try XCTUnwrap(c.state.object)
            diff(reads(s, c.today), g.steps[0].reads, "\(c.name): reads")
            for (op, step) in zip(c.ops, g.steps.dropFirst()) {
                let name = try XCTUnwrap(op.first?.stringValue)
                let at = "\(c.name): \(name)"
                var result: JSONValue = .null
                switch name {
                case "chooseRotation": result = .bool(Schedule.chooseRotation(&s, today: c.today, now: c.now))
                case "chooseFixedWeek": Schedule.chooseFixedWeek(&s, today: c.today)
                case "startPass": result = .bool(Schedule.startPass(&s, today: c.today, now: c.now))
                case "stopPass": Schedule.stopPass(&s, today: c.today)
                case "startNewPass": Schedule.startNewPass(&s, today: c.today, now: c.now)
                case "refillIfComplete": result = .bool(Schedule.refillIfComplete(&s, today: c.today, now: c.now))
                case "refillAfter":
                    let w = try XCTUnwrap(Schedule.workouts(s).first { $0["id"] == op[1] })
                    result = .bool(Schedule.refillAfter(&s, workout: w, today: c.today, now: c.now))
                case "saveRotation":
                    // A new loop's id is random in the JavaScript: take the one it made.
                    let made = step.plan?.object?["rotation"]?.object?["id"]?.stringValue ?? "none"
                    Schedule.saveRotation(&s, ids: Schedule.strings(op[1]), label: op[2].stringValue, today: c.today, now: c.now, newId: { made })
                default: XCTFail("unknown op \(name)")
                }
                diff(result, step.result ?? .null, "\(at): result")
                diff(plan(s), try XCTUnwrap(step.plan), "\(at): plan")
                diff(reads(s, c.today), step.reads, "\(at): reads")
            }
        }
    }
}
