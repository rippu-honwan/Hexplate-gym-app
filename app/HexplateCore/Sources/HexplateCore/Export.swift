import Foundation

/// What leaves the app: the workout CSV (lib/export-csv.js workoutsCSV) and daily automatic
/// backups of the document. The JSON export is the state file itself.
public enum Export {
    public typealias Object = [String: JSONValue]

    public static let workoutColumns = ["date", "start_time", "end_time", "workout", "workout_note", "exercise", "exercise_id", "body_part",
                                        "superset_id", "set", "set_type", "side", "weight", "unit", "reps", "rpe", "rir", "distance_km",
                                        "seconds", "incline", "note", "set_note"]

    static func field(_ v: String) -> String {
        var s = v
        if s.range(of: #"^[=+\-@\t\r]"#, options: .regularExpression) != nil && s.range(of: #"^-?\d"#, options: .regularExpression) == nil { s = "'" + s }
        let quote = s.range(of: #"[",\r\n]"#, options: .regularExpression) != nil || s.range(of: #"^\s|\s$"#, options: .regularExpression) != nil
        return quote ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// `String(Math.round(v * 1e6) / 1e6)`, as JavaScript prints it.
    static func n(_ v: JSONValue?) -> String {
        guard let x = v?.numberValue ?? (v?.stringValue).flatMap(Double.init), x.isFinite else { return "" }
        let r = ((x * 1e6) + 0.5).rounded(.down) / 1e6
        return r == r.rounded() && abs(r) < 1e15 ? String(Int64(r)) : String(r)
    }

    static func stamp(_ ms: Double?) -> String {
        guard let ms, ms.isFinite, ms != 0 else { return "" }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    static func distanceKm(_ s: Object) -> String {
        let min = s["min"]?.num ?? 0, speed = s["speed"]?.num ?? 0
        let km = speed * min / 60
        guard km > 0 else { return "0" }
        func jsRound(_ v: Double) -> Double { (v + 0.5).rounded(.down) }
        for d in 2..<6 {
            let p = pow(10, Double(d))
            let r = jsRound(km * p) / p
            if jsRound(r / (min / 60) * 100) == jsRound(speed * 100) { return n(.number(r)) }
        }
        return n(.number(km))
    }

    /// Every completed set of every workout from `from` to `to` (days, either end open), one row
    /// each (drops and sides get their own rows).
    public static func workoutsCSV(_ s: Object, catalog: ExerciseCatalog, from: String? = nil, to: String? = nil) -> String {
        csv(workoutColumns, workoutRows(s, catalog: catalog, from: from, to: to))
    }

    static func csv(_ header: [String], _ rows: [[String]]) -> String {
        "\u{FEFF}" + ([header] + rows).map { $0.map(field).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func inside(_ d: String?, _ from: String?, _ to: String?) -> Bool {
        guard let d, !d.isEmpty else { return false }
        return (from == nil || d >= from!) && (to == nil || d <= to!)
    }

    static func workoutRows(_ s: Object, catalog: ExerciseCatalog, from: String?, to: String?) -> [[String]] {
        let unit = s["unit"] == .string("lb") ? "lb" : "kg"
        let custom = (s["customEx"]?.arrayValue ?? []).compactMap(\.object)
        var rows: [[String]] = []
        let workouts = (s["workouts"]?.arrayValue ?? []).compactMap(\.object)
            .filter { Day.date($0["d"]?.stringValue ?? "") != nil && inside($0["d"]?.stringValue, from, to) }
            .enumerated().sorted { a, b in
                let da = a.element["d"]!.stringValue!, db = b.element["d"]!.stringValue!
                if da != db { return da < db }
                let sa = a.element["start"]?.num ?? 0, sb = b.element["start"]?.num ?? 0
                return sa != sb ? sa < sb : a.offset < b.offset
            }.map(\.element)
        for w in workouts {
            let end = w["end"]?.num ?? 0, start = w["start"]?.num ?? 0
            let head = [w["d"]!.stringValue!, stamp(w["start"]?.numberValue), end > start ? stamp(end) : "", w["name"]?.stringValue ?? "", w["note"]?.stringValue ?? ""]
            var groups: [String: Int] = [:]
            for e in (w["entries"]?.arrayValue ?? []).compactMap(\.object) {
                let id = e["id"]?.stringValue ?? ""
                let mine = custom.first { $0["id"]?.stringValue == id }
                let ex = catalog[id]
                let name = mine.map { $0["n"]?.stringValue ?? id } ?? ex.map(\.displayName) ?? id
                let bodyPart = mine?["bp"]?.stringValue ?? ex?.bodyPart ?? ""
                let sg = e["sg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                if let sg, groups[sg] == nil { groups[sg] = groups.count + 1 }
                let exCells = [name, id, bodyPart, sg.map { "\(groups[$0]!)" } ?? ""]
                var no = 0
                var noteLeft = e["note"]?.stringValue ?? ""
                func push(_ cells: [String], _ setNote: String = "") {
                    rows.append(head + exCells + cells + [noteLeft, setNote])
                    noteLeft = ""
                }
                for set in e["sets"]?.arrayValue ?? [] where Session.hasCompletedWork(set) {
                    guard let o = set.object else { continue }
                    no += 1
                    let type = Session.isWarmup(set) ? "warmup" : o["failure"] == .bool(true) ? "failure" : "normal"
                    var setNote = (o["note"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !((o["r"]?.num ?? 0) > 0) && ((o["min"]?.num ?? 0) > 0 || (o["speed"]?.num ?? 0) > 0) {
                        let secs = ((o["min"]?.num ?? 0) * 60 + 0.5).rounded(.down)
                        push(["\(no)", type, "", "", unit, "", "", "", distanceKm(o), n(.number(secs)), o["incline"].map { $0 == .null ? "" : n($0) } ?? ""], setNote)
                        continue
                    }
                    func one(_ x: Object, _ side: String) {
                        if !side.isEmpty && x["done"] != .bool(true) { return }
                        let timed = (x["sec"]?.num ?? 0) > 0 && !((x["r"]?.num ?? 0) > 0)
                        let effort = [x["rpe"].map { $0 == .null ? "" : n($0) } ?? "", x["rir"].map { $0 == .null ? "" : n($0) } ?? ""]
                        push(["\(no)", type, side, n(.number(x["w"]?.num ?? 0)), unit, timed ? "" : n(.number(x["r"]?.num ?? 0))] + effort + ["", timed ? n(x["sec"]) : "", ""], setNote)
                        setNote = ""
                        let isDrop = x["type"] == .string("dropset")
                        for d in isDrop ? (x["drops"]?.arrayValue ?? []).compactMap(\.object) : [] {
                            push(["\(no)", "drop", side, n(.number(d["w"]?.num ?? 0)), unit, n(.number(d["r"]?.num ?? 0)), "", "", "", "", ""])
                        }
                    }
                    if Session.isSideSet(set), let sides = o["sides"]?.object {
                        one(sides["L"]?.object ?? [:], "L")
                        one(sides["R"]?.object ?? [:], "R")
                    } else {
                        one(o, "")
                    }
                }
            }
        }
        return rows
    }

    // MARK: Body (lib/export-csv.js bodyCSV)

    /// The built-in measurements in openGym's order, as their CSV columns.
    static let measurementColumns: [(key: String, column: String)] = [
        "neck", "shoulders", "chest", "waist", "hips", "abdomen", "upperArmLeft", "upperArmRight", "forearmLeft", "forearmRight",
        "wristLeft", "wristRight", "thighLeft", "thighRight", "calfLeft", "calfRight", "ankleLeft", "ankleRight", "bodyFat",
    ].map { k in (k, k == "bodyFat" ? "body_fat_percent" : k.replacing(/[A-Z]/) { "_" + $0.output.lowercased() } + "_cm") }
    static let customUnits = ["cm", "in", "%", "kg", "lb", "none"]

    /// A weigh-in time as typed, "7:05" read as "07:05"; nil when it is none.
    static func cleanTime(_ v: JSONValue?) -> String? {
        let t = (v?.stringValue ?? v?.numberValue.map { String($0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = t.firstMatch(of: /^(\d{1,2}):(\d{2})/), let h = Int(m.1), let mi = Int(m.2), h <= 23, mi <= 59 else { return nil }
        return String(format: "%02d:", h) + m.2
    }

    /// One row per day, or per weigh-in on a day with several (its time beside the date); the
    /// day's measurements on its first row. Weight in the profile's unit, lengths in cm, custom
    /// fields in their own unit.
    public static func bodyCSV(_ s: Object, from: String? = nil, to: String? = nil) -> String {
        let unit = s["unit"] == .string("lb") ? "lb" : "kg"
        var order: [String] = []
        var days: [String: (rs: [(w: Double, at: String?)], m: Object?)] = [:]
        func touch(_ d: String) { if days[d] == nil { days[d] = ([], nil); order.append(d) } }
        for b in (s["bodyweight"]?.arrayValue ?? []).compactMap(\.object) {
            guard let d = b["d"]?.stringValue, inside(d, from, to), let w = b["w"]?.numberValue, w > 0 else { continue }
            touch(d)
            if let ins = b["ins"]?.arrayValue {
                let rs = ins.compactMap(\.object).enumerated().compactMap { i, r -> (Int, Double, String?, Double)? in
                    guard let id = r["id"], id != .null, let w = r["w"]?.numberValue, w > 0 else { return nil }
                    return (i, w, cleanTime(r["at"]), r["t"]?.numberValue ?? 0)
                }.sorted { a, b in
                    let x = a.2 ?? "", y = b.2 ?? ""
                    return x != y ? x < y : a.3 != b.3 ? a.3 < b.3 : a.0 < b.0
                }
                days[d]!.rs = rs.map { ($0.1, $0.2) }
            } else {
                days[d]!.rs = [(w, nil)]
            }
        }
        for m in (s["measurements"]?.arrayValue ?? []).compactMap(\.object) {
            guard let d = m["d"]?.stringValue, inside(d, from, to) else { continue }
            touch(d)
            days[d]!.m = m
        }
        let present = { (v: JSONValue?) in v != nil && v != .null }
        let fields = measurementColumns.filter { f in days.values.contains { present($0.m?[f.key]) } }
        var defs: [String: Object] = [:]
        for c in (s["customMeasurements"]?.arrayValue ?? []).compactMap(\.object) {
            if let id = c["id"]?.stringValue, !id.isEmpty, defs[id] == nil { defs[id] = c }
        }
        var custom: [(id: String, name: String, unit: String?)] = []
        for d in order {
            for o in (days[d]!.m?["other"]?.arrayValue ?? []).compactMap(\.object) {
                guard let id = o["id"]?.stringValue, !id.isEmpty, present(o["value"]), !custom.contains(where: { $0.id == id }) else { continue }
                let def = defs[id]
                let name = [def?["name"]?.stringValue, o["name"]?.stringValue].compactMap { $0 }.first { !$0.isEmpty } ?? "Other"
                let u = [def?["unit"]?.stringValue, o["unit"]?.stringValue].compactMap { $0 }.first { !$0.isEmpty }
                custom.append((id, name, u))
            }
        }
        let known = { (u: String?) in u.flatMap { customUnits.contains($0) ? $0 : nil } }
        let header = ["date", "weight_" + unit] + fields.map(\.column)
            + custom.map { $0.unit == "none" ? $0.name : "\($0.name) (\(known($0.unit) ?? "cm"))" }
        var rows: [[String]] = []
        for d in order.sorted() {
            let (rs, m) = days[d]!
            let meas = fields.map { present(m?[$0.key]) ? n(m?[$0.key]) : "" } + custom.map { c in
                guard let o = (m?["other"]?.arrayValue ?? []).compactMap(\.object).first(where: { $0["id"]?.stringValue == c.id }),
                      present(o["value"]), let v = o["value"]?.numberValue else { return "" }
                guard let u = known(c.unit) else { return n(.number(v)) }
                let shown = u == "in" ? v / 2.54 : u == "lb" ? v * 2.2046226218 : v
                return n(.number(((shown * 10) + 0.5).rounded(.down) / 10))
            }
            if rs.isEmpty { rows.append([d, ""] + meas); continue }
            for (i, r) in rs.enumerated() {
                rows.append([r.at.map { "\(d) \($0)" } ?? d, n(.number(r.w))] + (i > 0 ? meas.map { _ in "" } : meas))
            }
        }
        return csv(header, rows)
    }

    public struct Counts: Equatable, Sendable { public let workouts, sets, weighIns, measurements: Int }

    /// What each file would hold, for the line under its button.
    public static func counts(_ s: Object, catalog: ExerciseCatalog, from: String? = nil, to: String? = nil) -> Counts {
        let workouts = (s["workouts"]?.arrayValue ?? []).compactMap(\.object).filter { inside($0["d"]?.stringValue, from, to) }.count
        let weighIns = (s["bodyweight"]?.arrayValue ?? []).compactMap(\.object).filter { inside($0["d"]?.stringValue, from, to) && ($0["w"]?.numberValue ?? 0) > 0 }
            .reduce(0) { sum, b in
                let ins = (b["ins"]?.arrayValue ?? []).compactMap(\.object).filter { r in r["id"].map { $0 != .null } ?? false && (r["w"]?.numberValue ?? 0) > 0 }
                return sum + max(1, b["ins"]?.arrayValue != nil ? ins.count : 1)
            }
        let measurements = (s["measurements"]?.arrayValue ?? []).compactMap(\.object).filter { inside($0["d"]?.stringValue, from, to) }.count
        return Counts(workouts: workouts, sets: workoutRows(s, catalog: catalog, from: from, to: to).count, weighIns: weighIns, measurements: measurements)
    }
}

extension StateStore {
    /// Keeps one copy of the document per day in `backups/auto-YYYY-MM-DD.json`, the newest `keep`.
    @discardableResult
    public func autoBackup(today: String, keep: Int = 7) throws -> Bool {
        let fm = FileManager.default
        let folder = directory.appending(path: "backups")
        let url = folder.appending(path: "auto-\(today).json")
        guard !fm.fileExists(atPath: url.path), let current = load() else { return false }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try current.data().write(to: url)
        let autos = try fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("auto-") }.sorted()
        for old in autos.dropLast(keep) { try? fm.removeItem(at: folder.appending(path: old)) }
        return true
    }

    /// The automatic backups, newest first.
    public func backups() -> [URL] {
        let folder = directory.appending(path: "backups")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted(by: >).map { folder.appending(path: $0) }
    }
}

/// Plates per side of a bar (lib/plates.js).
public enum Plates {
    public static let sizes: [String: [Double]] = ["kg": [25, 20, 15, 10, 5, 2.5, 2, 1.5, 1.25, 1, 0.5], "lb": [45, 35, 25, 15, 10, 5, 2.5, 1.25, 1, 0.5]]
    static let uncommon: [String: Set<Double>] = ["kg": [2, 1.5, 1, 0.5], "lb": [15, 1.25, 1, 0.5]]

    /// Owned pairs per plate size, heaviest first: `plates[unit]`, or six pairs of the common sizes.
    public static func inventory(_ s: [String: JSONValue]) -> [(w: Double, n: Int)] {
        let unit = s["unit"] == .string("lb") ? "lb" : "kg"
        let own = (s["plates"]?.object?[unit]?.object ?? [:]).compactMap { k, v -> (Double, Int)? in
            guard let w = Double(k), w > 0 else { return nil }
            let n = Int(v.num.rounded(.down))
            return n > 0 ? (w, n) : nil
        }
        let hasOwn = (s["plates"]?.object?[unit]?.object ?? [:]).keys.contains { (Double($0) ?? 0) > 0 }
        let list = hasOwn ? own : sizes[unit]!.filter { !uncommon[unit]!.contains($0) }.map { ($0, 6) }
        return list.sorted { $0.0 > $1.0 }.map { (w: $0.0, n: $0.1) }
    }

    /// The fewest plates making `weight` from the inventory, and what is left over (plateStack).
    public static func stack(_ weight: Double, _ inv: [(w: Double, n: Int)]) -> (plates: [Double], missing: Double) {
        let q = { (w: Double) in Int((w * 4 + 0.5).rounded(.down)) }
        let requested = max(0, weight)
        let target = Int((requested * 4).rounded(.down))
        if target == 0 { return ([], requested) }
        let items = inv.filter { $0.w > 0 && $0.n > 0 }.sorted { $0.w > $1.w }
        var greedy: [Double] = [], left = target
        for p in items {
            var k = min(p.n, left / q(p.w))
            while k > 0 { greedy.append(p.w); left -= q(p.w); k -= 1 }
        }
        let all = items.reduce(0) { $0 + q($1.w) * $1.n }
        if left == 0 || target >= all { return (greedy, requested - Double(target - left) / 4) }
        let inf = 1_000_000_000, n = items.count
        var f = Array(repeating: Array(repeating: inf, count: target + 1), count: n + 1)
        f[n][0] = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            let unit = q(items[i].w), cap = items[i].n
            for s in 0...target {
                var best = f[i + 1][s]
                var k = 1
                while k <= cap && k * unit <= s { best = min(best, f[i + 1][s - k * unit] + k); k += 1 }
                f[i][s] = best
            }
        }
        var sum = target
        while sum > 0 && f[0][sum] >= inf { sum -= 1 }
        var plates: [Double] = [], s = sum
        for i in 0..<n {
            let unit = q(items[i].w), cap = items[i].n
            for k in stride(from: min(cap, s / unit), through: 0, by: -1) where f[i + 1][s - k * unit] + k == f[i][s] {
                plates += Array(repeating: items[i].w, count: k)
                s -= k * unit
                break
            }
        }
        return (plates, requested - Double(sum) / 4)
    }
}
