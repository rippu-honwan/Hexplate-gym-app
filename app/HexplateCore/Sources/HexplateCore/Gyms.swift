import Foundation

/// Equipment per gym (openGym lib/gym-inventory.js, #808). Each equipment profile in
/// `equipProfiles` is a gym with its own `plates`, `dumbbells`, `barDefaults` and `stackWeights`.
/// The top-level fields of the same names hold the ACTIVE gym's inventory, a working copy every
/// reader already uses (Equipment, Session, the plate calculator), mirrored both ways:
/// `invGym` names the gym the copy belongs to, and `sync` settles the two on every change.
/// With no gym at all nothing here does anything.
/// ponytail: switching mid-workout does not move open sets onto the new gym's loads
/// (reRoundOpenSets), and editing a saved workout reads the active gym's plates, not the gym it
/// was done at (sessionGymView).
public enum Gyms {
    public typealias Object = [String: JSONValue]

    static let keys = ["plates", "dumbbells", "barDefaults", "stackWeights"]
    /// The fields whose entries carry their own `_ts` (per unit, per exercise).
    static let stamped: Set<String> = ["plates", "dumbbells", "stackWeights"]
    /// openGym's ACC_V: a profile saved with the accessories checklist.
    static let accessoriesVersion = 2.0

    public static func all(_ s: Object) -> [Object] {
        (s["equipProfiles"]?.arrayValue ?? []).compactMap(\.object).filter { $0["id"] != nil && $0["id"] != .null }
    }

    public static func active(_ s: Object) -> Object? { all(s).first { $0["id"] == s["activeEquipId"] } }

