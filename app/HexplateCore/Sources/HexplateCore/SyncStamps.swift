import Foundation

/// Stamps a change the way the openGym store does (frontend/src/lib/sync-merge.js stampChange),
/// so a document Hexplate wrote merges on a server exactly like one the Capacitor app wrote:
/// every routine, setting, plan day and removal the change touched gets one time that comes after
/// every stamp the previous copy carried. SyncStampGoldenTests holds this to the JavaScript.
public enum SyncStamps {
    typealias Object = [String: JSONValue]

    /// Stamps what differs between `prev` and `next` into `next`; returns the time used, which
    /// the caller sets as the document's `_ts`.
    public static func stampChange(prev: [String: JSONValue], next: inout [String: JSONValue], wall: Double) -> Double {
        let now = max(wall, highestStamp(prev) + 1)

        // Workouts a screen re-stamped: an edit takes the change's time, a save that changed
        // nothing keeps the stamp it had.
        if var workouts = next["workouts"]?.arrayValue {
            let before = byId(prev["workouts"])
            for i in workouts.indices {
                guard var w = workouts[i].object, let id = w["id"], id != .null, let ts = w["_ts"], ts != .null,
                      let old = before[key(id)], old["_ts"] != ts else { continue }
                if sameEntry(old, w) {
                    if let was = old["_ts"], was != .null { w["_ts"] = was } else { w["_ts"] = nil }
                } else {
                    stampEntry(old: old, &w, now)
                }
                workouts[i] = .object(w)
            }
            next["workouts"] = .array(workouts)
        }

        // Settings maps whose entries carry their own stamp.
        for f in stampedMaps {
            guard var n = next[f]?.object else { continue }
            let p = prev[f]?.object ?? [:]
            for (k, v) in n {
                guard var entry = v.object, let ts = entry["_ts"], ts != .null, stamp(of: v) != stamp(of: p[k]) else { continue }
                entry["_ts"] = .number(now)
                n[k] = .object(entry)
            }
            next[f] = .object(n)
        }

        // A weigh-in or check-in the change logged or corrected (its `t` moved).
        for f in ["bodyweight", "measurements"] {
            guard var entries = next[f]?.arrayValue else { continue }
            var before: [String: Object] = [:]
            for e in prev[f]?.arrayValue ?? [] {
                if let o = e.object, let d = o["d"], d != .null { before[key(d)] = o }
            }
            for i in entries.indices {
                guard var e = entries[i].object, let d = e["d"], d != .null, let t = e["t"], t != .null else { continue }
                let old = before[key(d)]
                if let old, old["t"] == t { continue }
                let was = t.num
                let at = max(was, now)
                e["t"] = .number(at)
                if f == "bodyweight", var ins = e["ins"]?.arrayValue, at != was {
                    var prior: [String: Object] = [:]
                    for r in old?["ins"]?.arrayValue ?? [] {
                        if let o = r.object, let id = o["id"], id != .null { prior[key(id)] = o }
                    }
                    for j in ins.indices {
                        guard var r = ins[j].object else { continue }
                        let p = r["id"].flatMap { prior[key($0)] }
                        if p == nil || p?["t"] != r["t"] || p?["w"] != r["w"] || p?["at"] != r["at"] {
                            r["t"] = .number(at)
                            ins[j] = .object(r)
                        }
                    }
                    e["ins"] = .array(ins)
                    if var gone = e["gone"]?.object {
                        let oldGone = old?["gone"]?.object ?? [:]
                        for (k, v) in gone where v.num != (oldGone[k]?.num ?? .nan) { gone[k] = .number(at) }
                        e["gone"] = .object(gone)
                    }
                }
                entries[i] = .object(e)
            }
            next[f] = .array(entries)
        }

        // A routine put back by an Undo keeps the edit time it had.
        let gone = prev["deleted"]?.object?["routines"]?.object ?? [:]
        let prevRoutineIds = Set((prev["routines"]?.arrayValue ?? []).compactMap { $0.object?["id"] }.map(key))
        let putBack = { (r: Object) -> Bool in
            guard let id = r["id"] else { return false }
            let removed = gone[key(id)]?.num ?? 0
            let ts = r["_ts"]?.num ?? 0
            return removed > 0 && (!(ts > 0) || ts < removed) && !prevRoutineIds.contains(key(id))
        }
        stampEntries("routines", prev, &next, now, skip: putBack)
        for f in ["customEx", "equipProfiles", "gymCards"] { stampEntries(f, prev, &next, now) }
        stampDeletions(prev, &next, now)
        stampEdits(prev, &next, now)
        return now
    }

    // MARK: Entries

    private static let entryMeta: Set<String> = ["id", "_ts", "_f", "_u"]
    static let stampedMaps = ["balanceOverrides", "loadKind", "plates", "dbLoad", "dumbbells", "stackWeights", "exUnit", "dayNotes", "dayPhotos", "exMerged"]

