import XCTest
@testable import HexplateCore

final class ReadinessTests: XCTestCase {
    private func calendar(identifier: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: identifier)!
        return cal
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func emptyLoad(
        acute: Double = 0,
        chronic: Double = 0,
        ratio: Double? = nil,
        muscles: [String: Recovery.MuscleDetail] = [:]
    ) -> Recovery.LoadSummary {
        Recovery.LoadSummary(
            muscles: muscles,
            global: Recovery.GlobalLoad(acute: acute, chronic: chronic, ratio: ratio)
        )
    }

    // MARK: - Sleep Tests

    func testSleepWindowClampingExcludesInBedAndAwakeAndPicksSingleStageSource() throws {
        let cal = calendar(identifier: "Asia/Tokyo")
        let window = try XCTUnwrap(Readiness.overnightWindow(for: "2026-11-26", calendar: cal))
        let now = date(2026, 11, 26, 12, 30, calendar: cal)

        let samples: [Readiness.SleepSample] = [
            // Excluded stages from Apple Watch
            .init(start: date(2026, 11, 25, 22, 0, calendar: cal), end: date(2026, 11, 26, 7, 0, calendar: cal), stage: .inBed, sourceId: "com.apple.watch", sourceName: "Apple Watch"),
            .init(start: date(2026, 11, 26, 2, 0, calendar: cal), end: date(2026, 11, 26, 2, 30, calendar: cal), stage: .awake, sourceId: "com.apple.watch", sourceName: "Apple Watch"),
            // Stage-capable Apple Watch: 17:00-19:00 clamped to 18:00-19:00 (1h) + 23:00-06:00 (7h) = 8h total
            .init(start: date(2026, 11, 25, 17, 0, calendar: cal), end: date(2026, 11, 25, 19, 0, calendar: cal), stage: .asleepCore, sourceId: "com.apple.watch", sourceName: "Apple Watch"),
            .init(start: date(2026, 11, 25, 23, 0, calendar: cal), end: date(2026, 11, 26, 1, 0, calendar: cal), stage: .asleepDeep, sourceId: "com.apple.watch", sourceName: "Apple Watch"),
            .init(start: date(2026, 11, 26, 1, 0, calendar: cal), end: date(2026, 11, 26, 4, 0, calendar: cal), stage: .asleepCore, sourceId: "com.apple.watch", sourceName: "Apple Watch"),
            .init(start: date(2026, 11, 26, 4, 0, calendar: cal), end: date(2026, 11, 26, 6, 0, calendar: cal), stage: .asleepREM, sourceId: "com.apple.watch", sourceName: "Apple Watch"),
            // Second unspecified source covering 22:00-08:00 must be ignored when a stage-capable source exists.
            .init(start: date(2026, 11, 25, 22, 0, calendar: cal), end: date(2026, 11, 26, 8, 0, calendar: cal), stage: .asleepUnspecified, sourceId: "com.thirdparty.pillow", sourceName: "Pillow"),
        ]

        let summary = try XCTUnwrap(Readiness.summarizeSleep(samples, windowStart: window.start, windowEnd: window.end, now: now))
        XCTAssertTrue(summary.hasStages)
        XCTAssertEqual(summary.sourceName, "Apple Watch")
        XCTAssertEqual(summary.totalHours, 8.0, accuracy: 1e-6)
        XCTAssertEqual(summary.coreHours ?? -1, 4.0, accuracy: 1e-6)
        XCTAssertEqual(summary.deepHours ?? -1, 2.0, accuracy: 1e-6)
        XCTAssertEqual(summary.remHours ?? -1, 2.0, accuracy: 1e-6)
        XCTAssertFalse(summary.isProvisional)
    }

