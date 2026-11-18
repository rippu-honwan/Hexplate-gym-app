import Foundation

/// What the running workout's Live Activity shows (lib/live-activity.js buildLiveActivity's
/// `state`): the set to do now, the few after it, the first open set of the next exercises, the
/// rest and hold clocks, and how far along the session is. The app wraps it in
/// WorkoutActivityAttributes (Widgets/WorkoutActivity.swift).
///
/// ponytail: no paused clocks (the native timer cannot pause), no auto-hold chain, no
/// per-exercise weight units; the 4 KB trim counts the state only.
public enum LiveActivity {
    public typealias Object = [String: JSONValue]

    /// A clock running until `endsAt` (ms since 1970), `total` seconds long.
    public struct Clock: Sendable {
        public var endsAt: Double
        public var total: Double
        public init(endsAt: Double, total: Double) { self.endsAt = endsAt; self.total = total }
    }

    static let ahead = 8
    static let unitCount = 4
    static let budget = 3000

    struct Pick { let entryIdx: Int, setIdx: Int, restAfter: Double, unit: Int }

    static func n(_ v: JSONValue?) -> Double? { if case .number(let x)? = v, x.isFinite { return x }; return nil }
    static func sets(_ e: JSONValue?) -> [JSONValue] { e?.object?["sets"]?.arrayValue ?? [] }

    /// supersetFlow.js restSecFor without a set's own rest.
    static func restSec(_ entries: [JSONValue], _ unit: [Int], _ fallback: Double) -> Double {
        let fallback = max(0, fallback)
        if unit.count > 1, let r = unit.lazy.compactMap({ n(entries[$0].object?["target"]?.object?["sgRest"]) }).first(where: { $0 > 0 }) {
            return Session.jsRound(r)
        }
        return unit.reduce(0) { max($0, ActiveEdit.exerciseRest(entries[$1].object?["target"]?.object) ?? fallback) }
    }

    /// The sets still to do, in the order the workout screen leads through them (upcomingSets).
    static func upcoming(_ s: Object) -> [Pick] {
        guard let a = s["active"]?.object, let entries = a["entries"]?.arrayValue, !entries.isEmpty else { return [] }
        let units = ActiveEdit.units(entries)
        let cur = max(0, min(entries.count - 1, Int(n(a["cur"]) ?? 0)))
        let start = max(0, units.firstIndex { $0.contains(cur) } ?? 0)
        var out: [Pick] = []
        for unit in units[start...] + units[..<start] {
            let rounds = unit.map { sets(entries[$0]).count }.max() ?? 0
            let rest = restSec(entries, unit, n(s["restSec"]) ?? 0)
            for r in 0..<rounds {
                let open = unit.filter { i in sets(entries[i]).indices.contains(r) && !Session.truthy(sets(entries[i])[r].object?["done"]) }
                for (k, i) in open.enumerated() {
                    out.append(Pick(entryIdx: i, setIdx: r, restAfter: k == open.count - 1 ? rest : 0, unit: unit[0]))
                }
            }
        }
        return out
    }

    /// "Warm-up 2" / "Set 1 of 3": (warm-up, number, work sets). The app passes its own language.
    public typealias SetLine = @Sendable (Bool, Int, Int) -> String
    public static let english: SetLine = { warm, n, of in warm ? "Warm-up \(n)" : "Set \(n) of \(of)" }

