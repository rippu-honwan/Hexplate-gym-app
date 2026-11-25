import HexplateCore
import SwiftUI

/// Every logged workout, newest first, a section per month. Read only.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var deleting: AppModel.Item?
    @State private var logging = false

    var body: some View {
        NavigationStack {
            Group {
                if model.months.isEmpty {
                    ContentUnavailableView {
                        Label("No workouts yet", systemImage: "dumbbell")
                    } description: {
                        Text("Import your backup to see your history here.")
                    } actions: {
                        Button("Import data") { importing = true }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(Theme.ink)
                    }
                } else {
                    List(model.months) { month in
                        Section(month.title) {
                            ForEach(month.items) { item in
                                NavigationLink(value: WorkoutLink(id: item.id)) { WorkoutRow(item: item) }
                                    .swipeActions {
                                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .workoutDestination()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Log a past workout", systemImage: "calendar.badge.plus") { logging = true }
                            .disabled(model.active != nil)
                        Button("Import data", systemImage: "square.and.arrow.down") { importing = true }
                    }
                }
            }
            .sheet(isPresented: $importing) { ImportView() }
            .sheet(isPresented: $logging, onDismiss: { if model.isBackfill { model.showWorkout = true } }) { LogPastWorkoutSheet() }
            .alert("Delete this workout?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { item in
                Button("Delete", role: .destructive) { model.deleteWorkout(id: item.id) }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text("\(item.workout.name ?? "This workout") is removed from your history for good.")
            }
        }
    }
}

struct WorkoutRow: View {
    let item: AppModel.Item
    @ScaledMetric(relativeTo: .title3) private var tile = 46.0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text(item.weekday)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.day)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            .frame(width: tile, height: tile)
            .background(.fill.tertiary, in: .rect(cornerRadius: 10))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.workout.name ?? "Workout")
                    .font(.headline)
                // One line at ordinary sizes; a line each once the text is too large to share one.
                Text(item.metrics.joined(separator: typeSize.isAccessibilitySize ? "\n" : " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if item.workout.recordCount > 0 {
                    RecordBadge(count: item.workout.recordCount)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
        // One separator inset for every row, with or without a badge.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        var parts = [item.workout.name ?? "Workout", item.dateSpoken] + item.metrics
        if item.workout.recordCount > 0 { parts.append(RecordBadge.spoken(item.workout.recordCount)) }
        return parts.joined(separator: ", ")
    }
}

/// Purple means one thing: a personal record.
struct RecordBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "trophy.fill")
            Text("\(count) PR")
        }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.record)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.record.opacity(0.16), in: .capsule)
            .accessibilityLabel(Self.spoken(count))
    }

    static func spoken(_ n: Int) -> String { n == 1 ? "1 personal record" : "\(n) personal records" }
}

/// A workout's id pushed on a navigation stack opens its detail.
struct WorkoutLink: Hashable { let id: String }

extension View {
    func workoutDestination() -> some View { modifier(WorkoutDestination()) }
}

private struct WorkoutDestination: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.navigationDestination(for: WorkoutLink.self) { link in
            if let workout = model.workout(id: link.id), let history = model.history {
                WorkoutDetailView(workout: workout, history: history)
            }
        }
    }
}

/// When, how long and which routine for a workout logged after the fact (sheets.jsx LogPastWorkout).
/// A day that already has a workout asks whether to replace it or add a second one.
struct LogPastWorkoutSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var start = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0,
                                                     of: Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now) ?? .now
    @State private var minutes = 60
    @State private var routineId = ""
    @State private var sameDay: [AppModel.Object] = []

    var body: some View {
        let future = start.addingTimeInterval(Double(minutes) * 60) > .now
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $start, in: ...Date.now, displayedComponents: .date)
                    DatePicker("Start time", selection: $start, displayedComponents: .hourAndMinute)
                    Stepper("Duration: \(minutes) min", value: $minutes, in: 1...Backfill.maxDurationMin, step: 5)
                } footer: {
                    Text(future ? "That’s still in the future. Try an earlier start." : "Logged on the usual workout screen, without timers.")
                        .foregroundStyle(future ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                }
                Picker("Routine", selection: $routineId) {
                    Text("Freestyle").tag("")
                    ForEach(routines.indices, id: \.self) { i in
                        Text(routines[i]["name"]?.stringValue ?? "Routine").tag(routines[i]["id"]?.stringValue ?? "")
                    }
                }
            }
            .navigationTitle("Log a past workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        sameDay = Backfill.workoutsOn(model.root, Day.iso(start))
                        if sameDay.isEmpty { go(nil) }
                    }
                    .disabled(future)
                }
            }
            .confirmationDialog("There is already a workout on that day.", isPresented: choosing, titleVisibility: .visible) {
                ForEach(sameDay.indices, id: \.self) { i in
                    Button(replaceLabel(sameDay[i]), role: .destructive) { go(sameDay[i]["id"]?.stringValue) }
                }
                Button("Add as second workout") { go(nil) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var routines: [AppModel.Object] {
        (model.root["routines"]?.arrayValue ?? []).compactMap(\.object).filter { !RoutineOps.isAIClone($0) }
    }
    private var choosing: Binding<Bool> { Binding(get: { !sameDay.isEmpty }, set: { if !$0 { sameDay = [] } }) }
    private func replaceLabel(_ w: AppModel.Object) -> String {
        sameDay.count > 1 ? "Replace · " + (w["name"]?.stringValue ?? "") : "Replace"
    }

    private func go(_ replaceId: String?) {
        model.beginBackfill(start: start, minutes: minutes, routineIds: routineId.isEmpty ? [] : [routineId], replaceId: replaceId)
        dismiss()
    }
}
