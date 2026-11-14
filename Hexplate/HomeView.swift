import HexplateCore
import SwiftUI

/// Today: what is planned, how the week stands, the loop, and the latest workout.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    today
                } header: {
                    if let date = Day.date(model.today) {
                        Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Theme.locale)))
                    }
                } footer: {
                    if let next { Text(next) }
                }

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

                if let latest = model.months.first?.items.first {
                    Section("Latest workout") {
                        NavigationLink(value: WorkoutLink(id: latest.id)) { WorkoutRow(item: latest) }
                    }
                }
            }
            .navigationTitle("Today")
            .workoutDestination()
        }
    }

    @ViewBuilder private var today: some View {
        let ids = Schedule.routineIds(model.root, on: model.today, today: model.today)
        let done = model.history?.workouts.filter { $0.date == model.today } ?? []
        if ids.isEmpty && done.isEmpty {
            Label("Rest day", systemImage: "moon.fill")
                .foregroundStyle(.secondary)
        }
        ForEach(ids, id: \.self) { id in
            if let routine = model.routine(id) {
                let logged = done.first { $0.routineId == id }
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(routine.name).font(.headline)
                            Text(routine.slots.count == 1 ? "1 exercise" : "\(routine.slots.count) exercises")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: routine.symbol).foregroundStyle(.tint)
                    }
                    Spacer()
                    if logged != nil {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        // Trained today on something the plan did not hold.
        ForEach(done.filter { w in !ids.contains(w.routineId ?? "") }) { w in
            Label(w.name ?? "Workout", systemImage: "checkmark.circle.fill")
        }
    }

    private var next: String? {
        guard let day = Schedule.nextTrainingDay(model.root, after: model.today, today: model.today),
              let date = Day.date(day.iso) else { return nil }
        let names = day.routineIds.compactMap { model.routine($0)?.name }.joined(separator: " + ")
        return "Next session: \(date.formatted(.dateTime.weekday(.wide).locale(Theme.locale))), \(names)"
    }

    private var week: [WeekStrip.DayCell] {
        let start = Schedule.weekKey(model.today, weekStart: model.root["weekStart"] == .number(0) ? 0 : 1) ?? model.today
        let trained = Set(model.history?.workouts.map(\.date) ?? [])
        return (0..<7).compactMap { Day.adding($0, to: start) }.map { iso in
            let date = Day.date(iso)
            return WeekStrip.DayCell(
                id: iso,
                letter: date?.formatted(.dateTime.weekday(.narrow).locale(Theme.locale)) ?? "",
                number: date?.formatted(.dateTime.day().locale(Theme.locale)) ?? "",
                spoken: date?.formatted(.dateTime.weekday(.wide).day().locale(Theme.locale)) ?? iso,
                trained: trained.contains(iso),
                planned: !Schedule.routineIds(model.root, on: iso, today: model.today).isEmpty,
                isToday: iso == model.today
            )
        }
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