    static func view(_ s: Object, _ entries: [JSONValue], _ p: Pick, _ c: ExerciseCatalog, _ settings: ProfileSettings, _ line: SetLine = english) -> JSONValue {
        let e = entries[p.entryIdx].object ?? [:]
        let id = e["id"]?.stringValue ?? ""
        let rows = sets(entries[p.entryIdx])
        let row = rows[p.setIdx]
        let target = e["target"]?.object ?? [:]
        let warm = Session.isWarmup(row)
        let work = rows.filter { !Session.isWarmup($0) }.count
        let nth = rows[..<p.setIdx].filter { Session.isWarmup($0) == warm }.count + 1
        let t = try? JSONValue.object(target).decoded(as: Target.self)
        let label = (try? row.decoded(as: WorkoutSet.self)).map { SetLabel.text(exerciseId: id, set: $0, target: t, catalog: c, settings: settings) } ?? ""
        let nonEmpty = { (v: JSONValue?) in v?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        return .object([
            "exId": .string(id), "entryIdx": .number(Double(p.entryIdx)), "setIdx": .number(Double(p.setIdx)),
            "exName": .string(c[id]?.displayName ?? nonEmpty(target["name"]) ?? nonEmpty(e["name"]) ?? id),
            "setLine": .string(line(warm, nth, work)),
            "target": .string(label),
            "restAfter": .number(max(0, Session.jsRound(p.restAfter))),
            "unit": .number(Double(p.unit)),
        ])
    }

    /// The activity's state, or nil when no workout runs (or a saved one is being edited).
    public static func state(_ s: Object, rest: Clock?, hold: Clock?, catalog c: ExerciseCatalog, setLine line: @escaping SetLine = english) -> Object? {
        guard let a = s["active"]?.object, let entries = a["entries"]?.arrayValue, !entries.isEmpty,
              a["editingWorkoutId"] == nil || a["editingWorkoutId"] == .null else { return nil }
        let settings = ProfileSettings(s)
        let next = upcoming(s)
        let all = entries.flatMap(sets)
        var starts: [Pick] = []
        for x in next where x.unit != next[0].unit && !starts.contains(where: { $0.unit == x.unit }) {
            if starts.count >= unitCount { break }
            starts.append(x)
        }
        let views = { (ps: ArraySlice<Pick>) in ps.map { view(s, entries, $0, c, settings, line) } }
        var ahead = views(next.dropFirst().prefix(Self.ahead))
        var unitStarts = views(starts[...])
        func out() -> Object {
            [
                "name": .string(a["name"]?.stringValue ?? ""),
                "cur": next.first.map { view(s, entries, $0, c, settings, line) } ?? .null,
                "ahead": .array(ahead), "unitStarts": .array(unitStarts),
                "restEndsAt": rest.map { .number($0.endsAt) } ?? .null, "restLeft": .null, "restTotal": rest.map { .number($0.total) } ?? .null,
                "holdEndsAt": hold.map { .number($0.endsAt) } ?? .null, "holdLeft": .null, "holdTotal": hold.map { .number($0.total) } ?? .null,
                "holdKind": hold == nil ? .null : .string("hold"), "auto": .bool(false),
                "done": .number(Double(all.filter { Session.truthy($0.object?["done"]) }.count)), "total": .number(Double(all.count)),
            ]
        }
        // ActivityKit drops an update over 4 KB: the farthest sets go first (fitLive).
        while (try? JSONEncoder().encode(JSONValue.object(out())).count) ?? 0 > budget, !ahead.isEmpty || !unitStarts.isEmpty {
            if ahead.count > unitStarts.count { ahead.removeLast() } else { unitStarts.removeLast() }
        }
        return out()
    }

    /// Where Next exercise from `from` goes: the first entry of the next unit with sets open, or nil
    /// when the session already moved off that unit or nothing else is open (nextExerciseTarget).
    public static func nextExerciseTarget(_ a: Object?, from: Int) -> Int? {
        guard let entries = a?["entries"]?.arrayValue else { return nil }
        let units = ActiveEdit.units(entries)
        guard let i = units.firstIndex(where: { $0.contains(from) }), units[i].contains(Int(n(a?["cur"]) ?? 0)) else { return nil }
        let open = { (u: [Int]) in u.contains { sets(entries[$0]).contains { !Session.truthy($0.object?["done"]) } } }
        return (units[(i + 1)...] + units[..<i]).first(where: open)?.first
    }

    /// MyGym: the set the phone's "Start set on the watch" offers: the next open set, when the
    /// watch records that exercise's motion (reps, not legs; WatchStartBar.jsx nextWatchSet).
    public static func watchSet(_ s: Object, catalog c: ExerciseCatalog, setLine line: @escaping SetLine = english) -> Object? {
        guard let entries = s["active"]?.object?["entries"]?.arrayValue, let p = upcoming(s).first else { return nil }
        let id = entries[p.entryIdx].object?["id"]?.stringValue ?? ""
        var cfg = entries[p.entryIdx].object?["target"]?.object ?? [:]
        cfg["id"] = .string(id)
        guard Session.mode(cfg, c) == "reps", !["upper legs", "lower legs"].contains(c[id]?.bodyPart ?? "") else { return nil }
        return view(s, entries, p, c, ProfileSettings(s), line).object
    }

    /// MyGym: the exercises the Start set bar can switch to: each with an open set the watch
    /// records (reps, not legs), as (entry index, name).
    public static func watchChoices(_ s: Object, catalog c: ExerciseCatalog) -> [(entry: Int, name: String)] {
        let entries = s["active"]?.object?["entries"]?.arrayValue ?? []
        return entries.indices.compactMap { i in
            guard let e = entries[i].object, let id = e["id"]?.stringValue,
                  sets(entries[i]).contains(where: { !Session.truthy($0.object?["done"]) }) else { return nil }
            var cfg = e["target"]?.object ?? [:]
            cfg["id"] = .string(id)
            guard Session.mode(cfg, c) == "reps", !["upper legs", "lower legs"].contains(c[id]?.bodyPart ?? "") else { return nil }
            return (i, c[id]?.displayName ?? cfg["name"]?.stringValue ?? id)
        }
    }
}
