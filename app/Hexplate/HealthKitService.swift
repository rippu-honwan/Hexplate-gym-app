import Foundation
import HealthKit
import HexplateCore
import Observation
import UIKit

enum HealthAuthStatus: Equatable, Sendable {
    case unavailable
    case shouldRequest
    case unnecessary
    case unknown
}

struct NutritionSource: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct ExternalMealSummary: Identifiable, Equatable, Sendable {
    let id: String
    let day: String
    let time: String?
    let name: String
    let sourceName: String
    let sourceBundleId: String
    let macros: Nutrition.Macros
}

/// Protocol abstracting Apple Health reads and writes behind Swift 6 actor isolation.
protocol HealthReading: Sendable {
    var isAvailable: Bool { get }
    func authorizationRequestStatus() async -> HealthAuthStatus
    func requestAuthorization() async -> Bool
    func hasAnyDietaryWriteAuthorization() async -> Bool
    func saveWeight(_ weight: Double, unit: String, at date: Date) async
    func saveWorkout(start: Date, end: Date) async
    func readWeights(unit: String, days: Int) async -> [(date: Date, weight: Double)]
    func startWatchStrengthWorkout() async throws -> Bool
    func readExternalNutritionSeries(from: String, to: String, excludedBundleIds: Set<String>) async -> [String: Nutrition.Macros]?
    func readExternalMeals(on day: String, excludedBundleIds: Set<String>) async -> [ExternalMealSummary]?
    func readReadinessSignals(today: String, now: Date) async -> Readiness.HealthSignals?
    func nutritionSources() async -> [NutritionSource]
    func applyMealOp(_ op: Nutrition.HealthSyncOp) async throws
}

