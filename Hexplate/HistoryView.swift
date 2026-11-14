import HexplateCore
import SwiftUI

/// Every logged workout, newest first, a section per month. Read only.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false

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
                        Button("Import data", systemImage: "square.and.arrow.down") { importing = true }
                    }
                }
            }
            .sheet(isPresented: $importing) { ImportView() }
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