    func testSleepUnspecifiedMergesOverlappingSources() throws {
        let cal = calendar(identifier: "Asia/Tokyo")
        let window = try XCTUnwrap(Readiness.overnightWindow(for: "2026-11-26", calendar: cal))
        let now = date(2026, 11, 26, 13, 0, calendar: cal)

        let samples: [Readiness.SleepSample] = [
            .init(start: date(2026, 11, 25, 23, 0, calendar: cal), end: date(2026, 11, 26, 5, 0, calendar: cal), stage: .asleepUnspecified, sourceId: "app.a", sourceName: "App A"),
            .init(start: date(2026, 11, 26, 1, 0, calendar: cal), end: date(2026, 11, 26, 6, 30, calendar: cal), stage: .asleepUnspecified, sourceId: "app.b", sourceName: "App B"),
        ]

        let summary = try XCTUnwrap(Readiness.summarizeSleep(samples, windowStart: window.start, windowEnd: window.end, now: now))
        XCTAssertFalse(summary.hasStages)
        XCTAssertNil(summary.sourceName)
        XCTAssertEqual(summary.totalHours, 7.5, accuracy: 1e-6)
    }

    func testSleepOvernightWindowHandlesDSTSpringForwardAndFallBack() throws {
        let la = calendar(identifier: "America/Los_Angeles")
        // Spring forward on 2026-03-08 (2:00 AM skipped -> 18:00 to 12:00 is 17 hours)
        let spring = try XCTUnwrap(Readiness.overnightWindow(for: "2026-03-08", calendar: la))
        XCTAssertEqual(spring.end.timeIntervalSince(spring.start) / 3600.0, 17.0, accuracy: 1e-6)

        // Fall back on 2026-11-01 (1:00 AM repeated -> 18:00 to 12:00 is 19 hours)
        let fall = try XCTUnwrap(Readiness.overnightWindow(for: "2026-11-01", calendar: la))
        XCTAssertEqual(fall.end.timeIntervalSince(fall.start) / 3600.0, 19.0, accuracy: 1e-6)
    }

    func testProvisionalSleepSkipsShortSleepPenalty() throws {
        let cal = calendar(identifier: "Asia/Tokyo")
        let window = try XCTUnwrap(Readiness.overnightWindow(for: "2026-11-26", calendar: cal))
        // Only 4 hours synced so far, latest sample ended 15 minutes ago, still before 12:00 window end.
        let now = date(2026, 11, 26, 7, 15, calendar: cal)
        let samples: [Readiness.SleepSample] = [
            .init(start: date(2026, 11, 26, 3, 0, calendar: cal), end: date(2026, 11, 26, 7, 0, calendar: cal), stage: .asleepCore, sourceId: "watch", sourceName: "Apple Watch"),
        ]

        let sleep = try XCTUnwrap(Readiness.summarizeSleep(samples, windowStart: window.start, windowEnd: window.end, now: now))
        XCTAssertTrue(sleep.isProvisional)

        let result = Readiness.evaluate(Readiness.Input(
            signals: Readiness.HealthSignals(sleep: sleep),
            healthState: .available,
            load: emptyLoad(),
            plannedLoad: [:],
            hasTodayPlan: false
        ))
        XCTAssertTrue(result.sleepProvisional)
        XCTAssertEqual(result.verdict, .good)
        XCTAssertEqual(result.score, 80)
        XCTAssertFalse(result.reasons.contains { if case .shortSleep = $0.reason { return true }; return false })
    }

    // MARK: - HRV & RHR Tests

