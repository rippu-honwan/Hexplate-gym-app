import Foundation

/// An exercise's numbers per session, for the workout's exercise card: the heaviest weight, the
/// best estimated one-rep max, the best single set's volume and the session's volume. Ticked work
/// rows only (warm-ups out); a per-side set counts each side as its own row, and its set volume is
/// both sides together. ponytail: weights as logged, so body weight and assistance are not
/// folded in (the history list's own volume does that); fine for comparing a lift with itself.
public enum ExerciseRecords {
    public typealias Object = [String: JSONValue]

    public struct Metrics: Equatable, Sendable {
        public var heaviest = 0.0
        public var best1RM = 0.0
        public var bestSet = 0.0
        public var session = 0.0
        /// The set behind `best1RM` (weight, reps), for the history line.
        public var top: (w: Double, r: Double)? = nil

        public var isEmpty: Bool { heaviest == 0 && session == 0 && best1RM == 0 }
        public static func == (a: Metrics, b: Metrics) -> Bool {
            a.heaviest == b.heaviest && a.best1RM == b.best1RM && a.bestSet == b.bestSet && a.session == b.session
                && a.top?.w == b.top?.w && a.top?.r == b.top?.r
        }
    }

    public struct Session: Equatable, Sendable {
        public let day: String
        public let workoutId: String
        public let metrics: Metrics
    }

    static func num(_ v: JSONValue?) -> Double { v?.numberValue.flatMap { $0.isFinite ? $0 : nil } ?? 0 }

    /// The numbers of one session's entries of an exercise (a session can hold it twice).
    public static func metrics(_ entries: [Object], formula: String = "epley") -> Metrics {
        var m = Metrics()
        for e in entries {
            for s in e["sets"]?.arrayValue ?? [] where !HexplateCore.Session.isWarmup(s) {
                guard let o = s.object else { continue }
                let rows = HexplateCore.Session.isSideSet(s) ? [o["sides"]?.object?["L"]?.object ?? [:], o["sides"]?.object?["R"]?.object ?? [:]] : [o]
                var setVolume = 0.0
                for r in rows where r["done"] == .bool(true) {
                    let w = num(r["w"]), reps = num(r["r"])
                    m.heaviest = max(m.heaviest, w)
                    setVolume += w * reps
                    if w > 0, reps > 0, let est = Stats.estimate1RM(w, reps, formula: formula), est > m.best1RM {
                        m.best1RM = est
                        m.top = (w, reps)
                    }
                }
                m.bestSet = max(m.bestSet, setVolume)
                m.session += setVolume
            }
        }
        return m
    }

    /// Every saved workout with this exercise ticked, oldest first.
    public static func history(_ s: Object, exerciseId id: String, formula: String = "epley") -> [Session] {
        let workouts = (s["workouts"]?.arrayValue ?? []).compactMap(\.object).enumerated().compactMap { i, w -> (String, Int, Object)? in
            guard let d = w["d"]?.stringValue, d.count == 10 else { return nil }
            return (d, i, w)
        }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return workouts.compactMap { d, _, w in
            let entries = (w["entries"]?.arrayValue ?? []).compactMap(\.object).filter { $0["id"]?.stringValue == id }
            let m = metrics(entries, formula: formula)
            return entries.isEmpty || m.isEmpty ? nil : Session(day: d, workoutId: w["id"]?.stringValue ?? "", metrics: m)
        }
    }

    /// How hard today's session works each muscle, 0...1 (the hardest is 1): its work sets, done or
    /// still to do, by each exercise's muscle weights.
    public static func sessionMuscles(_ entries: [Object], catalog c: ExerciseCatalog) -> [String: Double] {
        var load: [String: Double] = [:]
        for e in entries {
            let sets = Double((e["sets"]?.arrayValue ?? []).filter { !HexplateCore.Session.isWarmup($0) }.count)
            guard sets > 0, let ex = e["id"]?.stringValue.flatMap({ c[$0] }) else { continue }
            for (m, share) in c.muscleWeights(of: ex) { load[m, default: 0] += share * sets }
        }
        let top = load.values.max() ?? 0
        return top > 0 ? load.mapValues { $0 / top } : [:]
    }

    /// Work sets done and planned in a live session (warm-ups out).
    public static func progress(_ entries: [Object]) -> (done: Int, total: Int) {
        let rows = entries.flatMap { $0["sets"]?.arrayValue ?? [] }.filter { !HexplateCore.Session.isWarmup($0) }
        return (rows.filter(HexplateCore.Session.hasCompletedWork).count, rows.count)
    }
}
