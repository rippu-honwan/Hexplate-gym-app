import HexplateCore
import SwiftUI

/// An exercise's id pushed on a navigation stack opens its page.
struct ExerciseLink: Hashable { let id: String }

extension View {
    func exerciseDestination() -> some View {
        navigationDestination(for: ExerciseLink.self) { ExerciseDetailView(id: $0.id) }
    }
}

/// What the profile keeps about exercises: favEx (ids), exNotes (id: text), exAliases (id: names).
extension AppModel {
    var favourites: Set<String> { Set((root["favEx"]?.arrayValue ?? []).compactMap(\.stringValue)) }

    func toggleFavourite(_ id: String) {
        change { root in
            var list = root["favEx"]?.arrayValue ?? []
            if list.contains(.string(id)) { list.removeAll { $0 == .string(id) } } else { list.append(.string(id)) }
            root["favEx"] = .array(list)
        }
    }

    func note(of id: String) -> String { root["exNotes"]?.object?[id]?.stringValue ?? "" }

    func setNote(_ text: String, of id: String) {
        guard text != note(of: id) else { return }
        change { root in
            var notes = root["exNotes"]?.object ?? [:]
            notes[id] = text.isEmpty ? nil : .string(text)
            root["exNotes"] = .object(notes)
        }
    }

    func aliases(of id: String) -> [String] { (root["exAliases"]?.object?[id]?.arrayValue ?? []).compactMap(\.stringValue) }

    func setAliases(_ names: [String], of id: String) {
        change { root in
            var all = root["exAliases"]?.object ?? [:]
            all[id] = names.isEmpty ? nil : .array(names.map(JSONValue.string))
            root["exAliases"] = .object(all)
        }
    }
}