    func testHRVOvernightBucketingCalibrationAndDelta() throws {
        let cal = calendar(identifier: "Asia/Tokyo")
        // Build 5 prior nights (< 7 -> calibrating) + today overnight + a daytime sample to ignore.
        var samples: [Readiness.DatedValue] = [
            .init(date: date(2026, 11, 26, 3, 0, calendar: cal), value: 40),
            .init(date: date(2026, 11, 26, 5, 0, calendar: cal), value: 44),
            .init(date: date(2026, 11, 26, 14, 0, calendar: cal), value: 120), // daytime -> excluded
        ]
        for d in 21...25 {
            samples.append(.init(date: date(2026, 11, d, 4, 0, calendar: cal), value: 60))
        }
        let calSummary = try XCTUnwrap(Readiness.summarizeHRV(samples, today: "2026-11-26", calendar: cal))
        XCTAssertEqual(calSummary.latestMs ?? -1, 42.0, accuracy: 1e-6)
        XCTAssertTrue(calSummary.calibrating)
        XCTAssertNil(calSummary.baselineMs)
        XCTAssertNil(calSummary.deltaPct)

        // Add 3 more prior nights (total 8 >= 7 -> calibrated, excluding today from baseline).
        for d in 18...20 {
            samples.append(.init(date: date(2026, 11, d, 23, 0, calendar: cal), value: 60)) // 23:00 belongs to next night (19, 20, 21)
        }
        samples.append(.init(date: date(2026, 11, 17, 23, 0, calendar: cal), value: 60)) // belongs to night 18
        samples.append(.init(date: date(2026, 11, 16, 23, 0, calendar: cal), value: 60)) // belongs to night 17

        let full = try XCTUnwrap(Readiness.summarizeHRV(samples, today: "2026-11-26", calendar: cal))
        XCTAssertFalse(full.calibrating)
        XCTAssertEqual(full.baselineMs ?? -1, 60.0, accuracy: 1e-6)
        XCTAssertEqual(full.deltaPct ?? 0, (42.0 - 60.0) / 60.0, accuracy: 1e-6)
    }

    func testRHRFreshnessCutoffAndBaselineExcludesLatestSampleDay() throws {
        let cal = calendar(identifier: "Asia/Tokyo")
        let now = date(2026, 11, 26, 10, 0, calendar: cal)

        // Latest sample is yesterday at 08:00 (26h ago -> fresh, sampleDateISO = 2026-11-25) with huge spike 80 bpm.
        // Baseline must exclude 2026-11-25 so baseline stays 55 bpm across 7 earlier days (Nov 18..24).
        var samples: [Readiness.DatedValue] = [
            .init(date: date(2026, 11, 25, 8, 0, calendar: cal), value: 80),
        ]
        for d in 18...24 {
            samples.append(.init(date: date(2026, 11, d, 8, 0, calendar: cal), value: 55))
        }

        let summary = try XCTUnwrap(Readiness.summarizeRHR(samples, today: "2026-11-26", now: now, calendar: cal))
        XCTAssertEqual(summary.latestBpm ?? -1, 80.0, accuracy: 1e-6)
        XCTAssertEqual(summary.sampleDateISO, "2026-11-25")
        XCTAssertEqual(summary.daysCount, 7)
        XCTAssertFalse(summary.calibrating)
        XCTAssertEqual(summary.baselineBpm ?? -1, 55.0, accuracy: 1e-6)
        XCTAssertEqual(summary.deltaBpm ?? -1, 25.0, accuracy: 1e-6)

        // If newest sample is 40 hours old (> 36h), latestBpm must be nil.
        let staleNow = date(2026, 11, 27, 0, 0, calendar: cal)
        let stale = try XCTUnwrap(Readiness.summarizeRHR(samples, today: "2026-11-27", now: staleNow, calendar: cal))
        XCTAssertNil(stale.latestBpm)
        XCTAssertNil(stale.sampleDateISO)
    }

    // MARK: - Evaluator Invariants

