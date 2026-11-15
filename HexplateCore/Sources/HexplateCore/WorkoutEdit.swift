import Foundation

/// Editing a saved workout (lib/session-edit.js): a copy becomes the live session, Save puts it
/// back over the record and recomputes PR flags and remembered best weights.
public enum WorkoutEdit {
    public typealias Object = [String: JSONValue]

    public enum Failure: LocalizedError, Equatable {
        case busy, missing, gone, empty
        public var errorDescription: String? {
            switch self {
            case .busy: "Finish the current workout first."
            case .missing: "Workout deleted"
            case .gone: "This workout was deleted on another device. Your edits are still here."
            case .empty: "Nothing logged yet"
            }
        }
    }

    static let sessionFields = ["note", "name", "bw"]
    static func workouts(_ s: Object) -> [Object] { (s["workouts"]?.arrayValue ?? []).compactMap(\.object) }

    /// String(n) for a number, as JavaScript writes it.
    static func jsString(_ v: JSONValue) -> String {
        switch v {
        case .string(let t): t
        case .number(let x): x == x.rounded() && abs(x) < 1e15 ? String(Int64(x)) : String(x)
        case .null: "null"
        case .bool(let b): String(b)
        default: ""
        }
    }

    /// A workout's sync key: its id, or day and start for an old record without one.
    public static func key(_ w: Object) -> String {
        if let id = w["id"], id != .null { return jsString(id) }
        return "\(w["d"].map(jsString) ?? "undefined")|\(w["start"].map(jsString) ?? "undefined")"
    }