/// Real Apple HealthKit client isolated on its own actor.
actor HealthClient: HealthReading {
    private let store = HKHealthStore()

    private static let bodyMass = HKQuantityType(.bodyMass)
    private static let energy = HKQuantityType(.dietaryEnergyConsumed)
    private static let protein = HKQuantityType(.dietaryProtein)
    private static let carbs = HKQuantityType(.dietaryCarbohydrates)
    private static let fat = HKQuantityType(.dietaryFatTotal)
    private static let hrv = HKQuantityType(.heartRateVariabilitySDNN)
    private static let restingHR = HKQuantityType(.restingHeartRate)
    private static let sleep = HKCategoryType(.sleepAnalysis)

    private static var shareTypes: Set<HKSampleType> {
        [bodyMass, .workoutType(), energy, protein, carbs, fat]
    }

    private static var readTypes: Set<HKObjectType> {
        [bodyMass, energy, protein, carbs, fat, hrv, restingHR, sleep]
    }

    private static let dietarySpecs: [(nutrient: Nutrition.Nutrient, type: HKQuantityType, unit: HKUnit)] = [
        (.kcal, energy, .kilocalorie()),
        (.protein, protein, .gram()),
        (.carbs, carbs, .gram()),
        (.fat, fat, .gram()),
    ]

    nonisolated var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func authorizationRequestStatus() async -> HealthAuthStatus {
        guard isAvailable else { return .unavailable }
        do {
            let status = try await store.statusForAuthorizationRequest(toShare: Self.shareTypes, read: Self.readTypes)
            return switch status {
            case .shouldRequest: .shouldRequest
            case .unnecessary: .unnecessary
            case .unknown: .unknown
            @unknown default: .unknown
            }
        } catch {
            return .unknown
        }
    }

    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: Self.shareTypes, read: Self.readTypes)
            return true
        } catch {
            return false
        }
    }

    func hasAnyDietaryWriteAuthorization() async -> Bool {
        guard isAvailable else { return false }
        return Self.dietarySpecs.contains { store.authorizationStatus(for: $0.type) == .sharingAuthorized }
    }

    func saveWeight(_ weight: Double, unit: String, at date: Date) async {
        guard isAvailable, weight > 0 else { return }
        guard store.authorizationStatus(for: Self.bodyMass) == .sharingAuthorized else { return }
        let quantity = HKQuantity(unit: unit == "lb" ? .pound() : .gramUnit(with: .kilo), doubleValue: weight)
        let sample = HKQuantitySample(type: Self.bodyMass, quantity: quantity, start: date, end: date)
        try? await store.save(sample)
    }

    func saveWorkout(start: Date, end: Date) async {
        guard isAvailable, end > start else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        do {
            try await builder.beginCollection(at: start)
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch {}
    }

    func readWeights(unit: String, days: Int = 90) async -> [(date: Date, weight: Double)] {
        guard isAvailable else { return [] }
        let from = Calendar.current.date(byAdding: .day, value: -days, to: .now)
        let query = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: Self.bodyMass, predicate: HKQuery.predicateForSamples(withStart: from, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples = (try? await query.result(for: store)) ?? []
        let hkUnit: HKUnit = unit == "lb" ? .pound() : .gramUnit(with: .kilo)
        return samples.map { ($0.startDate, $0.quantity.doubleValue(for: hkUnit)) }
    }

    /// Requests workout share permission, builds the `HKWorkoutConfiguration` inside the actor,
    /// and asks watchOS to launch the companion workout app. Returns whether workout sharing was authorized.
    func startWatchStrengthWorkout() async throws -> Bool {
        guard isAvailable else { return false }
        try? await store.requestAuthorization(toShare: [.workoutType()], read: [])
        let allowed = store.authorizationStatus(for: .workoutType()) == .sharingAuthorized
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        try await store.startWatchApp(toHandle: config)
        return allowed
    }

    func nutritionSources() async -> [NutritionSource] {
        guard isAvailable else { return [] }
        let ownBundle = Bundle.main.bundleIdentifier
        var seen: [String: String] = [:]
        for spec in Self.dietarySpecs {
            let descriptor = HKSourceQueryDescriptor(predicate: .quantitySample(type: spec.type))
            guard let sources = try? await descriptor.result(for: store) else { continue }
            for source in sources {
                let bid = source.bundleIdentifier
                if bid == ownBundle || bid.isEmpty { continue }
                if seen[bid] == nil {
                    seen[bid] = source.name.isEmpty ? bid : source.name
                }
            }
        }
        return seen.map { NutritionSource(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Scalable daily external nutrition totals via `HKStatisticsCollectionQueryDescriptor`,
    /// excluding Hexplate's own `Bundle.main` source and user-excluded third-party sources.
    /// Returns `nil` when HealthKit is unavailable or throws (e.g. device locked).
    func readExternalNutritionSeries(
        from: String,
        to: String,
        excludedBundleIds: Set<String>
    ) async -> [String: Nutrition.Macros]? {
        guard isAvailable,
              let startDate = Self.localStartOfDay(from),
              let toStart = Self.localStartOfDay(to),
              let endDate = Calendar.current.date(byAdding: .day, value: 1, to: toStart) else {
            return nil
        }

        let excludedIds = excludedBundleIds.union(Bundle.main.bundleIdentifier.map { [$0] } ?? [])
        var byDay: [String: Nutrition.Macros] = [:]

        do {
            for spec in Self.dietarySpecs {
                let sourceDescriptor = HKSourceQueryDescriptor(predicate: .quantitySample(type: spec.type))
                let allSources = try await sourceDescriptor.result(for: store)
                let excludedSources = Set(allSources.filter { excludedIds.contains($0.bundleIdentifier) })

                let datePredicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
                let predicate: NSPredicate
                if excludedSources.isEmpty {
                    predicate = datePredicate
                } else {
                    let notExcluded = NSCompoundPredicate(
                        notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: excludedSources)
                    )
                    predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate, notExcluded])
                }

                let descriptor = HKStatisticsCollectionQueryDescriptor(
                    predicate: .quantitySample(type: spec.type, predicate: predicate),
                    options: .cumulativeSum,
                    anchorDate: startDate,
                    intervalComponents: DateComponents(day: 1)
                )
                let collection = try await descriptor.result(for: store)
                collection.enumerateStatistics(from: startDate, to: toStart) { stats, _ in
                    guard let sum = stats.sumQuantity()?.doubleValue(for: spec.unit), sum > 0 else { return }
                    let day = Day.iso(stats.startDate)
                    var macros = byDay[day] ?? .zero
                    switch spec.nutrient {
                    case .kcal: macros.kcal += sum
                    case .protein: macros.protein += sum
                    case .carbs: macros.carbs += sum
                    case .fat: macros.fat += sum
                    }
                    byDay[day] = macros
                }
            }
            return byDay
        } catch {
            return nil
        }
    }

    /// Single-day external meal rows via `HKSampleQueryDescriptor`, applying both bundle exclusion
    /// and `"hexplate.meal."` `HKMetadataKeySyncIdentifier` prefix filtering as a backstop.
    func readExternalMeals(on day: String, excludedBundleIds: Set<String>) async -> [ExternalMealSummary]? {
        guard isAvailable,
              let startDate = Self.localStartOfDay(day),
              let endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate) else {
            return nil
        }

        let ownBundle = Bundle.main.bundleIdentifier
        let datePredicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        struct GroupKey: Hashable {
            let bundleId: String
            let minute: String
            let food: String
        }
        struct Accumulator {
            var sourceName: String
            var time: String
            var food: String
            var bundleId: String
            var macros: Nutrition.Macros
        }

        var grouped: [GroupKey: Accumulator] = [:]
        let cal = Calendar.current

        do {
            for spec in Self.dietarySpecs {
                let query = HKSampleQueryDescriptor(
                    predicates: [.quantitySample(type: spec.type, predicate: datePredicate)],
                    sortDescriptors: [SortDescriptor(\.startDate)]
                )
                let samples = try await query.result(for: store)
                for sample in samples {
                    let syncId = sample.metadata?[HKMetadataKeySyncIdentifier] as? String
                    if Nutrition.Nutrient.isHexplateSyncId(syncId) { continue }
                    let bundleId = sample.sourceRevision.source.bundleIdentifier
                    if bundleId == ownBundle || excludedBundleIds.contains(bundleId) { continue }

                    let value = sample.quantity.doubleValue(for: spec.unit)
                    guard value > 0 else { continue }

                    let comps = cal.dateComponents([.hour, .minute], from: sample.startDate)
                    let timeText = String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
                    let food = (sample.metadata?[HKMetadataKeyFoodType] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let sourceName = sample.sourceRevision.source.name.isEmpty ? bundleId : sample.sourceRevision.source.name

                    let key = GroupKey(bundleId: bundleId, minute: timeText, food: food)
                    var acc = grouped[key] ?? Accumulator(
                        sourceName: sourceName,
                        time: timeText,
                        food: food,
                        bundleId: bundleId,
                        macros: .zero
                    )
                    switch spec.nutrient {
                    case .kcal: acc.macros.kcal += value
                    case .protein: acc.macros.protein += value
                    case .carbs: acc.macros.carbs += value
                    case .fat: acc.macros.fat += value
                    }
                    grouped[key] = acc
                }
            }

            return grouped.values.map { acc in
                ExternalMealSummary(
                    id: "\(acc.bundleId)|\(day)|\(acc.time)|\(acc.food)",
                    day: day,
                    time: acc.time,
                    name: acc.food.isEmpty ? acc.sourceName : acc.food,
                    sourceName: acc.sourceName,
                    sourceBundleId: acc.bundleId,
                    macros: acc.macros
                )
            }.sorted { a, b in
                let ta = a.time ?? "", tb = b.time ?? ""
                return ta != tb ? ta < tb : a.id < b.id
            }
        } catch {
            return nil
        }
    }

    /// Reads overnight sleep (`18:00 yesterday – 12:00 today`), 28-day overnight HRV SDNN, and
    /// resting heart rate. Returns `nil` only when HealthKit is unavailable or throws (e.g. locked
    /// device); denied read permissions yield empty results (never penalized by Readiness).
    func readReadinessSignals(today: String, now: Date) async -> Readiness.HealthSignals? {
        guard isAvailable else { return nil }
        let cal = Calendar.current
        guard let window = Readiness.overnightWindow(for: today, calendar: cal),
              let hrvStart = cal.date(byAdding: .day, value: -29, to: window.start),
              let rhrStart = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: now)) else {
            return Readiness.HealthSignals()
        }

        do {
            let sleepPredicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
            let sleepQuery = HKSampleQueryDescriptor(
                predicates: [.categorySample(type: Self.sleep, predicate: sleepPredicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            )

            let hrvPredicate = HKQuery.predicateForSamples(withStart: hrvStart, end: window.end, options: [])
            let hrvQuery = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: Self.hrv, predicate: hrvPredicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            )

            let rhrPredicate = HKQuery.predicateForSamples(withStart: rhrStart, end: now, options: [])
            let rhrQuery = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: Self.restingHR, predicate: rhrPredicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            )

            async let sleepRaw = sleepQuery.result(for: store)
            async let hrvRaw = hrvQuery.result(for: store)
            async let rhrRaw = rhrQuery.result(for: store)

            let sleepSamples: [Readiness.SleepSample] = try await sleepRaw.compactMap { sample in
                guard let stage = Self.mapSleepStage(sample.value) else { return nil }
                let src = sample.sourceRevision.source
                return Readiness.SleepSample(
                    start: sample.startDate,
                    end: sample.endDate,
                    stage: stage,
                    sourceId: src.bundleIdentifier,
                    sourceName: src.name
                )
            }

            let msUnit = HKUnit.secondUnit(with: .milli)
            let hrvValues: [Readiness.DatedValue] = try await hrvRaw.map { sample in
                Readiness.DatedValue(date: sample.startDate, value: sample.quantity.doubleValue(for: msUnit))
            }

            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            let rhrValues: [Readiness.DatedValue] = try await rhrRaw.map { sample in
                Readiness.DatedValue(date: sample.startDate, value: sample.quantity.doubleValue(for: bpmUnit))
            }

            let sleepSummary = Readiness.summarizeSleep(
                sleepSamples,
                windowStart: window.start,
                windowEnd: window.end,
                now: now
            )
            let hrvSummary = Readiness.summarizeHRV(hrvValues, today: today, calendar: cal)
            let rhrSummary = Readiness.summarizeRHR(rhrValues, today: today, now: now, calendar: cal)
            return Readiness.HealthSignals(sleep: sleepSummary, hrv: hrvSummary, rhr: rhrSummary)
        } catch {
            return nil
        }
    }

    /// Maps `HKCategoryValueSleepAnalysis` raw values explicitly and ignores unknown future values.
    /// Raw value 1 (`asleepUnspecified`) also covers the deprecated `.asleep` value.
    private static func mapSleepStage(_ rawValue: Int) -> Readiness.SleepStage? {
        switch rawValue {
        case HKCategoryValueSleepAnalysis.inBed.rawValue: .inBed
        case HKCategoryValueSleepAnalysis.awake.rawValue: .awake
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: .asleepUnspecified
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue: .asleepCore
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: .asleepDeep
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue: .asleepREM
        default: nil
        }
    }

    /// Writes or deletes one meal's authorized dietary nutrient samples using `HKMetadataKeySyncIdentifier`
    /// and `HKMetadataKeySyncVersion = Int64(ts)`.
    func applyMealOp(_ op: Nutrition.HealthSyncOp) async throws {
        guard isAvailable else { return }
        switch op.kind {
        case .upsert:
            guard let meal = op.meal else { return }
            let sampleDate = Self.localDate(day: meal.date, time: meal.time) ?? .now
            let version = NSNumber(value: Int64(max(1, meal.ts.rounded())))
            let foodName = meal.name.trimmingCharacters(in: .whitespacesAndNewlines)

            for spec in Self.dietarySpecs {
                guard store.authorizationStatus(for: spec.type) == .sharingAuthorized else { continue }
                let syncId = spec.nutrient.syncId(mealId: meal.id)
                if let value = spec.nutrient.value(in: meal) {
                    var metadata: [String: Any] = [
                        HKMetadataKeySyncIdentifier: syncId,
                        HKMetadataKeySyncVersion: version,
                    ]
                    if !foodName.isEmpty {
                        metadata[HKMetadataKeyFoodType] = foodName
                    }
                    let sample = HKQuantitySample(
                        type: spec.type,
                        quantity: HKQuantity(unit: spec.unit, doubleValue: value),
                        start: sampleDate,
                        end: sampleDate,
                        metadata: metadata
                    )
                    try await store.save(sample)
                } else {
                    let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [syncId])
                    _ = try await store.deleteObjects(of: spec.type, predicate: predicate)
                }
            }

        case .delete:
            for spec in Self.dietarySpecs {
                guard store.authorizationStatus(for: spec.type) == .sharingAuthorized else { continue }
                let syncId = spec.nutrient.syncId(mealId: op.mealId)
                let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [syncId])
                _ = try await store.deleteObjects(of: spec.type, predicate: predicate)
            }
        }
    }

    // MARK: - Local Calendar Helpers

    private static func localStartOfDay(_ iso: String) -> Date? {
        localDate(day: iso, time: "00:00")
    }

    private static func localDate(day: String, time: String?) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let hm = Nutrition.cleanTime(time)?.split(separator: ":").compactMap { Int($0) }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        comps.hour = hm?.first ?? 12
        comps.minute = hm?.count == 2 ? hm![1] : 0
        return Calendar.current.date(from: comps)
    }
}

