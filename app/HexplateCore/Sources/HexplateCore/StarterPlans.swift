import Foundation

/// Ready-made plans for a new profile (starter.js): routines plus the weekdays they go on.
// ponytail: plans are loaded as written; fitting them to an equipment profile is not ported.
public enum StarterPlans {
    public typealias Object = [String: JSONValue]
    public struct Plan: Identifiable, Sendable {
        public let id, name, about: String
        let routines: [(key: String, name: String, glyph: String, ex: [(String, Int, Int)])]
        let schedule: [(day: Int, key: String)]
        public var days: Int { schedule.count }
    }

    public static let all: [Plan] = [
        Plan(id: "ppl", name: "Push / Pull / Legs", about: "Push, pull and legs each get their own day.", routines: [
            ("push", "Push Day", "barbell", [("0025", 4, 8), ("0047", 3, 10), ("0426", 3, 10), ("0334", 3, 12), ("0241", 3, 12), ("0251", 3, 10)]),
            ("pull", "Pull Day", "pullup", [("2330", 4, 10), ("0027", 4, 8), ("1323", 3, 10), ("0031", 3, 10), ("0313", 3, 12)]),
            ("legs", "Leg Day", "legs", [("0043", 4, 8), ("0085", 3, 10), ("0739", 3, 12), ("0585", 3, 12), ("0586", 3, 12), ("0605", 4, 15)]),
        ], schedule: [(1, "push"), (3, "pull"), (5, "legs")]),
        Plan(id: "upper-lower", name: "Upper / Lower", about: "Upper body twice, lower body twice.", routines: [
            ("upper-a", "Upper A", "barbell", [("0025", 3, 8), ("2330", 3, 10), ("0047", 2, 10), ("1323", 2, 10), ("0334", 2, 12), ("0241", 2, 12), ("0031", 2, 12)]),
            ("lower-a", "Lower A", "legs", [("0043", 3, 8), ("0085", 3, 8), ("0739", 2, 10), ("0586", 2, 12), ("0605", 3, 15)]),
            ("upper-b", "Upper B", "barbell", [("0047", 3, 8), ("0027", 3, 8), ("0426", 2, 10), ("2330", 2, 10), ("0334", 2, 12), ("0241", 2, 12), ("0313", 2, 12)]),
            ("lower-b", "Lower B", "legs", [("0739", 3, 10), ("0085", 2, 10), ("0585", 2, 12), ("0586", 3, 12), ("0605", 3, 15)]),
        ], schedule: [(1, "upper-a"), (2, "lower-a"), (4, "upper-b"), (5, "lower-b")]),
        Plan(id: "full-body", name: "Full Body", about: "Three sessions, the whole body each time.", routines: [
            ("fb-a", "Full Body A", "figureStrength", [("0043", 3, 8), ("0025", 3, 8), ("2330", 3, 10), ("0586", 3, 12), ("0334", 2, 12), ("0031", 2, 12)]),
            ("fb-b", "Full Body B", "figureStrength", [("0085", 3, 8), ("0047", 3, 10), ("1323", 3, 10), ("0585", 3, 12), ("0334", 2, 12), ("0241", 2, 12)]),
            ("fb-c", "Full Body C", "figureStrength", [("0739", 3, 10), ("0025", 2, 10), ("0027", 3, 10), ("0426", 2, 10), ("0586", 3, 12), ("0605", 3, 15)]),
        ], schedule: [(1, "fb-a"), (3, "fb-b"), (5, "fb-c")]),
        Plan(id: "5x5", name: "5×5", about: "Five sets of five on the main barbell lifts.", routines: [
            ("5x5-a", "5×5 A", "barbell", [("0043", 5, 5), ("0025", 5, 5), ("0027", 5, 5)]),
            ("5x5-b", "5×5 B", "barbell", [("0085", 5, 5), ("0426", 5, 5), ("2330", 5, 5)]),
            ("5x5-c", "5×5 C", "barbell", [("0739", 5, 5), ("0047", 5, 5), ("1323", 5, 5)]),
        ], schedule: [(1, "5x5-a"), (3, "5x5-b"), (5, "5x5-c")]),
    ]

    /// Whether loading `plan` would change a weekday that already has a routine on it.
    public static func takesOverDays(_ s: Object, _ plan: Plan) -> Bool {
        let have = Set((s["routines"]?.arrayValue ?? []).compactMap { $0.object?["id"]?.stringValue })
        let week = s["week"]?.object ?? [:]
        return plan.schedule.contains { d in
            let v = week[String(d.day)]
            return (v?.arrayValue ?? (v.map { [$0] } ?? [])).contains { $0.stringValue.map(have.contains) ?? false }
        }
    }

    /// Adds the plan's routines (reusing one with the same name and lifts) and puts them on their
    /// weekdays (sheets.jsx loadStarterPlan).
    public static func load(_ s: inout Object, _ plan: Plan, newId: () -> String) {
        var routines = s["routines"]?.arrayValue ?? []
        var week = s["week"]?.object ?? [:]
        var idOf: [String: String] = [:]
        for r in plan.routines {
            let ex: [JSONValue] = r.ex.map { .object(["id": .string($0.0), "sets": .number(Double($0.1)), "reps": .number(Double($0.2)), "weight": .number(0)]) }
            let ids = r.ex.map(\.0)
            if let have = routines.compactMap(\.object).first(where: { o in
                o["name"]?.stringValue == r.name && (o["ex"]?.arrayValue ?? []).compactMap { $0.object?["id"]?.stringValue } == ids
            }), let id = have["id"]?.stringValue {
                idOf[r.key] = id
            } else {
                let id = newId()
                routines.append(.object(["id": .string(id), "name": .string(r.name), "emoji": .string(r.glyph), "ex": .array(ex)]))
                idOf[r.key] = id
            }
        }
        for d in plan.schedule { if let id = idOf[d.key] { week[String(d.day)] = .array([.string(id)]) } }
        s["routines"] = .array(routines)
        s["week"] = .object(week)
    }
}
