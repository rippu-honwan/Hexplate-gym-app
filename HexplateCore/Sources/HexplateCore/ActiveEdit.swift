import Foundation

/// Changes to the live session's exercise list from an exercise's ⋯ menu: move, superset, swap,
/// remove, keep out of progression (active-workout-order.js, active-exercise-swap.js,
/// session-noprog.js, Workout.jsx removeActiveExercise). Each mutates `S.active`.
public enum ActiveEdit {
    public typealias Object = [String: JSONValue]

    static func entries(_ a: Object) -> [JSONValue] { a["entries"]?.arrayValue ?? [] }
    static func sg(_ e: JSONValue) -> String? { e.object?["sg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    static func cur(_ a: Object) -> Int { Int(a["cur"]?.num ?? 0) }

    /// Neighbouring entries that share a superset tag, as index lists (supersetUnits).
    public static func units(_ list: [JSONValue]) -> [[Int]] {
        var out: [[Int]] = []
        for i in list.indices {
            if i > 0, let tag = sg(list[i]), sg(list[i - 1]) == tag { out[out.count - 1].append(i) } else { out.append([i]) }
        }
        return out
    }

    // MARK: Order

    static func unitMove(_ a: Object, _ i: Int, _ d: Int) -> (units: [[Int]], source: Int, target: Int)? {
        guard d == 1 || d == -1 else { return nil }
        let u = units(entries(a))
        guard let source = u.firstIndex(where: { $0.contains(i) }), u.indices.contains(source + d) else { return nil }
        return (u, source, source + d)
    }

    /// Inside a superset an exercise swaps with its partner; otherwise its whole unit moves.
    static func memberSwap(_ a: Object, _ i: Int, _ d: Int) -> (unit: [Int], target: Int)? {
        guard d == 1 || d == -1, let unit = units(entries(a)).first(where: { $0.contains(i) }), unit.count > 1, unit.contains(i + d) else { return nil }
        return (unit, i + d)
    }

    static func crossesMarker(_ a: Object, _ unit: [Int], _ i: Int, _ target: Int) -> Bool {
        let c = cur(a)
        return unit.contains(c) && min(i, target) < c && max(i, target) >= c
    }

    public static func canMove(_ a: Object, _ i: Int, _ d: Int) -> Bool {
        if let s = memberSwap(a, i, d) { return !crossesMarker(a, s.unit, i, s.target) }
        return unitMove(a, i, d) != nil
    }

    public static func move(_ a: inout Object, _ i: Int, _ d: Int) {
        let list = entries(a)
        if let s = memberSwap(a, i, d) {
            guard !crossesMarker(a, s.unit, i, s.target) else { return }
            var next = list
            next.swapAt(i, s.target)
            a["entries"] = .array(next)
            return
        }
        guard var m = unitMove(a, i, d) else { return }
        m.units.swapAt(m.source, m.target)
        let order = m.units.flatMap { $0 }
        a["entries"] = .array(order.map { list[$0] })
        a["cur"] = .number(Double(order.firstIndex(of: i) ?? 0))
    }

    // MARK: Supersets

    public static func pair(_ a: inout Object, _ first: Int, _ second: Int) {
        if let next = RoutineOps.pairAdjacent(entries(a), first, second) { a["entries"] = .array(next) }
    }

    public static func unpair(_ a: inout Object, _ i: Int) {
        if let next = RoutineOps.unpairSuperset(entries(a), i) { a["entries"] = .array(next) }
    }

    // MARK: Remove, swap, progression

    public static func remove(_ a: inout Object, _ i: Int) {
        var list = entries(a)
        guard list.indices.contains(i) else { return }
        list.remove(at: i)
        RoutineOps.cleanupSupersets(&list)
        a["entries"] = .array(list)
        var c = cur(a)
        if i < c { c -= 1 }
        if c >= list.count { c = max(0, list.count - 1) }
        a["cur"] = .number(Double(c))
    }

    public static func hasLoggedSet(_ e: Object) -> Bool { (e["sets"]?.arrayValue ?? []).contains { $0.object?["done"] == .bool(true) } }

    /// Puts `replacement` in place of entry `i`. With sets logged the original stays and the
    /// replacement goes after it: next to it inside its superset (`keepGroup`), else after the
    /// superset (swapActiveExercise).
    public static func swap(_ a: inout Object, _ i: Int, with replacement: Object, keepGroup: Bool = false) {
        var list = entries(a)
        guard list.indices.contains(i), let current = list[i].object else { return }
        if !hasLoggedSet(current) {
            var next = current.filter { !["id", "target", "plan", "planned", "carried", "sets", "sg"].contains($0.key) }
            next.merge(replacement) { _, b in b }
            if let tag = sg(list[i]) { next["sg"] = .string(tag) }
            list[i] = .object(next)
            a["entries"] = .array(list)
            a["cur"] = .number(Double(i))
            return
        }
        let keep = keepGroup && sg(list[i]) != nil
        let unit = units(list).first { $0.contains(i) } ?? [i]
        let at = keep ? i + 1 : (unit.count > 1 ? unit.last! + 1 : i + 1)
        var entry = replacement
        if let rid = current["rid"] { entry["rid"] = rid }
        if keep { entry["sg"] = list[i].object?["sg"] }
        list.insert(.object(entry), at: at)
        a["entries"] = .array(list)
        a["cur"] = .number(Double(at))
    }

    /// One exercise kept out of progression or counted again; counting one again means the
    /// session as a whole is no longer out (setEntryNoProg).
    public static func setNoProg(_ a: inout Object, _ i: Int, _ on: Bool) {
        var list = entries(a)
        guard list.indices.contains(i), var e = list[i].object else { return }
        e["noProg"] = on ? .bool(true) : nil
        list[i] = .object(e)
        a["entries"] = .array(list)
        if !on { a["noProg"] = nil }
    }
}
