import HexplateCore
import SwiftUI

/// The Profile tab: Settings, motivation cards, body weight, latest workout, training calendar,
/// 1RM progress, and last week's muscle targets.
struct ProfileView: View {
    private enum ProfileRoute: Hashable { case history }

    private struct DayWorkouts: Identifiable {
        let id: String
        let workoutIds: [String]
    }

    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var settings = false
    @State private var importing = false
    @State private var logging = false
    @State private var pickingDay: DayWorkouts?
    @State private var pendingWorkoutId: String?

    private var weekStart: Int { model.root["weekStart"] == .number(0) ? 0 : 1 }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            List {
                if Modules.isOn(model.root, "motivation") {
                    WrappedHomeSection()
                    StreakPartySection()
                    ChallengesSection()
                }

                // Look & Home -> Body weight (S.showWeightCard, Body module): latest weigh-in, weekly avg, and one-tap logging.
                if Modules.isOn(model.root, "body"), model.root["showWeightCard"] != .bool(false) {
                    Section {
                        let last = BodyData.weights(model.root).last
                        LabeledContent("Body weight") {
                            Text(last.map { "\(Format.number($0.weight, decimals: model.settings.weightDecimals)) \(model.settings.unit)" } ?? "–")
                                .monospacedDigit()
                        }
                        if let week = BodyData.weekAverage(model.root, today: model.today) {
                            LabeledContent("This week avg") {
                                HStack(spacing: 6) {
                                    Text("\(Format.number(week.avg, decimals: model.settings.weightDecimals)) \(model.settings.unit)")
                                    if let d = week.delta {
                                        Text("(\(signedDelta(d, decimals: model.settings.weightDecimals)))")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .monospacedDigit()
                            }
                        }
                        Button(last?.day == model.today ? "Change today’s weight" : "Log weight", systemImage: "scalemass") {
                            model.presentWeightSheet = true
                        }
                    }
                }

                if let latest = model.months.first?.items.first {
                    Section("Latest workout") {
                        NavigationLink(value: WorkoutLink(id: latest.id)) { WorkoutRow(item: latest) }
                    }
                }

                Section("Training calendar") {
                    TrainingCalendarView(
                        byDay: Stats.workoutsByDay(model.root),
                        today: model.today,
                        weekStart: weekStart
                    ) { iso, ids in
                        let validIds = ids.filter { model.workout(id: $0) != nil }
                        guard !validIds.isEmpty else { return }
                        if validIds.count == 1 {
                            path.append(WorkoutLink(id: validIds[0]))
                        } else {
                            pickingDay = DayWorkouts(id: iso, workoutIds: validIds)
                        }
                    }

                    if model.months.isEmpty {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No workouts yet").font(.headline)
                                Text("Import your backup to see your history here.").font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "dumbbell").foregroundStyle(.tint)
                        }
                        Button("Import data", systemImage: "square.and.arrow.down") { importing = true }
                    } else {
                        NavigationLink(value: ProfileRoute.history) {
                            LabeledContent("All workouts", value: "\(model.history?.workouts.count ?? 0)")
                        }
                    }
                }

                if Modules.isOn(model.root, "strength") {
                    RMProgressSection()
                }

                LastWeekTargetsSection()
            }
            .navigationTitle("Profile")
            .workoutDestination()
            .navigationDestination(for: LiftLink.self) { OneRepMaxView(id: $0.id) }
            .navigationDestination(for: ProfileRoute.self) { route in
                switch route {
                case .history:
                    HistoryListView(importing: $importing, logging: $logging)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { settings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Log a past workout", systemImage: "calendar.badge.plus") { logging = true }
                            .disabled(model.active != nil)
                        Button("Import data", systemImage: "square.and.arrow.down") { importing = true }
                    }
                }
            }
            .sheet(isPresented: $settings, onDismiss: drainWeighInRequest) { SettingsView() }
            .sheet(isPresented: $model.presentWeightSheet) { WeightEntry() }
            .sheet(isPresented: $importing, onDismiss: drainWeighInRequest) { ImportView() }
            .sheet(isPresented: $logging, onDismiss: {
                if model.isBackfill {
                    model.showWorkout = true
                } else {
                    drainWeighInRequest()
                }
            }) { LogPastWorkoutSheet() }
            .sheet(item: $pickingDay, onDismiss: {
                if let id = pendingWorkoutId {
                    pendingWorkoutId = nil
                    path.append(WorkoutLink(id: id))
                } else {
                    drainWeighInRequest()
                }
            }) { day in
                DayWorkoutPickerSheet(iso: day.id, workoutIds: day.workoutIds) { chosenId in
                    pendingWorkoutId = chosenId
                    pickingDay = nil
                }
            }
            .onAppear(perform: drainWeighInRequest)
            .onChange(of: model.weighInRequested) { drainWeighInRequest() }
            .onChange(of: model.nutritionSheetOpen) {
                if !model.nutritionSheetOpen { drainWeighInRequest() }
            }
            .onChange(of: model.homeSheetOpen) {
                if !model.homeSheetOpen { drainWeighInRequest() }
            }
            .onChange(of: model.analysisSheetOpen) {
                if !model.analysisSheetOpen { drainWeighInRequest() }
            }
        }
    }

    private func drainWeighInRequest() {
        guard model.weighInRequested, !model.showWorkout, model.wrappedYear == nil, !model.nutritionSheetOpen, !model.homeSheetOpen, !model.analysisSheetOpen else { return }
        if model.presentWeightSheet {
            model.weighInRequested = false
            return
        }
        if settings || importing || logging || pickingDay != nil {
            settings = false
            importing = false
            logging = false
            pickingDay = nil
            return
        }
        model.weighInRequested = false
        model.presentWeightSheet = true
    }
}