#if DEBUG
/// Deterministic mock HealthKit client for Simulator QA and SwiftUI previews (compiled in DEBUG only).
actor FakeHealthClient: HealthReading {
    enum ReadinessMode: Sendable {
        case good
        case low
        case calibrating
    }

    nonisolated let isAvailable: Bool
    private let unavailable: Bool
    private let readinessMode: ReadinessMode
    private var appliedOps: [Nutrition.HealthSyncOp] = []

    private let sources: [NutritionSource] = [
        NutritionSource(id: "com.example.myfitnesspal", name: "MyFitnessPal"),
        NutritionSource(id: "com.example.cronometer", name: "Cronometer"),
    ]

    init(isAvailable: Bool = true, unavailable: Bool = false, readinessMode: ReadinessMode = .good) {
        self.isAvailable = isAvailable
        self.unavailable = unavailable
        self.readinessMode = readinessMode
    }

    func authorizationRequestStatus() async -> HealthAuthStatus {
        isAvailable ? .unnecessary : .unavailable
    }

    func requestAuthorization() async -> Bool { isAvailable }
    func hasAnyDietaryWriteAuthorization() async -> Bool { isAvailable && !unavailable }
    func saveWeight(_ weight: Double, unit: String, at date: Date) async {}
    func saveWorkout(start: Date, end: Date) async {}
    func readWeights(unit: String, days: Int) async -> [(date: Date, weight: Double)] { [] }
    func startWatchStrengthWorkout() async throws -> Bool { isAvailable }
    func nutritionSources() async -> [NutritionSource] { isAvailable ? sources : [] }

    func readExternalNutritionSeries(
        from: String,
        to: String,
        excludedBundleIds: Set<String>
    ) async -> [String: Nutrition.Macros]? {
        guard isAvailable, !unavailable else { return nil }
        var out: [String: Nutrition.Macros] = [:]
        for item in sampleMeals(today: Day.today()) where item.day >= from && item.day <= to && !excludedBundleIds.contains(item.sourceBundleId) {
            out[item.day] = (out[item.day] ?? .zero) + item.macros
        }
        return out
    }

    func readExternalMeals(on day: String, excludedBundleIds: Set<String>) async -> [ExternalMealSummary]? {
        guard isAvailable, !unavailable else { return nil }
        return sampleMeals(today: Day.today()).filter { $0.day == day && !excludedBundleIds.contains($0.sourceBundleId) }
    }

    func readReadinessSignals(today: String, now: Date) async -> Readiness.HealthSignals? {
        guard isAvailable, !unavailable else { return nil }
        switch readinessMode {
        case .good:
            return Readiness.HealthSignals(
                sleep: .init(
                    totalHours: 7.6,
                    deepHours: 1.5,
                    remHours: 1.8,
                    coreHours: 4.3,
                    sourceName: "Apple Watch",
                    hasStages: true
                ),
                hrv: .init(latestMs: 59, baselineMs: 54, nightsCount: 14, calibrating: false, deltaPct: (59.0 - 54.0) / 54.0),
                rhr: .init(latestBpm: 55, sampleDateISO: today, baselineBpm: 57, daysCount: 14, calibrating: false, deltaBpm: -2.0)
            )
        case .low:
            return Readiness.HealthSignals(
                sleep: .init(
                    totalHours: 5.0,
                    deepHours: 0.7,
                    remHours: 0.9,
                    coreHours: 3.4,
                    sourceName: "Apple Watch",
                    hasStages: true
                ),
                hrv: .init(latestMs: 44, baselineMs: 56, nightsCount: 14, calibrating: false, deltaPct: (44.0 - 56.0) / 56.0),
                rhr: .init(latestBpm: 63, sampleDateISO: today, baselineBpm: 57, daysCount: 14, calibrating: false, deltaBpm: 6.0)
            )
        case .calibrating:
            return Readiness.HealthSignals(
                sleep: .init(
                    totalHours: 7.2,
                    deepHours: 1.3,
                    remHours: 1.6,
                    coreHours: 4.3,
                    sourceName: "Apple Watch",
                    hasStages: true
                ),
                hrv: .init(latestMs: 56, baselineMs: nil, nightsCount: 3, calibrating: true, deltaPct: nil),
                rhr: .init(latestBpm: 56, sampleDateISO: today, baselineBpm: nil, daysCount: 3, calibrating: true, deltaBpm: nil)
            )
        }
    }

    func applyMealOp(_ op: Nutrition.HealthSyncOp) async throws {
        appliedOps.append(op)
    }

    private func sampleMeals(today: String) -> [ExternalMealSummary] {
        var items: [ExternalMealSummary] = [
            ExternalMealSummary(
                id: "fake-today-1",
                day: today,
                time: "08:30",
                name: "Greek Yogurt Bowl",
                sourceName: "MyFitnessPal",
                sourceBundleId: "com.example.myfitnesspal",
                macros: Nutrition.Macros(kcal: 320, protein: 24, carbs: 38, fat: 8)
            ),
            ExternalMealSummary(
                id: "fake-today-lunch",
                day: today,
                time: "12:30",
                name: "Chicken Rice Bowl",
                sourceName: "MyFitnessPal",
                sourceBundleId: "com.example.myfitnesspal",
                macros: Nutrition.Macros(kcal: 750, protein: 52, carbs: 84, fat: 18)
            ),
            ExternalMealSummary(
                id: "fake-today-2",
                day: today,
                time: "16:00",
                name: "Whey Shake",
                sourceName: "Cronometer",
                sourceBundleId: "com.example.cronometer",
                macros: Nutrition.Macros(kcal: 180, protein: 30, carbs: 6, fat: 3)
            ),
        ]
        if let yesterday = Day.adding(-1, to: today) {
            items.append(
                ExternalMealSummary(
                    id: "fake-yesterday-1",
                    day: yesterday,
                    time: "12:30",
                    name: "Salmon Bento",
                    sourceName: "MyFitnessPal",
                    sourceBundleId: "com.example.myfitnesspal",
                    macros: Nutrition.Macros(kcal: 640, protein: 42, carbs: 62, fat: 22)
                )
            )
        }
        return items
    }
}
#endif

