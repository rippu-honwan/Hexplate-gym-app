import Foundation

/// The gear a profile owns, as openGym stores it (lib/plates.js, lib/dumbbells.js, lib/bar.js).
/// Plates and dumbbells are kept per unit and stamped (`_ts`), so the last change wins a sync;
/// bar weights are a plain per-unit map of the bars that differ from the built-in ones.
public enum Equipment {
    public typealias Object = [String: JSONValue]

    static func unit(_ s: Object) -> String { s["unit"] == .string("lb") ? "lb" : "kg" }

    // MARK: Plates (pairs of each size)

    public static let plateSizes: [String: [Double]] = ["kg": [25, 20, 15, 10, 5, 2.5, 2, 1.5, 1.25, 1, 0.5],
                                                        "lb": [45, 35, 25, 15, 10, 5, 2.5, 1.25, 1, 0.5]]

    /// Whether the profile counts its own plates for its unit, rather than the standard set.
    public static func ownsPlates(_ s: Object) -> Bool {
        (s["plates"]?.object?[unit(s)]?.object ?? [:]).keys.contains { (Double($0) ?? 0) > 0 }
    }

    /// `n` pairs of size `w` (withPlatePairs): the first change copies the standard set in.
    public static func settingPlates(_ s: inout Object, _ w: Double, _ n: Int, now: Double) {
        let u = unit(s)
        var list: Object = [:]
        for p in Plates.inventory(s) { list[key(p.w)] = .number(Double(p.n)) }
        list[key(w)] = .number(Double(max(0, n)))
        list["_ts"] = .number(now)
        var all = s["plates"]?.object ?? [:]
        all[u] = .object(list)
        s["plates"] = .object(all)
    }

    /// Back on the standard set: a stamped list with no sizes (withStandardPlates).
    public static func standardPlates(_ s: inout Object, now: Double) {
        var all = s["plates"]?.object ?? [:]
        all[unit(s)] = .object(["_ts": .number(now)])
        s["plates"] = .object(all)
    }

    /// A weight as JavaScript writes it as an object key: "20", "2.5".
    static func key(_ w: Double) -> String { Format.plain(w) }

    // MARK: Dumbbells (one bell each)

    public static func dumbbells(_ s: Object) -> [Double] {
        clean((s["dumbbells"]?.object?[unit(s)]?.object?["weights"]?.arrayValue ?? []).compactMap(\.numberValue))
    }
    public static func ownsNoDumbbells(_ s: Object) -> Bool { s["dumbbells"]?.object?["none"]?.object?["on"] == .bool(true) }

    public static func settingDumbbells(_ s: inout Object, _ weights: [Double], now: Double) {
        var all = s["dumbbells"]?.object ?? [:]
        all[unit(s)] = .object(["weights": .array(clean(weights).map { .number($0) }), "_ts": .number(now)])
        s["dumbbells"] = .object(all)
    }
    public static func settingNoDumbbells(_ s: inout Object, _ on: Bool, now: Double) {
        var all = s["dumbbells"]?.object ?? [:]
        all["none"] = .object(["on": .bool(on), "_ts": .number(now)])
        s["dumbbells"] = .object(all)
    }

    /// 2 to 50 kg every 2, or 5 to 100 lb every 5 (DB_PRESETS).
    public static func dumbbellPreset(_ s: Object) -> [Double] {
        unit(s) == "lb" ? stride(from: 5.0, through: 100, by: 5).map { $0 } : stride(from: 2.0, through: 50, by: 2).map { $0 }
    }

    static func clean(_ list: [Double]) -> [Double] {
        Array(Set(list.filter { $0.isFinite && $0 > 0 && $0 < 10000 }.map { ($0 * 1000).rounded() / 1000 })).sorted()
    }

    // MARK: Bars

    public static let barTypes = ["barbell", "olympic barbell", "ez barbell", "trap bar", "smith machine"]

    /// The bar a type starts from: yours, else the built-in one.
    public static func barWeight(_ s: Object, _ eq: String) -> Double {
        Session.barDefault(s, eq) ?? builtInBar(s, eq)
    }
    public static func builtInBar(_ s: Object, _ eq: String) -> Double {
        let b = Session.barEquipment[eq] ?? (20, 45)
        return unit(s) == "lb" ? b.lb : b.kg
    }

    /// `eq` set to `w`, or back on the built-in for 0 or the built-in weight (withBarDefault).
    public static func settingBar(_ s: inout Object, _ eq: String, _ w: Double) {
        let u = unit(s)
        var all = s["barDefaults"]?.object ?? [:]
        var mine = all[u]?.object ?? [:]
        let n = (w * 100).rounded() / 100
        if n > 0 && n != builtInBar(s, eq) { mine[eq] = .number(n) } else { mine[eq] = nil }
        all[u] = mine.isEmpty ? nil : .object(mine)
        s["barDefaults"] = all.isEmpty ? nil : .object(all)
    }
}
