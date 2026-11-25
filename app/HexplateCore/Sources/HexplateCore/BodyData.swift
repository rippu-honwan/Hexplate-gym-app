import Foundation

/// Body data in the document: weigh-ins (`bodyweight`, lib/weigh-ins.js) and measurements
/// (`measurements` + `customMeasurements`, lib/measurements.js). Body composition readings are
/// custom measurements with `scale-` ids, the same ones the original's scale import writes.
public enum BodyData {
    public typealias Object = [String: JSONValue]

    // MARK: Weigh-ins

    /// Adds one reading to its day (weigh-ins.js addWeighIn). A reading at the same clock time on
    /// that day replaces the earlier one. The day's weight follows `bwDaily`: first (default), last or avg.
    @discardableResult
    public static func addWeighIn(_ s: inout Object, day: String, time: String?, weight: Double, at t: Double, id: String) -> Bool {
        let w = (weight * 10 + 0.5).rounded(.down) / 10
        guard w > 0, day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        var days = (s["bodyweight"]?.arrayValue ?? []).compactMap(\.object)
        let reading: Object = ["id": .string(id), "at": time.map(JSONValue.string) ?? .null, "w": .number(w), "t": .number(t)]
        if let i = days.firstIndex(where: { $0["d"]?.stringValue == day }) {
            var d = days[i]
            var ins = d["ins"]?.arrayValue?.compactMap(\.object)
                // ponytail: a legacy day without readings becomes one reading; the original also folds in older edits.
                ?? [["id": .string("legacy"), "at": .null, "w": d["w"] ?? .null, "t": d["t"] ?? .null]]
            if let j = ins.firstIndex(where: { $0["id"]?.stringValue == id || (time != nil && $0["at"]?.stringValue == time) }) {
                let kept = ins[j]["id"]
                ins[j] = reading
                ins[j]["id"] = kept
            } else {
                ins.append(reading)
            }
            d["ins"] = .array(sorted(ins).map(JSONValue.object))
            d["t"] = .number(max(d["t"]?.num ?? 0, t))
            d["w"] = .number(dailyValue(sorted(ins), mode: s["bwDaily"]?.stringValue))
            days[i] = d
        } else {
            days.append(["d": .string(day), "w": .number(w), "t": .number(t), "ins": .array([.object(reading)])])
        }
        days.sort { ($0["d"]?.stringValue ?? "") < ($1["d"]?.stringValue ?? "") }
        s["bodyweight"] = .array(days.map(JSONValue.object))
        return true
    }

    static func sorted(_ ins: [Object]) -> [Object] {
        ins.sorted { a, b in
            let x = a["at"]?.stringValue ?? "", y = b["at"]?.stringValue ?? ""
            return x != y ? x < y : (a["t"]?.num ?? 0) < (b["t"]?.num ?? 0)
        }
    }

    static func dailyValue(_ ins: [Object], mode: String?) -> Double {
        let ws = ins.map { $0["w"]?.num ?? 0 }.filter { $0 > 0 }
        guard let first = ws.first else { return 0 }
        switch mode {
        case "last": return ws.last!
        case "avg": return ((ws.reduce(0, +) / Double(ws.count)) * 100 + 0.5).rounded(.down) / 100
        default: return first
        }
    }

    public struct Reading: Identifiable, Equatable, Sendable {
        public let day: String
        public let weight: Double
        public var id: String { day }
    }

    public static func weights(_ s: Object) -> [Reading] {
        (s["bodyweight"]?.arrayValue ?? []).compactMap { v in
            guard let o = v.object, let d = o["d"]?.stringValue, let w = o["w"]?.numberValue, w > 0 else { return nil }
            return Reading(day: d, weight: w)
        }
    }

    public struct WeekAverage: Equatable, Sendable {
        /// Unrounded mean body weight for `today`'s profile week.
        public let avg: Double
        /// Unrounded difference against the previous profile week's mean (`avg - lastWeekAvg`), nil if last week had no readings.
        public let delta: Double?
    }

