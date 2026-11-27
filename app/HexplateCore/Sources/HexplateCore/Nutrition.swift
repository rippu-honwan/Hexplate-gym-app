import Foundation

/// Nutrition tracking in the state document:
/// - `meals`: `{ "<id>": { id, date, time?, mealType?, name, kcal?, protein?, carbs?, fat?, source, photoId?, _ts } | { deleted: true, photoId?, _ts } }`
///   merged per-entry LWW in Swift by `HexMerge` and stamped by `HexStamps`.
/// - `nutritionGoals`: `{ kcal?, protein?, carbs?, fat?, proteinPerKg? }` storing only user overrides
///   (reset writes `{}` so whole-key LWW in `sync.js` propagates the reset across devices).
public enum Nutrition {
    public typealias Object = [String: JSONValue]

    public static let defaultProteinPerKg: Double = 2.0
    public static let kgPerLb: Double = 0.45359237

    public enum Source: String, Codable, Equatable, Sendable {
        case manual
        case photo
    }

    public enum MealType: String, CaseIterable, Codable, Identifiable, Sendable {
        case breakfast
        case lunch
        case afternoonTea = "afternoon_tea"
        case dinner
        case lateNight = "late_night"

        public var id: String { rawValue }

        /// Suggests a default meal type from a 24-hour local clock hour (`0...23`).
        public static func suggested(forHour hour: Int) -> MealType {
            switch hour {
            case 5...10: .breakfast
            case 11...13: .lunch
            case 14...16: .afternoonTea
            case 17...20: .dinner
            default: .lateNight
            }
        }
    }

    public enum Period: String, CaseIterable, Identifiable, Sendable {
        case week = "1W"
        case month = "1M"
        case sixMonths = "6M"

        public var id: String { rawValue }

        public var days: Int {
            switch self {
            case .week: 7
            case .month: 30
            case .sixMonths: 180
            }
        }
    }

    public enum Metric: String, CaseIterable, Identifiable, Sendable {
        case kcal
        case protein
        case carbs
        case fat

        public var id: String { rawValue }
    }

    public struct Meal: Identifiable, Codable, Equatable, Sendable {
        public var id: String
        public var date: String
        public var time: String?
        // ponytail: synthesized Codable inside `health-outbox.json`; if an older app build ever
        // reads an unknown raw `mealType` from the outbox file, decode falls back to `[]` and
        // `recentRepairPlan` self-heals the last 14 days on foreground sync.
        public var mealType: MealType?
        public var name: String
        public var kcal: Double?
        public var protein: Double?
        public var carbs: Double?
        public var fat: Double?
        public var source: Source
        public var photoId: String?
        public var ts: Double

        public init(
            id: String,
            date: String,
            time: String? = nil,
            mealType: MealType? = nil,
            name: String,
            kcal: Double? = nil,
            protein: Double? = nil,
            carbs: Double? = nil,
            fat: Double? = nil,
            source: Source = .manual,
            photoId: String? = nil,
            ts: Double = 0
        ) {
            self.id = id
            self.date = date
            self.time = time
            self.mealType = mealType
            self.name = name
            self.kcal = kcal
            self.protein = protein
            self.carbs = carbs
            self.fat = fat
            self.source = source
            self.photoId = photoId
            self.ts = ts
        }
    }

    /// User-set goal overrides persisted under `nutritionGoals`.
    public struct Goals: Equatable, Sendable {
        public var kcal: Double?
        public var protein: Double?
        public var carbs: Double?
        public var fat: Double?
        public var proteinPerKg: Double?

        public init(
            kcal: Double? = nil,
            protein: Double? = nil,
            carbs: Double? = nil,
            fat: Double? = nil,
            proteinPerKg: Double? = nil
        ) {
            self.kcal = kcal
            self.protein = protein
            self.carbs = carbs
            self.fat = fat
            self.proteinPerKg = proteinPerKg
        }

        public var isEmpty: Bool {
            kcal == nil && protein == nil && carbs == nil && fat == nil && proteinPerKg == nil
        }
    }

    /// Resolved daily goals with dynamic bodyweight-based protein when no explicit protein override exists.
    public struct EffectiveGoals: Equatable, Sendable {
        public let kcal: Double?
        public let protein: Double?
        public let proteinIsDerived: Bool
        public let carbs: Double?
        public let fat: Double?
        public let proteinPerKg: Double
        public let weightKgUsed: Double?

