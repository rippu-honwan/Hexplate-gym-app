import Foundation

/// The phone's side of the Apple Watch link (lib/watch-sync.js): the snapshot the watch runs a
/// workout from, and the events it sends back. The watch app is app/Watch; its model of the
/// snapshot is WatchCore/Model.swift.
///
/// ponytail: not sent yet: each exercise's best set, the Health workout type, per-exercise units,
/// streaks and exercise animations; `recording`, `watchStatus` and `healthDeleted` events are
/// acknowledged and dropped.
public enum WatchLink {
    public typealias Object = [String: JSONValue]

    static func num(_ v: JSONValue?) -> JSONValue {
        if case .number(let x)? = v, x.isFinite { return .number(x) }
        return .null
    }
    static func n(_ v: JSONValue?) -> Double? { if case .number(let x)? = v, x.isFinite { return x }; return nil }

    // MARK: Snapshot

    static func watchSet(_ s: JSONValue) -> JSONValue {
        let o = s.object ?? [:]
        var out: Object = ["w": num(o["w"]), "r": num(o["r"]), "sec": num(o["sec"]), "done": .bool(Session.truthy(o["done"])), "warmup": .bool(Session.isWarmup(s))]
        if let at = n(o["at"]), at != 0 { out["at"] = .number(at) }
        if Session.isSideSet(s), let sides = o["sides"]?.object {
            func row(_ v: JSONValue?) -> JSONValue {
                let x = v?.object ?? [:]
                return .object(["w": num(x["w"]), "r": num(x["r"]), "done": .bool(x["done"] == .bool(true))])
            }
            out["sides"] = .object(["L": row(sides["L"]), "R": row(sides["R"])])
        }
        return .object(out)
    }

    static func watchEntry(_ e: Object, _ s: Object, _ c: ExerciseCatalog, _ settings: ProfileSettings) -> JSONValue {
        let id = e["id"]?.stringValue ?? ""
        let ex = c[id]
        let target = e["target"]?.object ?? [:]
        var cfg = target; cfg["id"] = .string(id)
        let mode = Session.mode(cfg, c)
        let lastRows = Session.lastSets(s, id, e["rid"]?.stringValue)
        var last: JSONValue = .null
        if let rows = lastRows, !rows.isEmpty {
            let lastTarget = lastTargetOf(s, id, e["rid"]?.stringValue)
            let t = try? JSONValue.object(lastTarget ?? [:]).decoded(as: Target.self)
            last = .string(rows.compactMap { try? $0.decoded(as: WorkoutSet.self) }
                .map { SetLabel.text(exerciseId: id, set: $0, target: lastTarget == nil ? nil : t, catalog: c, settings: settings) }
                .joined(separator: ", "))
        }
        var out: Object = [
            "id": .string(id),
            "name": .string(ex?.displayName ?? target["name"]?.stringValue ?? e["name"]?.stringValue ?? id),
            "mode": .string(mode), "restSec": num(target["restSec"]), "last": last,
            "sets": .array((e["sets"]?.arrayValue ?? []).map(watchSet)),
        ]
        if RoutineOps.isBodyweight(cfg, catalog: c) { out["bodyweight"] = .bool(true) }
        if Session.isPerSide(cfg) { out["perSide"] = .bool(true) }
        if let sg = e["sg"]?.stringValue, !sg.isEmpty { out["group"] = .string(sg) }
        if mode == "reps" && (ex?.isAssisted ?? false) { out["assisted"] = .bool(true) }
        if mode == "reps" { out["step"] = .number(Session.weightIncrement(cfg, unit: settings.unit, c)) }
        if let bp = ex?.bodyPart, !bp.isEmpty { out["bodyPart"] = .string(bp) }
        return .object(out)
    }

    /// The target of the entry `lastSets` read (history.js lastEntryFor).
    static func lastTargetOf(_ s: Object, _ exId: String, _ rid: String?) -> Object? {
        func lastIn(_ rid: String?) -> Object?? {
            for w in Session.workouts(s).reversed() {
                guard let e = Session.entry(in: w, exId, rid), !Session.excluded(w, e) else { continue }
                if (e["sets"]?.arrayValue ?? []).contains(where: { Session.done($0) && !Session.isWarmup($0) }) { return .some(e["target"]?.object) }
            }
            return nil
        }
        if let rid, !Session.across(s), let own = lastIn(rid) { return own }
        return lastIn(nil) ?? nil
    }

