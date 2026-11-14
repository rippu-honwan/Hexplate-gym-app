import Foundation

/// One-line text for a logged set: "60×8 (RIR 2)", "L 20×6 · R 17.5×6", "62.5×7 ↘ 50×5", "0:45".
/// Ported from frontend/src/lib/history.js setLabel; HistoryGoldenTests holds it to that output.
public enum SetLabel {
    public static func text(exerciseId: String, set s: WorkoutSet, target: Target?, catalog: ExerciseCatalog, settings: ProfileSettings) -> String {
        let num = { (n: Double) in Format.number(n, decimals: settings.weightDecimals) }
        let exercise = catalog[target?.id ?? exerciseId]

        // How the exercise is logged (history.js modeOf), then what the set's own fields say.
        var mode: String
        if let m = target?.mode, ["reps", "time", "cardio"].contains(m) { mode = m }
        else if target?.hasCardioFields == true { mode = "cardio" }
        else { mode = exercise?.isCardio == true ? "cardio" : "reps" }

        let reps = s.reps ?? 0, minutes = s.minutes ?? 0, speed = s.speed ?? 0, seconds = s.seconds ?? 0
        if target == nil && !(reps > 0) {
            if minutes > 0 || speed > 0 { mode = "cardio" } else if seconds > 0 { mode = "time" }
        }
        let explicit = ["reps", "time", "cardio"].contains(target?.mode ?? "")
        if !explicit && mode != "reps" && reps > 0 && !(minutes > 0 || speed > 0 || seconds > 0) { mode = "reps" }

        if mode == "cardio" {
            let shown = settings.speedUnit == "mph" ? (speed / 1.609344 * 100 + 0.5).rounded(.down) / 100 : speed
            let incline = (s.incline ?? 0) > 0 ? " · \(num(s.incline ?? 0))% incline" : ""
            return "\(Format.plain(minutes)) min @ \(num(shown)) \(settings.speedUnit == "mph" ? "mph" : "km/h")" + incline
        }

        let fail = s.failure ? " F" : ""
        if mode == "time" {
            return Format.seconds(seconds) + ((s.weight ?? 0) > 0 ? " · \(num(s.weight ?? 0))" : "") + fail
        }

        // Bodyweight reads as what was done, "12" or "+10 × 12"; a dumbbell weight says what it means.
        let bodyweight = target?.bodyweight ?? (exercise?.isBodyweightEquipment == true)
        let meaning = !bodyweight && WorkoutMath.bells(target: target, exercise: exercise) == 2 ? target?.dbLoad : nil
        func load(_ w: Double, _ reps: String) -> String {
            if bodyweight { return (w > 0 ? "+\(num(w)) × " : "") + reps }
            switch meaning {
            case "each": return "\(num(w)) each × \(reps)"
            case "total": return "\(num(w)) total × \(reps)"
            default: return "\(num(w))×\(reps)"
            }
        }

        // A rest-pause set reads as its bursts, "60×7+3+2"; bursts that do not fit the total are
        // not shown, and a planned set whose total was changed by hand reads as its plain total.
        let planned = target?.intensifier == "restpause"
        func repsText(_ side: WorkoutSet) -> String {
            let total = side.reps ?? 0
            let bursts = side.clusters.map { $0.reps ?? 0 }.filter { $0 > 0 }
            let sum = bursts.reduce(0, +)
            if bursts.isEmpty || sum > total || (planned && sum != total) { return Format.plain(total) }
            return (total > sum ? [total - sum] + bursts : bursts).map(Format.plain).joined(separator: "+")
        }
        func oneSide(_ side: WorkoutSet) -> String {
            let drops = side.drops.filter { ($0.reps ?? 0) > 0 }
            return load(side.weight ?? 0, repsText(side))
                + drops.map { " ↘ " + load($0.weight ?? 0, Format.plain($0.reps ?? 0)) }.joined()
        }
        func effort(_ side: WorkoutSet) -> String {
            if let rir = side.rir { return " (RIR \(num(rir)))" }
            if let rpe = side.rpe { return " (RPE \(num(rpe)))" }
            return ""
        }

        if let (l, r) = s.perSide {
            let partial = l.done != r.done
            return [("L", l), ("R", r)].map { key, side in
                "\(key) " + (partial && !side.done ? "–" : oneSide(side) + effort(side))
            }.joined(separator: " · ") + fail
        }
        return oneSide(s) + fail + effort(s)
    }

    /// " ♥ 118/131" after a set's label, "" without a believable reading (heart-rate.js hrLabel).
    public static func heartRate(_ s: WorkoutSet) -> String {
        guard let avg = heartRateValues(s)?.avg, let max = heartRateValues(s)?.max else { return "" }
        return " ♥ \(avg)/\(max)"
    }

    public static func heartRateValues(_ s: WorkoutSet) -> (avg: Int, max: Int)? {
        guard let a = s.heartRate?.avg, let m = s.heartRate?.max, a.isFinite, m.isFinite else { return nil }
        let avg = Int((a + 0.5).rounded(.down)), max = Int((m + 0.5).rounded(.down))
        guard (25...250).contains(avg), (25...250).contains(max), max >= avg else { return nil }
        return (avg, max)
    }
}