        public func value(for metric: Metric) -> Double? {
            switch metric {
            case .kcal: kcal
            case .protein: protein
            case .carbs: carbs
            case .fat: fat
            }
        }
    }

    public struct Macros: Codable, Equatable, Sendable {
        public var kcal: Double
        public var protein: Double
        public var carbs: Double
        public var fat: Double

        public init(kcal: Double = 0, protein: Double = 0, carbs: Double = 0, fat: Double = 0) {
            self.kcal = kcal
            self.protein = protein
            self.carbs = carbs
            self.fat = fat
        }

        public static let zero = Macros()

        public var isNonZero: Bool {
            kcal > 0 || protein > 0 || carbs > 0 || fat > 0
        }

        public static func + (lhs: Macros, rhs: Macros) -> Macros {
            Macros(
                kcal: lhs.kcal + rhs.kcal,
                protein: lhs.protein + rhs.protein,
                carbs: lhs.carbs + rhs.carbs,
                fat: lhs.fat + rhs.fat
            )
        }

        public func value(for metric: Metric) -> Double {
            switch metric {
            case .kcal: kcal
            case .protein: protein
            case .carbs: carbs
            case .fat: fat
            }
        }
    }

    public struct DailyTotals: Identifiable, Equatable, Sendable {
        public let day: String
        public let hexplate: Macros
        /// Live external HealthKit totals for this day; `nil` when Health is off, locked, or unavailable.
        public let external: Macros?
        public let mealCount: Int
        /// Contiguous calendar-day segment index so Swift Charts `LineMark` breaks across missing days.
        public let run: Int

        public var id: String { day }
        public var total: Macros { hexplate + (external ?? .zero) }
    }

    // MARK: - HealthKit Meal-Sync Model (Pure Planning)

    public enum Nutrient: String, CaseIterable, Codable, Equatable, Sendable {
        case kcal
        case protein
        case carbs
        case fat

        public static let syncIdPrefix = "hexplate.meal."

        public func syncId(mealId: String) -> String {
            "\(Self.syncIdPrefix)\(mealId).\(rawValue)"
        }

        public static func isHexplateSyncId(_ id: String?) -> Bool {
            id?.hasPrefix(syncIdPrefix) == true
        }

        public func value(in meal: Meal) -> Double? {
            switch self {
            case .kcal: Nutrition.positive(meal.kcal)
            case .protein: Nutrition.positive(meal.protein)
            case .carbs: Nutrition.positive(meal.carbs)
            case .fat: Nutrition.positive(meal.fat)
            }
        }
    }

    public struct HealthSyncOp: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Equatable, Sendable {
            case upsert
            case delete
        }

        public let mealId: String
        public let kind: Kind
        public let ts: Double
        public let meal: Meal?

        public static func upsert(_ meal: Meal) -> HealthSyncOp {
            HealthSyncOp(mealId: meal.id, kind: .upsert, ts: meal.ts, meal: meal)
        }

        public static func delete(mealId: String, ts: Double) -> HealthSyncOp {
            HealthSyncOp(mealId: mealId, kind: .delete, ts: ts, meal: nil)
        }

        /// Maintains at most one pending op per `mealId`, keeping the higher timestamp (delete wins equal-ts ties).
        public static func coalesce(_ existing: [HealthSyncOp], adding op: HealthSyncOp) -> [HealthSyncOp] {
            var out = existing
            if let idx = out.firstIndex(where: { $0.mealId == op.mealId }) {
                let prev = out[idx]
                if op.ts > prev.ts || (op.ts == prev.ts && op.kind == .delete) {
                    out[idx] = op
                }
            } else {
                out.append(op)
            }
            return out
        }

