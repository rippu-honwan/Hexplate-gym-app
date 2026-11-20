import HexplateCore
import SwiftUI

/// Plan → Programmes (views/Programmes.jsx): the running one's card, your programmes, a new one.
// ponytail: no starter programmes and no sharing as a file yet.
struct ProgrammesView: View {
    @Environment(AppModel.self) private var model
    @State private var opened: ProgrammeLink?

    var body: some View {
        let list = Programmes.all(model.root)
        let running = Programmes.status(model.root, today: model.today)?.programme["id"]?.stringValue
        List {
            RunningProgrammeCard()
            Section {
                ForEach(list.indices, id: \.self) { i in
                    let p = list[i], id = p["id"]?.stringValue ?? ""
                    NavigationLink(value: ProgrammeLink(id: id)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Programmes.name(p))
                                Text(weeksText(p) + (id == running ? " · running" : "")).font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "calendar").foregroundStyle(.tint) }
                    }
                }
                Button("New programme", systemImage: "plus") {
                    let p = Programmes.make(model.root, name: "My programme", weeks: 4, id: RoutineOps.newId(now: model.now), now: model.now)
                    model.change { Programmes.save(&$0, p) }
                    opened = ProgrammeLink(id: p["id"]?.stringValue ?? "")
                }
            } header: { Text("Your programmes") } footer: {
                Text(list.isEmpty ? "No programmes yet. Make one from your plan." : "Your routines as a block of weeks, each week with its own %1RM or RPE.")
            }
        }
        .navigationTitle("Programmes")
        .navigationDestination(item: $opened) { ProgrammeEditor(id: $0.id) }
    }

    private func weeksText(_ p: AppModel.Object) -> String {
        let n = p["weeks"]?.arrayValue?.count ?? 1
        return n == 1 ? "1 week" : "\(n) weeks"
    }
}

struct ProgrammeLink: Hashable, Identifiable { let id: String }

extension Programmes {
    static func name(_ p: [String: JSONValue]) -> String { p["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Programme" }
}

/// Where the running programme stands, and what to do with it.
struct RunningProgrammeCard: View {
    @Environment(AppModel.self) private var model
    @State private var ending = false

