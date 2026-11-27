import Charts
import HexplateCore
import SwiftUI

/// The Nutrition tab: daily macro progress, gap-aware trends, selected-day meals (Hexplate + live
/// external Apple Health entries), nutrition goals, and segmental body scanner overview.
struct NutritionView: View {
    private enum NutritionRoute: Hashable {
        case bodyScans
    }

    private enum NutritionSheet: Identifiable {
        case scanMeal(date: String)
        case addMeal(date: String)
        case editMeal(Nutrition.Meal)
        case goals
        case addScan(day: String?)
        case healthSources

        var id: String {
            switch self {
            case .scanMeal(let date): "scanMeal-\(date)"
            case .addMeal(let date): "addMeal-\(date)"
            case .editMeal(let meal): "editMeal-\(meal.id)"
            case .goals: "goals"
            case .addScan(let day): "addScan-\(day ?? "new")"
            case .healthSources: "healthSources"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(HealthService.self) private var health
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("health") private var healthEnabledStorage = false

    @State private var selectedDay: String = Day.today()
    @State private var period: Nutrition.Period = .week
    @State private var trendMetric: Nutrition.Metric = .kcal
    @State private var bodyMetric: BodyData.SegmentMetric = .muscle
    @State private var sheet: NutritionSheet?
    @State private var deferWeighIn = false
    @State private var initializedDay = false

    private var healthEnabled: Bool {
        _ = healthEnabledStorage
        return health.isEnabled(root: model.root)
    }

    private var refreshKey: String {
        let excluded = health.excludedSourceIds.sorted().joined(separator: ",")
        return "\(model.today)|\(selectedDay)|\(period.rawValue)|\(healthEnabled)|\(excluded)"
    }

    private func present(_ next: NutritionSheet) {
        model.nutritionSheetOpen = true
        sheet = next
    }

    var body: some View {
        let goals = Nutrition.effectiveGoals(model.root)
        let externalForDay: Nutrition.Macros? = health.externalByDay.map { $0[selectedDay] ?? .zero }
        let dayTotals = Nutrition.dailyTotals(model.root, day: selectedDay, external: externalForDay)
        let dayMeals = Nutrition.meals(model.root, on: selectedDay)
        let externalMeals = health.externalItemsByDay[selectedDay] ?? []
        let series = Nutrition.dailySeries(model.root, period: period, today: model.today, externalByDay: health.externalByDay)
        let scans = BodyData.scanHistory(model.root)

        NavigationStack {
            List {
                if healthEnabled && health.authStatus == .shouldRequest {
                    Section {
                        Button("Enable new Health data", systemImage: "heart.badge.plus") {
                            Task {
                                _ = await health.authorise()
                                await health.refreshExternalNutrition(
                                    root: model.root,
                                    period: period,
                                    today: model.today,
                                    selectedDay: selectedDay
                                )
                            }
                        }
                    } footer: {
                        Text("Allow Apple Health nutrition permissions to read third-party meals and write your Hexplate meals.")
                    }
                }

                // MARK: Summary & Day Selector

                Section {
                    daySwitcherRow
                    macroSummaryRow(title: "Calories", unit: "kcal", value: dayTotals.total.kcal, goal: goals.kcal, subtitle: nil, decimals: 0)
                    macroSummaryRow(
                        title: "Protein",
                        unit: "g",
                        value: dayTotals.total.protein,
                        goal: goals.protein,
                        subtitle: goals.proteinIsDerived ? "\(Format.number(goals.proteinPerKg)) g/kg" : nil,
                        decimals: 0
                    )
                    macroSummaryRow(title: "Carbs", unit: "g", value: dayTotals.total.carbs, goal: goals.carbs, subtitle: nil, decimals: 0)
                    macroSummaryRow(title: "Fat", unit: "g", value: dayTotals.total.fat, goal: goals.fat, subtitle: nil, decimals: 0)
                } footer: {
                    if healthEnabled && health.externalUnavailable {
                        Text("Health data unavailable. Showing Hexplate meals only.")
                    } else if let ext = dayTotals.external, ext.isNonZero {
                        Text("Includes \(Format.number(ext.kcal, decimals: 0)) kcal from Apple Health.")
                    }
                }

                // MARK: Meals for Selected Day

                Section {
                    if dayMeals.isEmpty && externalMeals.isEmpty {
                        Text("No meals logged.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(dayMeals) { meal in
                            Button {
                                present(.editMeal(meal))
                            } label: {
                                mealRow(meal)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button("Delete", role: .destructive) {
                                    model.deleteMeal(id: meal.id)
                                }
                            }
                        }

                        ForEach(externalMeals) { ext in
                            externalMealRow(ext)
                        }
                    }

                    Button("Scan meal", systemImage: "camera.viewfinder") {
                        present(.scanMeal(date: selectedDay))
                    }

                    Button("Log meal", systemImage: "plus") {
                        present(.addMeal(date: selectedDay))
                    }
                } header: {
                    Text("Meals")
                }

                // MARK: Daily Trends

                Section("Daily trends") {
                    Picker("Period", selection: $period) {
                        ForEach(Nutrition.Period.allCases) { p in
                            Text(LocalizedStringKey(p.rawValue)).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Metric", selection: $trendMetric) {
                        Text("Calories").tag(Nutrition.Metric.kcal)
                        Text("Protein").tag(Nutrition.Metric.protein)
                        Text("Carbs").tag(Nutrition.Metric.carbs)
                        Text("Fat").tag(Nutrition.Metric.fat)
                    }
                    .pickerStyle(.segmented)

                    if series.isEmpty {
                        Text("No nutrition data in this period.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        let goalLine = goals.value(for: trendMetric)
                        let domain = trendXDomain
                        Chart {
                            ForEach(series) { point in
                                if let d = Day.date(point.day) {
                                    let y = point.total.value(for: trendMetric)
                                    LineMark(
                                        x: .value("Day", d),
                                        y: .value(metricUnit(trendMetric), y),
                                        series: .value("Run", point.run)
                                    )
                                    PointMark(
                                        x: .value("Day", d),
                                        y: .value(metricUnit(trendMetric), y)
                                    )
                                    .symbolSize(24)
                                }
                            }
                            if let goalLine, goalLine > 0 {
                                RuleMark(y: .value("Goal", goalLine))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .modifier(OptionalXDomain(domain: domain))
                        .chartXAxis {
                            switch period {
                            case .week:
                                AxisMarks(values: .stride(by: .day, count: 2)) {
                                    AxisGridLine()
                                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day().locale(Theme.locale))
                                }
                            case .month:
                                AxisMarks(values: .stride(by: .day, count: 7)) {
                                    AxisGridLine()
                                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day().locale(Theme.locale))
                                }
                            case .sixMonths:
                                AxisMarks(values: .stride(by: .month, count: 1)) {
                                    AxisGridLine()
                                    AxisValueLabel(format: .dateTime.month(.abbreviated).locale(Theme.locale))
                                }
                            }
                        }
                        .frame(height: 170)
                        .accessibilityLabel(trendAccessibilityLabel)
                    }
                }

                // MARK: Body Composition

                if Modules.isOn(model.root, "body") {
                    Section("Body composition") {
                        if let latest = scans.last {
                            if latest.hasSegmentalMuscle || latest.hasSegmentalFat {
                                SegmentalBodyCard(
                                    scan: latest,
                                    female: model.root["body"] == .string("female"),
                                    metric: $bodyMetric
                                )
                            } else {
                                if let bf = latest.bodyFat {
                                    LabeledContent("Body fat", value: "\(Format.number(bf)) %").monospacedDigit()
                                }
                                if let mm = latest.muscleMass {
                                    LabeledContent("Muscle mass", value: "\(Format.number(mm)) kg").monospacedDigit()
                                }
                            }

                            NavigationLink(value: NutritionRoute.bodyScans) {
                                LabeledContent("Body scans", value: "\(scans.count)")
                            }
                        } else {
                            Text("No body scans yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Button("Add scan", systemImage: "figure.arms.open") {
                            present(.addScan(day: nil))
                        }
                    }
                }
            }
            .navigationTitle("Nutrition")
            .navigationDestination(for: NutritionRoute.self) { route in
                switch route {
                case .bodyScans:
                    BodyScanView { day in
                        present(.addScan(day: day))
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Log meal", systemImage: "plus") {
                        present(.addMeal(date: selectedDay))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Nutrition goals", systemImage: "target") {
                            present(.goals)
                        }
                        if Modules.isOn(model.root, "body") {
                            Button("Add scan", systemImage: "figure.arms.open") {
                                present(.addScan(day: nil))
                            }
                        }
                        if healthEnabled {
                            Button("Nutrition sources", systemImage: "heart.text.square") {
                                present(.healthSources)
                            }
                        }
                    }
                }
            }
            // Clear `nutritionSheetOpen` ONLY in `onDismiss` so ProfileView waits until dismissal finishes.
            .sheet(item: $sheet, onDismiss: {
                deferWeighIn = false
                model.nutritionSheetOpen = false
            }) { active in
                switch active {
                case .scanMeal(let date):
                    AIMealCaptureSheet(defaultDate: date, deferWeighIn: $deferWeighIn)
                case .addMeal(let date):
                    MealEditorSheet(existing: nil, defaultDate: date)
                case .editMeal(let meal):
                    MealEditorSheet(existing: meal, defaultDate: meal.date)
                case .goals:
                    NutritionGoalsSheet()
                case .addScan(let day):
                    BodyScanSheet(initialDay: day)
                case .healthSources:
                    NavigationStack {
                        HealthNutritionSourcesPage()
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { sheet = nil }
                                }
                            }
                    }
                }
            }
            .onAppear {
                if !initializedDay {
                    initializedDay = true
                    selectedDay = model.today
                }
            }
            .onChange(of: model.today) { oldToday, newToday in
                if selectedDay == oldToday {
                    selectedDay = newToday
                }
            }
            .onChange(of: model.weighInRequested) {
                if model.weighInRequested && sheet != nil && !deferWeighIn {
                    sheet = nil
                }
            }
            .task(id: refreshKey) {
                await health.refreshAuthStatus()
                await health.refreshExternalNutrition(
                    root: model.root,
                    period: period,
                    today: model.today,
                    selectedDay: selectedDay
                )
            }
        }
    }

    // MARK: - Subviews

    private var daySwitcherRow: some View {
        HStack {
            Button {
                if let prev = Day.adding(-1, to: selectedDay) { selectedDay = prev }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Previous day")

            Spacer(minLength: 0)

            Text(dayHeading(selectedDay))
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)

            Button {
                if let next = Day.adding(1, to: selectedDay), next <= model.today {
                    selectedDay = next
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(selectedDay >= model.today)
            .accessibilityLabel("Next day")
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
    }

    private func dayHeading(_ iso: String) -> String {
        if iso == model.today { return String(localized: "Today") }
        return Day.date(iso)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Theme.locale)) ?? iso
    }

    @ViewBuilder
    private func macroSummaryRow(
        title: LocalizedStringKey,
        unit: String,
        value: Double,
        goal: Double?,
        subtitle: String?,
        decimals: Int
    ) -> some View {
        let valueText: String = if let goal, goal > 0 {
            "\(Format.number(value, decimals: decimals)) / \(Format.number(goal, decimals: decimals)) \(unit)"
        } else {
            "\(Format.number(value, decimals: decimals)) \(unit)"
        }

        let headerLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))

        VStack(alignment: .leading, spacing: 4) {
            headerLayout {
                HStack(spacing: 6) {
                    Text(title)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Text(verbatim: valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.subheadline)

            if let goal, goal > 0 {
                Gauge(value: min(value, goal), in: 0...goal) {}
                    .gaugeStyle(.linearCapacity)
                    .tint(Theme.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func mealRow(_ meal: Nutrition.Meal) -> some View {
        let hasName = !meal.name.isEmpty
        let title = hasName ? meal.name : (meal.mealType?.localizedTitle ?? String(localized: "Meal"))
        let badgeTitle = hasName ? meal.mealType?.localizedTitle : nil
        let details = macroDetailLine(kcal: meal.kcal, protein: meal.protein, carbs: meal.carbs, fat: meal.fat)
        let rowLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return rowLayout {
            VStack(alignment: .leading, spacing: 2) {
                if !typeSize.isAccessibilitySize, let badgeTitle {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(verbatim: badgeTitle)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                } else {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if let badgeTitle {
                        Text(verbatim: badgeTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                if !details.isEmpty {
                    Text(verbatim: details)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            if let time = meal.time {
                Text(verbatim: time)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func externalMealRow(_ ext: ExternalMealSummary) -> some View {
        let details = macroDetailLine(
            kcal: Nutrition.positive(ext.macros.kcal),
            protein: Nutrition.positive(ext.macros.protein),
            carbs: Nutrition.positive(ext.macros.carbs),
            fat: Nutrition.positive(ext.macros.fat)
        )
        let rowLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return rowLayout {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(ext.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                }
                Text(verbatim: details.isEmpty ? ext.sourceName : "\(ext.sourceName) · \(details)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            if let time = ext.time {
                Text(verbatim: time)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var trendXDomain: ClosedRange<Date>? {
        guard let range = Nutrition.periodRange(period, today: model.today),
              let start = Day.date(range.from),
              let end = Day.date(range.to),
              start <= end else { return nil }
        return start...end
    }

    private func macroDetailLine(kcal: Double?, protein: Double?, carbs: Double?, fat: Double?) -> String {
        var parts: [String] = []
        if let kcal { parts.append("\(Format.number(kcal, decimals: 0)) kcal") }
        if let protein { parts.append("P \(Format.number(protein, decimals: 0))g") }
        if let carbs { parts.append("C \(Format.number(carbs, decimals: 0))g") }
        if let fat { parts.append("F \(Format.number(fat, decimals: 0))g") }
        return parts.joined(separator: " · ")
    }

    private func metricUnit(_ m: Nutrition.Metric) -> String {
        m == .kcal ? "kcal" : "g"
    }

    private var trendAccessibilityLabel: LocalizedStringKey {
        switch trendMetric {
        case .kcal: "Daily calories over time"
        case .protein: "Daily protein over time"
        case .carbs: "Daily carbs over time"
        case .fat: "Daily fat over time"
        }
    }
}

private struct OptionalXDomain: ViewModifier {
    let domain: ClosedRange<Date>?

    func body(content: Content) -> some View {
        if let domain {
            content.chartXScale(domain: domain)
        } else {
            content
        }
    }
}