    /// Today's planned session and up to eight other routines, ready to start on the watch.
    public static func ready(_ s: Object, today: String, catalog c: ExerciseCatalog) -> JSONValue {
        let settings = ProfileSettings(s)
        func session(_ ids: [String]) -> JSONValue? {
            let a = Session.begin(s, routineIds: ids, bodyweight: nil, id: "", now: 0, day: today, catalog: c)
            guard let rids = a["routineIds"]?.arrayValue, !rids.isEmpty else { return nil }
            return .object(["routineIds": .array(rids), "name": a["name"] ?? .string(""),
                            "entries": .array((a["entries"]?.arrayValue ?? []).compactMap(\.object).map { watchEntry($0, s, c, settings) })])
        }
        let todayIds = Schedule.routineIds(s, on: today, today: today)
        let todayCanonical = Set(todayIds.map { Schedule.canonical(s, $0) })
        let others = (s["routines"]?.arrayValue ?? []).compactMap(\.object)
            .filter { !RoutineOps.isAIClone($0) }
            .compactMap { $0["id"]?.stringValue }
            .filter { !todayCanonical.contains($0) }.prefix(8).compactMap { session([$0]) }
        return .object(["today": todayIds.isEmpty ? .null : session(todayIds) ?? .null, "others": .array(others)])
    }

    /// What the watch shows and runs (watch-sync.js buildSnapshot); `restEndsAt` in ms.
    /// `startSet`: MyGym's Start set pressed on the phone ({entryIdx, setIdx, at}), sent while fresh.
    public static func snapshot(_ s: Object, today: String, restEndsAt: Double?, health: Bool, lang: String = "en", startSet: Object? = nil, doneSet: Object? = nil, catalog c: ExerciseCatalog) -> Object {
        let unit = s["unit"] == .string("lb") ? "lb" : "kg"
        let restSec = n(s["restSec"]) ?? 0
        var snap: Object = ["v": .number(1), "unit": .string(unit), "restSec": .number(restSec), "ready": ready(s, today: today, catalog: c), "active": .null]
        let bw = BodyData.weights(s).last?.weight
        var settings: Object = ["health": .bool(health), "lang": .string(lang), "weighIn": .bool(s["weighIn"] != .bool(false))]
        if let bw { settings["lastBw"] = .number(bw) }
        if let e = s["effort"]?.stringValue, ["rir", "rpe"].contains(e) { settings["effort"] = .string(e) }
        if s["autoHolds"] == .bool(true) { settings["autoHolds"] = .bool(true) }
        snap["settings"] = .object(settings)
        guard let a = s["active"]?.object, let entries = a["entries"]?.arrayValue else { return snap }
        let ps = ProfileSettings(s)
        let list = entries.compactMap(\.object).filter { $0["id"] != nil && $0["id"] != .null }
        var active: Object = [
            "id": a["id"] ?? .null, "name": a["name"] ?? .string(""), "unit": .string(unit),
            "cur": .number(Double(max(0, min(entries.count - 1, Int(n(a["cur"]) ?? 0))))),
            "restSec": .number(restSec), "rest": restEndsAt.map { .object(["endsAt": .number($0)]) } ?? .null,
            "entries": .array(list.map { watchEntry($0, s, c, ps) }),
        ]
        if let start = n(a["start"]), start != 0 { active["start"] = .number(start) }
        if let startSet { active["startSet"] = .object(startSet) }
        if let doneSet { active["doneSet"] = .object(doneSet) }
        snap["active"] = .object(active)
        return snap
    }

    // MARK: Events

    /// `tick`: a work set of the running session was done on the watch; the phone starts its rest
    /// as a tick there does (the watch follows the phone's rest and would end its own otherwise).
    public enum Effect: Equatable, Sendable { case none, finish, discard, rest(endsAt: Double?), tick(entryIdx: Int, at: Double?) }

    static func hr(_ v: JSONValue?) -> JSONValue? {
        guard let o = v?.object, let a = n(o["avg"]), let m = n(o["max"]) else { return nil }
        let avg = Session.jsRound(a), max = Session.jsRound(m)
        guard avg >= 25, avg <= 250, max >= 25, max <= 250, max >= avg else { return nil }
        return .object(["avg": .number(avg), "max": .number(max)])
    }

    static func effort(_ ev: Object) -> Object {
        for (k, lo) in [("rpe", 1.0), ("rir", 0.0)] {
            guard let v = n(ev[k]) else { continue }
            let snapped = Session.jsRound(v * 2) / 2
            return snapped >= lo && snapped <= 10 ? [k: .number(snapped)] : [:]
        }
        return [:]
    }