/// The Exercises tab: the catalogue and your own exercises, searched and filtered, staples first.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter = ExerciseFilter()
    @State private var favouritesOnly = false
    @State private var customOnly = false
    @State private var mineOnly = true
    @State private var creating = false

    var body: some View {
        NavigationStack {
            let results = results
            let favourites = model.favourites
            List {
                ExerciseSections(results: results) { ex in
                    NavigationLink(value: ExerciseLink(id: ex.id)) {
                        ExerciseRow(exercise: ex, catalog: model.catalog, favourite: favourites.contains(ex.id))
                    }
                }
            }
            .safeAreaBar(edge: .top) { ExerciseFilterBar(filter: $filter) }
            .overlay {
                if results.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("No exercises", systemImage: "line.3.horizontal.decrease", description: Text("Nothing matches these filters."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .navigationTitle("Exercises")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search exercises")
            .exerciseDestination()
            .workoutDestination()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Filter", systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease") {
                        Toggle("Favourites", systemImage: "star", isOn: $favouritesOnly)
                        Toggle("My exercises", systemImage: "person", isOn: $customOnly)
                        if profile != nil { Toggle("My equipment only", systemImage: "dumbbell", isOn: $mineOnly) }
                        if isFiltered || filter.isOn {
                            Button("Clear", systemImage: "xmark") { filter = ExerciseFilter(); favouritesOnly = false; customOnly = false }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New exercise", systemImage: "plus") { creating = true }
                }
            }
            .sheet(isPresented: $creating) { CustomExerciseEditor() }
        }
    }

    private var profile: [String: JSONValue]? { ExerciseCatalog.activeProfile(model.root) }
    private var isFiltered: Bool { favouritesOnly || customOnly }

    // ponytail: filters all 5,600 exercises on every render; cache per (query, filters) if typing lags.
    private var results: [Exercise] {
        let catalog = model.catalog
        let words = query.lowercased().split(separator: " ")
        let have = mineOnly ? profile.map { ExerciseCatalog.equipment(of: $0) } : nil
        let favourites = model.favourites
        let aliases = model.root["exAliases"]?.object ?? [:]
        return catalog.all.filter { ex in
            if favouritesOnly && !favourites.contains(ex.id) { return false }
            if customOnly && !ex.isCustom { return false }
            if !filter.keeps(ex, catalog) { return false }
            if !words.isEmpty {
                let text = ([ex.name, ex.translatedName ?? ""] + (aliases[ex.id]?.arrayValue ?? []).compactMap(\.stringValue)).joined(separator: " ").lowercased()
                if !words.allSatisfy({ text.contains($0) }) { return false }
            }
            if let have, !catalog.isAvailable(ex, with: have) { return false }
            return true
        }
    }
}

/// One exercise in a list: picture, name, what it needs and trains.
struct ExerciseRow: View {
    let exercise: Exercise
    var catalog: ExerciseCatalog = .builtIn
    var favourite = false

    var body: some View {
        HStack(spacing: 12) {
            ExerciseThumb(id: exercise.id)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.displayName)
                    .foregroundStyle(.primary)
                // The filters' groups, so the line reads in the app's language.
                Text("\(Text(ExerciseFilter.label(ExerciseGroups.equipment(of: exercise)))) · \(Text(LocalizedStringKey(ExerciseGroups.muscle(of: exercise, catalog: catalog))))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if favourite {
                Spacer(minLength: 0)
                Image(systemName: "star.fill")
                    .font(.footnote)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Favourite")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// An exercise's page: how it looks, what it trains, how to do it, your notes and your history.
struct ExerciseDetailView: View {
    @Environment(AppModel.self) private var model
    let id: String
    @State private var note = ""
    @FocusState private var noteFocused: Bool
    @State private var editing = false
    @State private var addingAlias = false
    @State private var alias = ""

    var body: some View {
        if let ex = model.catalog[id] {
            page(ex)
        } else {
            ContentUnavailableView("Exercise not found", systemImage: "questionmark.circle")
        }
    }

    private func page(_ ex: Exercise) -> some View {
        let catalog = model.catalog
        let weights = catalog.muscleWeights(of: ex)
        let text = ExerciseCatalog.texts[ex.id]
        let aliases = model.aliases(of: ex.id)
        return List {
            if ExerciseMedia.clipURL(ex.id) != nil || ExerciseMedia.stillURL(ex.id) != nil {
                Section {
                    ExerciseClip(id: ex.id)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                        .accessibilityLabel("Demonstration of \(ex.displayName)")
                }
            }

            Section("Muscles") {
                if !weights.isEmpty {
                    HStack(spacing: 0) {
                        BodyMap(side: .front, levels: weights)
                        BodyMap(side: .back, levels: weights)
                    }
                    .frame(maxWidth: .infinity).frame(height: 220)
                    .accessibilityHidden(true)
                }
                muscles("Primary", weights.filter { $0.value >= 1 })
                muscles("Secondary", weights.filter { $0.value < 1 })
            }

            Section("Details") {
                if let eq = ex.equipment { LabeledContent("Equipment", value: Format.capWords(eq)) }
                if !ex.accessories.isEmpty { LabeledContent("Also needs", value: ex.accessories.map(Format.capWords).joined(separator: ", ")) }
                if let bp = ex.bodyPart { LabeledContent("Body part", value: Format.capWords(bp)) }
                if ex.isCustom { LabeledContent("Source", value: "Your exercise") }
            }

            if let about = ex.about ?? text?.about, !about.isEmpty {
                Section("About") { Text(about) }
            }
            if let steps = text?.steps, !steps.isEmpty {
                Section("How to") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(i + 1)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                            Text(step)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section("Notes") {
                TextField("Add a note", text: $note, axis: .vertical)
                    .focused($noteFocused)
            }

            Section("Also known as") {
                ForEach(aliases, id: \.self) { Text($0) }
                    .onDelete { offsets in
                        var names = aliases
                        names.remove(atOffsets: offsets)
                        model.setAliases(names, of: ex.id)
                    }
                Button("Add a name", systemImage: "plus") { alias = ""; addingAlias = true }
            }

            history(ex)
        }
        .navigationTitle(ex.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if noteFocused {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { noteFocused = false } }
            } else {
                if ex.isCustom {
                    ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    let on = model.favourites.contains(ex.id)
                    Button(on ? "Remove from favourites" : "Add to favourites", systemImage: on ? "star.fill" : "star") {
                        model.toggleFavourite(ex.id)
                    }
                }
            }
        }
        .onAppear { note = model.note(of: ex.id) }
        .onChange(of: noteFocused) { if !noteFocused { save(ex) } }
        .onDisappear { save(ex) }
        .sheet(isPresented: $editing) { CustomExerciseEditor(id: ex.id) }
        .alert("Another name", isPresented: $addingAlias) {
            TextField("Name", text: $alias)
            Button("Add") {
                let name = alias.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !aliases.contains(name) { model.setAliases(aliases + [name], of: ex.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Search finds this exercise by this name too.")
        }
    }

    private func save(_ ex: Exercise) {
        model.setNote(note.trimmingCharacters(in: .whitespacesAndNewlines), of: ex.id)
    }

    @ViewBuilder
    private func muscles(_ title: String, _ weights: [String: Double]) -> some View {
        let order = model.catalog.meta.muscles
        let names = weights.keys
            .sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            .map(model.catalog.muscleName)
        if !names.isEmpty { LabeledContent(title, value: names.joined(separator: ", ")) }
    }

    /// The last ten workouts that held this exercise, newest first.
    @ViewBuilder
    private func history(_ ex: Exercise) -> some View {
        if let history = model.history {
            let sessions = history.workouts
                .filter { $0.entries.contains { $0.exerciseId == ex.id || history.catalog[$0.exerciseId]?.id == ex.id } }
                .sorted { $0.date > $1.date }
                .prefix(10)
            Section("History") {
                if sessions.isEmpty {
                    Text("Not logged yet.").foregroundStyle(.secondary)
                }
                ForEach(sessions, id: \.id) { workout in
                    NavigationLink(value: WorkoutLink(id: workout.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Day.date(workout.date)?.formatted(.dateTime.weekday().day().month().year().locale(Theme.locale)) ?? workout.date)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            let sets = workout.entries
                                .filter { $0.exerciseId == ex.id || history.catalog[$0.exerciseId]?.id == ex.id }
                                .flatMap { history.rows(of: $0) }
                                .filter { !$0.isWarmup }
                                .map(\.label)
                            Text(sets.isEmpty ? "No completed sets" : sets.joined(separator: "  ·  "))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

/// Makes or edits one of your own exercises (the profile's customEx).
struct CustomExerciseEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var id: String?

    @State private var name = ""
    @State private var bodyPart = ""
    @State private var equipment = "body weight"
    @State private var target = ""
    @State private var secondary: Set<String> = []
    @State private var about = ""
    @State private var confirmingDelete = false

    var body: some View {
        let meta = model.catalog.meta
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Equipment", selection: $equipment) {
                        ForEach(meta.equipment, id: \.self) { Text(Format.capWords($0)).tag($0) }
                    }
                    Picker("Body part", selection: $bodyPart) {
                        Text("None").tag("")
                        ForEach(meta.bodyParts, id: \.self) { Text(Format.capWords($0)).tag($0) }
                    }
                }
                Section("Muscles") {
                    Picker("Primary", selection: $target) {
                        Text("None").tag("")
                        ForEach(meta.muscles, id: \.self) { Text(model.catalog.muscleName($0)).tag($0) }
                    }
                    DisclosureGroup("Secondary" + (secondary.isEmpty ? "" : " (\(secondary.count))")) {
                        ForEach(meta.muscles.filter { $0 != target }, id: \.self) { slug in
                            Toggle(model.catalog.muscleName(slug), isOn: Binding(
                                get: { secondary.contains(slug) },
                                set: { if $0 { secondary.insert(slug) } else { secondary.remove(slug) } }))
                        }
                    }
                }
                Section("About") {
                    TextField("How you do it, set-up, cues", text: $about, axis: .vertical)
                }
                if id != nil {
                    Section {
                        Button("Delete exercise", role: .destructive) { confirmingDelete = true }
                    } footer: {
                        Text("Workouts you logged with it keep their sets and its name.")
                    }
                }
            }
            .navigationTitle(id == nil ? "New exercise" : "Edit exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete this exercise?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    model.change { root in
                        root["customEx"] = .array((root["customEx"]?.arrayValue ?? []).filter { $0.object?["id"]?.stringValue != id })
                    }
                    dismiss()
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let id, let ex = model.catalog[id] else { return }
        name = ex.englishName
        bodyPart = ex.bodyPart ?? ""
        equipment = ex.equipment ?? "body weight"
        target = model.catalog.muscle(ex.target) ?? ""
        secondary = Set(ex.secondary.compactMap { model.catalog.muscle($0) })
        about = ex.about ?? ""
    }

    /// Same keys as the original app writes; an edit keeps whatever else the exercise holds.
    private func save() {
        let order = model.catalog.meta.muscles
        let others = order.filter { secondary.contains($0) && $0 != target }.map(JSONValue.string)
        model.change { root in
            var list = root["customEx"]?.arrayValue ?? []
            let index = list.firstIndex { $0.object?["id"]?.stringValue == id }
            var ex = index.flatMap { list[$0].object } ?? ["id": .string("c" + RoutineOps.newId()), "custom": .bool(true)]
            ex["n"] = .string(name.trimmingCharacters(in: .whitespaces))
            ex["eq"] = .string(equipment)
            ex["bp"] = bodyPart.isEmpty ? nil : .string(bodyPart)
            ex["tg"] = target.isEmpty ? nil : .string(target)
            ex["primaries"] = target.isEmpty ? nil : .array([.string(target)])
            ex["sm"] = .array(others)
            ex["secondaries"] = .array(others)
            ex["desc"] = about.isEmpty ? nil : .string(about)
            if let index { list[index] = .object(ex) } else { list.append(.object(ex)) }
            root["customEx"] = .array(list)
        }
    }
}
