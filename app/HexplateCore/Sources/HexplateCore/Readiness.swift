import Foundation

/// Pure, offline, rule-based daily Readiness evaluation combining training load (`Recovery.LoadSummary`)
/// with optional Apple Health recovery signals (sleep, overnight HRV, resting heart rate).
///
/// Key invariants:
/// - Sleep window is fixed at `18:00 yesterday – 12:00 today` (DST-safe via Calendar components).
/// - Picks one best stage-capable sleep source per night; merges overlapping intervals across sources
///   only when no source reports sleep stages. `.inBed` and `.awake` are always excluded.
/// - Missing, denied, disabled, provisional, or calibrating HealthKit signals NEVER penalize the
///   score and NEVER cause a false `.rest` verdict.
public enum Readiness {
    // MARK: - Sleep Types

    public enum SleepStage: Equatable, Sendable {
        case inBed
        case awake
        case asleepUnspecified
        case asleepCore
        case asleepDeep
        case asleepREM

        public var isAsleep: Bool {
            switch self {
            case .asleepUnspecified, .asleepCore, .asleepDeep, .asleepREM: true
            case .inBed, .awake: false
            }
        }

        public var isDetailedStage: Bool {
            switch self {
            case .asleepCore, .asleepDeep, .asleepREM: true
            case .inBed, .awake, .asleepUnspecified: false
            }
        }
    }

    public struct SleepSample: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let stage: SleepStage
        public let sourceId: String
        public let sourceName: String