    func testNoFalseRestWhenHealthKitMissingOrOff() {
        let missingResult = Readiness.evaluate(Readiness.Input(
            signals: nil,
            healthState: .available,
            load: emptyLoad(),
            plannedLoad: [:],
            hasTodayPlan: false
        ))
        XCTAssertEqual(missingResult.verdict, .good)
        XCTAssertEqual(missingResult.score, 80)
        XCTAssertEqual(missingResult.missingSignals, [.sleep, .hrv, .rhr])

        // Heavy training load + heavily fatigued planned muscle: `.off` must produce identical
        // verdict and score as `.unavailable` (R4).
        let heavyLoad = emptyLoad(
            acute: 60,
            chronic: 35,
            ratio: 60.0 / 35.0, // ~1.71 >= 1.5 (-20)
            muscles: ["chest": Recovery.MuscleDetail(fatigue: 0.78, lastSessionSets: 10, hoursToRecovered: 18)]
        )
        let offResult = Readiness.evaluate(Readiness.Input(
            signals: nil,
            healthState: .off,
            load: heavyLoad,
            plannedLoad: ["chest": 6.0],
            hasTodayPlan: true
        ))
        let unavailResult = Readiness.evaluate(Readiness.Input(
            signals: nil,
            healthState: .unavailable,
            load: heavyLoad,
            plannedLoad: ["chest": 6.0],
            hasTodayPlan: true
        ))

        XCTAssertEqual(offResult.verdict, unavailResult.verdict)
        XCTAssertEqual(offResult.score, unavailResult.score)
        XCTAssertEqual(offResult.missingSignals, [.sleep, .hrv, .rhr])
        XCTAssertEqual(offResult.verdict, .rest) // 80 - 20 - 18 = 42 < 45
        XCTAssertEqual(offResult.reasons.map(\.impact), [-20, -18])
    }

    func testVerdictTransitionsAndImpactSortedReasons() {
        let goodSignals = Readiness.HealthSignals(
            sleep: .init(totalHours: 8.0, deepHours: 1.8, remHours: 2.0, coreHours: 4.2, sourceName: "Watch", hasStages: true),
            hrv: .init(latestMs: 66, baselineMs: 58, nightsCount: 14, calibrating: false, deltaPct: 0.138),
            rhr: .init(latestBpm: 54, sampleDateISO: "2026-11-26", baselineBpm: 57, daysCount: 14, calibrating: false, deltaBpm: -3.0)
        )
        let good = Readiness.evaluate(Readiness.Input(
            signals: goodSignals,
            healthState: .available,
            load: emptyLoad(acute: 24, chronic: 24, ratio: 1.0),
            plannedLoad: [:],
            hasTodayPlan: true
        ))
        XCTAssertEqual(good.verdict, .good)
        XCTAssertEqual(good.score, 100)
        // Sorted strongest positive impact first: +10, +8, +5, +5
        XCTAssertEqual(good.reasons.first?.impact, 10)
        XCTAssertTrue(zip(good.reasons, good.reasons.dropFirst()).allSatisfy { $0.impact >= $1.impact })

        let lightSignals = Readiness.HealthSignals(
            sleep: .init(totalHours: 5.8, deepHours: nil, remHours: nil, coreHours: nil, sourceName: nil, hasStages: false),
            hrv: .init(latestMs: 50, baselineMs: 56, nightsCount: 14, calibrating: false, deltaPct: -0.107),
            rhr: .init(latestBpm: 57, sampleDateISO: "2026-11-26", baselineBpm: 57, daysCount: 14, calibrating: false, deltaBpm: 0)
        )
        let light = Readiness.evaluate(Readiness.Input(
            signals: lightSignals,
            healthState: .available,
            load: emptyLoad(),
            plannedLoad: [:],
            hasTodayPlan: false
        ))
        XCTAssertEqual(light.verdict, .light) // 80 - 12 - 10 = 58
        XCTAssertEqual(light.reasons.map(\.impact), [-12, -10])

        let restSignals = Readiness.HealthSignals(
            sleep: .init(totalHours: 4.8, deepHours: nil, remHours: nil, coreHours: nil, sourceName: nil, hasStages: false),
            hrv: .init(latestMs: 42, baselineMs: 58, nightsCount: 14, calibrating: false, deltaPct: -0.275),
            rhr: .init(latestBpm: 63, sampleDateISO: "2026-11-26", baselineBpm: 57, daysCount: 14, calibrating: false, deltaBpm: 6.0)
        )
        let rest = Readiness.evaluate(Readiness.Input(
            signals: restSignals,
            healthState: .available,
            load: emptyLoad(),
            plannedLoad: [:],
            hasTodayPlan: false
        ))
        XCTAssertEqual(rest.verdict, .rest) // 80 - 25 - 20 - 18 = 17
        XCTAssertEqual(rest.reasons.map(\.impact), [-25, -20, -18])
    }
}