    private static func sameEntry(_ a: Object, _ b: Object) -> Bool {
        a.filter { !["_ts", "_f", "_u"].contains($0.key) } == b.filter { !["_ts", "_f", "_u"].contains($0.key) }
    }

    /// `x` as edited at `now`: its `_ts`, and in `_f` every field that differs from `old`.
    private static func stampEntry(old: Object?, _ x: inout Object, _ now: Double) {
        x["_ts"] = .number(now)
        guard let old else { return }
        var f = old["_f"]?.object ?? [:]
        for k in Set(old.keys).union(x.keys) where !entryMeta.contains(k) && old[k] != x[k] {
            f[k] = .number(now)
        }
        x["_f"] = f.isEmpty ? nil : .object(f)
        x["_u"] = settleMarks(x["_u"], stamps: f, now).map(JSONValue.object)
    }

    /// Stamps every entry of `next[field]` that is new or differs from its version in `prev`.
    private static func stampEntries(_ field: String, _ prev: Object, _ next: inout Object, _ now: Double, skip: (Object) -> Bool = { _ in false }) {
        guard var entries = next[field]?.arrayValue else { return }
        let before = byId(prev[field])
        for i in entries.indices {
            guard var x = entries[i].object, let id = x["id"], id != .null else { continue }
            let old = before[key(id)]
            if old == nil && skip(x) { continue }
            if let old, sameEntry(old, x) { continue }
            stampEntry(old: old, &x, now)
            entries[i] = .object(x)
        }
        next[field] = .array(entries)
    }

