import HexplateCore
import SwiftUI

/// One logged workout: its totals, then every exercise with the sets that were done. Edit opens
/// it in the workout screen (session-edit.js); delete removes it.
struct WorkoutDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var editingNote = false
    @State private var noteText = ""
    @State private var changingDate = false
    @State private var changingDuration = false
    @State private var savingRoutine = false
    @State private var newRoutine: String?
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

            WorkoutPhotosSection(key: workout.id, record: record)

            Section("Session") {
                Button { noteText = record?["note"]?.stringValue ?? ""; editingNote = true } label: {
                    Label(record?["note"]?.stringValue ?? "Add session note", systemImage: "note.text")
                        .foregroundStyle(record?["note"] == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                Button { changingDate = true } label: {
                    LabeledContent {
                        Text(workout.start.map { Date(timeIntervalSince1970: $0 / 1000).formatted(.dateTime.day().month().hour().minute().locale(Theme.locale)) } ?? workout.date)
                    } label: { Label("Date & time", systemImage: "calendar") }
                }
                .foregroundStyle(.primary)
                .disabled(workout.start == nil)
                Button { changingDuration = true } label: {
                    LabeledContent {
                        Text("\(record.map(WorkoutEdit.durationMin) ?? 0) min")
                    } label: { Label("Duration", systemImage: "clock") }
                }
                .foregroundStyle(.primary)
                .disabled(workout.start == nil)
            }

            Section {
                Button("Edit workout", systemImage: "pencil") {
                    if model.editWorkout(key: workout.id) { model.showWorkout = true }
                }
                .disabled(model.active != nil)
                Button("Repeat today", systemImage: "arrow.counterclockwise") {
                    if let record, model.repeatWorkout(record) { model.showWorkout = true }
                }
                .disabled(model.active != nil)
                Button("Save as routine", systemImage: "plus.square.on.square") { savingRoutine = true }
                Button("Delete workout", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } footer: {
                if model.active != nil { Text("Finish the current workout first.") }
            }
        }
        .navigationTitle(workout.name ?? "Workout")
        .navigationBarTitleDisplayMode(.large)
        .alert("Session note", isPresented: $editingNote) {
            TextField("How the session went as a whole.", text: $noteText)
            Button("Save") { let t = noteText; update { WorkoutEdit.setNote($0, key: workout.id, t, now: model.now) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $changingDate) {
            WorkoutDateSheet(start: Date(timeIntervalSince1970: (workout.start ?? 0) / 1000), minutes: record.map(WorkoutEdit.durationMin) ?? 1) { iso, time in
                update { WorkoutEdit.move($0, key: workout.id, to: iso, at: time, now: model.now, catalog: model.catalog) }
            }
        }
        .sheet(isPresented: $changingDuration) {
            WorkoutDurationSheet(minutes: record.map(WorkoutEdit.durationMin) ?? 60) { m in
                update { WorkoutEdit.setDuration($0, key: workout.id, minutes: Double(m), now: model.now) }
            }
        }
        .alert("Save as routine?", isPresented: $savingRoutine) {
            Button("Save") { if let record { newRoutine = model.saveAsRoutine(record) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create an independent routine from these exercise targets. Your workout history is kept.")
        }
        .navigationDestination(item: $newRoutine) { RoutineEditorView(routineId: $0) }
        .alert("Delete this workout?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                dismiss()
                model.deleteWorkout(id: workout.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is removed from your history for good.")
        }
    }
}

extension WorkoutDetailView {
    /// The record as stored, for what the decoded workout leaves out (its note).
    private var record: AppModel.Object? {
        model.root["workouts"]?.arrayValue?.compactMap(\.object).first { $0["id"]?.stringValue == workout.id }
    }

    /// Writes the workouts list a WorkoutEdit function returned; nil means nothing changed.
    private func update(_ f: ([JSONValue]) -> [JSONValue]?) {
        model.change { s in if let next = f(s["workouts"]?.arrayValue ?? []) { s["workouts"] = .array(next) } }
    }
}

/// Another day and start for a saved workout; it keeps its length (sheets.jsx workoutDateSheet).
private struct WorkoutDateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var start: Date
    let minutes: Int
    let save: (String, String) -> Void

    var body: some View {
        let iso = Day.iso(start)
        let time = start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
        let future = WorkoutEdit.endsInFuture(iso, time, minutes: minutes, now: Date.now.timeIntervalSince1970 * 1000)
        NavigationStack {
            Form {
                DatePicker("Date", selection: $start, in: ...Date.now, displayedComponents: .date)
                DatePicker("Start time", selection: $start, displayedComponents: .hourAndMinute)
                Section {} footer: {
                    Text(future ? "That’s still in the future. Try an earlier start." : "The session keeps its length. Personal records are worked out again from the new order.")
                        .foregroundStyle(future ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            .navigationTitle("Change date & time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(iso, time); dismiss() }.disabled(future) }
            }
        }
        .presentationDetents([.medium])
    }
}

/// How long a saved workout really took (sheets.jsx workoutDurationSheet).
private struct WorkoutDurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var minutes: Int
    let save: (Int) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Stepper(value: $minutes, in: 1...(24 * 60), step: 5) {
                    LabeledContent("Duration", value: "\(minutes) min").monospacedDigit()
                }
                Section {} footer: { Text("Forgot to finish on time? Set how long the session really took. It keeps its start time and its sets.") }
            }
            .navigationTitle("Change duration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(minutes); dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct Summary: View {
    let workout: Workout
    let history: History
    @ScaledMetric(relativeTo: .title3) private var column = 72.0

    var body: some View {
        // As many across as fit: four on a phone at the default size, fewer as the text grows.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: column), alignment: .topLeading)], alignment: .leading, spacing: 12) {
            stats
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