    var body: some View {
        if let st = Programmes.status(model.root, today: model.today) {
            let name = Programmes.name(st.programme)
            Section("Running now") {
                LabeledContent(name, value: Programmes.chip(model.root, today: model.today) ?? "")
                if !st.done {
                    ProgressView(value: Double(st.week), total: Double(st.weeks))
                    if let w = st.current { Text(weekSummary(w, model.root)).font(.subheadline).foregroundStyle(.secondary) }
                    if st.paused {
                        Button("Resume", systemImage: "play") { act { Programmes.resume(&$0, today: $1) } }
                    } else {
                        Button("Pause", systemImage: "pause") { act { Programmes.pause(&$0, today: $1) } }
                    }
                    Button("End programme", systemImage: "stop", role: .destructive) { ending = true }
                } else {
                    Text("“\(name)” is done. Nicely lifted. What next?").font(.subheadline)
                    Button("Again, a bit heavier", systemImage: "arrow.up.right") { act { Programmes.again(&$0, today: $1, bump: Programmes.repeatBump) } }
                    Button("Run it again", systemImage: "arrow.counterclockwise") { act { Programmes.again(&$0, today: $1) } }
                    Button("Back to my plan", systemImage: "calendar") { ending = true }
                }
            }
            .alert("End “\(name)”?", isPresented: $ending) {
                Button("End programme", role: .destructive) { let t = model.now; act { Programmes.end(&$0, today: $1, now: t) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Your plan from before it comes back.") }
        }
    }

    private func act(_ f: @escaping (inout [String: JSONValue], String) -> Void) {
        let day = model.today
        model.change { f(&$0, day) }
    }
}

/// "Deload week · RPE 8 · 2 lifts at a %1RM", or what an empty week does.
func weekSummary(_ w: [String: JSONValue], _ s: [String: JSONValue]) -> String {
    let c = Programmes.cleanWeek(.object(w))
    var parts: [String] = []
    if c["deload"] == .bool(true) { parts.append("Deload week") }
    if let r = c["rpe"]?.numberValue { parts.append(rpeText(r, s)) }
    let n = (c["t"]?.object ?? [:]).values.filter { $0.object?["pct"] != nil }.count
    if n > 0 { parts.append(n == 1 ? "1 lift at a %1RM" : "\(n) lifts at a %1RM") }
    return parts.isEmpty ? "Nothing set, progression as usual" : parts.joined(separator: " · ")
}

/// The RPE as the profile logs effort: "RPE 8", or "RIR 2".
func rpeText(_ rpe: Double, _ s: [String: JSONValue]) -> String {
    (s["effort"] == .string("rir") || (s["effort"] == nil && s["showRir"] == .bool(true))) ? "RIR \(Format.number(max(0, 10 - rpe)))" : "RPE \(Format.number(rpe))"
}

/// One programme: its name, weeks, schedule and each week's targets.
struct ProgrammeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var name = ""
    @State private var week: WeekLink?
    @State private var starting = false
    @State private var deleting = false

    var body: some View {
        if let p = Programmes.byId(model.root, id) {
            let st = Programmes.status(model.root, today: model.today)
            let running = st?.programme["id"]?.stringValue == id
            let weeks = p["weeks"]?.arrayValue ?? []
            let summary = scheduleSummary(p)
            List {
                Section {
                    TextField("Name", text: $name)
                        .font(.title3.weight(.semibold))
                        .onSubmit { let v = name.trimmingCharacters(in: .whitespacesAndNewlines); edit { $0["name"] = .string(v.isEmpty ? "Programme" : v) } }
                }
                if running { RunningProgrammeCard() }
                Section {
                    Stepper("Weeks: \(weeks.count)", value: Binding(get: { weeks.count }, set: { n in edit { $0["weeks"] = .array(Programmes.resizeWeeks($0["weeks"]?.arrayValue ?? [], n)) } }),
                            in: 1...Programmes.maxWeeks)
                    LabeledContent {
                        Text(summary.isEmpty ? "No schedule yet" : summary).multilineTextAlignment(.trailing)
                    } label: { Label(p["sequence"] != nil ? "Rotation" : "Schedule", systemImage: p["sequence"] != nil ? "arrow.triangle.2.circlepath" : "calendar") }
                    Button("Use my current plan", systemImage: "square.and.arrow.down") {
                        let schedule = Programmes.currentSchedule(model.root)
                        edit { $0["days"] = nil; $0["sequence"] = nil; $0.merge(schedule) { $1 } }
                    }
                }
                Section {
                    ForEach(weeks.indices, id: \.self) { i in
                        let w = weeks[i].object ?? [:]
                        Button { week = WeekLink(index: i) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Week \(i + 1)")
                                    Text(weekSummary(w, model.root)).font(.subheadline).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: w["deload"] == .bool(true) ? "chart.line.downtrend.xyaxis" : "chart.line.uptrend.xyaxis")
                                    .foregroundStyle(w["deload"] == .bool(true) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tint))
                            }
                        }
                        .tint(.primary)
                        .listRowBackground(running && st?.week == i + 1 && st?.done == false ? Theme.accent.opacity(0.15) : nil)
                    }
                } header: { Text("Weeks") } footer: {
                    Text("The week is the calendar week: week 1 is the one you start in. A pause holds it.")
                }
                Section {
                    if !running {
                        Button("Start programme", systemImage: "play") { starting = true }.disabled(summary.isEmpty)
                    }
                    Button("Delete programme", systemImage: "trash", role: .destructive) { deleting = true }
                }
            }
            .navigationTitle(Programmes.name(p))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { name = p["name"]?.stringValue ?? "" }
            .onDisappear { let v = name.trimmingCharacters(in: .whitespacesAndNewlines); if !v.isEmpty && v != p["name"]?.stringValue { edit { $0["name"] = .string(v) } } }
            .sheet(item: $week) { WeekEditor(id: id, index: $0.index) }
            .alert("Start “\(Programmes.name(p))”?", isPresented: $starting) {
                Button("Start programme") { let (d, t) = (model.today, model.now); model.change { Programmes.start(&$0, id, today: d, now: t) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Its schedule takes over your plan until you end it. Then your plan comes back as it was.") }
            .alert("Delete “\(Programmes.name(p))”?", isPresented: $deleting) {
                Button("Delete", role: .destructive) {
                    let (d, t) = (model.today, model.now)
                    model.change { Programmes.delete(&$0, id, today: d, now: t) }
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text(running ? "It is running: ending it brings your plan back. Its routines stay." : "Its routines stay.") }
        } else {
            ContentUnavailableView("This programme is gone.", systemImage: "calendar")
        }
    }

    private func edit(_ f: @escaping (inout [String: JSONValue]) -> Void) {
        model.change { s in
            guard var p = Programmes.byId(s, id) else { return }
            f(&p)
            Programmes.save(&s, p)
        }
    }

    private func scheduleSummary(_ p: [String: JSONValue]) -> String {
        func name(_ id: String) -> String? { id == Schedule.rest ? "Rest day" : model.routine(id)?.name }
        if let seq = p["sequence"]?.arrayValue { return seq.compactMap { $0.stringValue.flatMap(name) }.joined(separator: " → ") }
        let days = p["days"]?.object ?? [:]
        let ws = model.root["weekStart"] == .number(0) ? 0 : 1
        let symbols = Calendar(identifier: .gregorian).shortWeekdaySymbols
        return (0..<7).map { ($0 + ws) % 7 }.compactMap { d -> String? in
            let ids = (days[String(d)]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !ids.isEmpty else { return nil }
            return "\(symbols[d]) " + ids.compactMap(name).joined(separator: " + ")
        }.joined(separator: " · ")
    }
}

struct WeekLink: Identifiable { let index: Int; var id: Int { index } }

/// One week's targets: a deload, an effort for the week, a %1RM per lift (Programmes.jsx WeekSheet).
struct WeekEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    let index: Int
    static let rpes: [Double] = [6, 7, 7.5, 8, 8.5, 9, 9.5, 10]

    var body: some View {
        NavigationStack {
            if let p = Programmes.byId(model.root, id), let weeks = p["weeks"]?.arrayValue, weeks.indices.contains(index) {
                let w = weeks[index].object ?? [:]
                Form {
                    Section {
                        Toggle("Deload week", isOn: Binding(get: { w["deload"] == .bool(true) }, set: { v in setWeek { $0["deload"] = v ? .bool(true) : nil } }))
                    } footer: { Text("Lighter weights, and its sessions do not count toward progression.") }
                    Picker("Effort for the week", selection: Binding(get: { w["rpe"]?.numberValue ?? 0 }, set: { v in setWeek { $0["rpe"] = v > 0 ? .number(v) : nil } })) {
                        Text("None").tag(0.0)
                        ForEach(Self.rpes, id: \.self) { Text(rpeText($0, model.root)).tag($0) }
                    }
                    Section {
                        ForEach(lifts(p), id: \.self) { exId in liftRow(exId, w) }
                    } header: { Text("%1RM per lift") } footer: {
                        Text("Empty leaves the weight to your progression. A %1RM is worked out from your best estimated 1RM.")
                    }
                    if index > 0 {
                        Button("Same as last week, a bit heavier", systemImage: "doc.on.doc") {
                            let prev = weeks[index - 1]
                            setWeek { $0 = Programmes.stepWeek(prev) }
                        }
                    }
                }
                .keyboardDismissal()
                .navigationTitle("Week \(index + 1) of \(weeks.count)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
    }

    @ViewBuilder private func liftRow(_ exId: String, _ w: [String: JSONValue]) -> some View {
        let pct = w["t"]?.object?[exId]?.object?["pct"]?.numberValue
        let cfg: [String: JSONValue] = ["id": .string(exId)]
        let step = Session.increment(cfg, unit: model.settings.unit, catalog: model.catalog)
        let est = pct.flatMap { Programmes.pctWeight(model.root, exId, $0, step: step, floor: 0, catalog: model.catalog) }
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.catalog[exId]?.displayName ?? exId)
                if pct != nil {
                    Text(est.map { "about \(Format.number($0)) \(model.settings.unit)" } ?? "Log a set first to work this out")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            TextField("—", value: Binding(get: { pct }, set: { v in setPct(exId, v) }), format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Text("%").foregroundStyle(.secondary)
        }
    }

    /// The loaded, rep-counted lifts of the programme's routines, once each.
    private func lifts(_ p: [String: JSONValue]) -> [String] {
        let ids = Programmes.routineIds(model.root, p)
        var out: [String] = []
        for rid in ids {
            for o in (model.routine(rid)?.slots ?? []) {
                guard let ex = o["id"]?.stringValue, !out.contains(ex),
                      RoutineOps.mode(o, catalog: model.catalog) == "reps", !RoutineOps.isBodyweight(o, catalog: model.catalog) else { continue }
                out.append(ex)
            }
        }
        return out
    }

    private func setPct(_ exId: String, _ v: Double?) {
        setWeek { w in
            var t = w["t"]?.object ?? [:]
            var one = t[exId]?.object ?? [:]
            one["pct"] = Programmes.cleanPct(v.map(JSONValue.number)).map(JSONValue.number)
            t[exId] = .object(one)
            w["t"] = .object(t)
        }
    }

    private func setWeek(_ f: @escaping (inout [String: JSONValue]) -> Void) {
        let (id, index) = (id, index)
        model.change { s in
            guard var p = Programmes.byId(s, id), var weeks = p["weeks"]?.arrayValue, weeks.indices.contains(index) else { return }
            var w = weeks[index].object ?? [:]
            f(&w)
            weeks[index] = .object(Programmes.cleanWeek(.object(w)))
            p["weeks"] = .array(weeks)
            Programmes.save(&s, p)
        }
    }
}