    /// Writes fields into one set of the running session or of a saved workout
    /// (watch-sync.js patchSetIn). `ifNewer`: a saved set logged after the event keeps its
    /// numbers and only takes heart rate and a missing effort.
    @discardableResult
    public static func patchSet(_ s: inout Object, wid: String, exId: String, entryIdx: Int, setIdx: Int, side: String?, _ fields: Object, ifNewer: Double? = nil) -> Bool {
        func write(_ set: inout Object, _ f: Object) {
            let cur = side.flatMap { set["sides"]?.object?[$0]?.object } ?? set
            if Session.isWarmup(.object(set)) && ((f["w"] != nil && f["w"] != cur["w"]) || (f["r"] != nil && f["r"] != cur["r"])) { set["edited"] = .bool(true) }
            if let side, Session.isSideSet(.object(set)), var sides = set["sides"]?.object {
                var one = sides[side]?.object ?? [:]
                for k in ["w", "r", "rpe", "rir"] { if let v = f[k], v != .null { one[k] = v } }
                if f["done"] == .bool(true) { one["done"] = .bool(true) }
                sides[side] = .object(one)
                set["sides"] = .object(sides)
                var agg = Session.syncSides(set).object ?? set
                for (k, v) in f where !["w", "r", "done", "rpe", "rir"].contains(k) { agg[k] = v }
                set = agg
            } else {
                set.merge(f) { $1 }
            }
        }
        func index(_ entries: [JSONValue]) -> Int? {
            if entries.indices.contains(entryIdx), entries[entryIdx].object?["id"]?.stringValue == exId { return entryIdx }
            return entries.firstIndex { $0.object?["id"]?.stringValue == exId }
        }
        func patch(_ w: inout Object, saved: Bool) -> Bool {
            guard var entries = w["entries"]?.arrayValue, let i = index(entries), var e = entries[i].object,
                  var sets = e["sets"]?.arrayValue, sets.indices.contains(setIdx), var set = sets[setIdx].object else { return false }
            var f = fields
            if saved, let ifNewer, set["done"] == .bool(true), (n(set["at"]) ?? 0) > ifNewer {
                f = [:]
                if let h = fields["hr"] { f["hr"] = h }
                if let h = fields["restHr"] { f["restHr"] = h }
                if set["rpe"] == nil && set["rir"] == nil { f.merge(effort(fields)) { $1 } }
                if f.isEmpty { return false }
            }
            write(&set, f)
            sets[setIdx] = .object(set); e["sets"] = .array(sets); entries[i] = .object(e); w["entries"] = .array(entries)
            return true
        }
        if var a = s["active"]?.object, a["id"]?.stringValue == wid {
            let ok = patch(&a, saved: false)
            s["active"] = .object(a)
            return ok
        }
        guard var list = s["workouts"]?.arrayValue, let k = list.firstIndex(where: { $0.object?["id"]?.stringValue == wid }), var w = list[k].object else { return false }
        let ok = patch(&w, saved: true)
        list[k] = .object(w); s["workouts"] = .array(list)
        return ok
    }

    /// A watch start that is the phone's running workout: started on the phone (not from a watch),
    /// same routines, same day, within half an hour of each other.
    static func adopts(_ a: Object, start ev: Object, wid: String, at: Double) -> Bool {
        guard wid.hasPrefix("watch-"), let id = a["id"]?.stringValue, !id.hasPrefix("watch-"), let begun = n(a["start"]) else { return false }
        let ids = { (o: Object) in Set((o["routineIds"]?.arrayValue ?? []).compactMap(\.stringValue)) }
        return !ids(a).isEmpty && ids(a) == ids(ev) && a["d"]?.stringValue == Day.iso(at) && abs(begun - at) <= 30 * 60_000
    }

    /// `sessionEffort` on the saved workout `wid`, or on the running one when it is still that.
    static func setEffort(_ s: inout Object, wid: String, _ v: Double) {
        if var list = s["workouts"]?.arrayValue, let k = list.firstIndex(where: { $0.object?["id"]?.stringValue == wid }), var w = list[k].object {
            w["sessionEffort"] = .number(v)
            list[k] = .object(w)
            s["workouts"] = .array(list)
        } else if var a = s["active"]?.object, a["id"]?.stringValue == wid {
            a["sessionEffort"] = .number(v)
            s["active"] = .object(a)
        }
    }

