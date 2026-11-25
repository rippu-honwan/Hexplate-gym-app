import HexplateCore
import SwiftUI

/// The Gym tab: summary card + radar chart above Plan, Programmes, and Exercises under one navigation stack.
struct GymView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var editMode: EditMode = .inactive
    @State private var period: Stats.SummaryPeriod = .month
    @State private var filter = ExerciseFilter()
    @State private var favouritesOnly = false
    @State private var customOnly = false
    @State private var mineOnly = true
    @State private var creating = false

    private var activeEquipmentProfile: [String: JSONValue]? { ExerciseCatalog.activeProfile(model.root) }
    private var isExercisesFiltered: Bool { favouritesOnly || customOnly }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch model.gymSegment {
                case .plan:
                    PlanContent(path: $path, period: $period)
                case .programmes:
                    ProgrammesContent(period: $period)
                case .exercises:
                    LibraryContent(
                        period: $period,
                        filter: $filter,
                        favouritesOnly: $favouritesOnly,
                        customOnly: $customOnly,
                        mineOnly: $mineOnly
                    )
                }
            }
            .navigationTitle("Gym")
            .toolbar {
                if model.gymSegment == .plan && model.routines.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
                if model.gymSegment == .exercises {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Filter", systemImage: isExercisesFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease") {
                            Toggle("Favourites", systemImage: "star", isOn: $favouritesOnly)
                            Toggle("My exercises", systemImage: "person", isOn: $customOnly)
                            if activeEquipmentProfile != nil {
                                Toggle("My equipment only", systemImage: "dumbbell", isOn: $mineOnly)
                            }
                            if isExercisesFiltered || filter.isOn {
                                Button("Clear", systemImage: "xmark") {
                                    filter = ExerciseFilter()
                                    favouritesOnly = false
                                    customOnly = false
                                }
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New exercise", systemImage: "plus") { creating = true }
                    }
                }
            }
            // Applied outside .toolbar so EditButton toggles GymView's owned editMode binding.
            .environment(\.editMode, $editMode)
            .sheet(isPresented: $creating) { CustomExerciseEditor() }
            .navigationDestination(for: RoutineLink.self) { RoutineEditorView(routineId: $0.id) }
            .navigationDestination(for: ProgrammeLink.self) { ProgrammeEditor(id: $0.id) }
            .exerciseDestination()
            .workoutDestination()
        }
        .onChange(of: model.gymSegment) {
            editMode = .inactive
            path = NavigationPath()
        }
        .onChange(of: model.gymResetToken) {
            editMode = .inactive
            path = NavigationPath()
        }
    }
}

/// Scrollable top sections shared by Plan, Programmes, and Exercises: summary card + segment picker.
struct GymHeader: View {
    @Binding var period: Stats.SummaryPeriod

    var body: some View {
        GymSummarySection(period: $period)
        GymSegmentSection()
    }
}

private struct GymSummarySection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var period: Stats.SummaryPeriod

    var body: some View {
        // ponytail: decodes up to 1Y of workouts when root or period changes; cache keyed by (root._ts, period) if 1Y ever lags.
        let summary = Stats.dailyVolumeSummary(model.root, period: period, today: model.today, catalog: model.catalog)
        let radar = Stats.trainingBalanceRadar(model.root, today: model.today, catalog: model.catalog)
        let kpiLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))

        Section {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Summary period", selection: $period) {
                    ForEach(Stats.SummaryPeriod.allCases) { p in
                        Text(LocalizedStringKey(p.rawValue)).tag(p)
                    }
                }
                .pickerStyle(.segmented)

                kpiLayout {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily avg volume")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Format.number(summary.avgDailyVolume, decimals: model.settings.weightDecimals)) \(model.settings.unit)")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily avg sets")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Format.number(summary.avgDailySets, decimals: 1))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }

                Divider()

                Text("4-week balance")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                RadarChart(axes: radar)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct GymSegmentSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Picker("Gym", selection: $model.gymSegment) {
                Text("Plan").tag(AppModel.GymSegment.plan)
                Text("Programmes").tag(AppModel.GymSegment.programmes)
                Text("Exercises").tag(AppModel.GymSegment.exercises)
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }
}
