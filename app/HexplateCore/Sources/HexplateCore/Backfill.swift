import Foundation

/// Logging a workout after the fact (backfill.js): the ordinary live session with a `backfill`
/// field, built from the history before its day and filed where its date belongs.
public enum Backfill {
    public typealias Object = [String: JSONValue]

    public static let maxDurationMin = 24 * 60

    public static func isBackfill(_ active: Object?) -> Bool { active?["backfill"]?.object != nil }
    static func replaceId(_ a: Object) -> JSONValue? { a["backfill"]?.object?["replaceId"].flatMap { $0 == .null ? nil : $0 } }

    public static func workoutsOn(_ s: Object, _ iso: String) -> [Object] {
        (s["workouts"]?.arrayValue ?? []).compactMap(\.object).filter { $0["d"]?.stringValue == iso }
    }

    /// The history a session filed at `d`/`start` is built from: only what comes before it, without
    /// the workout it replaces, and confirmed weights not dated after its day (historyAsOf).
    public static func historyAsOf(_ s: Object, d: String, start: Double, replaceId: JSONValue? = nil, strict: Bool = false) -> Object {
        func before(_ w: Object) -> Bool {
            let wd = w["d"]?.stringValue ?? "", ws = w["start"]?.numberValue ?? 0
            return wd < d || (wd == d && (strict ? ws < start : ws <= start))
        }
        var out = s
        out["workouts"] = .array((s["workouts"]?.arrayValue ?? []).filter { v in
            guard let w = v.object else { return false }
            return before(w) && !(replaceId != nil && w["id"] == replaceId)
        })
        if let kept = s["exWeights"]?.object {
            out["exWeights"] = .object(kept.filter { _, v in
                guard let kd = v.object?["d"]?.stringValue, !kd.isEmpty else { return true }
                return kd <= d
            })
        }
        return out
    }

    /// Where a workout goes in the chronological list: after anything from the same moment.
    public static func insertionIndex(_ list: [JSONValue], _ w: Object) -> Int {
        let d = w["d"]?.stringValue ?? "", s = w["start"]?.numberValue ?? 0
        var i = list.count
        while i > 0 {
            let p = list[i - 1].object
            let pd = p?["d"]?.stringValue ?? "", ps = p?["start"]?.numberValue ?? 0
            if pd < d || (pd == d && ps <= s) { break }
            i -= 1
        }
        return i
    }

    /// The workouts once a backfilled one is filed, the one it replaces gone and that one's
    /// session note carried over (completeBackfill). `w` gets the carried note and a fresh stamp.
    public static func file(_ workouts: [JSONValue], _ active: Object, _ w: inout Object, now: Double) -> [JSONValue] {
        var list = workouts
        if let rid = replaceId(active) {
            if let replaced = list.first(where: { $0.object?["id"] == rid })?.object {
                WorkoutPhotos.merge(into: &w, from: replaced)
                let old = (replaced["note"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let fresh = (w["note"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !old.isEmpty && old != fresh {
                    w["note"] = .string(!fresh.isEmpty && !fresh.contains(old) ? "\(old)\n\(fresh)" : (fresh.isEmpty ? old : fresh))
                }
            }
            list.removeAll { $0.object?["id"] == rid }
        }
        list.insert(.object(w), at: insertionIndex(list, w))
        return list
    }

    /// A new session logged into the past, from the history before it (sheets.jsx beginBackfill).
    public static func begin(_ s: Object, iso: String, start: Double, durationMin: Int, routineIds: [String],
                             replaceId: String?, id: String, catalog c: ExerciseCatalog) -> Object {
        let past = historyAsOf(s, d: iso, start: start, replaceId: replaceId.map(JSONValue.string))
        var a = Session.begin(past, routineIds: routineIds, bodyweight: nil, id: id, now: start, day: iso, catalog: c)
        a["backfill"] = .object(["durationMin": .number(Double(durationMin)), "replaceId": replaceId.map(JSONValue.string) ?? .null])
        return a
    }

    /// A logged session ends when you said it did.
    public static func end(_ a: Object) -> Double {
        (a["start"]?.numberValue ?? 0) + max(1, a["backfill"]?.object?["durationMin"]?.numberValue ?? 60) * 60_000
    }

    /// Files a finished backfill into `s`: PR flags rebuilt for what it and the replaced workout
    /// trained, confirmed weights left alone (sheets.jsx doFinishWorkout, past branch).
    public static func finish(_ s: inout Object, now: Double, catalog c: ExerciseCatalog) -> Object? {
        guard let a = s["active"]?.object, isBackfill(a) else { return nil }
        var w = Session.completedWorkout(a, end: end(a), prs: [], catalog: c)
        w["_ts"] = .number(now)
        let workouts = s["workouts"]?.arrayValue ?? []
        let replaced = replaceId(a).flatMap { rid in workouts.first { $0.object?["id"] == rid }?.object }
        let touched = Set(((replaced?["entries"]?.arrayValue ?? []) + (w["entries"]?.arrayValue ?? [])).compactMap { $0.object?["id"]?.stringValue })
        let filed = file(workouts, a, &w, now: now)
        let at = filed.firstIndex { $0.object?["id"] == w["id"] }
        let list = WorkoutEdit.rebuildPrs(filed, touched, moved: at, c)
        s["workouts"] = .array(list)
        s["active"] = nil
        return at.flatMap { list[$0].object } ?? w
    }

    /// Every set ticked, both sides of a per-side set (markAllSetsDone).
    public static func markAllDone(_ entries: [JSONValue]) -> [JSONValue] {
        entries.map { e in
            guard var o = e.object else { return e }
            o["sets"] = .array((o["sets"]?.arrayValue ?? []).map { row in
                guard case .object(var r) = row else { return row }
                if Session.isSideSet(row), var sides = r["sides"]?.object {
                    for k in ["L", "R"] { if case .object(var one)? = sides[k] { one["done"] = .bool(true); sides[k] = .object(one) } }
                    r["sides"] = .object(sides)
                    return Session.syncSides(r)
                }
                r["done"] = .bool(true)
                return .object(r)
            })
            return .object(o)
        }
    }
}