    /// Mean body weight in `today`'s profile week (respecting `weekStart`, ignoring readings after `today`)
    /// and change versus the previous profile week. Returns nil when `today` is invalid or `today`'s week has no weigh-ins.
    public static func weekAverage(_ s: Object, today: String) -> WeekAverage? {
        guard Report.valid(today) != nil, let prevDay = Day.adding(-7, to: today) else { return nil }
        let start = Schedule.weekStart(s)
        guard let thisWeek = Schedule.weekKey(today, weekStart: start),
              let lastWeek = Schedule.weekKey(prevDay, weekStart: start) else { return nil }

        var thisSum = 0.0, thisCount = 0
        var lastSum = 0.0, lastCount = 0
        for r in weights(s) {
            guard Report.valid(r.day) != nil, r.day <= today,
                  let wk = Schedule.weekKey(r.day, weekStart: start) else { continue }
            if wk == thisWeek {
                thisSum += r.weight
                thisCount += 1
            } else if wk == lastWeek {
                lastSum += r.weight
                lastCount += 1
            }
        }
        guard thisCount > 0 else { return nil }
        let avg = thisSum / Double(thisCount)
        let delta = lastCount > 0 ? avg - (lastSum / Double(lastCount)) : nil
        return WeekAverage(avg: avg, delta: delta)
    }

    // MARK: Measurements

