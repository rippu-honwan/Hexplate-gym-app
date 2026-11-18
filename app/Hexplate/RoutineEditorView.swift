import HexplateCore
import SwiftUI

/// One routine: its name, icon and planned exercises. Every edit is saved at once.
struct RoutineEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let routineId: String

    @State private var name = ""
    @FocusState private var naming: Bool
    @State private var picking = false
    @State private var editing: SlotLink?
    @State private var confirmDelete = false

    var body: some View {
        if let routine = model.routine(routineId) {
            List {
                Section {
                    TextField("Routine name", text: $name)
                        .focused($naming)
                        .submitLabel(.done)
                        .onChange(of: naming) { if !naming { saveName() } }
                    Picker(selection: Binding(get: { stored("emoji") ?? "figureStrength" }, set: { glyph in
                        model.changeRoutine(routineId) { $0["emoji"] = .string(glyph) }
                    })) {
                        ForEach(Glyph.groups, id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.names, id: \.self) { Label(Glyph.title($0), systemImage: Glyph.symbol($0)).tag($0) }
                            }
                        }
                    } label: {
                        Label("Icon", systemImage: routine.symbol)
                    }
                }

                Section {
                    ForEach(Array(routine.slots.enumerated()), id: \.offset) { index, slot in
                        Button { editing = SlotLink(index: index) } label: {
                            SlotRow(slot: slot, startsSuperset: startsSuperset(routine.slots, index), inSuperset: tag(slot) != nil)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            if tag(slot) != nil {
                                Button("Unlink", systemImage: "link.badge.plus") { changeSlots { RoutineOps.unpairSuperset($0, index) } }
                            } else if index > 0 {
                                Button("Superset", systemImage: "link") { changeSlots { RoutineOps.pairAdjacent($0, index - 1, index) } }
                                    .tint(Theme.superset)
                            }
                        }
                    }
                    .onMove { from, to in changeSlots { var ex = $0; ex.move(fromOffsets: from, toOffset: to); return ex } }
                    .onDelete { offsets in changeSlots { var ex = $0; ex.remove(atOffsets: offsets); return ex } }
                    Button("Add exercise", systemImage: "plus") { picking = true }
                } header: {
                    Text("Exercises")
                } footer: {
                    Text(routine.slots.isEmpty
                        ? "No exercises yet. Add your first one."
                        : "Swipe right on an exercise to superset it with the one above. Swipe left to remove it.")
                }

                Section {
                    Button("Duplicate routine", systemImage: "plus.square.on.square") { duplicate() }
                    Button("Delete routine", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(routine.name.isEmpty ? "Routine" : routine.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if routine.slots.count > 1 { EditButton() } }
            .toolbar {
                if model.active == nil && !routine.slots.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Start workout") {
                            model.startWorkout(routineIds: [routineId])
                            model.showWorkout = true
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Theme.ink)
                    }
                }
            }
            .toolbar(.hidden, for: .tabBar)
            .onAppear { name = routine.name }
            .onDisappear { saveName() }
            .sheet(isPresented: $picking) {
                ExercisePicker { id in
                    changeSlots { $0 + [.object(RoutineOps.pickedConfig(id: id, catalog: model.catalog).merging(["id": .string(id)]) { a, _ in a })] }
                }
            }
            .sheet(item: $editing) { SlotEditor(routineId: routineId, index: $0.index) }
            .confirmationDialog("Delete routine?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    model.change { RoutineOps.deleteRoutine(&$0, id: routineId) }
                    dismiss()
                }
            } message: {
                Text("“\(routine.name)” and its exercises will be removed. Workouts you logged with it stay in History.")
            }
        } else {
            ContentUnavailableView("Routine not found", systemImage: "questionmark.folder")
        }
    }

    private func stored(_ key: String) -> String? {
        (model.root["routines"]?.arrayValue ?? []).first { $0.object?["id"] == .string(routineId) }?.object?[key]?.stringValue
    }

    private func saveName() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != stored("name") else { return }
        model.changeRoutine(routineId) { $0["name"] = .string(clean) }
    }

    private func tag(_ slot: [String: JSONValue]) -> String? { slot["sg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    private func startsSuperset(_ slots: [[String: JSONValue]], _ i: Int) -> Bool {
        guard let t = tag(slots[i]) else { return false }
        return i == 0 || tag(slots[i - 1]) != t
    }

    /// Changes the exercise list; superset tags and their shared name and rest are tidied after.
    private func changeSlots(_ edit: ([JSONValue]) -> [JSONValue]?) {
        model.changeRoutine(routineId) { r in
            guard var ex = edit(r["ex"]?.arrayValue ?? []) else { return }
            RoutineOps.cleanupSupersets(&ex)
            r["ex"] = .array(ex)
        }
    }

    private func duplicate() {
        saveName()
        model.change { s in
            guard let list = s["routines"]?.arrayValue, let r = list.first(where: { $0.object?["id"] == .string(routineId) })?.object else { return }
            var copy = RoutineOps.copyRoutine(r, newId: RoutineOps.newId())
            // The copy is a new routine: it starts without the original's edit stamps.
            copy["_ts"] = nil; copy["_f"] = nil; copy["_u"] = nil
            s["routines"] = .array(list + [.object(copy)])
        }
        dismiss()
    }
}

