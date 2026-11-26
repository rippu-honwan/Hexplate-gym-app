import HexplateCore
import SwiftUI

/// Today: readiness overview, today's planned workout, nutrition rings with AI meal capture,
/// how the week stands, and the rotation loop.
struct HomeView: View {
    private enum HomeSheet: Identifiable {
        case choosingPlan
        case importing
        case swapping
        case scanMeal
        case logMeal

        var id: String {
            switch self {
            case .choosingPlan: "choosingPlan"
            case .importing: "importing"
            case .swapping: "swapping"
            case .scanMeal: "scanMeal"
            case .logMeal: "logMeal"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(HealthService.self) private var health
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("health") private var healthEnabledStorage = false

    @State private var sheet: HomeSheet?
    @State private var deferWeighIn = false

    private var healthEnabled: Bool {
        _ = healthEnabledStorage
        return health.isEnabled(root: model.root)
    }

    private var refreshKey: String {
        let excluded = health.excludedSourceIds.sorted().joined(separator: ",")
        return "\(model.today)|\(healthEnabled)|\(excluded)"
    }

    private func present(_ next: HomeSheet) {
        model.homeSheetOpen = true
        sheet = next
    }

    var body: some View {
        let todayIds = Schedule.routineIds(model.root, on: model.today, today: model.today)
        let todayCtx = health.evaluateTodaySnapshot(root: model.root, today: model.today, now: model.now, catalog: model.catalog)
        let load = todayCtx.load
        let readiness = todayCtx.readiness
        let goals = Nutrition.effectiveGoals(model.root)
        let todayTotals = Nutrition.dailyTotals(model.root, day: model.today, external: todayCtx.externalToday)

        NavigationStack {
            List {
                if healthEnabled && health.authStatus == .shouldRequest {
                    Section {
                        Button("Enable new Health data", systemImage: "heart.badge.plus") {
                            Task {
                                _ = await health.authorise()
                                await health.refreshReadiness(root: model.root, today: model.today)
                                await health.refreshTodayExternalNutrition(root: model.root, today: model.today)
                            }
                        }
                    } footer: {
                        Text("Allow Apple Health permissions for sleep, HRV, resting heart rate, and nutrition.")
                    }
                }

                // MARK: Readiness Card

                Section {
                    ReadinessCard(
                        result: readiness,
                        signals: todayCtx.signals,
                        load: load,
                        today: model.today
                    )
                } header: {
                    if let date = Day.date(model.today) {
                        Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Theme.locale)))
                    }
                } footer: {
                    if let footer = readinessFooter(readiness) {
                        Text(footer)
                    }
                }

                // MARK: Today's Planned Workout

                Section {
                    today(ids: todayIds)
                } header: {
                    Text("Today’s workout")
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        if let chip = Programmes.chip(model.root, today: model.today) { Label(chip, systemImage: "calendar.badge.clock") }
                        if let next { Text(next) }
                    }
                }

                // A new profile: a ready-made plan, your own, or your old app's data (Home.jsx Welcome).
                if model.routines.isEmpty && model.active == nil {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Welcome!").font(.headline)
                                Text("Set up your weekly routine to get going, or grab a ready-made starter plan.").font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "calendar").foregroundStyle(.tint) }
                        Button("Load starter plan", systemImage: "list.clipboard") { present(.choosingPlan) }
                        Button("Build my own plan", systemImage: "square.and.pencil") {
                            model.gymSegment = .plan
                            model.tab = "gym"
                        }
                        Button("Import data", systemImage: "square.and.arrow.down") { present(.importing) }
                    }
                }

                // MARK: Nutrition Rings & AI Meal Capture

                Section {
                    NutritionRingsCard(totals: todayTotals.total, goals: goals) {
                        model.tab = "nutrition"
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))

                    Button("Scan meal", systemImage: "camera.viewfinder") {
                        present(.scanMeal)
                    }
                    Button("Log meal", systemImage: "plus") {
                        present(.logMeal)
                    }
                } header: {
                    let headerLayout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout())
                    headerLayout {
                        Text("Nutrition")
                        if !typeSize.isAccessibilitySize {
                            Spacer()
                        }
                        Button("View all") {
                            model.tab = "nutrition"
                        }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                    }
                } footer: {
                    if healthEnabled && health.externalUnavailable {
                        Text("Health data unavailable. Showing Hexplate meals only.")
                    } else if let ext = todayTotals.external, ext.isNonZero {
                        Text("Includes \(Format.number(ext.kcal, decimals: 0)) kcal from Apple Health.")
                    }
                }

                // Look & Home -> Recovery tips (openGym S.recoveryHint, Health module).
                if Modules.isOn(model.root, "health"), model.root["recoveryHint"] != .bool(false),
                   let hint = Recovery.hint(model.root, now: model.now, today: model.today, catalog: model.catalog) {
                    Section { RecoveryCard(hint: hint) { present(.swapping) } }
                }

                if model.root["homeMuscleSets"] == .bool(true) { MuscleSetsSection() }

                Section {
                    WeekStrip(days: week)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8))
                } header: {
                    Text("This week")
                } footer: {
                    if let left = Schedule.workoutsLeft(model.root, today: model.today) {
                        Text(left.left == 0 ? "All done this week. Nice." : "\(left.left) of \(left.of) left this week")
                    }
                }

                if Schedule.scheduleMode(model.root) == "rotation", let view = Schedule.queueView(model.root, today: model.today) {
                    Section(view.label.isEmpty ? "The loop" : view.label) {
                        ForEach(view.items) { QueueRow(item: $0) }
                    }
                }
            }
            .navigationTitle("Today")
            .toolbar {
                if model.active == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Empty workout", systemImage: "plus") {
                            model.startWorkout(routineIds: [])
                            model.showWorkout = true
                        }
                    }
                }
            }
            .sheet(item: $sheet, onDismiss: {
                deferWeighIn = false
                model.homeSheetOpen = false
            }) { activeSheet in
                switch activeSheet {
                case .choosingPlan:
                    StarterPlanSheet()
                case .importing:
                    ImportView()
                case .swapping:
                    DaySwapSheet(iso: model.today)
                case .scanMeal:
                    AIMealCaptureSheet(defaultDate: model.today, deferWeighIn: $deferWeighIn)
                case .logMeal:
                    MealEditorSheet(defaultDate: model.today)
                }
            }
            .task(id: refreshKey) {
                await health.refreshReadiness(root: model.root, today: model.today)
                await health.refreshTodayExternalNutrition(root: model.root, today: model.today)
            }
            .onChange(of: model.weighInRequested) {
                // Defer dismissing an active AI analysis or unsaved AI draft so paid estimates are not lost.
                if model.weighInRequested, sheet != nil, !deferWeighIn {
                    sheet = nil
                }
            }
        }
    }

    @ViewBuilder private func today(ids: [String]) -> some View {
        let canonicalIds = Set(ids.map { Schedule.canonical(model.root, $0) })
        let done = model.history?.workouts.filter { $0.date == model.today } ?? []
        if ids.isEmpty && done.isEmpty {
            Label("Rest day", systemImage: "moon.fill")
                .foregroundStyle(.secondary)
        }
        ForEach(ids, id: \.self) { id in
            if let routine = model.routine(id) {
                let cid = Schedule.canonical(model.root, id)
                let logged = done.first { $0.routineId == cid }
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(routine.name).font(.headline)
                            HStack(spacing: 6) {
                                Text(routine.slots.count == 1 ? "1 exercise" : "\(routine.slots.count) exercises")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if routine.isAIClone {
                                    Text("AI-adjusted")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tint)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.tint.opacity(0.14), in: Capsule())
                                }
                            }
                        }
                    } icon: {
                        Image(systemName: routine.symbol).foregroundStyle(.tint)
                    }
                    Spacer()
                    if logged != nil {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                    } else if model.active == nil {
                        Button("Start") {
                            model.startWorkout(routineIds: [id])
                            model.showWorkout = true
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Theme.ink)
                        .accessibilityLabel("Start \(routine.name)")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        // Trained today on something the plan did not hold.
        ForEach(done.filter { w in !canonicalIds.contains(w.routineId ?? "") }) { w in
            Label(w.name ?? "Workout", systemImage: "checkmark.circle.fill")
        }
    }

    private func readinessFooter(_ result: Readiness.Result) -> String? {
        if result.sleepProvisional {
            return String(localized: "Sleep still syncing. Readiness will update once your watch finishes syncing.")
        }
        switch result.healthState {
        case .off:
            return String(localized: "Apple Health is off. Readiness is based on your training load.")
        case .unavailable:
            return String(localized: "Health data unavailable. Readiness is based on your training load.")
        case .available:
            var parts: [String] = []
            if !result.missingSignals.isEmpty {
                let names = result.missingSignals.map(Self.signalName).joined(separator: ", ")
                parts.append(String(localized: "Missing: \(names)."))
            }
            if !result.calibratingSignals.isEmpty {
                parts.append(String(localized: "Baseline calibrating (needs 7 nights)."))
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    private static func signalName(_ kind: Readiness.SignalKind) -> String {
        switch kind {
        case .sleep: String(localized: "Sleep")
        case .hrv: String(localized: "HRV")
        case .rhr: String(localized: "Resting HR")
        }
    }

    private var next: String? {
        guard let day = Schedule.nextTrainingDay(model.root, after: model.today, today: model.today),
              let date = Day.date(day.iso) else { return nil }
        let names = day.routineIds.compactMap { model.routine($0)?.name }.joined(separator: " + ")
        return String(localized: "Next session: \(date.formatted(.dateTime.weekday(.wide).locale(Theme.locale))), \(names)")
    }

    private var week: [WeekStrip.DayCell] {
        let start = Schedule.weekKey(model.today, weekStart: model.root["weekStart"] == .number(0) ? 0 : 1) ?? model.today
        let trained = Set(model.history?.workouts.map(\.date) ?? [])
        return (0..<7).compactMap { Day.adding($0, to: start) }.map { iso in
            let date = Day.date(iso)
            return WeekStrip.DayCell(
                id: iso,
                letter: date?.formatted(.dateTime.weekday(.narrow).locale(Theme.locale)) ?? "",
                number: date.map { String(Calendar.current.component(.day, from: $0)) } ?? "",
                spoken: date?.formatted(.dateTime.weekday(.wide).day().locale(Theme.locale)) ?? iso,
                trained: trained.contains(iso),
                planned: !Schedule.routineIds(model.root, on: iso, today: model.today).isEmpty,
                isToday: iso == model.today
            )
        }
    }
}

// MARK: - Readiness Card

private struct ReadinessCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .callout) private var rawScoreRingSize: CGFloat = 48
    let result: Readiness.Result
    let signals: Readiness.HealthSignals?
    let load: Recovery.LoadSummary
    let today: String

    private var scoreRingSize: CGFloat { min(rawScoreRingSize, 88) }

    private var verdictTitle: String {
        switch result.verdict {
        case .good: String(localized: "Ready to train")
        case .light: String(localized: "Go lighter today")
        case .rest: String(localized: "Consider rest")
        }
    }

    private var columns: [GridItem] {
        let count = typeSize.isAccessibilitySize ? 2 : 4
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let headerLayout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))

            headerLayout {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Readiness")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(verdictTitle)
                        .font(.title3.weight(.semibold))
                }
                if !typeSize.isAccessibilitySize {
                    Spacer(minLength: 8)
                }
                scoreRing
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(String(localized: "Readiness")): \(verdictTitle), \(result.score) / 100")

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                metricCell(
                    title: "Sleep",
                    value: signals?.sleep.map { "\(Format.number($0.totalHours, decimals: 1)) h" } ?? "–",
                    subtitle: result.sleepProvisional ? String(localized: "Syncing") : nil
                )
                metricCell(
                    title: "HRV",
                    value: signals?.hrv?.latestMs.map { "\(Format.number($0, decimals: 0)) ms" } ?? "–",
                    subtitle: signals?.hrv?.calibrating == true ? String(localized: "Calibrating") : nil
                )
                metricCell(
                    title: "Resting HR",
                    value: signals?.rhr?.latestBpm.map { "\(Format.number($0, decimals: 0)) bpm" } ?? "–",
                    subtitle: rhrDateSubtitle
                )
                metricCell(
                    title: "Load",
                    value: load.global.ratio.map { "\(Format.number($0, decimals: 2))×" } ?? "–",
                    subtitle: nil
                )
            }

            if !result.reasons.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(result.reasons.prefix(3).enumerated()), id: \.offset) { _, scored in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle()
                                .fill(scored.impact < 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                            Text(reasonText(scored.reason))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var scoreRing: some View {
        let strokeWidth: CGFloat = typeSize.isAccessibilitySize ? 6 : 5
        return ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: strokeWidth)
            Circle()
                .trim(from: 0, to: CGFloat(result.score) / 100.0)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(result.score)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, 8)
        }
        .frame(width: scoreRingSize, height: scoreRingSize)
        .accessibilityHidden(true)
    }

    private var rhrDateSubtitle: String? {
        if signals?.rhr?.calibrating == true {
            return String(localized: "Calibrating")
        }
        guard let iso = signals?.rhr?.sampleDateISO else { return nil }
        if iso == today { return String(localized: "Today") }
        if let yesterday = Day.adding(-1, to: today), iso == yesterday {
            return String(localized: "Yesterday")
        }
        return Day.date(iso)?.formatted(.dateTime.day().month(.abbreviated).locale(Theme.locale)) ?? iso
    }

    private func metricCell(title: LocalizedStringKey, value: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func reasonText(_ reason: Readiness.Reason) -> String {
        switch reason {
        case .goodSleep(let hours):
            String(localized: "Good sleep last night (\(Format.number(hours, decimals: 1)) h).")
        case .shortSleep(let hours):
            String(localized: "Short sleep last night (\(Format.number(hours, decimals: 1)) h).")
        case .strongHRV(let delta):
            String(localized: "HRV is above your 28-day baseline (+\(Int((delta * 100).rounded()))%).")
        case .lowHRV(let delta):
            String(localized: "HRV is below your 28-day baseline (\(Int((delta * 100).rounded()))%).")
        case .lowRHR(let delta):
            String(localized: "Resting HR is below baseline (\(Format.number(delta, decimals: 0)) bpm).")
        case .elevatedRHR(let delta):
            String(localized: "Resting HR is above baseline (+\(Format.number(delta, decimals: 0)) bpm).")
        case .highTrainingLoad(let ratio):
            String(localized: "7-day training load is much higher than usual (\(Format.number(ratio, decimals: 2))×).")
        case .elevatedTrainingLoad(let ratio):
            String(localized: "7-day training load is higher than usual (\(Format.number(ratio, decimals: 2))×).")
        case .balancedTrainingLoad:
            String(localized: "Training load is well balanced.")
        case .plannedMusclesRecovering(let hours):
            String(localized: "Planned muscles are still recovering (~\(max(1, Int(hours.rounded()))) h left).")
        }
    }
}