    public struct Field: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        /// "cm", "%", "kg" or "" (a plain number).
        public let unit: String
    }

    public static let tapeFields: [Field] = [
        ("neck", "Neck"), ("shoulders", "Shoulders"), ("chest", "Chest"), ("waist", "Waist"), ("hips", "Hips"), ("abdomen", "Abdomen"),
        ("upperArmLeft", "Left upper arm"), ("upperArmRight", "Right upper arm"), ("forearmLeft", "Left forearm"), ("forearmRight", "Right forearm"),
        ("wristLeft", "Left wrist"), ("wristRight", "Right wrist"), ("thighLeft", "Left thigh"), ("thighRight", "Right thigh"),
        ("calfLeft", "Left calf"), ("calfRight", "Right calf"), ("ankleLeft", "Left ankle"), ("ankleRight", "Right ankle"),
    ].map { Field(id: $0.0, name: $0.1, unit: "cm") }

    /// What a body composition scale reads (the fields of a Yamato DF870 style scale). Body fat %
    /// is the built-in `bodyFat`; the rest are custom measurements.
    public static let compositionFields: [Field] = [
        Field(id: "bodyFat", name: "Body fat", unit: "%"),
        Field(id: "scale-fatMass", name: "Body fat mass", unit: "kg"),
        Field(id: "scale-visceral", name: "Visceral fat index", unit: ""),
        Field(id: "scale-muscleMass", name: "Muscle mass", unit: "kg"),
        Field(id: "scale-muscle", name: "Skeletal muscle mass", unit: "kg"),
        Field(id: "scale-bone", name: "Bone mass (est.)", unit: "kg"),
        Field(id: "scale-water", name: "Body water", unit: "kg"),
        Field(id: "scale-smi", name: "SMI (kg/m2)", unit: ""),
        Field(id: "scale-bmi", name: "BMI", unit: ""),
        Field(id: "scale-bmr", name: "BMR (kcal)", unit: ""),
        Field(id: "scale-fatArmL", name: "Body fat left arm", unit: "%"),
        Field(id: "scale-fatArmR", name: "Body fat right arm", unit: "%"),
        Field(id: "scale-fatLegL", name: "Body fat left leg", unit: "%"),
        Field(id: "scale-fatLegR", name: "Body fat right leg", unit: "%"),
        Field(id: "scale-fatTrunk", name: "Body fat trunk", unit: "%"),
        Field(id: "scale-muscleArmL", name: "Muscle left arm", unit: "kg"),
        Field(id: "scale-muscleArmR", name: "Muscle right arm", unit: "kg"),
        Field(id: "scale-muscleLegL", name: "Muscle left leg", unit: "kg"),
        Field(id: "scale-muscleLegR", name: "Muscle right leg", unit: "kg"),
        Field(id: "scale-muscleTrunk", name: "Muscle trunk", unit: "kg"),
    ]

    static func storedUnit(_ unit: String) -> JSONValue { .string(unit.isEmpty ? "none" : unit) }

    /// A day's values by field id (built-in keys and custom ids alike).
    public static func values(_ s: Object, day: String) -> [String: Double] {
        guard let e = (s["measurements"]?.arrayValue ?? []).compactMap(\.object).first(where: { $0["d"]?.stringValue == day }) else { return [:] }
        var out: [String: Double] = [:]
        for (k, v) in e where k != "other" && k != "d" && k != "t" { if let x = v.numberValue { out[k] = x } }
        for o in (e["other"]?.arrayValue ?? []).compactMap(\.object) {
            if let id = o["id"]?.stringValue, let x = o["value"]?.numberValue { out[id] = x }
        }
        return out
    }

    /// The latest value of a field and its day.
    public static func latest(_ s: Object, _ id: String) -> (day: String, value: Double)? {
        for e in (s["measurements"]?.arrayValue ?? []).compactMap(\.object).reversed() {
            if let d = e["d"]?.stringValue, let v = values(s, day: d)[id] { return (d, v) }
        }
        return nil
    }

    /// Writes one day's readings: given fields are set, nil clears them, others stay. Custom
    /// fields are registered in `customMeasurements` the first time they are used.
    public static func saveMeasurements(_ s: inout Object, day: String, at t: Double, _ changes: [String: Double?], fields: [Field]) {
        let builtIn = Set(tapeFields.map(\.id) + ["bodyFat"])
        var custom = (s["customMeasurements"]?.arrayValue ?? []).compactMap(\.object)
        for f in fields where !builtIn.contains(f.id) && changes[f.id] != nil && !custom.contains(where: { $0["id"]?.stringValue == f.id }) {
            custom.append(["id": .string(f.id), "name": .string(f.name), "enabled": .bool(true), "unit": storedUnit(f.unit)])
        }
        s["customMeasurements"] = .array(custom.map(JSONValue.object))

        var list = (s["measurements"]?.arrayValue ?? []).compactMap(\.object)
        let i = list.firstIndex { $0["d"]?.stringValue == day }
        var e: Object = i.map { list[$0] } ?? ["d": .string(day)]
        var other = (e["other"]?.arrayValue ?? []).compactMap(\.object)
        for (id, value) in changes {
            let v: JSONValue = value.map(JSONValue.number) ?? .null
            if builtIn.contains(id) { e[id] = v; continue }
            if let j = other.firstIndex(where: { $0["id"]?.stringValue == id }) {
                other[j]["value"] = v
            } else if let f = fields.first(where: { $0.id == id }) {
                other.append(["id": .string(id), "name": .string(f.name), "value": v, "unit": storedUnit(f.unit)])
            }
        }
        e["other"] = .array(other.map(JSONValue.object))
        e["t"] = .number(t)
        if let i { list[i] = e } else { list.append(e) }
        list.sort { ($0["d"]?.stringValue ?? "") < ($1["d"]?.stringValue ?? "") }
        s["measurements"] = .array(list.map(JSONValue.object))
    }

    /// Goal weight (`targetW`), if set.
    public static func goal(_ s: Object) -> Double? { s["targetW"]?.numberValue.flatMap { $0 > 0 ? $0 : nil } }

    // MARK: Body Composition Scans & Anatomical Segment Mapping

    public struct Scan: Identifiable, Equatable, Sendable {
        public let day: String
        public let weight: Double?
        public let bodyFat: Double?
        public let fatMass: Double?
        public let visceralFat: Double?
        public let muscleMass: Double?
        public let skeletalMuscle: Double?
        public let boneMass: Double?
        public let bodyWater: Double?
        public let smi: Double?
        public let bmi: Double?
        public let bmr: Double?
        public let fatArmL: Double?
        public let fatArmR: Double?
        public let fatTrunk: Double?
        public let fatLegL: Double?
        public let fatLegR: Double?
        public let muscleArmL: Double?
        public let muscleArmR: Double?
        public let muscleTrunk: Double?
        public let muscleLegL: Double?
        public let muscleLegR: Double?

        public var id: String { day }

        public var hasSegmentalMuscle: Bool {
            muscleArmL != nil || muscleArmR != nil || muscleTrunk != nil || muscleLegL != nil || muscleLegR != nil
        }

        public var hasSegmentalFat: Bool {
            fatArmL != nil || fatArmR != nil || fatTrunk != nil || fatLegL != nil || fatLegR != nil
        }
    }

    private static let compositionFieldIds = Set(compositionFields.map(\.id))

    /// Single-pass chronological history of days carrying at least one body composition scale reading
    /// (ignoring tape-only measurement days), joined with same-day body weight when available.
    public static func scanHistory(_ s: Object) -> [Scan] {
        let weightByDay = Dictionary(weights(s).map { ($0.day, $0.weight) }, uniquingKeysWith: { _, latest in latest })
        var scans: [Scan] = []
        for entry in (s["measurements"]?.arrayValue ?? []).compactMap(\.object) {
            guard let day = entry["d"]?.stringValue, Report.valid(day) != nil else { continue }
            var vals: [String: Double] = [:]
            if let bf = entry["bodyFat"]?.numberValue, bf.isFinite { vals["bodyFat"] = bf }
            for o in (entry["other"]?.arrayValue ?? []).compactMap(\.object) {
                guard let id = o["id"]?.stringValue, compositionFieldIds.contains(id),
                      let x = o["value"]?.numberValue, x.isFinite else { continue }
                vals[id] = x
            }
            guard !vals.isEmpty else { continue }
            scans.append(Scan(
                day: day,
                weight: weightByDay[day],
                bodyFat: vals["bodyFat"],
                fatMass: vals["scale-fatMass"],
                visceralFat: vals["scale-visceral"],
                muscleMass: vals["scale-muscleMass"],
                skeletalMuscle: vals["scale-muscle"],
                boneMass: vals["scale-bone"],
                bodyWater: vals["scale-water"],
                smi: vals["scale-smi"],
                bmi: vals["scale-bmi"],
                bmr: vals["scale-bmr"],
                fatArmL: vals["scale-fatArmL"],
                fatArmR: vals["scale-fatArmR"],
                fatTrunk: vals["scale-fatTrunk"],
                fatLegL: vals["scale-fatLegL"],
                fatLegR: vals["scale-fatLegR"],
                muscleArmL: vals["scale-muscleArmL"],
                muscleArmR: vals["scale-muscleArmR"],
                muscleTrunk: vals["scale-muscleTrunk"],
                muscleLegL: vals["scale-muscleLegL"],
                muscleLegR: vals["scale-muscleLegR"]
            ))
        }
        return scans.sorted { $0.day < $1.day }
    }

    public enum AnatomicalSide: String, Hashable, Sendable {
        case left
        case right
    }

    public struct PartSide: Hashable, Sendable {
        public let slug: String
        public let side: AnatomicalSide

        public init(slug: String, side: AnatomicalSide) {
            self.slug = slug
            self.side = side
        }
    }

    /// Maps an SVG subpath's horizontal midpoint to the person's anatomical side.
    /// On the front view (facing the viewer), viewer-left (`subpathMidX < boxMidX`) is anatomical right;
    /// on the back view (facing away), viewer-left is anatomical left.
    public static func anatomicalSide(subpathMidX: Double, boxMidX: Double, isFront: Bool) -> AnatomicalSide {
        let viewerLeft = subpathMidX < boxMidX
        if isFront {
            return viewerLeft ? .right : .left
        } else {
            return viewerLeft ? .left : .right
        }
    }

    public enum SegmentMetric: String, CaseIterable, Identifiable, Sendable {
        case muscle
        case fat

        public var id: String { rawValue }
    }

    public struct SegmentShading: Equatable, Sendable {
        /// Whole-slug shading for trunk muscles (avoids midline subpath straddling).
        public let levels: [String: Double]
        /// Per-side shading for bilateral limb muscles (arms and legs).
        public let sideLevels: [PartSide: Double]

        public static let empty = SegmentShading(levels: [:], sideLevels: [:])
    }

    public static let armSlugs = ["deltoids", "biceps", "triceps", "forearm"]
    public static let legSlugs = ["quadriceps", "hamstring", "adductors", "gluteal", "calves", "tibialis", "hip-flexors"]
    public static let trunkSlugs = ["chest", "abs", "obliques", "serratus", "upper-back", "lower-back", "trapezius"]

    /// Computes normalized body-map shading for a scan's segmental muscle (kg) or body fat (%).
    /// Muscle is normalized within each L/R pair (arms L vs R, legs L vs R) so limb asymmetry stays
    /// visible alongside trunk mass; fat shares `%` units across all five regions.
    public static func segmentShading(for scan: Scan, metric: SegmentMetric) -> SegmentShading {
        var levels: [String: Double] = [:]
        var sideLevels: [PartSide: Double] = [:]

        func applyLimbs(_ slugs: [String], left: Double?, right: Double?) {
            for slug in slugs {
                if let left { sideLevels[PartSide(slug: slug, side: .left)] = left }
                if let right { sideLevels[PartSide(slug: slug, side: .right)] = right }
            }
        }

        switch metric {
        case .muscle:
            func pairNormalized(_ l: Double?, _ r: Double?) -> (Double?, Double?) {
                let lv = l.flatMap { $0 > 0 ? $0 : nil }
                let rv = r.flatMap { $0 > 0 ? $0 : nil }
                let hi = max(lv ?? 0, rv ?? 0)
                guard hi > 0 else { return (nil, nil) }
                func scale(_ v: Double?) -> Double? {
                    guard let v else { return nil }
                    let ratio = v / hi
                    return 0.30 + 0.70 * min(1, max(0, (ratio - 0.5) / 0.5))
                }
                return (scale(lv), scale(rv))
            }

            let arms = pairNormalized(scan.muscleArmL, scan.muscleArmR)
            applyLimbs(armSlugs, left: arms.0, right: arms.1)

            let legs = pairNormalized(scan.muscleLegL, scan.muscleLegR)
            applyLimbs(legSlugs, left: legs.0, right: legs.1)

            if let trunk = scan.muscleTrunk, trunk > 0 {
                let trunkLevel: Double
                if let total = scan.muscleMass, total > 0 {
                    trunkLevel = min(0.90, max(0.35, (trunk / total) * 1.4))
                } else {
                    trunkLevel = 0.75
                }
                for slug in trunkSlugs { levels[slug] = trunkLevel }
            }

        case .fat:
            let all = [scan.fatArmL, scan.fatArmR, scan.fatTrunk, scan.fatLegL, scan.fatLegR].compactMap { $0 }.filter { $0 > 0 }
            guard let lo = all.min(), let hi = all.max() else { return .empty }
            func scale(_ v: Double?) -> Double? {
                guard let v, v > 0 else { return nil }
                guard hi - lo >= 0.01 else { return 0.75 }
                return 0.30 + 0.70 * ((v - lo) / (hi - lo))
            }

            applyLimbs(armSlugs, left: scale(scan.fatArmL), right: scale(scan.fatArmR))
            applyLimbs(legSlugs, left: scale(scan.fatLegL), right: scale(scan.fatLegR))
            if let trunk = scale(scan.fatTrunk) {
                for slug in trunkSlugs { levels[slug] = trunk }
            }
        }

        return SegmentShading(levels: levels, sideLevels: sideLevels)
    }
}
