import AudioToolbox
import HexplateCore
import SwiftUI
import UserNotifications

// MARK: - The live session in the document (`S.active`)

extension AppModel {
    typealias Object = [String: JSONValue]

    var active: Object? { root["active"]?.object }
    var activeEntries: [Object] { (active?["entries"]?.arrayValue ?? []).compactMap(\.object) }

    func startWorkout(routineIds: [String]) {
        guard active == nil else { return }
        let bw = history?.weighIns.last?.weight
        let session = Session.begin(root, routineIds: routineIds, bodyweight: bw, id: RoutineOps.newId(now: now), now: now, day: today, catalog: catalog)
        change { $0["active"] = .object(session) }
        WatchBridge.shared.send()
        WatchBridge.shared.openOnWatch()
    }

    /// "Repeat today": a saved workout's exercises as a new freestyle session, each seeded from
    /// what that workout logged (session-repeat.js). The saved record stays as it is.
    // ponytail: no toast for exercises left out because they were deleted.
    func repeatWorkout(_ w: Object) -> Bool {
        guard active == nil else { errorMessage = "Finish the current workout first."; return false }
        let c = catalog
        let entries = SessionCopy.repeatEntries(root, w, catalog: c) { c[$0] != nil }.entries
        guard !entries.isEmpty else { errorMessage = "Nothing to repeat. Its exercises no longer exist."; return false }
        let name = w["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Freestyle"
        let session: Object = ["id": .string(RoutineOps.newId(now: now)), "d": .string(today), "start": .number(now), "routineIds": .array([]),
                               "name": .string(name), "bw": history?.weighIns.last.map { .number($0.weight) } ?? .null, "cur": .number(0), "entries": .array(entries)]
        change { $0["active"] = .object(session) }
        WatchBridge.shared.send()
        WatchBridge.shared.openOnWatch()
        return true
    }

    /// "Save as routine": the workout's exercise setup as a new routine (session-routines.js). Its id.
    func saveAsRoutine(_ w: Object) -> String? {
        let routines = (root["routines"]?.arrayValue ?? []).compactMap(\.object)
        guard let r = SessionCopy.routine(from: w, name: w["name"]?.stringValue, routines: routines, catalog: catalog) else {
            errorMessage = "Nothing logged yet"; return nil
        }
        change { s in s["routines"] = .array((s["routines"]?.arrayValue ?? []) + [.object(r)]) }
        return r["id"]?.stringValue
    }

    var isEditingSaved: Bool { WorkoutEdit.isEditing(active) }
    var isBackfill: Bool { Backfill.isBackfill(active) }
    /// No clock and no rest timers: a saved workout open for editing, or one logged after the fact.
    var isPastSession: Bool { isEditingSaved || isBackfill }

    /// Starts logging a workout after the fact (sheets.jsx beginBackfill).
    func beginBackfill(start: Date, minutes: Int, routineIds: [String], replaceId: String?) {
        guard active == nil else { return }
        let iso = Day.iso(start), at = start.timeIntervalSince1970 * 1000
        let a = Backfill.begin(root, iso: iso, start: at, durationMin: max(1, minutes), routineIds: routineIds,
                               replaceId: replaceId, id: RoutineOps.newId(now: now), catalog: catalog)
        change { $0["active"] = .object(a) }
    }

    /// Opens a saved workout in the workout screen. False when it could not (another session runs).
    func editWorkout(key: String) -> Bool {
        var failure: Error?
        change { s in do { try WorkoutEdit.begin(&s, key: key) } catch { failure = error } }
        if let failure { errorMessage = failure.localizedDescription }
        return failure == nil
    }

    /// Saves the edits over the record; the message when it could not.
    func saveWorkoutEdit() -> String? {
        var failure: Error?
        let (c, t) = (catalog, now)
        change { s in do { try WorkoutEdit.save(&s, now: t, catalog: c) } catch { failure = error } }
        return failure?.localizedDescription
    }

    func changeActive(_ mutate: (inout Object) -> Void) {
        change { s in
            guard var a = s["active"]?.object else { return }
            mutate(&a)
            s["active"] = .object(a)
        }
    }

    func changeEntry(_ e: Int, _ mutate: (inout Object) -> Void) {
        changeActive { a in
            guard var list = a["entries"]?.arrayValue, list.indices.contains(e), var entry = list[e].object else { return }
            mutate(&entry)
            list[e] = .object(entry)
            a["entries"] = .array(list)
        }
    }

    func changeSets(_ e: Int, _ mutate: (inout [JSONValue]) -> Void) {
        changeEntry(e) { entry in
            var sets = entry["sets"]?.arrayValue ?? []
            mutate(&sets)
            entry["sets"] = .array(sets)
        }
    }

    func addExercise(_ id: String) {
        let cfg = RoutineOps.pickedConfig(id: id, catalog: catalog)
        let entry = Session.freestyleEntry(root, cfg: cfg, catalog: catalog)
        changeActive { a in a["entries"] = .array((a["entries"]?.arrayValue ?? []) + [entry]) }
    }

    /// Saves the session as a workout. Returns it for the summary.
    func finishWorkout() -> Object? {
        guard let a = active else { return nil }
        if isBackfill {
            var filed: Object?
            let (c, day, at) = (catalog, today, now)
            change { s in
                filed = Backfill.finish(&s, now: at, catalog: c)
                if let filed { _ = Schedule.refillAfter(&s, workout: filed, today: day, now: at) }
            }
            return filed
        }
        let prs = Session.records(a, in: root, catalog: catalog)
        let w = Session.completedWorkout(a, end: Session.sessionEnd(a, now: now), prs: prs, catalog: catalog)
        let (day, at) = (today, now)
        change { s in
            var best = s["exWeights"]?.object ?? [:]
            for e in (w["entries"]?.arrayValue ?? []).compactMap(\.object) {
                guard let id = e["id"]?.stringValue else { continue }
                let top = Session.bestWeight(e, catalog)
                let prev = best[id]?.object?["w"]?.numberValue ?? 0
                let assisted = catalog[id]?.isAssisted ?? false
                if top > 0 && (prev <= 0 || (assisted ? top < prev : top > prev)) { best[id] = .object(["w": .number(top), "d": w["d"] ?? .string(day)]) }
            }
            s["exWeights"] = .object(best)
            s["workouts"] = .array((s["workouts"]?.arrayValue ?? []) + [.object(w)])
            s["active"] = nil
            _ = Schedule.refillAfter(&s, workout: w, today: day, now: at)
        }
        if UserDefaults.standard.bool(forKey: "health"), let start = w["start"]?.numberValue, let end = w["end"]?.numberValue {
            Task { await Health.save(workout: Date(timeIntervalSince1970: start / 1000), end: Date(timeIntervalSince1970: end / 1000)) }
        }
        return w
    }

    /// The rest after a set of entry `i`: nil while its superset goes on to a partner, else the
    /// superset's, the exercise's or the profile's rest (0: no rest).
    func restSeconds(after i: Int) -> Double? {
        let entries = activeEntries
        guard entries.indices.contains(i) else { return nil }
        let entry = entries[i], target = entry["target"]?.object ?? [:]
        let sg = entry["sg"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        if let sg, entries.indices.contains(where: { $0 > i && entries[$0]["sg"]?.stringValue == sg }) { return nil }
        return (sg != nil ? target["sgRest"]?.numberValue : nil) ?? ActiveEdit.exerciseRest(target) ?? defaultRest
    }

    /// The rest a ticked set starts: the set's own (its menu) or the exercise's; nil going on to a
    /// superset partner, or in a past session.
    func restAfter(entry e: Int, set i: Int) -> Double? {
        guard !isPastSession, let exerciseRest = restSeconds(after: e) else { return nil }
        let sets = activeEntries[e]["sets"]?.arrayValue ?? []
        return (sets.indices.contains(i) ? SetEdit.ownRest(sets[SetEdit.span(sets, i).start]) : nil) ?? exerciseRest
    }

    /// The profile's rest between sets (Settings → Rest timer).
    var defaultRest: Double { root["restSec"]?.numberValue ?? 90 }

    /// "rir" or "rpe" when sets record how hard they were (history.js effortOf), else nil.
    var effortKind: String? {
        switch root["effort"]?.stringValue {
        case "rir": "rir"
        case "rpe": "rpe"
        case "none": nil
        default: root["showRir"] == .bool(true) ? "rir" : nil
        }
    }

    func discardWorkout() {
        // MyGym: named to the watch (the snapshot's "discarded"), so it ends without a summary
        // or the how-hard question.
        if let id = active?["id"]?.stringValue {
            let d = UserDefaults.standard
            d.set(Array(((d.stringArray(forKey: "watchDiscarded") ?? []) + [id]).suffix(10)), forKey: "watchDiscarded")
        }
        change { $0["active"] = nil }
    }
}

// MARK: - Rest and hold timer

@Observable @MainActor
final class RestTimer {
    enum Kind { case rest, hold }
    private(set) var end: Date?
    private(set) var total: Double = 0
    private(set) var kind = Kind.rest
    var flashing = false
    private var task: Task<Void, Never>?
    private var onEnd: (() -> Void)?

    func start(_ seconds: Double, kind: Kind = .rest, alerts: Alerts, onEnd: (() -> Void)? = nil) {
        stop()
        total = seconds
        self.kind = kind
        self.onEnd = onEnd
        let end = Date.now.addingTimeInterval(seconds)
        self.end = end
        schedule(at: end, alerts: alerts)
    }

    func add(_ seconds: Double, alerts: Alerts) {
        guard let end else { return }
        let next = max(Date.now, end.addingTimeInterval(seconds))
        total = max(1, total + seconds)
        self.end = next
        schedule(at: next, alerts: alerts)
    }

    func stop() {
        task?.cancel()
        task = nil
        end = nil
        onEnd = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["rest"])
    }

    struct Alerts { var sound: Bool; var flash: Bool }

    private func schedule(at end: Date, alerts: Alerts) {
        task?.cancel()
        let kind = kind
        // The app may be in the background when the rest ends: a local notification covers that.
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = kind == .rest ? String(localized: "Rest is over") : String(localized: "Time")
            content.body = kind == .rest ? String(localized: "Next set.") : String(localized: "Hold done.")
            if alerts.sound { content.sound = .default }
            let wait = end.timeIntervalSinceNow
            guard wait > 1 else { return }
            try? await center.add(UNNotificationRequest(identifier: "rest", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)))
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if alerts.sound { AudioServicesPlaySystemSound(1007) }
            if alerts.flash {
                withAnimation(.easeOut(duration: 0.15)) { self.flashing = true }
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.easeIn(duration: 0.3)) { self.flashing = false }
            }
            let done = self.onEnd
            self.onEnd = nil
            if self.kind == .hold { self.end = nil }
            done?()
        }
    }
}