/// `@MainActor` coordinator managing HealthKit authorization status, live external nutrition cache,
/// persisted write outbox (`health-outbox.json`), and bounded pushed ledger (`health-pushed.json`).
@MainActor
@Observable
final class HealthService {
    static let shared = HealthService()

    private static let excludedSourcesKey = "healthExcludedNutritionSources"
    private static let outboxURL = URL.applicationSupportDirectory.appending(path: "Hexplate/health-outbox.json")
    private static let pushedURL = URL.applicationSupportDirectory.appending(path: "Hexplate/health-pushed.json")

    let client: any HealthReading
    #if DEBUG
    let isDebugFakeActive: Bool
    #endif

    private(set) var authStatus: HealthAuthStatus = .unknown
    private(set) var externalByDay: [String: Nutrition.Macros]?
    private(set) var externalItemsByDay: [String: [ExternalMealSummary]] = [:]
    private(set) var externalUnavailable = false
    private(set) var readinessSignals: Readiness.HealthSignals?
    private(set) var readinessUnavailable = false
    private(set) var availableSources: [NutritionSource] = []

    var excludedSourceIds: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(excludedSourceIds).sorted(), forKey: Self.excludedSourcesKey)
        }
    }

    private var outbox: [Nutrition.HealthSyncOp] = []
    private var pushed: [String: Nutrition.PushedEntry] = [:]
    private var foregroundTask: Task<Void, Never>?
    private var isFlushing = false
    private var unlockObserver: NSObjectProtocol?
    private weak var observedModel: AppModel?

    var isAvailable: Bool { client.isAvailable }

    init(client: (any HealthReading)? = nil) {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let fakeOn = args.contains("-hexplate-fake-health")
        let fakeLow = args.contains("-hexplate-fake-health-low")
        let fakeCalibrating = args.contains("-hexplate-fake-health-calibrating")
        let fakeUnavailable = args.contains("-hexplate-fake-health-unavailable")
        if let client {
            self.client = client
            self.isDebugFakeActive = false
        } else if fakeOn || fakeLow || fakeCalibrating || fakeUnavailable {
            let mode: FakeHealthClient.ReadinessMode = fakeLow ? .low : (fakeCalibrating ? .calibrating : .good)
            self.client = FakeHealthClient(unavailable: fakeUnavailable, readinessMode: mode)
            self.isDebugFakeActive = true
        } else {
            self.client = HealthClient()
            self.isDebugFakeActive = false
        }
        #else
        self.client = client ?? HealthClient()
        #endif

        self.excludedSourceIds = Set(UserDefaults.standard.stringArray(forKey: Self.excludedSourcesKey) ?? [])
        self.outbox = Self.loadJSON([Nutrition.HealthSyncOp].self, from: Self.outboxURL) ?? []
        self.pushed = Self.loadJSON([String: Nutrition.PushedEntry].self, from: Self.pushedURL) ?? [:]
    }

    func isEnabled(root: [String: JSONValue]) -> Bool {
        guard Modules.isOn(root, "health") else { return false }
        #if DEBUG
        if isDebugFakeActive { return true }
        #endif
        return UserDefaults.standard.bool(forKey: "health")
    }

    struct TodaySnapshotContext {
        let healthState: Readiness.HealthState
        let readiness: Readiness.Result
        let signals: Readiness.HealthSignals?
        let load: Recovery.LoadSummary
        let externalToday: Nutrition.Macros?
    }

    /// Shared readiness, recovery load, and live external nutrition snapshot used identically by
    /// `HomeView` and `CoachSheet`.
    func evaluateTodaySnapshot(
        root: [String: JSONValue],
        today: String,
        now: Double,
        catalog: ExerciseCatalog
    ) -> TodaySnapshotContext {
        let enabled = isEnabled(root: root)
        let todayIds = Schedule.routineIds(root, on: today, today: today)
        let load = Recovery.loadSummary(root, now: now, catalog: catalog)
        let plannedLoad = Recovery.plannedMuscleLoad(root, on: today, today: today, catalog: catalog)
        let healthState: Readiness.HealthState = !enabled ? .off : (readinessUnavailable ? .unavailable : .available)
        let readiness = Readiness.evaluate(Readiness.Input(
            signals: readinessSignals,
            healthState: healthState,
            load: load,
            plannedLoad: plannedLoad,
            hasTodayPlan: !todayIds.isEmpty
        ))
        let externalToday: Nutrition.Macros? = enabled ? externalByDay.map { $0[today] ?? .zero } : nil
        return TodaySnapshotContext(
            healthState: healthState,
            readiness: readiness,
            signals: healthState == .available ? readinessSignals : nil,
            load: load,
            externalToday: externalToday
        )
    }

    func startObservingUnlock(model: AppModel) {
        observedModel = model
        guard unlockObserver == nil else { return }
        unlockObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let model = self.observedModel else { return }
                await self.flushOutboxIfAllowed(root: model.root)
            }
        }
    }

    // MARK: - Authorization & Existing Weight / Workout / Watch Calls

    func refreshAuthStatus() async {
        authStatus = await client.authorizationRequestStatus()
    }

    func authorise() async -> Bool {
        let ok = await client.requestAuthorization()
        await refreshAuthStatus()
        return ok
    }

    func saveWeight(_ weight: Double, unit: String, at date: Date) {
        Task { await client.saveWeight(weight, unit: unit, at: date) }
    }

    func saveWorkout(start: Date, end: Date) async {
        await client.saveWorkout(start: start, end: end)
    }

    func readWeights(unit: String, days: Int = 90) async -> [(date: Date, weight: Double)] {
        await client.readWeights(unit: unit, days: days)
    }

    func startWatchStrengthWorkout() async throws -> Bool {
        try await client.startWatchStrengthWorkout()
    }

    func loadNutritionSources() async {
        availableSources = await client.nutritionSources()
    }

    // MARK: - Live External Nutrition Reads

    func refreshExternalNutrition(
        root: [String: JSONValue],
        period: Nutrition.Period,
        today: String,
        selectedDay: String
    ) async {
        guard isEnabled(root: root) else {
            externalByDay = nil
            externalItemsByDay = [:]
            externalUnavailable = false
            return
        }
        guard isAvailable else {
            externalByDay = nil
            externalItemsByDay = [:]
            externalUnavailable = true
            return
        }
        guard let range = Nutrition.periodRange(period, today: today) else { return }
        let queryFrom = min(range.from, selectedDay)
        let queryTo = max(range.to, selectedDay)
        let excluded = excludedSourceIds

        async let series = client.readExternalNutritionSeries(from: queryFrom, to: queryTo, excludedBundleIds: excluded)
        async let dayItems = client.readExternalMeals(on: selectedDay, excludedBundleIds: excluded)

        let resolvedSeries = await series
        let resolvedItems = await dayItems

        externalByDay = resolvedSeries
        if let resolvedItems {
            externalItemsByDay[selectedDay] = resolvedItems
        } else {
            externalItemsByDay.removeValue(forKey: selectedDay)
        }
        externalUnavailable = (resolvedSeries == nil || resolvedItems == nil)
    }

    func refreshExternalMeals(root: [String: JSONValue], on day: String) async {
        guard isEnabled(root: root) else {
            externalItemsByDay = [:]
            externalUnavailable = false
            return
        }
        guard isAvailable else {
            externalItemsByDay = [:]
            externalUnavailable = true
            return
        }
        if let items = await client.readExternalMeals(on: day, excludedBundleIds: excludedSourceIds) {
            externalItemsByDay[day] = items
            externalUnavailable = (externalByDay == nil)
        } else {
            externalItemsByDay.removeValue(forKey: day)
            externalUnavailable = true
        }
    }

    /// Refreshes today's live external nutrition totals and merges `today` into `externalByDay`
    /// without clobbering multi-day series loaded by `NutritionView`. Strictly honors `isEnabled(root:)`.
    func refreshTodayExternalNutrition(root: [String: JSONValue], today: String) async {
        guard isEnabled(root: root) else {
            externalByDay = nil
            externalItemsByDay = [:]
            externalUnavailable = false
            return
        }
        guard isAvailable else {
            externalByDay = nil
            externalItemsByDay = [:]
            externalUnavailable = true
            return
        }
        if let result = await client.readExternalNutritionSeries(from: today, to: today, excludedBundleIds: excludedSourceIds) {
            let todayMacros = result[today] ?? .zero
            if var merged = externalByDay {
                merged[today] = todayMacros
                externalByDay = merged
            } else {
                externalByDay = [today: todayMacros]
            }
            externalUnavailable = false
        } else {
            externalUnavailable = true
        }
    }

    /// Refreshes sleep, HRV, and resting heart rate signals for Readiness. Strictly honors `isEnabled(root:)`.
    func refreshReadiness(root: [String: JSONValue], today: String, now: Date = .now) async {
        guard isEnabled(root: root) else {
            readinessSignals = nil
            readinessUnavailable = false
            return
        }
        guard isAvailable else {
            readinessSignals = nil
            readinessUnavailable = true
            return
        }
        if let signals = await client.readReadinessSignals(today: today, now: now) {
            readinessSignals = signals
            readinessUnavailable = false
        } else {
            readinessSignals = nil
            readinessUnavailable = true
        }
    }

    // MARK: - Meal Outbox & Bounded 14-Day Foreground Repair

    /// Enqueues a local user add/edit meal op. NEVER call from `takeMergedCopy` or `takeServerCopy`.
    func enqueueMealUpsert(_ meal: Nutrition.Meal, root: [String: JSONValue]) {
        guard isEnabled(root: root), meal.ts > 0 else { return }
        outbox = Nutrition.HealthSyncOp.coalesce(outbox, adding: .upsert(meal))
        Self.saveJSON(outbox, to: Self.outboxURL)
        Task { await flushOutboxIfAllowed(root: root) }
    }

    /// Enqueues a local user delete meal op. NEVER call from `takeMergedCopy` or `takeServerCopy`.
    func enqueueMealDelete(mealId: String, ts: Double, root: [String: JSONValue]) {
        guard isEnabled(root: root), ts > 0 else { return }
        outbox = Nutrition.HealthSyncOp.coalesce(outbox, adding: .delete(mealId: mealId, ts: ts))
        Self.saveJSON(outbox, to: Self.outboxURL)
        Task { await flushOutboxIfAllowed(root: root) }
    }

    /// Gated outbox flush (called on local writes, cold launch `.task`, unlock notification, and foreground).
    func flushOutboxIfAllowed(root: [String: JSONValue]) async {
        guard !isFlushing, !outbox.isEmpty else { return }
        guard isEnabled(root: root),
              isAvailable,
              UIApplication.shared.isProtectedDataAvailable,
              await client.hasAnyDietaryWriteAuthorization() else { return }

        isFlushing = true
        defer { isFlushing = false }

        while !outbox.isEmpty {
            let batch = outbox
            var failed: [Nutrition.HealthSyncOp] = []
            var pushedChanged = false
            var stopEarly = false

            for op in batch {
                if stopEarly {
                    failed.append(op)
                    continue
                }
                do {
                    try await client.applyMealOp(op)
                    if let prev = pushed[op.mealId], prev.ts > op.ts {
                        // Preserve a newer already-confirmed ledger stamp.
                    } else {
                        pushed[op.mealId] = Nutrition.PushedEntry(kind: op.kind, ts: op.ts)
                        pushedChanged = true
                    }
                } catch {
                    failed.append(op)
                    if Self.isDatabaseInaccessible(error) {
                        stopEarly = true
                    }
                }
            }

            let reconciled = Nutrition.HealthSyncOp.reconcileAfterFlush(
                batch: batch,
                failed: failed,
                current: outbox
            )
            if reconciled != outbox {
                outbox = reconciled
                Self.saveJSON(outbox, to: Self.outboxURL)
            }
            if pushedChanged {
                pushed = Nutrition.prunedPushedLedger(pushed, against: root)
                Self.saveJSON(pushed, to: Self.pushedURL)
            }

            // Retry immediately only when new or superseding ops arrived mid-flush and HealthKit is accessible.
            let hasFreshWork = reconciled.contains { !failed.contains($0) }
            if stopEarly || !hasFreshWork {
                break
            }
        }
    }

    /// Debounced 2-second foreground sync: refreshes auth status, flushes outbox, and runs the
    /// strictly gated, ledger-bounded 14-day repair pass.
    func scheduleForegroundSync(model: AppModel) {
        foregroundTask?.cancel()
        foregroundTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            await self.refreshAuthStatus()
            await self.refreshReadiness(root: model.root, today: model.today)
            await self.refreshTodayExternalNutrition(root: model.root, today: model.today)
            await self.flushOutboxIfAllowed(root: model.root)
            await self.repairRecentMealsIfAllowed(root: model.root, today: model.today)
        }
    }

    private func repairRecentMealsIfAllowed(root: [String: JSONValue], today: String) async {
        guard isEnabled(root: root),
              isAvailable,
              UIApplication.shared.isProtectedDataAvailable,
              await client.hasAnyDietaryWriteAuthorization() else { return }

        let queuedIds = Set(outbox.map(\.mealId))
        let plan = Nutrition.recentRepairPlan(root, today: today, days: 14, pushed: pushed)
            .filter { !queuedIds.contains($0.mealId) }

        var pushedChanged = false
        for op in plan {
            do {
                try await client.applyMealOp(op)
                pushed[op.mealId] = Nutrition.PushedEntry(kind: op.kind, ts: op.ts)
                pushedChanged = true
            } catch {
                if Self.isDatabaseInaccessible(error) { break }
            }
        }

        let pruned = Nutrition.prunedPushedLedger(pushed, against: root)
        if pushedChanged || pruned.count != pushed.count {
            pushed = pruned
            Self.saveJSON(pushed, to: Self.pushedURL)
        }
    }

    // MARK: - Persistence Helpers

    private static func isDatabaseInaccessible(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == HKErrorDomain && ns.code == HKError.errorDatabaseInaccessible.rawValue
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func saveJSON<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {}
    }
}