    public static func label(_ p: Object?) -> String {
        let n = (p?["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "My gym" : n
    }

    static func map(_ v: JSONValue?) -> Object { v?.object ?? [:] }
    static func stamp(_ v: JSONValue?) -> Double { v?.object?["_ts"]?.numberValue ?? 0 }

    static func setTop(_ s: inout Object, _ k: String, _ v: Object) {
        // No bars of your own means the built-in ones: an empty map is written as absent.
        if k == "barDefaults" && v.isEmpty { s[k] = nil } else { s[k] = .object(v) }
    }

    /// The inventory as edited `now`: a loaded gym must not lose a sync to a stale stamp.
    static func restamp(_ k: String, _ v: Object, _ now: Double) -> Object {
        guard stamped.contains(k) else { return v }
        return v.mapValues { e in
            guard var o = e.object, o["_ts"] != nil else { return e }
            o["_ts"] = .number(now)
            return .object(o)
        }
    }

    /// Key by key, the entry edited last; a tie keeps the top-level one.
    static func newerByKey(_ top: Object, _ prof: Object) -> Object {
        var out = prof.merging(top) { _, t in t }
        for (k, v) in prof where top[k] != nil && stamp(v) > stamp(top[k]) { out[k] = v }
        return out
    }

    /// Settles the top-level copy with gym `p` (both change). `prev` is the state before this change.
    static func settle(_ s: inout Object, _ p: inout Object, _ prev: Object?) {
        for k in keys {
            let top = map(s[k]), own = map(p[k])
            if top == own { continue }
            if let prev, map(prev[k]) != top { p[k] = .object(top); continue }
            if stamped.contains(k) {
                let m = newerByKey(top, own)
                if m != own { p[k] = .object(m) }
                if m != top { setTop(&s, k, m) }
                continue
            }
            let ts = s["edited"]?.object?[k]?.numberValue ?? 0, ps = p["_f"]?.object?[k]?.numberValue ?? 0
            if ps > ts { setTop(&s, k, own) } else { p[k] = .object(top) }
        }
    }

    static func load(_ s: inout Object, _ p: inout Object, _ now: Double) {
        for k in keys {
            let v = restamp(k, map(p[k]), now)
            p[k] = .object(v)
            setTop(&s, k, v)
        }
    }

    /// Keeps the top-level inventories and the gyms' copies in step, and records on a running
    /// session which gym it is done at (syncGymInventory). Called on every change.
    public static func sync(_ s: inout Object, prev: Object?, now: Double) {
        var list = s["equipProfiles"]?.arrayValue ?? []
        let real = list.indices.filter { list[$0].object.map { $0["id"] != nil && $0["id"] != .null } ?? false }
        if !real.isEmpty {
            let before = list
            // A gym without a list gets the one from before this change (the migration).
            let base = prev ?? s
            for i in real {
                var p = list[i].object!
                for k in keys where p[k] == nil { p[k] = .object(map(base[k])) }
                list[i] = .object(p)
            }
            let a = real.first { list[$0].object?["id"] == s["activeEquipId"] }
            let inv = s["invGym"].flatMap { $0 == .null ? nil : $0 }
            let owner = inv.flatMap { id in real.first { list[$0].object?["id"] == id } }
            if let a, let inv, inv != list[a].object?["id"] {
                if let owner { var o = list[owner].object!; settle(&s, &o, nil); list[owner] = .object(o) }
                var p = list[a].object!; load(&s, &p, now); list[a] = .object(p)
                s["invGym"] = p["id"]
            } else if let a {
                var p = list[a].object!
                if s["invGym"] != p["id"] { s["invGym"] = p["id"] }
                settle(&s, &p, prev); list[a] = .object(p)
            } else if let owner {
                var o = list[owner].object!; settle(&s, &o, prev); list[owner] = .object(o)
            }
            if list != before { s["equipProfiles"] = .array(list) }
        }
        tagSession(&s)
    }

    /// A live session remembers the gym it is done at (`active.gym`); a past workout logged after
    /// the fact, or one being edited, keeps what it had.
    static func tagSession(_ s: inout Object) {
        guard var a = s["active"]?.object, a["editingWorkoutId"] == nil || a["editingWorkoutId"] == .null,
              a["backfill"] == nil || a["backfill"] == .null, a["gym"] == nil, let g = active(s) else { return }
        a["gym"] = .object(["id": g["id"]!, "name": .string(label(g))])
        s["active"] = .object(a)
    }

    /// Makes gym `id` the active one: the current copy goes back to the gym it came from, the new
    /// gym's comes in. False when there is no such gym or it is active already (switchGym).
    @discardableResult
    public static func switchTo(_ s: inout Object, _ id: JSONValue, now: Double) -> Bool {
        var list = s["equipProfiles"]?.arrayValue ?? []
        guard let t = list.firstIndex(where: { $0.object?["id"] == id }) else { return false }
        let from = s["invGym"].flatMap { $0 == .null ? nil : $0 } ?? s["activeEquipId"] ?? .null
        if from == id && s["activeEquipId"] == id { return false }
        if let f = list.firstIndex(where: { $0.object?["id"] == from }), var p = list[f].object {
            for k in keys where map(s[k]) != map(p[k]) { p[k] = .object(map(s[k])) }
            list[f] = .object(p)
        }
        var to = list[t].object!
        for k in keys where to[k] == nil { to[k] = .object(map(s[k])) }
        load(&s, &to, now)
        list[t] = .object(to)
        s["equipProfiles"] = .array(list)
        s["activeEquipId"] = id
        s["invGym"] = id
        if var a = s["active"]?.object, a["editingWorkoutId"] == nil || a["editingWorkoutId"] == .null, a["backfill"] == nil || a["backfill"] == .null {
            a["gym"] = .object(["id": id, "name": .string(label(to))])
            s["active"] = .object(a)
        }
        return true
    }

    /// A new gym (newProfile): the first one becomes the active one. Its id, for the editor.
    @discardableResult
    public static func add(_ s: inout Object, name: String, equipment: [String], now: Double) -> String {
        let id = "eq" + String(Int(now), radix: 36) + String(UUID().uuidString.lowercased().prefix(4))
        var list = s["equipProfiles"]?.arrayValue ?? []
        list.append(.object(["id": .string(id), "name": .string(name), "equipment": .array(equipment.map(JSONValue.string)), "accV": .number(accessoriesVersion)]))
        s["equipProfiles"] = .array(list)
        if s["activeEquipId"] == nil || s["activeEquipId"] == .null { s["activeEquipId"] = .string(id) }
        return id
    }

    public static func edit(_ s: inout Object, _ id: JSONValue, name: String, equipment: [String]) {
        guard var list = s["equipProfiles"]?.arrayValue, let i = list.firstIndex(where: { $0.object?["id"] == id }), var p = list[i].object else { return }
        p["name"] = .string(name)
        p["equipment"] = .array(equipment.map(JSONValue.string))
        p["accV"] = .number(accessoriesVersion)
        list[i] = .object(p)
        s["equipProfiles"] = .array(list)
    }

    /// Removes a gym; removing the active one makes the next one active, with its own lists.
    public static func remove(_ s: inout Object, _ id: JSONValue, now: Double) {
        let rest = all(s).filter { $0["id"] != id }
        if s["activeEquipId"] == id, let next = rest.first?["id"] { switchTo(&s, next, now: now) }
        s["equipProfiles"] = .array((s["equipProfiles"]?.arrayValue ?? []).filter { $0.object?["id"] != id })
        if s["activeEquipId"] == id { s["activeEquipId"] = .null }
        if s["invGym"] == id { s["invGym"] = nil }
    }
}