// MARK: - The workout screen

struct WorkoutView: View {
    @Environment(AppModel.self) private var model
    @Environment(RestTimer.self) private var timer
    @Environment(\.dismiss) private var dismiss
    @State private var confirmFinish = false
    @State private var confirmDiscard = false
    /// Discard was chosen in the first question; the second opens once that one has closed.
    @State private var wantsDiscard = false
    @State private var picking = false
    @State private var summary: AppModel.Object?
    @State private var noteFor: Int?
    @State private var setNoteFor: EntryAction?
    @State private var editingSessionNote = false
    @State private var renaming = false
    @State private var editError: String?
    @State private var confirmDropEdits = false
    @State private var noteText = ""
    @State private var removeFor: Int?
    @State private var swapFor: EntryAction?
    @State private var detailFor: EntryAction?
    @State private var pendingSwap: (index: Int, entry: AppModel.Object)?

    var body: some View {
        NavigationStack {
            List {
                if model.isBackfill {
                    Text("Logging a past workout, so no rest timers.").font(.subheadline).foregroundStyle(.secondary)
                }
                if let a = model.active, !model.isPastSession, let start = a["start"]?.numberValue {
                    Section {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            LabeledContent("Elapsed", value: Format.seconds(Date.now.timeIntervalSince1970 - start / 1000))
                                .monospacedDigit()
                        }
                    }
                }
                ForEach(Array(model.activeEntries.enumerated()), id: \.offset) { i, entry in
                    EntrySection(index: i, entry: entry, next: next(after: i)) { act($0) }
                }
                Section {
                    Button("Add exercise", systemImage: "plus") { picking = true }
                    Button { noteText = model.active?["note"]?.stringValue ?? ""; editingSessionNote = true } label: {
                        Label(model.active?["note"]?.stringValue ?? "Add session note", systemImage: "note.text")
                            .foregroundStyle(model.active?["note"] == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    }
                }
            }
            .listSectionSpacing(.compact)
            // The second question hangs on the list, not next to the first one: two alerts on
            // one view share a presenter, and the second then ignored taps.
            .alert("Really discard this workout?", isPresented: $confirmDiscard) {
                Button("Discard", role: .destructive) {
                    timer.stop()
                    model.discardWorkout()
                    dismiss()
                }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("Nothing from this session is saved. This cannot be undone.")
            }
            .keyboardDone()
            .navigationTitle(model.active?["name"]?.stringValue ?? "Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Minimise", systemImage: "chevron.down") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") { sessionMenu }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.isEditingSaved ? "Save" : "Finish") {
                        if model.isEditingSaved {
                            if let message = model.saveWorkoutEdit() { editError = message } else { dismiss() }
                        } else { confirmFinish = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.ink)
                }
            }
            .safeAreaInset(edge: .bottom) { if timer.end != nil { RestBar() } else { WatchStartBar() } }
            .overlay { if timer.flashing { Color.white.opacity(0.85).ignoresSafeArea().allowsHitTesting(false) } }
            // Finish asks whether to keep the session: a practice run can be thrown away.
            // Alerts, not a dialog: a dialog on the toolbar opens as a popover, and a second question
            // shown as it closes stopped taking taps in the simulator.
            .onChange(of: confirmFinish) {
                if !confirmFinish && wantsDiscard { wantsDiscard = false; confirmDiscard = true }
            }
            .alert("Save this workout?", isPresented: $confirmFinish) {
                Button("Save workout") {
                    timer.stop()
                    summary = model.finishWorkout()
                }
                Button("Discard workout", role: .destructive) {
                    // The second question opens once this one has closed.
                    wantsDiscard = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(unfinished > 0 ? "\(unfinished) planned \(unfinished == 1 ? "set is" : "sets are") not done and will be left out." : "Every set is done.")
            }
            .sheet(isPresented: $picking) { ExercisePicker { model.addExercise($0) } }
            .sheet(isPresented: present($noteFor)) {
                if let i = noteFor, let e = entry(i) { ExerciseNoteSheet(index: i, entry: e) }
            }
            .alert("Could not save", isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } }), presenting: editError) { _ in
                Button("OK", role: .cancel) {}
            } message: { Text($0) }
            .alert("Discard your changes?", isPresented: $confirmDropEdits) {
                Button("Discard changes", role: .destructive) {
                    model.change { WorkoutEdit.discard(&$0) }
                    dismiss()
                }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("The saved workout stays as it was.")
            }
            .alert("Session note", isPresented: $editingSessionNote) {
                TextField("How did it go?", text: $noteText)
                Button("Save") { let t = noteText; model.changeActive { ActiveEdit.setNote(&$0, t) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename workout", isPresented: $renaming) {
                TextField("Workout title", text: $noteText)
                Button("Save") { let t = noteText; model.changeActive { ActiveEdit.rename(&$0, t) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Set note", isPresented: Binding(get: { setNoteFor != nil }, set: { if !$0 { setNoteFor = nil } }), presenting: setNoteFor) { action in
                TextField("A word about this set", text: $noteText)
                Button("Save") {
                    if case .setNote(let e, let i) = action { model.changeSets(e) { $0 = SetEdit.setNote($0, i, noteText) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Remove \(removeFor.flatMap(entry).map(name) ?? "exercise")?", isPresented: present($removeFor), presenting: removeFor) { i in
                Button("Remove", role: .destructive) { model.changeActive { ActiveEdit.remove(&$0, i) } }
                Button("Cancel", role: .cancel) {}
            } message: { i in
                Text(entry(i).map(ActiveEdit.hasLoggedSet) == true ? "The sets you logged for this exercise in this session will be lost." : "This removes the exercise from your current session.")
            }
            .confirmationDialog("Swap exercise?", isPresented: Binding(get: { pendingSwap != nil }, set: { if !$0 { pendingSwap = nil } }), titleVisibility: .visible) {
                if let p = pendingSwap, entry(p.index)?["sg"]?.stringValue.map({ !$0.isEmpty }) == true {
                    Button("Keep in the superset") { commitSwap(keepGroup: true) }
                    Button("Put after the superset") { commitSwap(keepGroup: false) }
                } else {
                    Button("Continue") { commitSwap(keepGroup: false) }
                }
                Button("Cancel", role: .cancel) { pendingSwap = nil }
            } message: {
                Text("Logged sets stay with the original exercise. The replacement will be inserted afterward.")
            }
            .sheet(item: $swapFor) { action in
                if case .swap(let i) = action { ExercisePicker(title: "Swap exercise") { swap(i, to: $0) } }
            }
            .sheet(item: $detailFor) { action in
                if case .detail(let id) = action {
                    NavigationStack {
                        ExerciseDetailView(id: id)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detailFor = nil } } }
                    }
                }
            }
            .sheet(item: Binding(get: { summary.map(Summary.init) }, set: { if $0 == nil { summary = nil; dismiss() } })) { FinishSummary(summary: $0) }
        }
    }

    private var unfinished: Int {
        model.activeEntries.flatMap { $0["sets"]?.arrayValue ?? [] }.filter { !Session.hasCompletedWork($0) && !Session.isWarmup($0) }.count
    }

    /// The workout's own ⋯ (Workout.jsx openViewMenu): the rest and sound used now, what to add,
    /// the note and name, progression, and throwing the session away.
    @ViewBuilder private var sessionMenu: some View {
        let a = model.active ?? [:]
        let inSession = Set((a["routineIds"]?.arrayValue ?? []).compactMap(\.stringValue))
        let routines = (model.root["routines"]?.arrayValue ?? []).compactMap(\.object)
        Section("Workout settings") {
            Picker(selection: Binding(get: { model.defaultRest }, set: { model.set("restSec", .number($0)) })) {
                Text("No timer").tag(0.0)
                ForEach([30.0, 45, 60, 90, 120, 150, 180, 240, 300], id: \.self) { Text(Format.seconds($0)).tag($0) }
            } label: { Label("Rest timer", systemImage: "timer") }
            .pickerStyle(.menu)
            Toggle("Sound", systemImage: "speaker.wave.2", isOn: Binding(get: { model.root["sound"] != .bool(false) }, set: { model.set("sound", .bool($0)) }))
        }
        Section {
            Button("Add exercise", systemImage: "plus.circle") { picking = true }
            if model.isBackfill && !model.activeEntries.isEmpty {
                Button("Mark all sets done", systemImage: "checkmark.circle") {
                    model.changeActive { $0["entries"] = .array(Backfill.markAllDone($0["entries"]?.arrayValue ?? [])) }
                }
            }
            Button(a["note"] == nil ? "Add session note" : "Edit session note", systemImage: "note.text") {
                noteText = a["note"]?.stringValue ?? ""; editingSessionNote = true
            }
            if !model.isEditingSaved { Menu("Add routine", systemImage: "list.clipboard") {
                ForEach(routines.indices, id: \.self) { i in
                    let r = routines[i], id = r["id"]?.stringValue ?? ""
                    let empty = (r["ex"]?.arrayValue ?? []).isEmpty
                    Button(r["name"]?.stringValue ?? "Routine") { model.changeActive { ActiveEdit.addRoutine(&$0, model.root, r, catalog: model.catalog) } }
                        .disabled(inSession.contains(id) || empty)
                }
            } }
            Button("Rename workout", systemImage: "pencil") { noteText = a["name"]?.stringValue ?? ""; renaming = true }
            Toggle("Don’t count for progression", systemImage: "chart.line.downtrend.xyaxis", isOn: Binding(
                get: { a["noProg"] == .bool(true) },
                set: { on in
                    let out = Set(routines.filter { $0["excludeFromProgression"] == .bool(true) }.compactMap { $0["id"]?.stringValue })
                    model.changeActive { ActiveEdit.setSessionNoProg(&$0, on) { out.contains($0["rid"]?.stringValue ?? "") } }
                }))
        }
        Section {
            if model.isEditingSaved {
                Button("Discard changes", systemImage: "arrow.uturn.backward", role: .destructive) { confirmDropEdits = true }
            } else {
                Button("Discard workout", systemImage: "trash", role: .destructive) { confirmDiscard = true }
            }
        }
    }

    private func entry(_ i: Int) -> AppModel.Object? { model.activeEntries.indices.contains(i) ? model.activeEntries[i] : nil }
    private func name(_ e: AppModel.Object) -> String { e["id"]?.stringValue.map { model.catalog[$0]?.displayName ?? $0 } ?? "exercise" }
    private func present(_ v: Binding<Int?>) -> Binding<Bool> { Binding(get: { v.wrappedValue != nil }, set: { if !$0 { v.wrappedValue = nil } }) }

    private func act(_ a: EntryAction) {
        switch a {
        case .note(let i): noteFor = i
        case .remove(let i): removeFor = i
        case .swap: swapFor = a
        case .detail: detailFor = a
        case .setNote(let e, let i):
            noteText = SetEdit.note(entry(e)?["sets"]?.arrayValue?[safe: i])
            setNoteFor = a
        }
    }

    /// The picked exercise takes the slot (sheets.jsx commitActiveSwap); with sets logged it asks first.
    private func swap(_ i: Int, to id: String) {
        guard let current = entry(i) else { return }
        var cfg = RoutineOps.pickedConfig(id: id, catalog: model.catalog)
        cfg["id"] = .string(id)
        var replacement = Session.freestyleEntry(model.root, cfg: cfg, catalog: model.catalog).object ?? [:]
        if let rid = current["rid"] { replacement["rid"] = rid }
        if current["noProg"] == .bool(true) { replacement["noProg"] = .bool(true) }
        if ActiveEdit.hasLoggedSet(current) { pendingSwap = (i, replacement) } else {
            timer.stop()
            model.changeActive { ActiveEdit.swap(&$0, i, with: replacement) }
        }
    }

    private func commitSwap(keepGroup: Bool) {
        guard let p = pendingSwap else { return }
        pendingSwap = nil
        timer.stop()
        model.changeActive { ActiveEdit.swap(&$0, p.index, with: p.entry, keepGroup: keepGroup) }
    }

    /// The superset partner that comes next after entry `i`, if any.
    private func next(after i: Int) -> Int? {
        let entries = model.activeEntries
        // SwiftUI can still ask for a row of a session that just finished.
        guard entries.indices.contains(i), let sg = entries[i]["sg"]?.stringValue, !sg.isEmpty else { return nil }
        return entries.indices.first { $0 > i && entries[$0]["sg"]?.stringValue == sg }
    }
}

/// What an exercise's ⋯ menu asks the workout screen to show.
enum EntryAction: Identifiable {
    case note(Int), swap(Int), remove(Int), detail(String), setNote(Int, Int)
    var id: String {
        switch self {
        case .setNote(let e, let i): "setNote\(e)-\(i)"
        case .note(let i): "note\(i)"
        case .swap(let i): "swap\(i)"
        case .remove(let i): "remove\(i)"
        case .detail(let id): "detail\(id)"
        }
    }
}

private struct EntrySection: View {
    @Environment(AppModel.self) private var model
    @Environment(RestTimer.self) private var timer
    let index: Int
    let entry: AppModel.Object
    let next: Int?
    let onAction: (EntryAction) -> Void

    private var id: String { entry["id"]?.stringValue ?? "" }
    private var target: AppModel.Object { entry["target"]?.object ?? [:] }
    private var mode: String { RoutineOps.mode(target.merging(["id": .string(id)]) { a, _ in a }, catalog: model.catalog) }
    private var sets: [JSONValue] { entry["sets"]?.arrayValue ?? [] }
    private var gifSize: String { model.root["gifSize"]?.stringValue ?? "full" }
    private var step: Double { Session.increment(target, unit: model.settings.unit, catalog: model.catalog) }

    var body: some View {
        Section {
            if gifSize == "full" {
                WorkoutMedia(id: id, compact: entry["sg"]?.stringValue.map { !$0.isEmpty } ?? false)
                    .listRowInsets(EdgeInsets())
                    .id(id)
            }
            // The plan's instruction, the standing note, last time's pin, then today's note
            // (Workout.jsx): four notes with four lifetimes, each on its own line.
            if let plan = target["note"]?.stringValue, !plan.isEmpty {
                Label(plan, systemImage: "list.clipboard").font(.subheadline)
            }
            if let standing = ActiveEdit.standingNote(model.root, id) {
                Label(standing, systemImage: "info.circle").font(.subheadline)
            }
            if let pin = ActiveEdit.pinnedNote(model.root, id) {
                Label("From \(Day.date(pin.day)?.formatted(.dateTime.day().month().locale(Theme.locale)) ?? pin.day): \(pin.note)", systemImage: "pin")
                    .font(.subheadline).foregroundStyle(.tint)
            }
            if let note = entry["note"]?.stringValue, !note.isEmpty {
                Label(note, systemImage: "note.text").font(.subheadline)
            }
            if entry["noProg"] == .bool(true) {
                HStack {
                    Label("Not counted for progression", systemImage: "chart.line.downtrend.xyaxis").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if !routineKeepsOut { Button("Undo") { model.changeActive { ActiveEdit.setNoProg(&$0, index, false) } }.buttonStyle(.borderless).font(.subheadline) }
                }
            }
            if let line = lastLine { Label(line, systemImage: "clock.arrow.circlepath").font(.subheadline).foregroundStyle(.secondary) }
            if let why = advice { Label(why.text, systemImage: why.symbol).font(.subheadline).foregroundStyle(.secondary) }
            ForEach(Array(sets.enumerated()), id: \.offset) { i, row in
                SetRow(entry: index, index: i, number: number(of: i), row: row, mode: mode, step: step, rows: sets, onAction: onAction, onDone: { completed(set: i) })
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { model.changeSets(index) { $0.remove(at: i) } }
                    }
                    .swipeActions(edge: .leading) {
                        if mode == "reps" && !Session.isWarmup(row) {
                            Button("Drop set", systemImage: "arrow.down.right") { model.changeSets(index) { $0[i] = Session.addingDrop($0[i], step: step) } }
                            Button("Rest-pause", systemImage: "pause") {
                                let rest = model.root["restPauseSec"]?.numberValue ?? 15
                                model.changeSets(index) { $0[i] = Session.addingCluster($0[i], restSec: rest) }
                                timer.start(rest, alerts: alerts)
                            }
                        }
                    }
            }
            HStack {
                Button("Add set", systemImage: "plus") { model.changeSets(index) { sets in addSet(&sets) } }
                Spacer()
                if mode != "cardio" {
                    Button("Warm-up", systemImage: "flame") { model.changeSets(index) { $0 = Session.addingWarmup($0, step: step) } }
                        .tint(Theme.warmup)
                }
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
        } header: {
            HStack {
                if gifSize == "mini" { WorkoutThumb(id: id).textCase(nil) }
                Text(name)
                if let sg = entry["sg"]?.stringValue, !sg.isEmpty {
                    Text("Superset").font(.caption.bold()).foregroundStyle(Theme.superset)
                }
                Spacer()
                menu.textCase(nil)
            }
        }
    }

    private var name: String { model.catalog[id]?.displayName ?? id }

    /// A deload or rehab routine keeps its exercises out of progression itself.
    private var routineKeepsOut: Bool {
        guard let rid = entry["rid"]?.stringValue else { return false }
        return model.root["routines"]?.arrayValue?.contains { $0.object?["id"]?.stringValue == rid && $0.object?["excludeFromProgression"] == .bool(true) } ?? false
    }

    /// The exercise's ⋯ menu (Workout.jsx openMore).
    private var menu: some View {
        let a = model.active ?? [:]
        let count = model.activeEntries.count
        let units = ActiveEdit.units(a["entries"]?.arrayValue ?? [])
        let unit = units.first { $0.contains(index) } ?? [index]
        return Menu {
            Section {
                Button(entry["note"] == nil ? "Add note" : "Edit note", systemImage: "note.text") { onAction(.note(index)) }
                Button("Swap exercise", systemImage: "arrow.left.arrow.right") { onAction(.swap(index)) }
                Button("How to do it and history", systemImage: "info.circle") { onAction(.detail(id)) }
                Picker(selection: Binding(get: { ActiveEdit.exerciseRest(target) ?? -1 }, set: { v in model.changeActive { ActiveEdit.setExerciseRest(&$0, index, v < 0 ? nil : v) } })) {
                    Text("Default (\(Format.seconds(model.defaultRest)))").tag(-1.0)
                    Text("No timer").tag(0.0)
                    ForEach([30.0, 45, 60, 90, 120, 150, 180, 240, 300], id: \.self) { Text(Format.seconds($0)).tag($0) }
                } label: { Label("Rest timer", systemImage: "timer") }
                .pickerStyle(.menu)
            }
            Section("Order and supersets") {
                if unit.count == 1 {
                    if index > 0 { Button("Make superset with previous", systemImage: "link") { model.changeActive { ActiveEdit.pair(&$0, index - 1, index) } } }
                    if index < count - 1 { Button("Make superset with next", systemImage: "link") { model.changeActive { ActiveEdit.pair(&$0, index, index + 1) } } }
                } else {
                    Button("Take out of the superset", systemImage: "personalhotspot.slash") { model.changeActive { ActiveEdit.unpair(&$0, index) } }
                }
                Button("Move up", systemImage: "chevron.up") { model.changeActive { ActiveEdit.move(&$0, index, -1) } }
                    .disabled(!ActiveEdit.canMove(a, index, -1))
                Button("Move down", systemImage: "chevron.down") { model.changeActive { ActiveEdit.move(&$0, index, 1) } }
                    .disabled(!ActiveEdit.canMove(a, index, 1))
            }
            if !routineKeepsOut {
                Section("This session") {
                    Toggle("Don’t count for progression", systemImage: "chart.line.downtrend.xyaxis", isOn: Binding(
                        get: { entry["noProg"] == .bool(true) },
                        set: { on in model.changeActive { ActiveEdit.setNoProg(&$0, index, on) } }))
                }
            }
            Section {
                Button("Remove exercise", systemImage: "trash", role: .destructive) { onAction(.remove(index)) }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3).accessibilityLabel("More for \(name)")
        }
    }

    private var alerts: RestTimer.Alerts {
        .init(sound: model.root["sound"] != .bool(false), flash: model.root["timerFlash"] == .bool(true))
    }

    private func number(of i: Int) -> String {
        if Session.isWarmup(sets[i]) { return "W" }
        return "\(sets[..<i].filter { !Session.isWarmup($0) }.count + 1)"
    }

    private func addSet(_ sets: inout [JSONValue]) {
        guard var last = sets.last(where: { !Session.isWarmup($0) })?.object else { return }
        for k in ["drops", "clusters", "type", "at", "rir", "rpe"] { last[k] = nil }
        sets.append(Session.settingDone(.object(last), false, at: 0))
    }

    /// After a set: on to the superset partner, or rest.
    private func completed(set i: Int) {
        if let rest = model.restAfter(entry: index, set: i), rest > 0 { timer.start(rest, alerts: alerts) }
    }

    private var lastLine: String? {
        let rows = Session.lastRows(model.root, id, routineId: entry["rid"]?.stringValue)
        guard !rows.isEmpty else { return nil }
        let parts = rows.map { r -> String in
            let o = r.object ?? [:]
            if mode == "time" { return "\(Int(o["sec"]?.numberValue ?? 0))s" }
            if mode == "cardio" { return "\(Format.number(o["min"]?.numberValue ?? 0)) min" }
            let w = o["w"]?.numberValue ?? 0
            return w > 0 ? "\(Format.number(w)) × \(Int(o["r"]?.numberValue ?? 0))" : "\(Int(o["r"]?.numberValue ?? 0))"
        }
        let best = Session.bestWeightFor(model.root, id, catalog: model.catalog)
        return String(localized: "Last") + " " + parts.joined(separator: ", ") + (best > 0 && mode == "reps" ? " · " + String(localized: "best") + " \(Format.number(best)) \(model.settings.unit)" : "")
    }

    /// The progression note, with its placeholders filled in.
    private var advice: (text: String, symbol: String)? {
        guard let plan = entry["plan"]?.object, let why = plan["why"]?.arrayValue, let raw = why.first?.stringValue else { return nil }
        // The note's template in the app's language (zh-Hant.lproj), placeholders kept.
        var text = Bundle.main.localizedString(forKey: raw, value: nil, table: nil)
        for (k, v) in why.dropFirst().enumerated() {
            text = text.replacingOccurrences(of: "{\(k)}", with: v.stringValue ?? Format.number(v.numberValue ?? 0))
        }
        let kind = plan["kind"]?.stringValue
        return (text, kind == "up" ? "arrow.up.right" : kind == "deload" ? "arrow.down.right" : kind == "programme" ? "calendar" : "equal")
    }
}

private struct SetRow: View {
    @Environment(AppModel.self) private var model
    @Environment(RestTimer.self) private var timer
    let entry: Int
    let index: Int
    let number: String
    let row: JSONValue
    let mode: String
    let step: Double
    let rows: [JSONValue]
    let onAction: (EntryAction) -> Void
    let onDone: () -> Void

    private var o: AppModel.Object { row.object ?? [:] }

    var body: some View {
        if Session.isSideSet(row), let sides = o["sides"]?.object {
            ForEach(["L", "R"], id: \.self) { side in
                line(label: number + side, fields: sides[side]?.object ?? [:], side: side)
            }
        } else {
            line(label: number, fields: o, side: nil)
        }
        if !SetEdit.note(row).isEmpty {
            Label(SetEdit.note(row), systemImage: "note.text").font(.caption).foregroundStyle(.secondary).padding(.leading, 42)
        }
        ForEach(Array((o["drops"]?.arrayValue ?? []).enumerated()), id: \.offset) { k, drop in
            HStack {
                Text("Drop").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                field(drop.object?["w"], unit: model.settings.unit) { v in edit { $0.edited("drops", k, "w", v) } }
                Text("×").foregroundStyle(.secondary)
                field(drop.object?["r"], unit: "reps") { v in edit { $0.edited("drops", k, "r", v) } }
            }
            .padding(.leading, 12)
        }
        ForEach(Array((o["clusters"]?.arrayValue ?? []).enumerated()), id: \.offset) { k, burst in
            HStack {
                Text("Burst").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                field(burst.object?["r"], unit: "reps") { v in edit { $0.edited("clusters", k, "r", v) } }
            }
            .padding(.leading, 12)
        }
    }

    private func line(label: String, fields: AppModel.Object, side: String?) -> some View {
        let isDone = fields["done"] == .bool(true)
        let warm = Session.isWarmup(row)
        return HStack(spacing: 10) {
            Menu { setMenu(warm: warm) } label: {
                Text(label)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(warm ? Theme.warmup : .secondary)
                    .frame(width: 32, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(warm ? "Warm-up, options" : "Set \(label), options")
            switch mode {
            case "time":
                field(fields["sec"], unit: "s") { v in set("sec", v, side) }
                if !isDone {
                    Button("Start hold", systemImage: "play.fill") { hold(fields["sec"]?.numberValue ?? 0, side) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            case "cardio":
                field(fields["min"], unit: "min") { v in set("min", v, side) }
                field(fields["speed"], unit: model.settings.speedUnit == "mph" ? "mph" : "km/h") { v in set("speed", v, side) }
            default:
                field(fields["w"], unit: model.settings.unit) { v in set("w", v, side) }
                Text("×").foregroundStyle(.secondary)
                field(fields["r"], unit: "reps") { v in set("r", v, side) }
            }
            Spacer(minLength: 0)
            if mode == "reps" && !warm, let kind = model.effortKind {
                EffortMenu(kind: kind, value: fields[kind]?.numberValue) { v in set(kind, v, side) }
            }
            Button {
                let now = model.now
                model.changeSets(entry) { $0[index] = Session.settingDone($0[index], !isDone, side: side, at: now) }
                if !isDone && !warm && (side == nil || side == "R") { onDone() }
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isDone ? "Done" : "Mark done")
        }
    }

    /// The set's own menu (Workout.jsx openSetMenu).
    @ViewBuilder private func setMenu(warm: Bool) -> some View {
        let start = SetEdit.span(rows, index).start
        let own = SetEdit.ownRest(rows[safe: start])
        let rest = model.restSeconds(after: entry) ?? 0
        Section(warm ? "Warm-up" : "Set \(number)") {
            if !warm && mode != "cardio" {
                Toggle("Taken to failure", systemImage: "gauge.with.dots.needle.100percent", isOn: Binding(
                    get: { SetEdit.isFailure(row) }, set: { _ in change { SetEdit.toggleFailure($0, index) } }))
            }
            if !warm && mode == "reps" && o["type"] != .string("restpause") {
                Button("Drop set", systemImage: "arrow.down.right") { change { var r = $0; r[index] = Session.addingDrop(r[index], step: step); return r } }
            }
            if !warm && mode == "reps" && o["type"] != .string("dropset") {
                Button("Rest-pause burst", systemImage: "bolt") {
                    let sec = model.root["restPauseSec"]?.numberValue ?? 15
                    change { var r = $0; r[index] = Session.addingCluster(r[index], restSec: sec); return r }
                    timer.start(sec, alerts: .init(sound: model.root["sound"] != .bool(false), flash: model.root["timerFlash"] == .bool(true)))
                }
            }
            Button("Copy this set", systemImage: "plus.square.on.square") { change { SetEdit.copy($0, index) } }
            Button(SetEdit.note(rows[safe: start]).isEmpty ? "Note" : "Edit note", systemImage: "note.text") { onAction(.setNote(entry, index)) }
        }
        Section {
            if !warm && mode == "reps" && SetEdit.canBeWarmup(row) && rows.indices.contains(where: { $0 != index && !Session.isWarmup(rows[$0]) }) {
                Button("Make it a warm-up set", systemImage: "sunrise") { change { SetEdit.makeWarmup($0, index) } }
            }
            if warm && mode == "reps" {
                Button("Count it as a working set", systemImage: "dumbbell") { change { SetEdit.makeWork($0, index) } }
            }
            Picker(selection: Binding(get: { own ?? -1 }, set: { v in change { SetEdit.setRest($0, index, v < 0 ? nil : v) } })) {
                Text("Default (\(Format.seconds(rest)))").tag(-1.0)
                Text("No timer").tag(0.0)
                ForEach([30.0, 45, 60, 90, 120, 150, 180, 240, 300], id: \.self) { Text(Format.seconds($0)).tag($0) }
            } label: {
                Label("Rest after this set", systemImage: "timer")
            }
            .pickerStyle(.menu)
        }
        Section {
            Button("Remove this set", systemImage: "trash", role: .destructive) { change { SetEdit.remove($0, index) } }
                .disabled(rows.count <= SetEdit.span(rows, index).count)
        }
    }

    private func change(_ f: @escaping ([JSONValue]) -> [JSONValue]) {
        model.changeSets(entry) { $0 = f($0) }
    }

    private func field(_ value: JSONValue?, unit: String, _ commit: @escaping (Double) -> Void) -> some View {
        NumberField(value: value?.numberValue, unit: unit, commit: commit)
    }

    private func edit(_ mutate: @escaping (inout AppModel.Object) -> Void) {
        model.changeSets(entry) { sets in
            guard case .object(var o) = sets[index] else { return }
            mutate(&o)
            sets[index] = .object(o)
        }
    }

    /// Sets one field of the row (or of one side); nil removes it.
    private func set(_ key: String, _ v: Double?, _ side: String?) {
        edit { o in
            if let side, var sides = o["sides"]?.object, var one = sides[side]?.object {
                one[key] = v.map(JSONValue.number)
                sides[side] = .object(one)
                o["sides"] = .object(sides)
                o = Session.syncSides(o).object ?? o
            } else {
                o[key] = v.map(JSONValue.number)
            }
        }
    }

    /// A timed set: counts down, then logs the hold and starts the rest.
    private func hold(_ seconds: Double, _ side: String?) {
        let alerts = RestTimer.Alerts(sound: model.root["sound"] != .bool(false), flash: model.root["timerFlash"] == .bool(true))
        timer.start(seconds, kind: .hold, alerts: alerts) { [model, entry, index] in
            let now = model.now
            model.changeSets(entry) { $0[index] = Session.settingDone($0[index], true, side: side, at: now) }
            if side == nil || side == "R" { onDone() }
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    /// Sets `key` of item `k` in the array under `list`.
    mutating func edited(_ list: String, _ k: Int, _ key: String, _ v: Double) {
        guard var items = self[list]?.arrayValue, items.indices.contains(k), var item = items[k].object else { return }
        item[key] = .number(v)
        items[k] = .object(item)
        self[list] = .array(items)
    }
}

/// How hard a set was: reps in reserve or RPE (history.js EFFORT, effort.js EFFORT_BANDS).
private struct EffortMenu: View {
    let kind: String
    let value: Double?
    let commit: (Double?) -> Void

    static let rir: [(Double, String)] = [(0, "Nothing left, went to failure"), (0.5, "Maybe half a rep left"), (1, "One more rep in the tank"),
                                         (2, "Two more reps"), (3, "Three more reps"), (4, "Easy, warm-up territory")]
    static let rpe: [Double] = Array(stride(from: 10.0, through: 6, by: -0.5))

    var body: some View {
        Menu {
            if kind == "rir" {
                ForEach(Self.rir, id: \.0) { v, feel in
                    Button { commit(v) } label: { Text("\(Format.number(v))\(v == 4 ? "+" : "") · \(feel)") }
                }
            } else {
                ForEach(Self.rpe, id: \.self) { v in Button("RPE \(Format.number(v))") { commit(v) } }
            }
            if value != nil { Button("Clear", role: .destructive) { commit(nil) } }
        } label: {
            Text(value.map { (kind == "rir" ? "RIR " : "RPE ") + Format.number($0) } ?? kind.uppercased())
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(.fill.tertiary, in: .capsule)
        }
        .accessibilityLabel(kind == "rir" ? "Reps in reserve" : "Effort, RPE")
        .accessibilityValue(value.map { Format.number($0) } ?? "Not set")
    }
}

/// A compact number entry; commits when editing ends.
private struct NumberField: View {
    let value: Double?
    let unit: String
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(unit, text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .focused($focused)
            .frame(minWidth: 52, maxWidth: 72)
            .padding(.vertical, 6)
            .background(.fill.tertiary, in: .rect(cornerRadius: 8))
            .accessibilityLabel(unit)
            // Two decimals: one would show 15.25 as "15.3" and save that on leaving the field.
            .onAppear { text = value.map { Format.number($0, decimals: 2) } ?? "" }
            .onChange(of: value) { if !focused { text = value.map { Format.number($0, decimals: 2) } ?? "" } }
            .onChange(of: focused) {
                guard !focused else { return }
                if let v = Double(text.replacingOccurrences(of: ",", with: ".")), v != value { commit(v) }
            }
    }
}

private struct RestBar: View {
    @Environment(AppModel.self) private var model
    @Environment(RestTimer.self) private var timer

    var body: some View {
        if let end = timer.end {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let left = end.timeIntervalSince(context.date)
                let over = -left
                // Green: the rest can end. Red: a minute past it.
                let colour: Color = left > 0 ? .accentColor : over < 60 ? .green : .red
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(timer.kind == .hold ? "Hold" : left > 0 ? "Rest" : "Rest over")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colour)
                        Text((left < 0 ? "+" : "") + Format.seconds(abs(left.rounded(.up))))
                            .font(.title2.weight(.semibold).monospacedDigit())
                            .contentTransition(.numericText(countsDown: true))
                    }
                    Spacer()
                    if timer.kind == .rest {
                        Button("−15 s") { timer.add(-15, alerts: alerts) }
                        Button("+15 s") { timer.add(15, alerts: alerts) }
                    }
                    Button(timer.kind == .hold ? "Stop" : "Skip") { timer.stop() }
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 12)
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var alerts: RestTimer.Alerts {
        .init(sound: model.root["sound"] != .bool(false), flash: model.root["timerFlash"] == .bool(true))
    }
}

// MARK: - After finishing

private struct Summary: Identifiable {
    let workout: AppModel.Object
    var id: String { workout["id"]?.stringValue ?? "" }
    init(_ w: AppModel.Object) { workout = w }
}

private struct FinishSummary: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let summary: Summary

    var body: some View {
        let w = summary.workout
        let entries = (w["entries"]?.arrayValue ?? []).compactMap(\.object)
        let sets = entries.flatMap { $0["sets"]?.arrayValue ?? [] }.filter { Session.hasCompletedWork($0) && !Session.isWarmup($0) }.count
        let minutes = ((w["end"]?.numberValue ?? 0) - (w["start"]?.numberValue ?? 0)) / 1000
        let prs = (w["prs"]?.arrayValue ?? []).compactMap(\.stringValue)
        NavigationStack {
            List {
                Section {
                    LabeledContent("Duration", value: Format.seconds(minutes))
                    LabeledContent("Sets", value: "\(sets)")
                    LabeledContent("Volume", value: "\(Format.number(w["vol"]?.numberValue ?? 0)) \(model.settings.unit)")
                }
                if !prs.isEmpty {
                    Section("Personal records") {
                        ForEach(prs, id: \.self) { id in
                            Label(model.catalog[id]?.displayName ?? id, systemImage: "trophy.fill").foregroundStyle(Theme.record)
                        }
                    }
                }
            }
            .navigationTitle("Workout saved")
            .toolbar { Button("Done") { dismiss() }.fontWeight(.semibold) }
        }
        .presentationDetents([.medium])
    }
}

/// Two notes for one exercise (sheets.jsx ExerciseNote): today's, saved on the entry and
/// optionally pinned for next time, and the standing one in `S.exNotes`, shown every session.
/// While a saved workout is edited only today's note is offered.
struct ExerciseNoteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let index: Int
    let entry: AppModel.Object
    @State private var note = ""
    @State private var pin = false
    @State private var standing = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("How it went, what to change.", text: $note, axis: .vertical).lineLimit(3...6)
                    Toggle("Show this next time", isOn: $pin).disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: { Text("This session") } footer: { Text("Brings it up again the next time you train this exercise.") }
                if !model.isEditingSaved {
                    Section("Always for this exercise") {
                        TextField("Seat height, pin position, a form cue.", text: $standing, axis: .vertical).lineLimit(2...4)
                    }
                }
            }
            .navigationTitle(model.catalog[entry["id"]?.stringValue ?? ""]?.displayName ?? "Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(); dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            note = entry["note"]?.stringValue ?? ""
            pin = entry["notePin"] == .bool(true)
            standing = ActiveEdit.standingNote(model.root, entry["id"]?.stringValue ?? "") ?? ""
        }
    }

    private func save() {
        let today = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ActiveEdit.noteMax))
        let always = String(standing.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ActiveEdit.noteMax))
        let (i, id, keep, pinned) = (index, entry["id"]?.stringValue ?? "", !model.isEditingSaved, pin)
        model.change { s in
            if var a = s["active"]?.object, var list = a["entries"]?.arrayValue, list.indices.contains(i), var e = list[i].object {
                e["note"] = today.isEmpty ? nil : .string(today)
                e["notePin"] = !today.isEmpty && pinned ? .bool(true) : nil
                list[i] = .object(e); a["entries"] = .array(list); s["active"] = .object(a)
            }
            if keep {
                var notes = s["exNotes"]?.object ?? [:]
                notes[id] = always.isEmpty ? nil : .string(always)
                s["exNotes"] = .object(notes)
            }
        }
    }
}