        public init(start: Date, end: Date, stage: SleepStage, sourceId: String, sourceName: String) {
            self.start = start
            self.end = end
            self.stage = stage
            self.sourceId = sourceId
            self.sourceName = sourceName
        }
    }

    public struct SleepSummary: Equatable, Sendable {
        public let totalHours: Double
        public let deepHours: Double?
        public let remHours: Double?
        public let coreHours: Double?
        public let sourceName: String?
        public let hasStages: Bool
        public let isProvisional: Bool

        public init(
            totalHours: Double,
            deepHours: Double?,
            remHours: Double?,
            coreHours: Double?,
            sourceName: String?,
            hasStages: Bool,
            isProvisional: Bool = false
        ) {
            self.totalHours = totalHours
            self.deepHours = deepHours
            self.remHours = remHours
            self.coreHours = coreHours
            self.sourceName = sourceName
            self.hasStages = hasStages
            self.isProvisional = isProvisional
        }
    }

    // MARK: - HRV & RHR Types

    public struct DatedValue: Equatable, Sendable {
        public let date: Date
        public let value: Double

        public init(date: Date, value: Double) {
            self.date = date
            self.value = value
        }
    }

    public struct HRVSummary: Equatable, Sendable {
        public let latestMs: Double?
        public let baselineMs: Double?
        public let nightsCount: Int
        public let calibrating: Bool
        public let deltaPct: Double?

        public init(latestMs: Double?, baselineMs: Double?, nightsCount: Int, calibrating: Bool, deltaPct: Double?) {
            self.latestMs = latestMs
            self.baselineMs = baselineMs
            self.nightsCount = nightsCount
            self.calibrating = calibrating
            self.deltaPct = deltaPct
        }
    }

    public struct RHRSummary: Equatable, Sendable {
        public let latestBpm: Double?
        public let sampleDateISO: String?
        public let baselineBpm: Double?
        public let daysCount: Int
        public let calibrating: Bool
        public let deltaBpm: Double?

        public init(
            latestBpm: Double?,
            sampleDateISO: String?,
            baselineBpm: Double?,
            daysCount: Int,
            calibrating: Bool,
            deltaBpm: Double?
        ) {
            self.latestBpm = latestBpm
            self.sampleDateISO = sampleDateISO
            self.baselineBpm = baselineBpm
            self.daysCount = daysCount
            self.calibrating = calibrating
            self.deltaBpm = deltaBpm
        }
    }

    // MARK: - Evaluation Types

    public enum HealthState: Equatable, Sendable {
        case available
        case off
        case unavailable
    }

    public struct HealthSignals: Equatable, Sendable {
        public let sleep: SleepSummary?
        public let hrv: HRVSummary?
        public let rhr: RHRSummary?

        public init(sleep: SleepSummary? = nil, hrv: HRVSummary? = nil, rhr: RHRSummary? = nil) {
            self.sleep = sleep
            self.hrv = hrv
            self.rhr = rhr
        }
    }

    public enum Verdict: Equatable, Sendable {
        case good
        case light
        case rest
    }

    public enum SignalKind: Equatable, Sendable {
        case sleep
        case hrv
        case rhr
    }

    public enum Reason: Equatable, Sendable {
        case goodSleep(hours: Double)
        case shortSleep(hours: Double)
        case strongHRV(deltaPct: Double)
        case lowHRV(deltaPct: Double)
        case lowRHR(deltaBpm: Double)
        case elevatedRHR(deltaBpm: Double)
        case highTrainingLoad(ratio: Double)
        case elevatedTrainingLoad(ratio: Double)
        case balancedTrainingLoad
        case plannedMusclesRecovering(hours: Double)
    }

    public struct ScoredReason: Equatable, Sendable {
        public let reason: Reason
        public let impact: Int

        public init(reason: Reason, impact: Int) {
            self.reason = reason
            self.impact = impact
        }
    }

    public struct Input: Equatable, Sendable {
        public let signals: HealthSignals?
        public let healthState: HealthState
        public let load: Recovery.LoadSummary
        public let plannedLoad: [String: Double]
        public let hasTodayPlan: Bool

        public init(
            signals: HealthSignals?,
            healthState: HealthState,
            load: Recovery.LoadSummary,
            plannedLoad: [String: Double],
            hasTodayPlan: Bool
        ) {
            self.signals = signals
            self.healthState = healthState
            self.load = load
            self.plannedLoad = plannedLoad
            self.hasTodayPlan = hasTodayPlan
        }
    }

    public struct Result: Equatable, Sendable {
        public let verdict: Verdict
        public let score: Int
        public let reasons: [ScoredReason]
        public let missingSignals: [SignalKind]
        public let calibratingSignals: [SignalKind]
        public let healthState: HealthState
        public let sleepProvisional: Bool

        public init(
            verdict: Verdict,
            score: Int,
            reasons: [ScoredReason],
            missingSignals: [SignalKind],
            calibratingSignals: [SignalKind],
            healthState: HealthState,
            sleepProvisional: Bool
        ) {
            self.verdict = verdict
            self.score = score
            self.reasons = reasons
            self.missingSignals = missingSignals
            self.calibratingSignals = calibratingSignals
            self.healthState = healthState
            self.sleepProvisional = sleepProvisional
        }
    }

    // MARK: - Constants

    public static let minCalibrationDays = 7
    public static let baselineDays = 28
    public static let rhrMaxAgeSeconds: TimeInterval = 36 * 3600
    public static let provisionalSleepMarginSeconds: TimeInterval = 30 * 60
    private static let minValidSleepSeconds: TimeInterval = 10 * 60

    // MARK: - Window Helpers

    /// Fixed overnight window `18:00 yesterday – 12:00 today` built with calendar components (DST-safe).
    public static func overnightWindow(
        for today: String,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        guard let todayNoon = dateNoon(for: today, calendar: calendar),
              let yesterdayNoon = calendar.date(byAdding: .day, value: -1, to: todayNoon),
              let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: yesterdayNoon),
              let end = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: todayNoon),
              end > start else {
            return nil
        }
        return (start, end)
    }

    // MARK: - Signal Summarizers

    /// Summarizes asleep samples inside `[windowStart, windowEnd]`.
    /// Picks one best stage-capable source when available; otherwise merges overlapping intervals
    /// across all sources. Marks `isProvisional = true` when `now < windowEnd` and the latest
    /// asleep segment ended within 30 minutes of `now` (Watch still syncing).
    public static func summarizeSleep(
        _ samples: [SleepSample],
        windowStart: Date,
        windowEnd: Date,
        now: Date
    ) -> SleepSummary? {
        guard windowEnd > windowStart else { return nil }

        struct ClampedSample {
            let start: Date
            let end: Date
            let stage: SleepStage
            let sourceId: String
            let sourceName: String
        }

        var clamped: [ClampedSample] = []
        for sample in samples where sample.stage.isAsleep {
            let s = max(sample.start, windowStart)
            let e = min(sample.end, windowEnd)
            guard e > s else { continue }
            clamped.append(ClampedSample(
                start: s,
                end: e,
                stage: sample.stage,
                sourceId: sample.sourceId,
                sourceName: sample.sourceName
            ))
        }
        guard !clamped.isEmpty else { return nil }

        let bySource = Dictionary(grouping: clamped, by: \.sourceId)
        let stageCapable = bySource.filter { _, items in
            items.contains { $0.stage.isDetailedStage }
        }

        if !stageCapable.isEmpty {
            let best = stageCapable.max { a, b in
                let aDur = mergedSeconds(a.value.map { ($0.start, $0.end) })
                let bDur = mergedSeconds(b.value.map { ($0.start, $0.end) })
                if abs(aDur - bDur) > 0.5 { return aDur < bDur }
                let aStages = a.value.filter { $0.stage.isDetailedStage }.count
                let bStages = b.value.filter { $0.stage.isDetailedStage }.count
                if aStages != bStages { return aStages < bStages }
                return a.key > b.key // lexicographically smaller sourceId wins
            }!

            let chosen = best.value
            let totalSec = mergedSeconds(chosen.map { ($0.start, $0.end) })
            guard totalSec >= minValidSleepSeconds else { return nil }

            let coreSec = mergedSeconds(chosen.filter { $0.stage == .asleepCore }.map { ($0.start, $0.end) })
            let deepSec = mergedSeconds(chosen.filter { $0.stage == .asleepDeep }.map { ($0.start, $0.end) })
            let remSec = mergedSeconds(chosen.filter { $0.stage == .asleepREM }.map { ($0.start, $0.end) })
            let latestEnd = chosen.map(\.end).max()
            let provisional = isSleepProvisional(latestEnd: latestEnd, windowEnd: windowEnd, now: now)
            let name = chosen.first(where: { !$0.sourceName.isEmpty })?.sourceName ?? best.key

            return SleepSummary(
                totalHours: totalSec / 3600.0,
                deepHours: deepSec / 3600.0,
                remHours: remSec / 3600.0,
                coreHours: coreSec / 3600.0,
                sourceName: name,
                hasStages: true,
                isProvisional: provisional
            )
        } else {
            let totalSec = mergedSeconds(clamped.map { ($0.start, $0.end) })
            guard totalSec >= minValidSleepSeconds else { return nil }
            let latestEnd = clamped.map(\.end).max()
            let provisional = isSleepProvisional(latestEnd: latestEnd, windowEnd: windowEnd, now: now)
            return SleepSummary(
                totalHours: totalSec / 3600.0,
                deepHours: nil,
                remHours: nil,
                coreHours: nil,
                sourceName: nil,
                hasStages: false,
                isProvisional: provisional
            )
        }
    }

    /// Summarizes overnight HRV SDNN (ms). Samples between 18:00 and 12:00 are bucketed into the
    /// wake-up day's night; daytime samples (`12:00 <= hour < 18:00`) are excluded. Baseline is the
    /// median of nightly medians across the 28 prior nights (excluding `today`).
    public static func summarizeHRV(
        _ samples: [DatedValue],
        today: String,
        calendar: Calendar = .current
    ) -> HRVSummary? {
        guard let minPrior = addingDays(-baselineDays, to: today, calendar: calendar),
              let maxPrior = addingDays(-1, to: today, calendar: calendar) else {
            return nil
        }

        var buckets: [String: [Double]] = [:]
        for s in samples where s.value.isFinite && s.value > 0 {
            let comps = calendar.dateComponents([.year, .month, .day, .hour], from: s.date)
            guard let y = comps.year, let m = comps.month, let d = comps.day, let hour = comps.hour else {
                continue
            }
            let localISO = String(format: "%04d-%02d-%02d", y, m, d)
            let nightISO: String?
            if hour >= 18 {
                nightISO = addingDays(1, to: localISO, calendar: calendar)
            } else if hour < 12 {
                nightISO = localISO
            } else {
                nightISO = nil
            }
            if let nightISO {
                buckets[nightISO, default: []].append(s.value)
            }
        }

        let latestMs = buckets[today].flatMap(median)
        var priorNightMedians: [Double] = []
        for (night, values) in buckets where night >= minPrior && night <= maxPrior {
            if let med = median(values) {
                priorNightMedians.append(med)
            }
        }

        let nightsCount = priorNightMedians.count
        if latestMs == nil && nightsCount == 0 {
            return nil
        }

        let calibrating = nightsCount < minCalibrationDays
        let baselineMs = calibrating ? nil : median(priorNightMedians)
        let deltaPct: Double? = {
            guard let latestMs, let baselineMs, baselineMs > 0 else { return nil }
            return (latestMs - baselineMs) / baselineMs
        }()

        return HRVSummary(
            latestMs: latestMs,
            baselineMs: baselineMs,
            nightsCount: nightsCount,
            calibrating: calibrating,
            deltaPct: deltaPct
        )
    }

    /// Summarizes Resting Heart Rate (bpm). Latest sample must be within 36 hours of `now` (older
    /// treated as missing) and retains its local ISO date. Baseline is the median of per-day medians
    /// over the 28 prior days, excluding both `today` and the latest sample's own day.
    public static func summarizeRHR(
        _ samples: [DatedValue],
        today: String,
        now: Date,
        calendar: Calendar = .current
    ) -> RHRSummary? {
        guard let minPrior = addingDays(-baselineDays, to: today, calendar: calendar) else {
            return nil
        }

        let valid = samples.filter { $0.value.isFinite && $0.value > 0 && $0.date <= now }
        guard !valid.isEmpty else { return nil }

        var newest: DatedValue?
        for s in valid {
            if let current = newest {
                if s.date >= current.date { newest = s }
            } else {
                newest = s
            }
        }

        var latestBpm: Double?
        var sampleDateISO: String?
        if let newest, now.timeIntervalSince(newest.date) <= rhrMaxAgeSeconds {
            latestBpm = newest.value
            sampleDateISO = isoString(newest.date, calendar: calendar)
        }

        var byDay: [String: [Double]] = [:]
        for s in valid {
            let dayISO = isoString(s.date, calendar: calendar)
            if dayISO >= minPrior && dayISO < today && dayISO != sampleDateISO {
                byDay[dayISO, default: []].append(s.value)
            }
        }

        let dailyMedians = byDay.values.compactMap(median)
        let daysCount = dailyMedians.count
        if latestBpm == nil && daysCount == 0 {
            return nil
        }

        let calibrating = daysCount < minCalibrationDays
        let baselineBpm = calibrating ? nil : median(dailyMedians)
        let deltaBpm: Double? = {
            guard let latestBpm, let baselineBpm else { return nil }
            return latestBpm - baselineBpm
        }()

        return RHRSummary(
            latestBpm: latestBpm,
            sampleDateISO: sampleDateISO,
            baselineBpm: baselineBpm,
            daysCount: daysCount,
            calibrating: calibrating,
            deltaBpm: deltaBpm
        )
    }

    // MARK: - Rule-Based Evaluator

    public static func evaluate(_ input: Input) -> Result {
        var score = 80
        var scoredReasons: [ScoredReason] = []
        var missingSignals: [SignalKind] = []
        var calibratingSignals: [SignalKind] = []
        var sleepProvisional = false

        // 1. Training load (always available from local workouts).
        if let ratio = input.load.global.ratio {
            if ratio >= 1.5 {
                score -= 20
                scoredReasons.append(ScoredReason(reason: .highTrainingLoad(ratio: ratio), impact: -20))
            } else if ratio >= 1.3 {
                score -= 10
                scoredReasons.append(ScoredReason(reason: .elevatedTrainingLoad(ratio: ratio), impact: -10))
            } else if input.load.global.acute > 0 {
                score += 5
                scoredReasons.append(ScoredReason(reason: .balancedTrainingLoad, impact: 5))
            }
        }

        // 2. Overlap between today's planned routine and still-recovering muscles.
        if input.hasTodayPlan {
            let targetedMuscles = input.plannedLoad.filter { $0.value >= 2.0 }.keys
            var maxFatigue = 0.0
            var maxHours = 0.0
            for slug in targetedMuscles {
                if let detail = input.load.muscles[slug] {
                    if detail.fatigue > maxFatigue { maxFatigue = detail.fatigue }
                    if detail.hoursToRecovered > maxHours { maxHours = detail.hoursToRecovered }
                }
            }
            if maxFatigue >= 0.70 {
                score -= 18
                scoredReasons.append(ScoredReason(reason: .plannedMusclesRecovering(hours: maxHours), impact: -18))
            } else if maxFatigue > 0.50 {
                score -= 10
                scoredReasons.append(ScoredReason(reason: .plannedMusclesRecovering(hours: maxHours), impact: -10))
            }
        }

        // 3. HealthKit signals (zero penalty when off, unavailable, missing, provisional, or calibrating).
        if input.healthState != .available {
            missingSignals = [.sleep, .hrv, .rhr]
        } else {
            let signals = input.signals

            // Sleep
            if let sleep = signals?.sleep {
                sleepProvisional = sleep.isProvisional
                if !sleep.isProvisional {
                    if sleep.totalHours < 5.5 {
                        score -= 25
                        scoredReasons.append(ScoredReason(reason: .shortSleep(hours: sleep.totalHours), impact: -25))
                    } else if sleep.totalHours < 6.5 {
                        score -= 12
                        scoredReasons.append(ScoredReason(reason: .shortSleep(hours: sleep.totalHours), impact: -12))
                    } else if sleep.totalHours >= 7.5 {
                        score += 10
                        scoredReasons.append(ScoredReason(reason: .goodSleep(hours: sleep.totalHours), impact: 10))
                    }
                }
            } else {
                missingSignals.append(.sleep)
            }

            // HRV
            if let hrv = signals?.hrv, hrv.latestMs != nil {
                if hrv.calibrating {
                    calibratingSignals.append(.hrv)
                } else if let delta = hrv.deltaPct {
                    if delta <= -0.15 {
                        score -= 20
                        scoredReasons.append(ScoredReason(reason: .lowHRV(deltaPct: delta), impact: -20))
                    } else if delta <= -0.08 {
                        score -= 10
                        scoredReasons.append(ScoredReason(reason: .lowHRV(deltaPct: delta), impact: -10))
                    } else if delta >= 0.08 {
                        score += 8
                        scoredReasons.append(ScoredReason(reason: .strongHRV(deltaPct: delta), impact: 8))
                    }
                }
            } else {
                missingSignals.append(.hrv)
                if signals?.hrv?.calibrating == true {
                    calibratingSignals.append(.hrv)
                }
            }

            // RHR
            if let rhr = signals?.rhr, rhr.latestBpm != nil {
                if rhr.calibrating {
                    calibratingSignals.append(.rhr)
                } else if let delta = rhr.deltaBpm {
                    if delta >= 5.0 {
                        score -= 18
                        scoredReasons.append(ScoredReason(reason: .elevatedRHR(deltaBpm: delta), impact: -18))
                    } else if delta >= 3.0 {
                        score -= 9
                        scoredReasons.append(ScoredReason(reason: .elevatedRHR(deltaBpm: delta), impact: -9))
                    } else if delta <= -2.0 {
                        score += 5
                        scoredReasons.append(ScoredReason(reason: .lowRHR(deltaBpm: delta), impact: 5))
                    }
                }
            } else {
                missingSignals.append(.rhr)
                if signals?.rhr?.calibrating == true {
                    calibratingSignals.append(.rhr)
                }
            }
        }

        let clampedScore = min(100, max(0, score))
        let verdict: Verdict = clampedScore >= 70 ? .good : (clampedScore >= 45 ? .light : .rest)

        let sortedReasons: [ScoredReason]
        switch verdict {
        case .good:
            sortedReasons = scoredReasons.sorted { a, b in
                if a.impact != b.impact { return a.impact > b.impact }
                return abs(a.impact) > abs(b.impact)
            }
        case .light, .rest:
            sortedReasons = scoredReasons.sorted { a, b in
                if a.impact != b.impact { return a.impact < b.impact }
                return abs(a.impact) > abs(b.impact)
            }
        }

        return Result(
            verdict: verdict,
            score: clampedScore,
            reasons: sortedReasons,
            missingSignals: missingSignals,
            calibratingSignals: calibratingSignals,
            healthState: input.healthState,
            sleepProvisional: sleepProvisional
        )
    }

    // MARK: - Internal Helpers

    private static func isSleepProvisional(latestEnd: Date?, windowEnd: Date, now: Date) -> Bool {
        guard let latestEnd, now < windowEnd, latestEnd <= now else { return false }
        return now.timeIntervalSince(latestEnd) <= provisionalSleepMarginSeconds
    }

    private static func mergedSeconds(_ intervals: [(Date, Date)]) -> TimeInterval {
        let valid = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        guard var current = valid.first else { return 0 }
        var total: TimeInterval = 0
        for next in valid.dropFirst() {
            if next.0 <= current.1 {
                if next.1 > current.1 { current.1 = next.1 }
            } else {
                total += current.1.timeIntervalSince(current.0)
                current = next
            }
        }
        total += current.1.timeIntervalSince(current.0)
        return total
    }

    private static func median(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return nil }
        let mid = finite.count / 2
        if finite.count % 2 == 1 {
            return finite[mid]
        }
        return (finite[mid - 1] + finite[mid]) / 2.0
    }

    private static func dateNoon(for iso: String, calendar: Calendar) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard iso.count == 10, parts.count == 3 else { return nil }
        let comps = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        guard comps.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: comps)
    }

    private static func isoString(_ date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private static func addingDays(_ days: Int, to iso: String, calendar: Calendar) -> String? {
        guard let noon = dateNoon(for: iso, calendar: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: noon) else {
            return nil
        }
        return isoString(shifted, calendar: calendar)
    }
}