        /// Reconciles `current` outbox contents after flushing `batch` where `failed` ops did not succeed.
        /// Keeps all `failed` ops plus any new or superseding ops enqueued mid-flush, while dropping
        /// `batch` ops that succeeded and were not replaced during the await.
        public static func reconcileAfterFlush(
            batch: [HealthSyncOp],
            failed: [HealthSyncOp],
            current: [HealthSyncOp]
        ) -> [HealthSyncOp] {
            let batchById = Dictionary(uniqueKeysWithValues: batch.map { ($0.mealId, $0) })
            var out = failed
            for op in current {
                if let sent = batchById[op.mealId], sent == op {
                    continue
                }
                out = coalesce(out, adding: op)
            }
            return out
        }
    }

    /// Last HealthKit operation confirmed written for a meal ID (persisted in `health-pushed.json`).
    public struct PushedEntry: Codable, Equatable, Sendable {
        public let kind: HealthSyncOp.Kind
        public let ts: Double

        public init(kind: HealthSyncOp.Kind, ts: Double) {
            self.kind = kind
            self.ts = ts
        }
    }

    // MARK: - Validation Helpers

    public static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Normalizes `"H:mm"` or `"HH:mm"` into `"HH:mm"`; returns `nil` when invalid or empty.
    public static func cleanTime(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = trimmed.firstMatch(of: /^(\d{1,2}):(\d{2})$/),
              let hour = Int(m.1), let minute = Int(m.2),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    // MARK: - Meal CRUD

    /// Reads one live meal by ID, or `nil` if absent, tombstoned, or malformed.
    public static func meal(_ s: Object, id: String) -> Meal? {
        guard let obj = s["meals"]?.object?[id]?.object else { return nil }
        return parseMeal(id: id, obj)
    }

    /// All live meals with valid dates, sorted chronologically (`date`, `time`, `ts`, `id`).
    public static func meals(_ s: Object) -> [Meal] {
        guard let map = s["meals"]?.object else { return [] }
        return map.compactMap { key, val in
            guard let obj = val.object else { return nil }
            return parseMeal(id: key, obj)
        }.sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            let ta = a.time ?? "", tb = b.time ?? ""
            if ta != tb { return ta < tb }
            if a.ts != b.ts { return a.ts < b.ts }
            return a.id < b.id
        }
    }

    public static func meals(_ s: Object, on day: String) -> [Meal] {
        guard Report.valid(day) != nil else { return [] }
        return meals(s).filter { $0.date == day }
    }

    public static func meals(_ s: Object, from: String, to: String) -> [Meal] {
        guard Report.valid(from) != nil, Report.valid(to) != nil, from <= to else { return [] }
        return meals(s).filter { $0.date >= from && $0.date <= to }
    }

    /// Inline tombstones retained in `meals` (used for bounded HealthKit delete repair and photo GC).
    public static func tombstonedMeals(_ s: Object) -> [(id: String, ts: Double, photoId: String?)] {
        guard let map = s["meals"]?.object else { return [] }
        return map.compactMap { key, val in
            guard let obj = val.object, obj["deleted"] == .bool(true) else { return nil }
            let ts = obj["_ts"]?.num ?? 0
            let photoId = obj["photoId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return (id: key, ts: ts, photoId: photoId)
        }.sorted { a, b in
            a.ts != b.ts ? a.ts < b.ts : a.id < b.id
        }
    }

    /// Inserts or updates a live meal in `s["meals"]`. `StateDocument.change` -> `HexStamps.stampMeals`
    /// stamps `_ts` on content change and leaves unchanged entries untouched.
    @discardableResult
    public static func upsertMeal(_ s: inout Object, _ meal: Meal) -> Bool {
        let id = meal.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, Report.valid(meal.date) != nil else { return false }

        let name = meal.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var obj: Object = [
            "id": .string(id),
            "date": .string(meal.date),
            "name": .string(name),
            "source": .string(meal.source.rawValue),
        ]
        if let time = cleanTime(meal.time) { obj["time"] = .string(time) }
        if let mealType = meal.mealType { obj["mealType"] = .string(mealType.rawValue) }
        if let kcal = positive(meal.kcal) { obj["kcal"] = .number(kcal) }
        if let protein = positive(meal.protein) { obj["protein"] = .number(protein) }
        if let carbs = positive(meal.carbs) { obj["carbs"] = .number(carbs) }
        if let fat = positive(meal.fat) { obj["fat"] = .number(fat) }
        if let photoId = meal.photoId?.trimmingCharacters(in: .whitespacesAndNewlines), !photoId.isEmpty {
            obj["photoId"] = .string(photoId)
        }

        var map = s["meals"]?.object ?? [:]
        if let existingTs = map[id]?.object?["_ts"], existingTs != .null {
            obj["_ts"] = existingTs
        } else if meal.ts > 0 {
            obj["_ts"] = .number(meal.ts)
        }
        map[id] = .object(obj)
        s["meals"] = .object(map)
        return true
    }

    /// Marks a live meal deleted via an inline tombstone (preserving `photoId` so local photo files
    /// survive concurrent LWW edits or undo until tombstone TTL expires).
    @discardableResult
    public static func deleteMeal(_ s: inout Object, id: String) -> Bool {
        guard var map = s["meals"]?.object,
              let existing = map[id]?.object,
              existing["deleted"] != .bool(true) else { return false }
        var tombstone: Object = ["deleted": .bool(true)]
        if let photoId = existing["photoId"]?.stringValue, !photoId.isEmpty {
            tombstone["photoId"] = .string(photoId)
        }
        map[id] = .object(tombstone)
        s["meals"] = .object(map)
        return true
    }

    /// All `photoId` tokens referenced by either live meals or retained tombstones.
    public static func referencedPhotoIds(_ s: Object) -> Set<String> {
        guard let map = s["meals"]?.object else { return [] }
        var ids = Set<String>()
        for value in map.values {
            if let pid = value.object?["photoId"]?.stringValue, !pid.isEmpty {
                ids.insert(pid)
            }
        }
        return ids
    }

    // MARK: - Goals

    public static func goals(_ s: Object) -> Goals {
        guard let obj = s["nutritionGoals"]?.object else { return Goals() }
        return Goals(
            kcal: positive(obj["kcal"]?.numberValue),
            protein: positive(obj["protein"]?.numberValue),
            carbs: positive(obj["carbs"]?.numberValue),
            fat: positive(obj["fat"]?.numberValue),
            proteinPerKg: positive(obj["proteinPerKg"]?.numberValue)
        )
    }

    /// Writes `nutritionGoals` as a concrete object (writing `{}` on reset so `edited["nutritionGoals"]`
    /// propagates the cleared goals cleanly through whole-key LWW in `sync.js`).
    public static func setGoals(_ s: inout Object, _ goals: Goals) {
        var obj: Object = [:]
        if let v = positive(goals.kcal) { obj["kcal"] = .number(v) }
        if let v = positive(goals.protein) { obj["protein"] = .number(v) }
        if let v = positive(goals.carbs) { obj["carbs"] = .number(v) }
        if let v = positive(goals.fat) { obj["fat"] = .number(v) }
        if let v = positive(goals.proteinPerKg) { obj["proteinPerKg"] = .number(v) }
        s["nutritionGoals"] = .object(obj)
    }

    /// Computes effective daily goals, deriving default protein dynamically from the latest bodyweight
    /// (converted from `lb` to `kg` when `unit == "lb"`).
    public static func effectiveGoals(_ s: Object) -> EffectiveGoals {
        let g = goals(s)
        let perKg = g.proteinPerKg ?? defaultProteinPerKg
        let latestWeight = BodyData.weights(s).last?.weight
        let weightKg: Double? = latestWeight.map { s["unit"] == .string("lb") ? $0 * kgPerLb : $0 }

        let protein: Double?
        let derived: Bool
        if let explicit = g.protein {
            protein = explicit
            derived = false
        } else if let weightKg {
            protein = (weightKg * perKg).rounded()
            derived = true
        } else {
            protein = nil
            derived = false
        }

        return EffectiveGoals(
            kcal: g.kcal,
            protein: protein,
            proteinIsDerived: derived,
            carbs: g.carbs,
            fat: g.fat,
            proteinPerKg: perKg,
            weightKgUsed: weightKg
        )
    }

    // MARK: - Aggregation & Trends

    public static func periodRange(_ period: Period, today: String) -> (from: String, to: String)? {
        guard Report.valid(today) != nil,
              let from = Day.adding(-(period.days - 1), to: today) else { return nil }
        return (from, today)
    }

    public static func dailyTotals(_ s: Object, day: String, external: Macros? = nil) -> DailyTotals {
        let dayMeals = meals(s, on: day)
        let hex = sum(dayMeals)
        return DailyTotals(day: day, hexplate: hex, external: external, mealCount: dayMeals.count, run: 0)
    }

    /// Chronological daily totals across `period` ending on `today`. Includes only days with at least
    /// one Hexplate meal or non-zero external HealthKit total, assigning contiguous-day `run` IDs so
    /// Swift Charts `LineMark` leaves honest gaps over unlogged days.
    public static func dailySeries(
        _ s: Object,
        period: Period,
        today: String,
        externalByDay: [String: Macros]? = nil
    ) -> [DailyTotals] {
        guard let range = periodRange(period, today: today) else { return [] }
        let grouped = Dictionary(grouping: meals(s, from: range.from, to: range.to), by: \.date)
        var days = Set(grouped.keys)
        if let externalByDay {
            for (day, macros) in externalByDay where day >= range.from && day <= range.to && macros.isNonZero {
                days.insert(day)
            }
        }
        let sortedDays = days.sorted()
        var out: [DailyTotals] = []
        var prevDay: String?
        var run = 0
        for day in sortedDays {
            if let prev = prevDay, Day.adding(1, to: prev) != day {
                run += 1
            }
            let dayMeals = grouped[day] ?? []
            let ext: Macros? = externalByDay.map { $0[day] ?? .zero }
            out.append(DailyTotals(day: day, hexplate: sum(dayMeals), external: ext, mealCount: dayMeals.count, run: run))
            prevDay = day
        }
        return out
    }

    // MARK: - Bounded Foreground HealthKit Repair Planner

    /// Computes the minimal delta of HealthKit upserts (live meals in the last `days` ending `today`)
    /// and deletes (retained tombstones) not yet confirmed in `pushed`.
    public static func recentRepairPlan(
        _ s: Object,
        today: String,
        days: Int = 14,
        pushed: [String: PushedEntry]
    ) -> [HealthSyncOp] {
        guard days > 0, Report.valid(today) != nil,
              let cutoff = Day.adding(-(days - 1), to: today) else { return [] }

        var ops: [HealthSyncOp] = []
        for m in meals(s, from: cutoff, to: today) where m.ts > 0 {
            if let entry = pushed[m.id], m.ts < entry.ts || (m.ts == entry.ts && entry.kind == .upsert) {
                continue
            }
            ops.append(.upsert(m))
        }
        for t in tombstonedMeals(s) where t.ts > 0 {
            if let entry = pushed[t.id], t.ts < entry.ts || (t.ts == entry.ts && entry.kind == .delete) {
                continue
            }
            ops.append(.delete(mealId: t.id, ts: t.ts))
        }
        return ops
    }

    /// Drops ledger entries whose meal IDs are no longer present in `s["meals"]` (e.g. aged-out tombstones).
    public static func prunedPushedLedger(_ pushed: [String: PushedEntry], against s: Object) -> [String: PushedEntry] {
        guard let map = s["meals"]?.object else { return [:] }
        return pushed.filter { map[$0.key] != nil }
    }

    // MARK: - Internals

    private static func parseMeal(id key: String, _ obj: Object) -> Meal? {
        guard obj["deleted"] != .bool(true) else { return nil }
        let id = (obj["id"]?.stringValue ?? key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              let date = obj["date"]?.stringValue,
              Report.valid(date) != nil else { return nil }
        let source = obj["source"]?.stringValue.flatMap(Source.init(rawValue:)) ?? .manual
        let mealType = obj["mealType"]?.stringValue.flatMap(MealType.init(rawValue:))
        return Meal(
            id: id,
            date: date,
            time: cleanTime(obj["time"]?.stringValue),
            mealType: mealType,
            name: obj["name"]?.stringValue ?? "",
            kcal: positive(obj["kcal"]?.numberValue),
            protein: positive(obj["protein"]?.numberValue),
            carbs: positive(obj["carbs"]?.numberValue),
            fat: positive(obj["fat"]?.numberValue),
            source: source,
            photoId: obj["photoId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            ts: obj["_ts"]?.num ?? 0
        )
    }

    private static func sum(_ list: [Meal]) -> Macros {
        list.reduce(.zero) { acc, m in
            Macros(
                kcal: acc.kcal + (m.kcal ?? 0),
                protein: acc.protein + (m.protein ?? 0),
                carbs: acc.carbs + (m.carbs ?? 0),
                fat: acc.fat + (m.fat ?? 0)
            )
        }
    }
}
