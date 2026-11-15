import Foundation

/// Structural balance: how each lift compares with an anchor lift or with body weight, against a
/// strength standard (lib/structuralBalance.js). The standards are bundled as
/// balance-templates.json, written from lib/structuralBalanceTemplates.js by golden.sh.
public enum Balance {
    public typealias Object = [String: JSONValue]

    public struct Role: Decodable, Sendable {
        public let id, label, evaluationMode: String
        public let exerciseIds: [String]
        public let anchorRoleId: String?
        let targetPct, targetPctFemale, repsTarget, repsTargetFemale, reps: Double?
    }
    public struct Template: Decodable, Sendable {
        public let id, label: String
        public let roles: [Role]
    }
    struct File: Decodable { let defaultId: String; let borderlinePct: Double; let templates: [Template] }

    static let file: File = {
        guard let url = Bundle.module.url(forResource: "balance-templates", withExtension: "json"),
              let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) else {
            return File(defaultId: "", borderlinePct: 5, templates: [])
        }
        return f
    }()
    public static var templates: [Template] { file.templates }

    /// The standard this profile chose (`balanceTemplate`), else the default.
    public static func template(_ s: Object) -> Template? {
        let id = s["balanceTemplate"]?.stringValue
        return templates.first { $0.id == id } ?? templates.first { $0.id == file.defaultId }
    }

    public struct Current: Equatable, Sendable {
        /// Estimated one-rep max (load ratio) or the load for the role's reps (body weight ratio), kg.
        public let kg: Double?
        public let w, r: Double
        public let exId, day: String
    }

    public struct Result: Equatable, Sendable {
        public let roleId: String
        public let configuredExerciseId: String?
        public let targetPct: Double
        public let isOverridden: Bool
        public let mappedExerciseId: String?
        public let current: Current?
        public let actualPct: Double?
        /// "balanced", "borderline", "weak" or "no-data".
        public let status: String
        public let needsBodyweight, needsAnchor: Bool
    }

    static let lbToKg = 0.45359237
    static func n(_ v: JSONValue?) -> Double { v?.num ?? 0 }
    static func kgOf(_ v: Double, _ s: Object) -> Double { s["unit"] == .string("lb") ? v * lbToKg : v }

    static func bodyweightKg(_ s: Object) -> Double? {
        let entries = (s["bodyweight"]?.arrayValue ?? []).compactMap(\.object)
        guard let last = entries.sorted(by: { ($0["d"]?.stringValue ?? "") < ($1["d"]?.stringValue ?? "") }).last, n(last["w"]) > 0 else { return nil }
        return kgOf(n(last["w"]), s)
    }

    static let lifterMovement = try! NSRegularExpression(pattern: #"\b(pull[- ]?ups?|chin[- ]?ups?|muscle[- ]?ups?|dips?)\b"#, options: .caseInsensitive)

    /// The lifter's own body is part of the load (body weight work, or a belt on pull-ups and dips).
    static func onLifter(_ e: Object, _ c: ExerciseCatalog) -> Bool {
        if let bw = e["target"]?.object?["bodyweight"] ?? e["bodyweight"], bw != .null { return Session.truthy(bw) }
        let id = e["id"]?.stringValue ?? ""
        if RoutineOps.isBodyweight(["id": .string(id)], catalog: c) { return true }
        guard let ex = c[id], ex.equipment == "weighted", id != "1755" else { return false }
        let r = NSRange(ex.name.startIndex..., in: ex.name)
        return lifterMovement.firstMatch(in: ex.name, range: r) != nil && ex.name.range(of: #"\bbench"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    static func assisted(_ e: Object, _ c: ExerciseCatalog) -> Bool { Session.isAssisted(["id": e["id"] ?? .null], c) }

    static func setLoadKg(_ s: Object, _ w: Object, _ e: Object, _ lift: Object, _ body: Double?, _ c: ExerciseCatalog) -> Double? {
        let logged = kgOf(n(lift["w"]), s)
        let stamped = n(w["bw"]) > 0 ? kgOf(n(w["bw"]), s) : nil
        let b = stamped ?? body
        if assisted(e, c) {
            guard logged > 0, let b, b > 0 else { return nil }
            return b - logged > 0 ? b - logged : nil
        }
        if !onLifter(e, c) { return logged }
        guard let b, b > 0 else { return nil }
        return b + logged
    }

    static func lifts(_ set: JSONValue) -> [Object] {
        guard let o = set.object else { return [] }
        if Session.isSideSet(set), let sides = o["sides"]?.object { return [sides["L"]?.object ?? [:], sides["R"]?.object ?? [:]] }
        return [o]
    }

    static func loadAtReps(_ load: Double, _ setReps: Double, _ reps: Double) -> Double? {
        let r = Session.jsRound(setReps)
        guard load.isFinite, load > 0, r >= 1 else { return nil }
        if r >= reps { return load }
        let oneRm = r == 1 ? load : load * (1 + r / 30)
        return reps > 1 ? oneRm / (1 + reps / 30) : oneRm
    }

    static func unrounded1RM(_ load: Double, _ reps: Double) -> Double? {
        guard Stats.estimate1RM(load, reps) != nil else { return nil }
        return reps == 1 ? load : load * (1 + Session.jsRound(reps) / 30)
    }

    static func workouts(_ s: Object) -> [Object] { (s["workouts"]?.arrayValue ?? []).compactMap(\.object) }
    static func entry(_ w: Object, _ id: String) -> Object? {
        (w["entries"]?.arrayValue ?? []).compactMap(\.object).first { $0["id"]?.stringValue == id }
    }
    static func workSet(_ set: JSONValue) -> Bool { set.object?["done"] == .bool(true) && !Session.isWarmup(set) }

    static func resolveCurrent(_ s: Object, _ ids: [String], _ body: Double?, reps: Double?, _ c: ExerciseCatalog) -> Current? {
        var best: Current?
        for id in ids {
            for w in workouts(s) {
                guard let e = entry(w, id) else { continue }
                for set in e["sets"]?.arrayValue ?? [] where workSet(set) {
                    for lift in lifts(set) {
                        guard let load = setLoadKg(s, w, e, lift, body, c) else { continue }
                        let kg = (reps ?? 0) > 1 ? loadAtReps(load, n(lift["r"]), reps!) : unrounded1RM(load, n(lift["r"]))
                        guard let kg else { continue }
                        if best == nil || kg > best!.kg! {
                            best = Current(kg: kg, w: n(lift["w"]), r: Session.jsRound(n(lift["r"])), exId: id, day: w["d"]?.stringValue ?? "")
                        }
                    }
                }
            }
        }
        return best
    }

    static func resolveCurrentReps(_ s: Object, _ ids: [String], _ c: ExerciseCatalog) -> Current? {
        var best: Current?
        for id in ids {
            for w in workouts(s) {
                guard let e = entry(w, id), !assisted(e, c) else { continue }
                var found: (r: Double, w: Double)?
                for set in e["sets"]?.arrayValue ?? [] where workSet(set) {
                    let o = set.object ?? [:]
                    let sides = o["sides"]?.object
                    let reps = Session.jsRound(Session.isSideSet(set) ? max(n(sides?["L"]?.object?["r"]), n(sides?["R"]?.object?["r"])) : n(o["r"]))
                    guard reps.isFinite, reps >= 1 else { continue }
                    if found == nil || reps > found!.r { found = (reps, n(o["w"])) }
                }
                if let found, best == nil || found.r > best!.r {
                    best = Current(kg: nil, w: found.w, r: found.r, exId: id, day: w["d"]?.stringValue ?? "")
                }
            }
        }
        return best
    }

    public static func overrideKey(_ t: Template, _ role: Role) -> String { "\(t.id):\(role.id)" }

    /// `balanceOverrides` with one role set to `exId`, or back on its default when nil. A clear stays a
    /// stamped `{ id: null }` so a sync keeps whichever choice was made last (withOverride).
    public static func withOverride(_ overrides: JSONValue?, _ key: String, _ exId: String?, now: Double) -> JSONValue {
        var o = overrides?.object ?? [:]
        o[key] = .object(["id": exId.map { .string($0) } ?? .null, "_ts": .number(now)])
        return .object(o)
    }

    static func override(_ s: Object, _ t: Template, _ role: Role) -> String? {
        let v = s["balanceOverrides"]?.object?[overrideKey(t, role)]
        let id = v?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? v?.object?["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return id != nil && id != role.exerciseIds.first ? id : nil
    }

    static func targetFor(_ role: Role, _ s: Object) -> Double {
        let female = s["body"] == .string("female")
        if role.evaluationMode == "rep-count" { return (female ? role.repsTargetFemale : nil) ?? role.repsTarget ?? 0 }
        return (female ? role.targetPctFemale : nil) ?? role.targetPct ?? 0
    }

    static func classify(_ pct: Double?, _ target: Double) -> String {
        guard let pct, pct.isFinite else { return "no-data" }
        if pct >= target - 1e-9 { return "balanced" }
        if pct >= target - file.borderlinePct - 1e-9 { return "borderline" }
        return "weak"
    }

    static func waitsOnBodyweight(_ s: Object, _ role: Role, _ ids: [String], _ current: Current?, _ body: Double?, _ c: ExerciseCatalog) -> Bool {
        if (body ?? 0) > 0 || role.evaluationMode == "rep-count" { return false }
        if current != nil { return role.evaluationMode == "bodyweight-ratio" }
        return workouts(s).contains { w in
            !(n(w["bw"]) > 0) && (w["entries"]?.arrayValue ?? []).compactMap(\.object).contains { e in
                ids.contains(e["id"]?.stringValue ?? "") && (assisted(e, c) || onLifter(e, c))
                    && (e["sets"]?.arrayValue ?? []).contains { workSet($0) && (!assisted(e, c) || kgOf(n($0.object?["w"]), s) > 0) }
            }
        }
    }

    /// Every role of the standard, scored (computeBalance).
    public static func compute(_ s: Object, _ t: Template, catalog c: ExerciseCatalog) -> [Result] {
        let body = bodyweightKg(s)
        var current: [String: Current] = [:]
        for role in t.roles {
            let ids = override(s, t, role).map { [$0] } ?? role.exerciseIds
            current[role.id] = role.evaluationMode == "rep-count"
                ? resolveCurrentReps(s, ids, c)
                : resolveCurrent(s, ids, body, reps: role.evaluationMode == "bodyweight-ratio" ? role.reps : nil, c)
        }
        return t.roles.map { role in
            let cur = current[role.id]
            let target = targetFor(role, s)
            let ov = override(s, t, role)
            let ids = ov.map { [$0] } ?? role.exerciseIds
            let needsBw = waitsOnBodyweight(s, role, ids, cur, body, c)
            guard let cur else {
                return Result(roleId: role.id, configuredExerciseId: ov ?? role.exerciseIds.first, targetPct: target, isOverridden: ov != nil,
                              mappedExerciseId: nil, current: nil, actualPct: nil, status: "no-data", needsBodyweight: needsBw, needsAnchor: false)
            }
            let anchor = role.anchorRoleId.map { current[$0] } ?? cur
            var pct: Double?
            switch role.evaluationMode {
            case "load-ratio":
                if let a = anchor?.kg, a > 0, let k = cur.kg { pct = k / a * 100 }
            case "bodyweight-ratio":
                if let body, body > 0, let k = cur.kg, k > 0 { pct = k / body * 100 }
            default:
                pct = cur.r / target * 100
            }
            let needsAnchor = role.anchorRoleId != nil && role.evaluationMode == "load-ratio" && !((anchor?.kg ?? 0) > 0)
            return Result(roleId: role.id, configuredExerciseId: ov ?? role.exerciseIds.first, targetPct: target, isOverridden: ov != nil,
                          mappedExerciseId: cur.exId, current: cur, actualPct: pct,
                          status: classify(pct, role.evaluationMode == "rep-count" ? 100 : target), needsBodyweight: needsBw, needsAnchor: needsAnchor)
        }
    }
}
