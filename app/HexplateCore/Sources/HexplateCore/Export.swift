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

    /// Every completed set of every workout, one row each (drops and sides get their own rows).
    public static func workoutsCSV(_ s: Object, catalog: ExerciseCatalog) -> String {
        let unit = s["unit"] == .string("lb") ? "lb" : "kg"
        let custom = (s["customEx"]?.arrayValue ?? []).compactMap(\.object)
        var rows: [[String]] = []
        let workouts = (s["workouts"]?.arrayValue ?? []).compactMap(\.object)
            .filter { Day.date($0["d"]?.stringValue ?? "") != nil }
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
        let lines = ([workoutColumns] + rows).map { $0.map(field).joined(separator: ",") }
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
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