    static func sessionField(_ w: Object, _ k: String) -> JSONValue {
        if k == "note" { return .string((w["note"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) }
        return w[k] ?? .null
    }

    /// Opens the editor on a saved workout (editCompletedSession).
    public static func begin(_ s: inout Object, key k: String) throws {
        if let a = s["active"], a != .null { throw Failure.busy }
        guard let original = workouts(s).first(where: { key($0) == k }) else { throw Failure.missing }
        var active = original
        active["cur"] = .number(0)
        active["editingWorkoutId"] = original["id"] != nil && original["id"] != .null ? original["id"] : .string(k)
        active["editBase"] = .object(Dictionary(uniqueKeysWithValues: sessionFields.map { ($0, sessionField(original, $0)) }))
        if original["excludeFromProgression"] == .bool(true) {
            active["entries"] = .array((active["entries"]?.arrayValue ?? []).map { e in
                guard var o = e.object, o["noProg"] != .bool(true) else { return e }
                o["noProg"] = .bool(true)
                return .object(o)
            })
            active["noProg"] = .bool(true)
        }
        for k in ["vol", "prs", "_ts", "media"] { active[k] = nil }
        s["active"] = .object(active)
    }

    public static func isEditing(_ a: Object?) -> Bool { a?["editingWorkoutId"].map { $0 != .null } ?? false }
    static func editKey(_ a: Object) -> String? {
        guard let v = a["editingWorkoutId"], v != .null else { return nil }
        return jsString(v)
    }

    public static func leftEmpty(_ a: Object) -> Bool {
        !(a["entries"]?.arrayValue ?? []).contains { e in (e.object?["sets"]?.arrayValue ?? []).contains(where: Session.hasCompletedWork) }
    }

    static func savedData(_ w: Object) -> Object { w.filter { !["id", "vol", "prs", "_ts"].contains($0.key) } }

    /// The record the editor would save over `current` (draftRecord).
    static func draft(_ a: Object, _ current: Object, _ c: ExerciseCatalog) -> Object {
        var updated = Session.completedWorkout(a, end: current["end"]?.num ?? 0, prs: (current["prs"]?.arrayValue ?? []).compactMap(\.stringValue), catalog: c)
        updated["vol"] = nil
        let logged = (a["entries"]?.arrayValue ?? []).compactMap(\.object).filter { e in (e["sets"]?.arrayValue ?? []).contains(where: Session.hasCompletedWork) }
        updated["entries"] = .array((updated["entries"]?.arrayValue ?? []).enumerated().map { i, entry in
            let e = entry.object ?? [:]
            var merged = logged.indices.contains(i) ? logged[i] : [:]
            merged.merge(e) { _, b in b }
            merged["plan"] = nil; merged["carried"] = nil
            // The entry's own muscle snapshot stays (snapshotFor); other keys only as finishing writes them.
            let snapshot = logged.indices.contains(i) ? logged[i]["muscleSnapshot"]?.object : nil
            for k in ["note", "notePin", "noProg", "rid", "planned"] where e[k] == nil { merged[k] = nil }
            merged["muscleSnapshot"] = (snapshot?.isEmpty == false) ? .object(snapshot!) : nil
            return .object(merged)
        })
        var record = current
        record.merge(updated) { _, b in b }
        record["id"] = a["editingWorkoutId"]; record["d"] = current["d"]; record["start"] = current["start"]; record["end"] = current["end"]
        if updated["excludeFromProgression"] == nil { record["excludeFromProgression"] = nil }
        let base = a["editBase"]?.object
        for k in sessionFields {
            let edited = base == nil || sessionField(updated, k) != (base?[k] ?? .null)
            let value = edited ? sessionField(updated, k) : (current[k] ?? .null)
            record[k] = value == .null || value == .string("") ? nil : value
        }
        return record
    }

    static func beats(_ id: String, _ w: Double, _ prev: Double, _ c: ExerciseCatalog) -> Bool {
        w > 0 && (prev <= 0 || (c[id]?.isAssisted == true ? w < prev : w > prev))
    }

    static func best(in w: Object?, _ id: String, _ c: ExerciseCatalog) -> Double {
        var best = 0.0
        for e in (w?["entries"]?.arrayValue ?? []).compactMap(\.object) where e["id"]?.stringValue == id {
            let top = Session.bestWeight(e, c)
            if beats(id, top, best, c) { best = top }
        }
        return best
    }

    /// PR flags again for these exercises, in order; `moved` (an index) earns one afresh (rebuildPrHistory).
    public static func rebuildPrs(_ list: [JSONValue], _ ids: Set<String>, moved: Int?, _ c: ExerciseCatalog) -> [JSONValue] {
        guard !ids.isEmpty else { return list }
        var best: [String: Double] = [:]
        return list.enumerated().map { i, item in
            guard var w = item.object else { return item }
            let had = (w["prs"]?.arrayValue ?? []).compactMap(\.stringValue)
            var kept: [String] = [], trains = false
            for e in (w["entries"]?.arrayValue ?? []).compactMap(\.object) {
                guard let id = e["id"]?.stringValue, ids.contains(id) else { continue }
                trains = true
                let top = Session.bestWeight(e, c)
                let leads = beats(id, top, best[id] ?? 0, c)
                if leads { best[id] = top }
                if leads && (i == moved || had.contains(id)) { kept.append(id) }
            }
            guard trains else { return item }
            var prs: [String] = []
            for id in had.filter({ !ids.contains($0) }) + kept where !prs.contains(id) { prs.append(id) }
            if prs == had { return item }
            w["prs"] = .array(prs.map(JSONValue.string))
            return .object(w)
        }
    }

    /// A remembered best weight that came from the old record and no longer stands goes back to the
    /// best still in history (lowerKeptWeights).
    static func lowerKept(_ s: inout Object, _ ids: [String], _ current: Object, _ saved: Object?, _ c: ExerciseCatalog) {
        var kept = s["exWeights"]?.object ?? [:]
        for id in ids {
            guard let w = kept[id]?.object?["w"]?.num, w > 0 else { continue }
            let before = best(in: current, id, c)
            guard w == before, beats(id, before, best(in: saved, id, c), c) else { continue }
            var top: (w: Double, d: JSONValue)?
            for wk in workouts(s) {
                let b = best(in: wk, id, c)
                if beats(id, b, top?.w ?? 0, c) { top = (b, wk["d"] ?? .null) }
            }
            kept[id] = top.map { .object(["w": .number($0.w), "d": $0.d]) }
        }
        if s["exWeights"] != nil || !kept.isEmpty { s["exWeights"] = .object(kept) }
    }

    /// Saves the editor over the record and closes it (saveWorkoutEdit).
    @discardableResult
    public static func save(_ s: inout Object, now: Double, catalog c: ExerciseCatalog) throws -> Object {
        guard let a = s["active"]?.object, let k = editKey(a) else { throw Failure.gone }
        var list = s["workouts"]?.arrayValue ?? []
        guard let index = list.firstIndex(where: { $0.object.map(key) == k }), let current = list[index].object else { throw Failure.gone }
        if leftEmpty(a) { throw Failure.empty }
        var record = draft(a, current, c)
        if savedData(record) == savedData(current) {
            s["active"] = nil
            return current
        }
        record["vol"] = .number(Session.volume(record, c))
        // A new stamp marks the record as edited; the document turns it into the change's time.
        record["_ts"] = .number(now)
        list[index] = .object(record)
        var touched: [String] = []
        for e in (current["entries"]?.arrayValue ?? []) + (record["entries"]?.arrayValue ?? []) {
            if let id = e.object?["id"]?.stringValue, !touched.contains(id) { touched.append(id) }
        }
        list = rebuildPrs(list, Set(touched), moved: index, c)
        s["workouts"] = .array(list)
        let saved = list[index].object
        lowerKept(&s, touched, current, saved, c)
        s["active"] = nil
        return saved ?? record
    }

    /// Drops the edits; the record stays as it was.
    public static func discard(_ s: inout Object) { s["active"] = nil }
}