private func signedDelta(_ value: Double, decimals: Int = 1) -> String {
    let text = Format.number(abs(value), decimals: decimals)
    if text == "0" { return "0" }
    return (value > 0 ? "+" : "-") + text
}

/// Disambiguation picker when a calendar day contains more than one logged workout.
private struct DayWorkoutPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let iso: String
    let workoutIds: [String]
    let onPick: (String) -> Void

    private var itemsById: [String: AppModel.Item] {
        var map: [String: AppModel.Item] = [:]
        for month in model.months {
            for item in month.items { map[item.id] = item }
        }
        return map
    }

    var body: some View {
        let lookup = itemsById
        let title = Day.date(iso)?.formatted(.dateTime.day().month(.wide).year().locale(Theme.locale)) ?? iso
        NavigationStack {
            List {
                ForEach(workoutIds, id: \.self) { id in
                    Button {
                        onPick(id)
                    } label: {
                        if let item = lookup[id] {
                            WorkoutRow(item: item)
                        } else if let workout = model.workout(id: id) {
                            Text(workout.name ?? "Workout").font(.headline)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Estimated 1RM progress across Chest, Back, Shoulders, Legs, and Overall (4 weeks vs first record).
private struct RMProgressSection: View {
    private enum Comparison: String, CaseIterable, Identifiable {
        case fourWeeks = "4 weeks"
        case firstRecord = "First record"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var comparison: Comparison = .fourWeeks

    var body: some View {
        let rows = Stats.groupRMProgress(model.root, today: model.today, catalog: model.catalog)
        let activeGroups = rows.filter { $0.id != "Overall" && $0.current != nil }.count

        Section("Estimated 1RM progress") {
            if activeGroups == 0 {
                Text("No 1RM data yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Compare against", selection: $comparison) {
                    ForEach(Comparison.allCases) { mode in
                        Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                ForEach(rows) { row in
                    if let exId = row.exerciseId {
                        NavigationLink(value: LiftLink(id: exId)) {
                            rowContent(row, activeGroups: activeGroups)
                        }
                    } else {
                        rowContent(row, activeGroups: activeGroups)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ row: Stats.GroupRMProgress, activeGroups: Int) -> some View {
        let delta = comparison == .fourWeeks ? row.change4w : row.changeFromFirst
        let headlineValue: Double? = row.id == "Overall" ? (delta?.current ?? row.current) : row.current
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))

        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(row.id))
                    .font(row.id == "Overall" ? .headline : .body)
                if let exId = row.exerciseId, let name = model.catalog[exId]?.displayName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if row.id == "Overall", let delta, delta.groupCount < activeGroups {
                    Text(String(localized: "\(delta.groupCount) of \(activeGroups) groups"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !typeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }

            VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                if let value = headlineValue {
                    Text("\(Format.number(value)) \(model.settings.unit)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                } else {
                    Text("–")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let delta {
                    let unitText = "\(signedDelta(delta.delta)) \(model.settings.unit)"
                    let pctText = delta.pct.map { " (\(signedDelta($0))%)" } ?? ""
                    Text(unitText + pctText)
                        .font(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .foregroundStyle(delta.delta > 0 ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                } else if headlineValue != nil {
                    Text("–")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Previous profile week's effective sets per muscle rendered with native linearCapacity gauges.
private struct LastWeekTargetsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = Stats.lastWeekMuscleSets(model.root, today: model.today, catalog: model.catalog)
        Section {
            ForEach(rows, id: \.slug) { row in
                MuscleTargetRow(row: row)
            }
        } header: {
            Text("Last week’s targets")
        } footer: {
            Text("Ticked-off work sets, shared out by how much each exercise works a muscle.")
        }
    }
}
