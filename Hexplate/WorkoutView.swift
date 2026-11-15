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
        return (sg != nil ? target["sgRest"]?.numberValue : nil) ?? target["restSec"]?.numberValue ?? root["restSec"]?.numberValue ?? 90
    }

    /// "rir" or "rpe" when sets record how hard they were (history.js effortOf), else nil.
    var effortKind: String? {
        switch root["effort"]?.stringValue {
        case "rir": "rir"
        case "rpe": "rpe"
        case "none": nil
        default: root["showRir"] == .bool(true) ? "rir" : nil
        }
    }

    func discardWorkout() { change { $0["active"] = nil } }
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
            content.title = kind == .rest ? "Rest is over" : "Time"
            content.body = kind == .rest ? "Next set." : "Hold done."
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
    @State private var noteText = ""
    @State private var removeFor: Int?
    @State private var swapFor: EntryAction?
    @State private var detailFor: EntryAction?
    @State private var pendingSwap: (index: Int, entry: AppModel.Object)?

    var body: some View {
        NavigationStack {
            List {
                if let a = model.active, let start = a["start"]?.numberValue {
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
            .navigationTitle(model.active?["name"]?.stringValue ?? "Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Minimise", systemImage: "chevron.down") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Discard workout", systemImage: "trash", role: .destructive) { confirmDiscard = true }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Finish") { confirmFinish = true }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Theme.ink)
                }
            }
            .safeAreaInset(edge: .bottom) { if timer.end != nil { RestBar() } }
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
            .alert(noteFor.flatMap { entry($0)?["note"] } == nil ? "Add note" : "Edit note", isPresented: present($noteFor), presenting: noteFor) { i in
                TextField("Note", text: $noteText)
                Button("Save") {
                    let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.changeEntry(i) { $0["note"] = text.isEmpty ? nil : .string(text) }
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

    private func entry(_ i: Int) -> AppModel.Object? { model.activeEntries.indices.contains(i) ? model.activeEntries[i] : nil }
    private func name(_ e: AppModel.Object) -> String { e["id"]?.stringValue.map { model.catalog[$0]?.displayName ?? $0 } ?? "exercise" }
    private func present(_ v: Binding<Int?>) -> Binding<Bool> { Binding(get: { v.wrappedValue != nil }, set: { if !$0 { v.wrappedValue = nil } }) }

    private func act(_ a: EntryAction) {
        switch a {
        case .note(let i): noteText = entry(i)?["note"]?.stringValue ?? ""; noteFor = i
        case .remove(let i): removeFor = i
        case .swap: swapFor = a
        case .detail: detailFor = a
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
    case note(Int), swap(Int), remove(Int), detail(String)
    var id: String {
        switch self {
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
                SetRow(entry: index, index: i, number: number(of: i), row: row, mode: mode, step: step, onDone: { completed(set: i) })
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
        if let rest = model.restSeconds(after: index), rest > 0 { timer.start(rest, alerts: alerts) }
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
        return "Last " + parts.joined(separator: ", ") + (best > 0 && mode == "reps" ? " · best \(Format.number(best)) \(model.settings.unit)" : "")
    }

    /// The progression note, with its placeholders filled in.
    private var advice: (text: String, symbol: String)? {
        guard let plan = entry["plan"]?.object, let why = plan["why"]?.arrayValue, var text = why.first?.stringValue else { return nil }
        for (k, v) in why.dropFirst().enumerated() {
            text = text.replacingOccurrences(of: "{\(k)}", with: v.stringValue ?? Format.number(v.numberValue ?? 0))
        }
        let kind = plan["kind"]?.stringValue
        return (text, kind == "up" ? "arrow.up.right" : kind == "deload" ? "arrow.down.right" : "equal")
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
            Text(label)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(warm ? Theme.warmup : .secondary)
                .frame(width: 32, alignment: .leading)
                .accessibilityLabel(warm ? "Warm-up" : "Set \(label)")
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
            .onAppear { text = value.map { Format.number($0) } ?? "" }
            .onChange(of: value) { if !focused { text = value.map { Format.number($0) } ?? "" } }
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
