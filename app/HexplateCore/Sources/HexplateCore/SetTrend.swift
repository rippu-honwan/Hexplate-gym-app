import Foundation

/// Each finished set against the same set last time (openGym lib/set-trend.js): ↑, = or ↓.
/// Work set N today against work set N last time; warm-ups and sets not done say nothing.
/// Weight first, then reps; when they pull apart the estimated 1RM decides. On an assisted
/// machine less help is better. Holds go by seconds, cardio by minutes then speed.
public enum SetTrend {
    public typealias Object = [String: JSONValue]

    public struct Trend: Equatable, Sendable {
        /// 1 better, 0 the same, -1 worse.
        public let dir: Int
        /// What decided it: "w", "r", "e1rm", "sec", "min" or "speed".
        public let by: String
        /// Today minus last time, in that measure.
        public let delta: Double
    }

    /// Settings → Workout → Compare sets with last time: on unless switched off.
    public static func on(_ s: Object) -> Bool { s["setTrend"] != .bool(false) }

    static let eps = 1e-6
    static func num(_ v: JSONValue?) -> Double { v?.num ?? 0 }
    static func sign(_ n: Double) -> Int { n > eps ? 1 : n < -eps ? -1 : 0 }

    public static func trend(_ cur: JSONValue?, _ prev: JSONValue?, mode: String, assisted: Bool, formula: String) -> Trend? {
        guard let cur, let prev, cur.object != nil, prev.object != nil, !Session.isWarmup(cur), !Session.isWarmup(prev) else { return nil }
        let c = cur.object!, p = prev.object!
        if mode == "time" {
            let a = num(c["sec"]), b = num(p["sec"])
            guard a > 0, b > 0 else { return nil }
            return Trend(dir: sign(a - b), by: "sec", delta: a - b)
        }
        if mode == "cardio" {
            let a = num(c["min"]), b = num(p["min"])
            guard a > 0, b > 0 else { return nil }
            if sign(a - b) != 0 { return Trend(dir: sign(a - b), by: "min", delta: a - b) }
            let ds = num(c["speed"]) - num(p["speed"])
            return sign(ds) != 0 && num(c["speed"]) > 0 && num(p["speed"]) > 0 ? Trend(dir: sign(ds), by: "speed", delta: ds) : Trend(dir: 0, by: "min", delta: 0)
        }
        let r = num(c["r"]), pr = num(p["r"])
        guard r > 0, pr > 0 else { return nil }
        let w = num(c["w"]), pw = num(p["w"]), rawW = w - pw
        let dw = sign(assisted ? -rawW : rawW), dr = sign(r - pr)
        if dw == 0 && dr == 0 { return Trend(dir: 0, by: "w", delta: 0) }
        if dw == 0 { return Trend(dir: dr, by: "r", delta: r - pr) }
        if dr == 0 || dw == dr { return Trend(dir: dw, by: "w", delta: rawW) }
        guard !assisted, w > 0, pw > 0, let a = Stats.estimate1RM(w, r, formula: formula), let b = Stats.estimate1RM(pw, pr, formula: formula) else {
            return Trend(dir: dw, by: "w", delta: rawW)
        }
        let de = a - b
        return Trend(dir: abs(de) < 0.05 ? 0 : (de > 0 ? 1 : -1), by: "e1rm", delta: de)
    }

    /// Every row of `entry` against `last` (Session.lastEntry), aligned with `entry.sets`.
    public static func trends(_ entry: Object, last: Object?, catalog: ExerciseCatalog, formula: String) -> [Trend?] {
        let rows = entry["sets"]?.arrayValue ?? []
        let prev = (last?["sets"]?.arrayValue ?? []).filter { $0.object != nil && !Session.isWarmup($0) }
        guard !prev.isEmpty else { return rows.map { _ in nil } }
        var cfg = entry["target"]?.object ?? [:]
        cfg["id"] = entry["id"]
        let m = Session.mode(cfg, catalog)
        if let lt = last?["target"]?.object {
            var lc = lt; lc["id"] = entry["id"]
            if Session.mode(lc, catalog) != m { return rows.map { _ in nil } }
        }
        let helped = Session.isAssisted(entry, catalog)
        var n = -1
        return rows.map { s in
            if s.object == nil || Session.isWarmup(s) { return nil }
            n += 1
            guard isDone(s), Session.hasCompletedWork(s), prev.indices.contains(n) else { return nil }
            return trend(s, prev[n], mode: m, assisted: helped, formula: formula)
        }
    }

    /// Done: both sides of a per-side set.
    public static func isDone(_ s: JSONValue) -> Bool {
        guard Session.isSideSet(s), let sides = s.object?["sides"]?.object else { return Session.done(s) }
        return Session.done(sides["L"]) && Session.done(sides["R"])
    }

    public static func glyph(_ t: Trend?) -> String { t.map { $0.dir > 0 ? "↑" : $0.dir < 0 ? "↓" : "=" } ?? "" }
}
