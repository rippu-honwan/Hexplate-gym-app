import HexplateCore
import SwiftUI

/// The plan segment inside Gym: how the week is scheduled (fixed weekdays or a loop) and the routines themselves.
struct PlanContent: View {
    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath
    @State private var editingDay: WeekdayLink?
    @State private var confirmWeek = false
    @State private var deleting: AppModel.Routine?

    var body: some View {
        let mode = Schedule.scheduleMode(model.root)
        List {
            Section {
                Picker("How you train", selection: Binding(get: { mode }, set: choose)) {
                    Text("Fixed Week").tag("week")
                    Text("Rotation").tag("rotation")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(mode == "week"
                    ? "The same routines on the same weekdays, every week."
                    : "Routines in a loop. Whatever is next stays next until you train it, whatever the day.")
            }

            if mode == "week" { weekSection } else { loopSection }

            Section {
                NavigationLink { ProgrammesView() } label: {
                    LabeledContent {
                        if let chip = Programmes.chip(model.root, today: model.today) { Text(chip) }
                    } label: { Label("Programmes", systemImage: "calendar.badge.clock") }
                }
            }

            Section {
                ForEach(model.routines) { routine in
                    NavigationLink(value: RoutineLink(id: routine.id)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(routine.name.isEmpty ? "Untitled" : routine.name)
                                Text(routine.slots.count == 1 ? "1 exercise" : "\(routine.slots.count) exercises")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: routine.symbol).foregroundStyle(.tint)
                        }
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = routine }
                    }
                }
                .onMove { from, to in
                    model.change { s in
                        guard var list = s["routines"]?.arrayValue else { return }
                        // Write reordered user routines back into their original slot indices so
                        // any server-interleaved aiClone entries keep their positions.
                        let slots = list.indices.filter {
                            guard let r = list[$0].object, r["id"]?.stringValue != nil else { return false }
                            return !RoutineOps.isAIClone(r)
                        }
                        var visible = slots.map { list[$0] }
                        visible.move(fromOffsets: from, toOffset: to)
                        for (slot, item) in zip(slots, visible) { list[slot] = item }
                        s["routines"] = .array(list)
                    }
                }
                Button("New routine", systemImage: "plus") { addRoutine() }
            } header: {
                Text("Routines")
            } footer: {
                if model.routines.isEmpty { Text("No routines yet. Make one to start planning.") }
            }
        }
        .sheet(item: $editingDay) { WeekdaySheet(weekday: $0.weekday) }
        .confirmationDialog("Back to a fixed week?", isPresented: $confirmWeek, titleVisibility: .visible) {
            Button("Use Fixed Week") { model.change { Schedule.chooseFixedWeek(&$0, today: model.today) } }
        } message: {
            Text("The loop stops. Your weekdays stay as they are, and the loop is saved for later.")
        }
        .confirmationDialog("Delete routine?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { routine in
            Button("Delete", role: .destructive) { model.change { RoutineOps.deleteRoutine(&$0, id: routine.id) } }
        } message: { routine in
            Text("“\(routine.name)” and its exercises will be removed. Workouts you logged with it stay in History.")
        }
    }

    private func choose(_ mode: String) {
        if mode == "rotation" {
            model.change { Schedule.chooseRotation(&$0, today: model.today, now: model.now) }
        } else if Schedule.queue(model.root) != nil {
            confirmWeek = true     // leaving a running loop loses its progress: ask first
        } else {
            model.change { Schedule.chooseFixedWeek(&$0, today: model.today) }
        }
    }

    private func addRoutine() {
        let id = RoutineOps.newId()
        model.change { s in
            s["routines"] = .array((s["routines"]?.arrayValue ?? []) + [.object(RoutineOps.newRoutine(id: id, name: "New routine"))])
        }
        path.append(RoutineLink(id: id))
    }

    // MARK: Fixed week

    private var weekSection: some View {
        let first = model.root["weekStart"] == .number(0) ? 0 : 1
        return Section {
            ForEach((0..<7).map { (first + $0) % 7 }, id: \.self) { weekday in
                Button { editingDay = WeekdayLink(weekday: weekday) } label: {
                    let names = Self.routineIds(model.root, weekday: weekday).compactMap { model.routine($0)?.name }
                    HStack {
                        Text(Self.weekdayName(weekday)).foregroundStyle(.primary)
                        Spacer()
                        Text(names.isEmpty ? "Rest day" : names.joined(separator: " + "))
                            .foregroundStyle(names.isEmpty ? .tertiary : .secondary)
                            .multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Your weekly routine")
        } footer: {
            Text("Want two routines on one day? Tap the day and pick both.")
        }
    }

    static func weekdayName(_ weekday: Int) -> String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][weekday % 7]
    }

    /// The routines a weekday holds, as stored (a single id or a list), that still exist.
    static func routineIds(_ root: [String: JSONValue], weekday: Int) -> [String] {
        let slot = root["week"]?.object?[String(weekday)]
        let ids = slot?.stringValue.map { [$0] } ?? (slot?.arrayValue ?? []).compactMap(\.stringValue)
        let known = Set((root["routines"]?.arrayValue ?? []).compactMap { $0.object?["id"]?.stringValue })
        return ids.filter(known.contains)
    }

    // MARK: The loop

    @ViewBuilder private var loopSection: some View {
        let sequence = Schedule.sequence(model.root)
        Section {
            if Schedule.queueRecovery(model.root) {
                Text("This rotation couldn’t be read. Another device may have written it.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(sequence.enumerated()), id: \.offset) { _, id in
                if id == Schedule.rest {
                    Label("Rest day", systemImage: "moon.fill").foregroundStyle(.secondary)
                } else if let routine = model.routine(id) {
                    Label { Text(routine.name) } icon: { Image(systemName: routine.symbol).foregroundStyle(.tint) }
                }
            }
            .onMove { from, to in
                var next = sequence
                next.move(fromOffsets: from, toOffset: to)
                saveLoop(next)
            }
            .onDelete { offsets in
                var next = sequence
                next.remove(atOffsets: offsets)
                saveLoop(next)
            }
            Menu("Add to the rotation", systemImage: "plus") {
                ForEach(model.routines) { routine in
                    Button(routine.name) { saveLoop(sequence + [routine.id]) }
                }
                if sequence.contains(where: { $0 != Schedule.rest }) {
                    Divider()
                    Button("Rest day", systemImage: "moon") { saveLoop(sequence + [Schedule.rest]) }
                }
            }
            .disabled(model.routines.isEmpty)
        } header: {
            Text("The loop")
        } footer: {
            if sequence.isEmpty {
                Text("No rotation yet. Add routines in the order you want to train them. The first one you haven’t logged stays up next.")
            } else if let view = Schedule.queueView(model.root, today: model.today) {
                Text(view.waiting && Day.date(view.startsOn) != nil
                    ? String(localized: "Next round starts \(Day.date(view.startsOn)!.formatted(.dateTime.weekday(.wide).day().month().locale(Theme.locale))).")
                    : "\(view.items.count - view.remaining.count) of \(view.items.count) done this round. Swipe to take one out.")
            }
        }

        if !sequence.isEmpty {
            Section {
                Button("Start the loop over") {
                    model.change { Schedule.startNewPass(&$0, today: model.today, now: model.now) }
                }
            } footer: {
                Text("Trained out of order? The round starts again from the top and only counts what you log from now.")
            }
        }
    }

    /// Every edit of the loop is saved at once and keeps the running round in step.
    private func saveLoop(_ next: [String]) {
        model.change { s in
            if next.contains(where: { $0 != Schedule.rest }) {
                let label = s["queue"]?.object?["label"]?.stringValue ?? s["rotation"]?.object?["label"]?.stringValue ?? ""
                Schedule.saveRotation(&s, ids: next, label: label, today: model.today, now: model.now, newId: { RoutineOps.newId() })
            } else {
                // Nothing left to train: the round stops and the loop is kept, empty.
                Schedule.stopPass(&s, today: model.today)
                if var rotation = s["rotation"]?.object {
                    rotation["sequence"] = .array([])
                    s["rotation"] = .object(rotation)
                }
            }
        }
    }
}

struct RoutineLink: Hashable { let id: String }
private struct WeekdayLink: Identifiable { let weekday: Int; var id: Int { weekday } }

/// Which routines a weekday holds. Each tap is saved at once.
private struct WeekdaySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let weekday: Int

    var body: some View {
        let chosen = PlanContent.routineIds(model.root, weekday: weekday)
        NavigationStack {
            List {
                Section {
                    ForEach(model.routines) { routine in
                        Button { toggle(routine.id, in: chosen) } label: {
                            HStack {
                                Label { Text(routine.name) } icon: { Image(systemName: routine.symbol).foregroundStyle(.tint) }
                                Spacer()
                                if chosen.contains(routine.id) {
                                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen.contains(routine.id) ? .isSelected : [])
                    }
                } footer: {
                    Text(model.routines.isEmpty ? "Make a routine first, then plan it here." : "Nothing ticked is a rest day.")
                }
                if !chosen.isEmpty {
                    Button("Rest day", systemImage: "moon") { save([]) }
                }
            }
            .navigationTitle(PlanContent.weekdayName(weekday))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle(_ id: String, in chosen: [String]) {
        save(chosen.contains(id) ? chosen.filter { $0 != id } : chosen + [id])
    }

    /// A day with nothing loses its key; a day never holds an empty list.
    private func save(_ ids: [String]) {
        model.change { s in
            var week = s["week"]?.object ?? [:]
            week[String(weekday)] = ids.isEmpty ? nil : .array(ids.map(JSONValue.string))
            s["week"] = .object(week)
        }
    }
}