// MARK: - Nutrition 4-Ring Dashboard Card

private struct NutritionRingsCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var rawRingSize: CGFloat = 56
    let totals: Nutrition.Macros
    let goals: Nutrition.EffectiveGoals
    let onSetGoal: () -> Void

    private var ringSize: CGFloat { min(rawRingSize, 100) }

    private var columns: [GridItem] {
        let count = typeSize.isAccessibilitySize ? 2 : 4
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ring(title: "Calories", unit: "kcal", value: totals.kcal, goal: goals.kcal)
            ring(title: "Protein", unit: "g", value: totals.protein, goal: goals.protein)
            ring(title: "Carbs", unit: "g", value: totals.carbs, goal: goals.carbs)
            ring(title: "Fat", unit: "g", value: totals.fat, goal: goals.fat)
        }
    }

    private func ring(title: LocalizedStringKey, unit: String, value: Double, goal: Double?) -> some View {
        let progress: Double = {
            guard let goal, goal > 0 else { return 0 }
            return min(1.0, max(0.0, value / goal))
        }()
        let valueText = Format.number(value, decimals: 0)
        let goalText = goal.map { "\(Format.number($0, decimals: 0)) \(unit)" }
        let strokeWidth: CGFloat = typeSize.isAccessibilitySize ? 7 : 6

        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: strokeWidth)
                if progress > 0 {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(valueText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(.horizontal, 10)
            }
            .frame(width: ringSize, height: ringSize)

            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.center)

            if let goalText {
                Text("/ \(goalText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else {
                Button("Set goal", action: onSetGoal)
                    .font(.caption2.weight(.medium))
                    .buttonStyle(.borderless)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A muscle group still recovering, or one left alone for a while (RecoveryHint.jsx).
private struct RecoveryCard: View {
    @Environment(AppModel.self) private var model
    let hint: Recovery.Hint
    let swap: () -> Void

    var body: some View {
        let words = Recovery.text(hint, today: model.today)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Recovery").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(words.0).font(.headline)
                Text(words.1).font(.subheadline).foregroundStyle(.secondary)
                if hint.kind == "lighter" {
                    Button("Swap session", systemImage: "arrow.left.arrow.right", action: swap)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Button("Hide for today", systemImage: "xmark") { model.set("recoveryHintDay", .string(model.today)) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Pick what to train on one day instead of the weekly plan (sheets.jsx DayOverride).
struct DaySwapSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let iso: String

    var body: some View {
        let plan = model.root["dayPlan"]?.object ?? [:]
        let current = Set(Schedule.routineIds(model.root, on: iso, today: model.today).map { Schedule.canonical(model.root, $0) })
        var weekly = model.root
        weekly["dayPlan"] = .object(plan.filter { $0.key != iso })
        let weeklyNames = Schedule.routineIds(weekly, on: iso, today: model.today).compactMap { model.routine($0)?.name }
        return NavigationStack {
            List {
                Section {
                    ForEach(model.routines) { r in
                        Button { set(.string(r.id)) } label: {
                            HStack {
                                Label(r.name, systemImage: r.symbol)
                                Spacer()
                                if current.contains(r.id) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    Button("Rest", systemImage: "moon.fill") { set(.string("rest")) }.foregroundStyle(.primary)
                } header: {
                    Text("Weekly plan: \(weeklyNames.isEmpty ? "Rest" : weeklyNames.joined(separator: " + "))")
                } footer: {
                    Text("Sick, missed a day or want a different session? Pick what to train instead.")
                }
                if plan[iso] != nil {
                    Button("Back to weekly plan", systemImage: "arrow.uturn.backward") { set(nil) }
                }
            }
            .navigationTitle(Day.date(iso)?.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Theme.locale)) ?? iso)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func set(_ v: JSONValue?) {
        model.change { root in
            var plan = root["dayPlan"]?.object ?? [:]
            plan[iso] = v
            root["dayPlan"] = .object(plan)
        }
        dismiss()
    }
}

/// Seven days: filled when trained, ringed when something is planned, today marked underneath.
private struct WeekStrip: View {
    struct DayCell: Identifiable {
        let id: String
        let letter: String
        let number: String
        let spoken: String
        let trained: Bool
        let planned: Bool
        let isToday: Bool
    }

    let days: [DayCell]
    @ScaledMetric(relativeTo: .body) private var size = 36.0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    Text(day.letter)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(day.number)
                        .font(.callout.weight(day.isToday ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(day.trained ? AnyShapeStyle(Theme.ink) : day.planned || day.isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(width: size, height: size)
                        .background {
                            if day.trained { Circle().fill(.tint) }
                            else if day.planned { Circle().strokeBorder(.tint.opacity(0.7), lineWidth: 1.5) }
                        }
                    Circle()
                        .fill(day.isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(.clear))
                        .frame(width: 4, height: 4)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([day.spoken, day.isToday ? "today" : nil, day.trained ? "trained" : day.planned ? "planned" : "rest"].compactMap { $0 }.joined(separator: ", "))
            }
        }
    }
}

/// One session of the loop's current pass.
struct QueueRow: View {
    let item: Schedule.QueueView.Item

    var body: some View {
        HStack {
            Image(systemName: item.state == "done" ? "checkmark.circle.fill" : item.state == "next" ? "circle.inset.filled" : item.state == "pinned" ? "pin.fill" : "circle")
                .foregroundStyle(item.state == "next" ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(item.name)
                .foregroundStyle(item.state == "done" ? .secondary : .primary)
            Spacer()
            if item.state == "next" {
                Text("Up next").font(.subheadline).foregroundStyle(.tint)
            } else if let on = item.on, let date = Day.date(on) {
                Text(date.formatted(.dateTime.weekday(.abbreviated).day().locale(Theme.locale)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The four starter plans; a plan that would take over a planned weekday asks first.
struct StarterPlanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirming: StarterPlans.Plan?

    var body: some View {
        NavigationStack {
            List(StarterPlans.all) { plan in
                Button { if StarterPlans.takesOverDays(model.root, plan) { confirming = plan } else { load(plan) } } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.name)
                        Text("\(plan.days) days per week · \(plan.about)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
            .navigationTitle("Choose starter plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Load \(confirming?.name ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { plan in
                Button("Load plan") { load(plan) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in Text("The new plan takes over its weekdays. Your existing routines stay.") }
        }
    }

    private func load(_ plan: StarterPlans.Plan) {
        let t = model.now
        var n = 0
        model.change { StarterPlans.load(&$0, plan) { n += 1; return RoutineOps.newId(now: t + Double(n)) } }
        dismiss()
    }
}
