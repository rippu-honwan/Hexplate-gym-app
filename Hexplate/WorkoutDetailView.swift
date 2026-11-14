import HexplateCore
import SwiftUI

/// One logged workout: its totals, then every exercise with the sets that were done. Read only.
struct WorkoutDetailView: View {
    let workout: Workout
    let history: History

    var body: some View {
        List {
            Section {
                Summary(workout: workout, history: history)
            } header: {
                if let date = Day.date(workout.date) {
                    Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Theme.locale)))
                }
            }

            ForEach(history.units(of: workout), id: \.self) { unit in
                Section {
                    ForEach(unit, id: \.self) { index in
                        EntryRow(entry: workout.entries[index], history: history, inSuperset: unit.count > 1)
                    }
                } header: {
                    if unit.count > 1 {
                        Label("Superset", systemImage: "link")
                            .foregroundStyle(Theme.superset)
                    }
                }
            }
        }
        .navigationTitle(workout.name ?? "Workout")
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct Summary: View {
    let workout: Workout
    let history: History

    var body: some View {
        // Side by side while it fits; stacked at the largest text sizes.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) { stats.frame(maxWidth: .infinity, alignment: .leading) }
            VStack(alignment: .leading, spacing: 12) { stats }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var stats: some View {
        if let duration = history.durationText(workout) {
            Stat(value: duration, caption: "Duration")
        }
        Stat(value: history.setsDone(workout).formatted(), caption: "Sets")
        Stat(value: Format.number(history.volume(workout), decimals: history.settings.weightDecimals),
             caption: "Volume, \(history.settings.unit)")
        if workout.recordCount > 0 {
            Stat(value: workout.recordCount.formatted(), caption: "Records", color: Theme.record)
                .accessibilityLabel(RecordBadge.spoken(workout.recordCount))
        }
    }
}

private struct Stat: View {
    let value: String
    let caption: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EntryRow: View {
    let entry: WorkoutEntry
    let history: History
    let inSuperset: Bool

    var body: some View {
        let rows = history.rows(of: entry)
        VStack(alignment: .leading, spacing: 8) {
            Text(history.name(of: entry))
                .font(.headline)
            if let note = entry.note, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text("No sets")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                SetLine(row: row, number: rows[...index].filter { !$0.isWarmup }.count)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, inSuperset ? 12 : 0)
        .overlay(alignment: .leading) {
            if inSuperset {
                Capsule().fill(Theme.superset).frame(width: 3)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct SetLine: View {
    let row: History.SetRow
    /// Its place among the work sets; warm-ups are marked instead of numbered.
    let number: Int
    @ScaledMetric(relativeTo: .caption) private var chip = 22.0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.isWarmup ? "W" : "\(number)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(row.isWarmup ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.secondary))
                .frame(minWidth: chip, minHeight: chip)
                .background(row.isWarmup ? AnyShapeStyle(Theme.warmup) : AnyShapeStyle(.fill.tertiary), in: .rect(cornerRadius: 6))
                .accessibilityLabel(row.isWarmup ? "Warm-up" : "Set \(number)")
            Text(row.label)
                .font(.body)
                .monospacedDigit()
                .accessibilityLabel(spokenLabel)
            Spacer(minLength: 8)
            if let hr = row.heartRate {
                Label("\(hr.avg)/\(hr.max)", systemImage: "heart.fill")
                    .labelStyle(HeartLabel())
                    .accessibilityLabel("Heart rate, average \(hr.avg), highest \(hr.max)")
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The label's signs, said as words.
    private var spokenLabel: String {
        row.label
            .replacingOccurrences(of: "×", with: " times ")
            .replacingOccurrences(of: "↘", with: ", then ")
            .replacingOccurrences(of: "–", with: "not done")
            .replacingOccurrences(of: " F", with: ", to failure")
    }
}

/// A small red heart before grey numbers: red is the heart rate, the numbers stay quiet.
private struct HeartLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.foregroundStyle(Theme.heart).imageScale(.small)
            configuration.title.foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
    }
}