    /// Applies one watch event to the document; what the app must still do comes back.
    public static func apply(_ ev: Object, to s: inout Object, today: String, now: Double, newId: String, catalog c: ExerciseCatalog) -> Effect {
        let active = s["active"]?.object
        let wid = ev["wid"]?.stringValue
        let ours = active != nil && (wid == nil || wid == active?["id"]?.stringValue)
        let at = n(ev["at"])
        let ref = (exId: ev["exId"]?.stringValue ?? "", entryIdx: Int(n(ev["entryIdx"]) ?? -1), setIdx: Int(n(ev["setIdx"]) ?? -1))
        let side = ev["side"]?.stringValue.flatMap { ["L", "R"].contains($0) ? $0 : nil }
        switch ev["type"]?.stringValue {
        case "start" where active == nil:
            let ids = (ev["routineIds"]?.arrayValue ?? []).compactMap(\.stringValue)
            let bw = n(ev["bw"]).flatMap { $0 > 0 && $0 < 700 ? $0 : nil }
            let start = at ?? now
            let day = wid != nil && at != nil ? Day.iso(start) : today
            // Clone-and-Pin 1b: Watch snapshots carry canonical parent IDs (1a), so resolve
            // through any aiClone pinned on `day`. Midnight boundary: if a snapshot built on day D
            // starts after 00:00 on D+1, `Day.iso(start)` resolves on D+1, finds no D pin, and
            // starts the parent routine.
            let resolvedIds = Schedule.resolvePin(s, ids: ids, day: day)
            s["active"] = .object(Session.begin(s, routineIds: resolvedIds, bodyweight: bw, id: wid ?? newId, now: start, day: day, catalog: c))
        case "start":
            // The watch started a workout, the phone started the same one before that start reached it
            // (the phone app was asleep): one workout, not two. The phone's takes the watch's id, so
            // the watch's sets land in it and the watch takes the phone's snapshots as its own.
            if let wid, var a = active, adopts(a, start: ev, wid: wid, at: at ?? now) {
                a["id"] = .string(wid)
                s["active"] = .object(a)
            }
        case "setDone":
            var f: Object = ["done": .bool(true)]
            for k in ["w", "r", "sec", "at"] { if let v = n(ev[k]) { f[k] = .number(v) } }
            if let h = hr(ev["hr"]) { f["hr"] = h }
            f.merge(effort(ev)) { $1 }
            if let st = n(ev["startedAt"]), st > 0, at == nil || (st <= at! && at! - st < 3_600_000) { f["startedAt"] = .number(st) }
            if case .bool? = ev["checked"] { f["checked"] = ev["checked"] }
            if let v = ev["vel"]?.object, let best = n(v["best"]), let last = n(v["last"]), let loss = n(v["loss"]),
               best > 0, best <= 50, last >= 0, last <= 50, loss >= 0, loss <= 1 { f["vel"] = .object(["best": .number(best), "last": .number(last), "loss": .number(loss)]) }
            let target = ours ? active!["id"]?.stringValue ?? "" : wid ?? ""
            // The row as it was, to tell a new tick from one the watch sends again.
            let entries = active?["entries"]?.arrayValue ?? []
            let i = entries.indices.contains(ref.entryIdx) && entries[ref.entryIdx].object?["id"]?.stringValue == ref.exId
                ? ref.entryIdx : entries.firstIndex { $0.object?["id"]?.stringValue == ref.exId }
            let row = i.flatMap { i in entries[i].object?["sets"]?.arrayValue.flatMap { $0.indices.contains(ref.setIdx) ? $0[ref.setIdx] : nil } }
            let wasDone = side.flatMap { row?.object?["sides"]?.object?[$0] }.map(Session.done) ?? Session.done(row)
            let ok = patchSet(&s, wid: target, exId: ref.exId, entryIdx: ref.entryIdx, setIdx: ref.setIdx, side: side, f, ifNewer: ours ? nil : at)
            if ours, ok, !wasDone, let i, let row, !Session.isWarmup(row), side == nil || side == "R" { return .tick(entryIdx: i, at: at) }
        case "setHr":
            var f: Object = [:]
            if let h = hr(ev["hr"]) { f["hr"] = h }
            if let h = hr(ev["restHr"]) { f["restHr"] = h }
            if !f.isEmpty, let wid { patchSet(&s, wid: wid, exId: ref.exId, entryIdx: ref.entryIdx, setIdx: ref.setIdx, side: nil, f) }
        case "weighIn":
            if let w = n(ev["w"]), w > 0, w < 700 {
                let when = at ?? now
                BodyData.addWeighIn(&s, day: Day.iso(when), time: nil, weight: w, at: when, id: newId)
            }
        case "effort":
            // MyGym: how hard the whole workout was (1-5), asked on the watch once it ended.
            if let wid, let v = n(ev["effort"]), (1...5).contains(v), v == v.rounded() { setEffort(&s, wid: wid, v) }
        case "rest" where ours: return .rest(endsAt: n(ev["endsAt"]))
        case "finish" where ours: return .finish
        case "discard" where ours: return .discard
        default: break
        }
        return .none
    }
}