private struct SlotLink: Identifiable { let index: Int; var id: Int { index } }

private struct SlotRow: View {
    @Environment(AppModel.self) private var model
    let slot: [String: JSONValue]
    let startsSuperset: Bool
    let inSuperset: Bool

    var body: some View {
        let id = slot["id"]?.stringValue ?? ""
        VStack(alignment: .leading, spacing: 3) {
            if startsSuperset {
                Label(slot["sgName"]?.stringValue ?? "Superset", systemImage: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.superset)
            }
            Text(model.catalog[id]?.displayName ?? id)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(RoutineOps.line(slot, catalog: model.catalog, settings: model.settings))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let note = slot["note"]?.stringValue, !note.isEmpty {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, inSuperset ? 12 : 0)
        .overlay(alignment: .leading) {
            if inSuperset { Capsule().fill(Theme.superset).frame(width: 3).accessibilityHidden(true) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What one planned exercise asks for. Saved with Done; fields this screen does not show stay as they were.
private struct SlotEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let routineId: String
    let index: Int
    @State private var cfg: [String: JSONValue] = [:]
    @State private var weight = ""
    @State private var loaded = false

    var body: some View {
        let mode = RoutineOps.mode(cfg, catalog: model.catalog)
        let bodyweight = RoutineOps.isBodyweight(cfg, catalog: model.catalog)
        NavigationStack {
            Form {
                Section {
                    Stepper("Sets: \(int("sets", 1))", value: number("sets", 1), in: 1...20)
                    if mode == "cardio" {
                        Stepper("Minutes: \(int("min", 20))", value: number("min", 20), in: 1...600)
                        Stepper("Speed: \(Format.number(cfg["speed"]?.numberValue ?? 8)) km/h", value: number("speed", 8), in: 0.5...60, step: 0.5)
                    } else {
                        if mode == "time" {
                            Stepper("Time: \(Format.seconds(cfg["sec"]?.numberValue ?? 45))", value: number("sec", 45), in: 5...3600, step: 5)
                        } else {
                            Stepper("Reps: \(int("reps", 10))", value: number("reps", 10), in: 1...200)
                            Toggle("Rep range", isOn: Binding(get: { ranged }, set: { on in
                                cfg["repsMin"] = on ? .number(max(1, (cfg["reps"]?.numberValue ?? 10) - 2)) : nil
                            }))
                            if ranged {
                                Stepper("From: \(int("repsMin", 1))", value: number("repsMin", 1), in: 1...max(1, Double(int("reps", 10) - 1)))
                            }
                        }
                        LabeledContent(bodyweight ? "Added weight" : "Weight") {
                            HStack(spacing: 4) {
                                TextField("0", text: $weight)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                Text(model.settings.unit).foregroundStyle(.secondary)
                            }
                        }
                        Picker("Logged as", selection: Binding(get: { mode }, set: { new in
                            cfg["mode"] = .string(new)
                            if new == "time", cfg["sec"] == nil { cfg["sec"] = .number(45) }
                            if new == "reps", cfg["reps"] == nil { cfg["reps"] = .number(10) }
                        })) {
                            Text("Reps").tag("reps")
                            Text("Time").tag("time")
                        }
                        Toggle("Per side", isOn: Binding(get: { cfg["side"] == .bool(true) }, set: { cfg["side"] = $0 ? .bool(true) : nil }))
                    }
                } footer: {
                    if cfg["side"] == .bool(true), mode == "reps" { Text("Reps are the total for both sides.") }
                    else if ranged { Text("Start at the low end and work up to \(int("reps", 10)) reps before adding weight.") }
                }

                Section {
                    Toggle("Own rest time", isOn: Binding(get: { cfg["restSec"]?.numberValue != nil }, set: { cfg["restSec"] = $0 ? .number(defaultRest) : nil }))
                    if cfg["restSec"]?.numberValue != nil {
                        Stepper("Rest: \(Format.seconds(cfg["restSec"]?.numberValue ?? defaultRest))", value: number("restSec", defaultRest), in: 0...900, step: 15)
                    }
                } footer: {
                    if cfg["restSec"]?.numberValue == nil { Text("Uses your usual rest, \(Format.seconds(defaultRest)).") }
                }

                Section("Note") {
                    TextField("Grip, seat position, a cue", text: Binding(get: { cfg["note"]?.stringValue ?? "" }, set: { text in
                        cfg["note"] = text.isEmpty ? nil : .string(String(text.prefix(500)))
                    }), axis: .vertical)
                }
            }
            .keyboardDone()
            .navigationTitle(model.catalog[cfg["id"]?.stringValue ?? ""]?.displayName ?? "Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save() } }
            }
            .onAppear {
                guard !loaded, let slot = model.routine(routineId)?.slots[safe: index] else { return }
                cfg = slot
                let w = slot["weight"]?.numberValue ?? 0
                weight = w == 0 ? "" : Format.number(w, decimals: 2).replacingOccurrences(of: ",", with: "")
                loaded = true
            }
        }
    }

    /// A range runs from `repsMin` up to `reps`; a floor at or above the reps is no range.
    private var ranged: Bool {
        let low = cfg["repsMin"]?.numberValue ?? 0
        return low > 0 && low < (cfg["reps"]?.numberValue ?? 0)
    }
    private var defaultRest: Double { model.root["restSec"]?.numberValue ?? 120 }
    private func int(_ key: String, _ fallback: Int) -> Int { Int(cfg[key]?.numberValue ?? Double(fallback)) }
    private func number(_ key: String, _ fallback: Double) -> Binding<Double> {
        Binding(get: { cfg[key]?.numberValue ?? fallback }, set: { cfg[key] = .number($0) })
    }

    private func save() {
        if RoutineOps.mode(cfg, catalog: model.catalog) != "cardio" {
            // A decimal comma is a decimal point; anything unreadable leaves the weight at 0.
            cfg["weight"] = .number(max(0, Double(weight.replacingOccurrences(of: ",", with: ".")) ?? 0))
        }
        if let low = cfg["repsMin"]?.numberValue, low >= (cfg["reps"]?.numberValue ?? 0) { cfg["repsMin"] = nil }
        let edited = cfg
        model.changeRoutine(routineId) { r in
            guard var ex = r["ex"]?.arrayValue, ex.indices.contains(index) else { return }
            ex[index] = .object(edited)
            r["ex"] = .array(ex)
        }
        dismiss()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Search the catalogue and pick one exercise.
struct ExercisePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var title = "Add exercise"
    let onPick: (String) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(results, id: \.id) { ex in
                Button {
                    onPick(ex.id)
                    dismiss()
                } label: {
                    ExerciseRow(exercise: ex, catalog: model.catalog)
                }
            }
            .overlay { if results.isEmpty { ContentUnavailableView.search(text: query) } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    /// With nothing typed: the exercises already in your plan and history first, then the catalogue.
    private var results: [Exercise] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return model.catalog.search(query) }
        var seen = Set<String>()
        let used = (model.routines.flatMap { $0.slots.compactMap { $0["id"]?.stringValue } }
            + (model.history?.workouts.flatMap { $0.entries.map(\.exerciseId) } ?? []))
            .filter { seen.insert($0).inserted }
            .compactMap { model.catalog[$0] }
        return used + model.catalog.search("", limit: 100).filter { !seen.contains($0.id) }
    }
}
