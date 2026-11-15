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
    @State private var picking = false
    @State private var summary: AppModel.Object?

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
                    EntrySection(index: i, entry: entry, next: next(after: i))
                }
                Section {
                    Button("Add exercise", systemImage: "plus") { picking = true }
                }
            }
            .listSectionSpacing(.compact)
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
            .confirmationDialog("Finish this workout?", isPresented: $confirmFinish, titleVisibility: .visible) {
                Button("Finish workout") {
                    timer.stop()
                    summary = model.finishWorkout()
                }
            } message: {
                Text(unfinished > 0 ? "\(unfinished) planned \(unfinished == 1 ? "set is" : "sets are") not done and will be left out." : "Every set is done.")
            }
            .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard workout", role: .destructive) {
                    timer.stop()
                    model.discardWorkout()
                    dismiss()
                }
            } message: {
                Text("Nothing from this session is saved.")
            }
            .sheet(isPresented: $picking) { ExercisePicker { model.addExercise($0) } }
            .sheet(item: Binding(get: { summary.map(Summary.init) }, set: { if $0 == nil { summary = nil; dismiss() } })) { FinishSummary(summary: $0) }
        }
    }

    private var unfinished: Int {
        model.activeEntries.flatMap { $0["sets"]?.arrayValue ?? [] }.filter { !Session.hasCompletedWork($0) && !Session.isWarmup($0) }.count
    }

    /// The superset partner that comes next after entry `i`, if any.
    private func next(after i: Int) -> Int? {
        let entries = model.activeEntries
        // SwiftUI can still ask for a row of a session that just finished.
        guard entries.indices.contains(i), let sg = entries[i]["sg"]?.stringValue, !sg.isEmpty else { return nil }
        return entries.indices.first { $0 > i && entries[$0]["sg"]?.stringValue == sg }
    }
}

private struct EntrySection: View {
    @Environment(AppModel.self) private var model
    @Environment(RestTimer.self) private var timer
    let index: Int
    let entry: AppModel.Object
    let next: Int?

    private var id: String { entry["id"]?.stringValue ?? "" }
    private var target: AppModel.Object { entry["target"]?.object ?? [:] }
    private var mode: String { RoutineOps.mode(target.merging(["id": .string(id)]) { a, _ in a }, catalog: model.catalog) }
    private var sets: [JSONValue] { entry["sets"]?.arrayValue ?? [] }
    private var step: Double { Session.increment(target, unit: model.settings.unit, catalog: model.catalog) }

    var body: some View {
        Section {
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
                Text(model.catalog[id]?.displayName ?? id)
                if let sg = entry["sg"]?.stringValue, !sg.isEmpty {
                    Text("Superset").font(.caption.bold()).foregroundStyle(Theme.superset)
                }
            }
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
        if next != nil { return }
        let rest = (entry["sg"]?.stringValue).flatMap { _ in target["sgRest"]?.numberValue }
            ?? target["restSec"]?.numberValue ?? model.root["restSec"]?.numberValue ?? 90
        if rest > 0 { timer.start(rest, alerts: alerts) }
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

    private func set(_ key: String, _ v: Double, _ side: String?) {
        edit { o in
            if let side, var sides = o["sides"]?.object, var one = sides[side]?.object {
                one[key] = .number(v)
                sides[side] = .object(one)
                o["sides"] = .object(sides)
                o = Session.syncSides(o).object ?? o
            } else {
                o[key] = .number(v)
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