    /// Undo markers brought up to date after a change stamped `now` (settleMarks).
    private static func settleMarks(_ marks: JSONValue?, stamps: Object, _ now: Double) -> Object? {
        guard let marks = marks?.object else { return nil }
        var out: Object = [:]
        for (k, m) in marks {
            guard let m = m.arrayValue else { continue }
            let at = stamps[k]?.num ?? 0
            if m.count == 2 && at == now { out[k] = .array([.number(m[0].num), .number(m[1].num), .number(now)]) }
            else if m.count == 3 && at > 0 && m[2].num == at { out[k] = .array(m) }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: Removals

    private static let deletionLists = ["workouts", "routines", "customEx", "bodyweight", "measurements", "gymCards", "equipProfiles", "favEx"]
    static let deletedMax = 5000

    private static func deletionKey(_ field: String, _ x: JSONValue) -> String {
        switch field {
        case "favEx": return key(x)
        case "bodyweight", "measurements": return x.object?["d"].map(key) ?? "undefined"
        case "workouts":
            if let id = x.object?["id"], id != .null { return key(id) }
            let part = { (k: String) in x.object?[k].map(key) ?? "undefined" }
            return "\(part("d"))|\(part("start"))"
        default: return x.object?["id"].map(key) ?? "undefined"
        }
    }

    /// When an entry was last edited, to hold against a removal.
    private static func deletionTime(_ field: String, _ x: JSONValue) -> Double {
        let o = x.object ?? [:]
        let n = { (k: String) in o[k]?.num ?? 0 }
        switch field {
        case "workouts": return [n("_ts"), n("end"), n("start")].first { $0 != 0 } ?? 0
        case "bodyweight", "measurements": return n("t")
        case "favEx": return 0
        default: return n("_ts")
        }
    }

    /// Records every entry `prev` had and `next` no longer has, and marks as added back (`-now`)
    /// any entry `next` brought in again whose removal was on record.
    private static func stampDeletions(_ prev: Object, _ next: inout Object, _ now: Double) {
        var del = next["deleted"]?.object ?? [:]
        var touched = false
        for f in deletionLists {
            let before = (prev[f]?.arrayValue ?? []).filter { $0 != .null }
            let after = (next[f]?.arrayValue ?? []).filter { $0 != .null }
            let have = Set(after.map { deletionKey(f, $0) })
            let had = Set(before.map { deletionKey(f, $0) })
            var m = del[f]?.object ?? [:]
            var changed = false
            for x in before where !have.contains(deletionKey(f, x)) {
                m[deletionKey(f, x)] = .number(max(now, deletionTime(f, x) + 1))
                changed = true
            }
            for k in have.subtracting(had) {
                if let recorded = m[k] { if recorded.num > 0 { m[k] = .number(-now); changed = true } }
                else if f == "favEx" { m[k] = .number(-now); changed = true }
            }
            if changed {
                if m.count > deletedMax {
                    for k in m.keys.sorted(by: { abs(m[$0]!.num) < abs(m[$1]!.num) }).prefix(m.count - deletedMax) { m[k] = nil }
                }
                del[f] = .object(m)
                touched = true
            }
        }
        if touched { next["deleted"] = .object(del) }
    }

    // MARK: Settings and plan days

    private static let ownMerge: Set<String> = [
        "_ts", "_rev", "_wid", "_wids", "_unstamped", "_prior", "active", "unit", "unitSet", "resetAt", "resetIds", "deleted", "edited", "undone", "routineOrder",
        "workouts", "routines", "customEx", "equipProfiles", "gymCards", "bodyweight", "measurements", "favEx",
        "exWeights", "balanceOverrides", "loadKind", "plates", "dbLoad", "dumbbells", "stackWeights", "exUnit", "dayNotes", "dayPhotos", "exMerged",
        // Hexplate-only CRDT maps handled by HexStamps / HexMerge (never stamped into `edited`).
        "meals",
    ]
    private static let perKey: Set<String> = ["week", "dayPlan", "exNotes", "barWeights", "exAliases", "programmes", "modules"]
    private static let editKeepMs = 180.0 * 86_400_000

    /// Stamps in `next.edited` every setting (and every day of the plan, note, bar weight) that
    /// differs from `prev`.
    private static func stampEdits(_ prev: Object, _ next: inout Object, _ now: Double) {
        var ed = next["edited"]?.object ?? [:]
        var touched = false
        for k in Set(prev.keys).union(next.keys) where !ownMerge.contains(k) {
            let p = prev[k], n = next[k]
            if p == n { continue }
            if perKey.contains(k) {
                let pm = p?.object ?? [:], nm = n?.object ?? [:]
                for s in Set(pm.keys).union(nm.keys) where pm[s] != nm[s] {
                    ed["\(k).\(s)"] = .number(now)
                    touched = true
                }
            } else {
                ed[k] = .number(now)
                touched = true
            }
        }
        if orderMoved(prev["routines"], next["routines"]) {
            ed["routineOrder"] = .number(now)
            touched = true
        }
        // An own accent colour is one choice made in two fields: either one changed stamps both.
        if touched, next["accent"] == .string("custom"), ed["accent"] == .number(now) || ed["accentCustom"] == .number(now) {
            ed["accent"] = .number(now)
            ed["accentCustom"] = .number(now)
        }
        if touched {
            // A per-key stamp of a key no longer there is dropped after half a year.
            for (k, at) in ed {
                guard let dot = k.firstIndex(of: "."), now - at.num >= editKeepMs else { continue }
                let map = next[String(k[..<dot])]?.object
                if map?[String(k[k.index(after: dot)...])] == nil { ed[k] = nil }
            }
            next["edited"] = .object(ed)
        }
        if next["undone"] != nil {
            next["undone"] = settleMarks(next["undone"], stamps: ed, now).map(JSONValue.object)
        }
    }

    /// Whether two lists hold the routines both have in a different order.
    private static func orderMoved(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        let ids = { (v: JSONValue?) in (v?.arrayValue ?? []).compactMap { $0.object?["id"] }.filter { $0 != .null }.map(key) }
        let ida = ids(a), idb = ids(b)
        return ida.filter(Set(idb).contains) != idb.filter(Set(ida).contains)
    }

    // MARK: Helpers

    /// The latest stamp a copy carries: its `_ts`, every setting, removal and entry stamp.
    static func highestStamp(_ s: Object) -> Double {
        var m = 0.0
        func see(_ v: JSONValue?) { m = max(m, abs(v?.num ?? 0)) }
        see(s["_ts"])
        see(s["unitSet"]?.object?["at"])
        see(s["resetAt"])
        s["edited"]?.object?.values.forEach(see)
        s["deleted"]?.object?.values.forEach { $0.object?.values.forEach(see) }
        for f in ["workouts", "routines", "customEx", "equipProfiles", "gymCards"] {
            for x in s[f]?.arrayValue ?? [] {
                see(x.object?["_ts"])
                x.object?["_f"]?.object?.values.forEach(see)
            }
        }
        for f in stampedMaps { s[f]?.object?.values.forEach { see($0.object?["_ts"]) } }
        for f in ["bodyweight", "measurements"] { s[f]?.arrayValue?.forEach { see($0.object?["t"]) } }
        return m
    }

    private static func stamp(of v: JSONValue?) -> Double { v?.object?["_ts"]?.num ?? 0 }

    private static func byId(_ list: JSONValue?) -> [String: Object] {
        var out: [String: Object] = [:]
        for x in list?.arrayValue ?? [] {
            if let o = x.object, let id = o["id"], id != .null { out[key(id)] = o }
        }
        return out
    }

    /// An id or key as JavaScript's `String(x)` prints it.
    static func key(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .number(let n): return Format.plain(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        default: return "[object Object]"
        }
    }
}

extension JSONValue {
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }

    /// JavaScript's `Number(v) || 0`.
    var num: Double {
        switch self {
        case .number(let n): return n.isNaN ? 0 : n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
        case .bool(let b): return b ? 1 : 0
        default: return 0
        }
    }
}
