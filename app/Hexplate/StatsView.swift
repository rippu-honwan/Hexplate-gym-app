import Charts
import HexplateCore
import SwiftUI

extension AppModel {
    func logWeight(_ w: Double, on day: String, fromHealth: Bool = false) {
        let at = now
        if !fromHealth && UserDefaults.standard.bool(forKey: "health") && Modules.isOn(root, "health") {
            Health.save(weight: w, unit: settings.unit, at: day == today ? .now : Day.date(day) ?? .now)
        }
        let time = Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
        change { BodyData.addWeighIn(&$0, day: day, time: day == today ? time : nil, weight: w, at: at, id: RoutineOps.newId(now: at)) }
    }

    func saveMeasurements(_ values: [String: Double?], on day: String, fields: [BodyData.Field]) {
        let at = now
        change { BodyData.saveMeasurements(&$0, day: day, at: at, values, fields: fields) }
    }
}

enum StatsSheet: String, Identifiable {
    case weight, composition, tape
    var id: String { rawValue }
}

/// All existing stats sections emitted directly into AnalysisView's outer List.
struct StatsContent: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: StatsSheet?

    var body: some View {
        if Modules.isOn(model.root, "motivation") { StreakSection() }
        if Modules.isOn(model.root, "body") { bodySection }
        MuscleSetsSection()
        volumeSection
        daysSection
        if Modules.isOn(model.root, "strength") { strengthSection }
        if Modules.isOn(model.root, "motivation") {
            TrophyShelfSection()
            WrappedYearsSection()
        }
        Section {
            NavigationLink("Structural balance") { BalanceView() }
        } footer: {
            Text("How each lift compares with the others, against a strength standard.")
        }
        Section {
            NavigationLink("Performance report (PDF)") { ReportView() }
        } footer: {
            Text("Totals, charts, new bests and every set over a stretch of days, to print or send to your coach.")
        }
    }

    // MARK: Body

    @ViewBuilder private var bodySection: some View {
        let weights = BodyData.weights(model.root)
        Section {
            if let last = weights.last {
                LabeledContent("Body weight") {
                    Text("\(Format.number(last.weight)) \(model.settings.unit)").monospacedDigit()
                }
                if let goal = BodyData.goal(model.root) {
                    LabeledContent("Goal", value: "\(Format.number(goal)) \(model.settings.unit)")
                }
                if weights.count > 1 {
                    Chart(weights.suffix(90)) { r in
                        if let d = Day.date(r.day) {
                            LineMark(x: .value("Day", d), y: .value("Weight", r.weight))
                            PointMark(x: .value("Day", d), y: .value("Weight", r.weight)).symbolSize(16)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 140)
                    .accessibilityLabel("Body weight over time")
                }
            }
            Button("Log weight", systemImage: "scalemass") { sheet = .weight }
            let comp = BodyData.compositionFields.prefix(5).compactMap { f in BodyData.latest(model.root, f.id).map { (f, $0) } }
            if !comp.isEmpty {
                ForEach(comp, id: \.0.id) { f, v in
                    LabeledContent(f.name, value: "\(Format.number(v.value))\(f.unit.isEmpty ? "" : " " + f.unit)")
                }
            }
            Button("Add body composition", systemImage: "figure.arms.open") { sheet = .composition }
            Button("Add measurements", systemImage: "ruler") { sheet = .tape }
        } header: {
            Text("Body")
        }
    }

    // MARK: Training

    @ViewBuilder private var volumeSection: some View {
        let weeks = Stats.weeklyVolume(model.root, today: model.today)
        if weeks.contains(where: { $0.volume > 0 }) {
            Section("Volume per week") {
                Chart(weeks, id: \.week) { w in
                    if let d = Day.date(w.week) {
                        BarMark(x: .value("Week", d, unit: .weekOfYear), y: .value("Volume", w.volume))
                    }
                }
                .frame(height: 140)
                .accessibilityLabel("Volume per week, last 12 weeks")
            }
        }
    }

    @ViewBuilder private var daysSection: some View {
        let trained = Stats.trainingDays(model.root)
        let start = model.root["weekStart"] == .number(0) ? 0 : 1
        if let thisWeek = Schedule.weekKey(model.today, weekStart: start) {
            let weeks = (0..<18).reversed().compactMap { Day.adding(-7 * $0, to: thisWeek) }
            Section {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    ForEach(0..<7, id: \.self) { d in
                        GridRow {
                            ForEach(weeks, id: \.self) { w in
                                let day = Day.adding(d, to: w) ?? ""
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(trained.contains(day) ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary))
                                    .opacity(day > model.today ? 0.3 : 1)
                                    .aspectRatio(1, contentMode: .fit)
                            }
                        }
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("\(weeks.flatMap { w in (0..<7).compactMap { Day.adding($0, to: w) } }.filter(trained.contains).count) training days in the last 18 weeks")
            } header: {
                Text("Training days")
            }
        }
    }

    @ViewBuilder private var strengthSection: some View {
        let levels = Stats.strengthLevels(model.root, catalog: model.catalog)
        let lifts = topLifts
        Section {
            ForEach(levels, id: \.id) { l in
                NavigationLink(value: LiftLink(id: l.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(model.catalog[l.id]?.displayName ?? l.lift)
                            Spacer()
                            Text(Stats.levels[l.level]).foregroundStyle(.tint)
                        }
                        Text("\(Format.number(l.ratio, decimals: 2))× body weight" + (l.nextWeight.map { " · \(Format.number($0)) \(model.settings.unit) for \(Stats.levels[l.level + 1].lowercased())" } ?? ""))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(lifts.filter { id in !levels.contains { $0.id == id.id } }, id: \.id) { lift in
                NavigationLink(value: LiftLink(id: lift.id)) {
                    LabeledContent(model.catalog[lift.id]?.displayName ?? lift.id, value: "\(Format.number(lift.best)) \(model.settings.unit)")
                }
            }
        } header: {
            Text("Strength")
        } footer: {
            Text(levels.isEmpty ? "Estimated one-rep maxes (\(Stats.formulaNames[Stats.formula(model.root)] ?? "Epley")). Log your body weight to see strength levels." : "Estimated one-rep maxes (\(Stats.formulaNames[Stats.formula(model.root)] ?? "Epley")).")
        }
    }

    /// Exercises with an estimated one-rep max, best first.
    private var topLifts: [(id: String, best: Double)] {
        let ids = Set((model.root["workouts"]?.arrayValue ?? []).flatMap { $0.object?["entries"]?.arrayValue ?? [] }.compactMap { $0.object?["id"]?.stringValue })
        return ids.compactMap { id in Stats.bestOneRepMax(model.root, id, catalog: model.catalog).map { (id: id, best: $0.estimate) } }
            .sorted { $0.best > $1.best }
            .prefix(12).map { $0 }
    }
}

struct LiftLink: Hashable { let id: String }

struct OneRepMaxView: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        let series = Stats.oneRepMaxSeries(model.root, id, catalog: model.catalog)
        List {
            Section {
                Chart(series, id: \.day) { p in
                    if let d = Day.date(p.day) {
                        LineMark(x: .value("Day", d), y: .value("Estimated 1RM", p.estimate))
                        PointMark(x: .value("Day", d), y: .value("Estimated 1RM", p.estimate)).symbolSize(20)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 200)
                .accessibilityLabel("Estimated one-rep max over time")
            }
            Section("Sessions") {
                ForEach(series.reversed(), id: \.day) { p in
                    LabeledContent {
                        Text("\(Format.number(p.estimate)) \(model.settings.unit)").monospacedDigit()
                    } label: {
                        Text(Day.date(p.day)?.formatted(.dateTime.day().month(.abbreviated).year().locale(Theme.locale)) ?? p.day)
                        Text("\(Format.number(p.weight)) × \(Int(p.reps))")
                    }
                }
            }
        }
        .navigationTitle(model.catalog[id]?.displayName ?? id)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WeightEntry: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var date = Date.now

    var body: some View {
        NavigationStack {
            Form {
                TextField("Weight (\(model.settings.unit))", text: $text)
                    .keyboardType(.decimalPad)
                    .font(.title2.monospacedDigit())
                DatePicker("Day", selection: $date, in: ...Date.now, displayedComponents: .date)
            }
            .keyboardDismissal()
            .navigationTitle("Log weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let w = Double(text.replacingOccurrences(of: ",", with: ".")) { model.logWeight(w, on: Day.iso(date)) }
                        dismiss()
                    }
                    .disabled(Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 <= 0)
                }
            }
            .onAppear { text = BodyData.weights(model.root).last.map { Format.number($0.weight) } ?? "" }
        }
        .presentationDetents([.medium])
    }
}

struct MeasurementEntry: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: String
    let fields: [BodyData.Field]
    let withWeight: Bool
    @State private var texts: [String: String] = [:]
    @State private var weight = ""
    @State private var date = Date.now

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Day", selection: $date, in: ...Date.now, displayedComponents: .date)
                if withWeight {
                    row("Weight", unit: model.settings.unit, text: $weight)
                }
                Section {
                    ForEach(fields) { f in
                        row(f.name, unit: f.unit, text: Binding(get: { texts[f.id] ?? "" }, set: { texts[f.id] = $0 }))
                    }
                }
            }
            .keyboardDismissal()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear(perform: load)
            .onChange(of: date) { load() }
        }
    }

    private func row(_ name: String, unit: String, text: Binding<String>) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField("–", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        } label: {
            Text(name)
        }
    }

    private func number(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }

    private func load() {
        let values = BodyData.values(model.root, day: Day.iso(date))
        texts = values.mapValues { Format.number($0, decimals: 2) }
    }

    private func save() {
        let day = Day.iso(date)
        let before = BodyData.values(model.root, day: day)
        var changes: [String: Double?] = [:]
        for f in fields {
            let v = number(texts[f.id] ?? "")
            if v != before[f.id] { changes[f.id] = .some(v) }
        }
        if !changes.isEmpty { model.saveMeasurements(changes, on: day, fields: fields) }
        if withWeight, let w = number(weight), w > 0 { model.logWeight(w, on: day) }
        dismiss()
    }
}

/// Structural balance against the chosen standard (views/StructuralBalance.jsx).
// ponytail: changing a role's exercise is not here yet; overrides set in the old app are honoured.
private struct BalanceView: View {
    @Environment(AppModel.self) private var model
    @State private var picking: String?

    var body: some View {
        let template = Balance.template(model.root)
        List {
            Section {
                Picker("Standard", selection: Binding(get: { template?.id ?? "" }, set: { model.set("balanceTemplate", .string($0)) })) {
                    ForEach(Balance.templates, id: \.id) { Text($0.label).tag($0.id) }
                }
            }
            if let template {
                Section {
                    ForEach(Balance.compute(model.root, template, catalog: model.catalog), id: \.roleId) { r in
                        if let role = template.roles.first(where: { $0.id == r.roleId }) {
                            Menu {
                                Button("Change exercise", systemImage: "pencil") { picking = role.id }
                                if r.isOverridden {
                                    Button("Use default exercise", systemImage: "arrow.uturn.backward") { setOverride(template, role, nil) }
                                }
                            } label: { row(r, role: role) }
                            .foregroundStyle(.primary)
                        }
                    }
                } footer: {
                    Text("Balanced: at the standard. Borderline: within 5 points of it. Estimated from your best logged sets.")
                }
            }
        }
        .navigationTitle("Structural balance")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) {
            ExercisePicker(title: "Change exercise") { id in
                if let template, let role = template.roles.first(where: { $0.id == picking }) { setOverride(template, role, id) }
            }
        }
    }

    private func setOverride(_ t: Balance.Template, _ role: Balance.Role, _ id: String?) {
        let now = model.now
        model.change { $0["balanceOverrides"] = Balance.withOverride($0["balanceOverrides"], Balance.overrideKey(t, role), id, now: now) }
    }

    private func row(_ r: Balance.Result, role: Balance.Role?) -> some View {
        let reps = role?.evaluationMode == "rep-count"
        let actual = r.status == "no-data" ? "–" : reps ? "\(Int(r.current?.r ?? 0))" : "\(Int((r.actualPct ?? 0).rounded()))%"
        let exId = r.mappedExerciseId ?? r.configuredExerciseId
        let (label, symbol): (String, String) = switch r.status {
        case "balanced": ("Balanced", "checkmark.circle.fill")
        case "borderline": ("Borderline", "minus.circle")
        case "weak": ("Weak", "arrow.down.circle")
        default: (r.needsAnchor ? "Not scored" : "No data", "circle.dashed")
        }
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(role?.label ?? r.roleId)
                Text((exId.flatMap { model.catalog[$0]?.displayName } ?? "") + (r.isOverridden ? " · Custom" : ""))
                    .font(.subheadline).foregroundStyle(.secondary)
                if r.needsBodyweight { Text("Log your body weight to score this lift.").font(.footnote).foregroundStyle(.secondary) }
                if r.needsAnchor { Text("Log the anchor lift to score this one.").font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Label(label, systemImage: symbol)
                    .foregroundStyle(r.status == "balanced" ? AnyShapeStyle(.tint) : r.status == "no-data" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                Text("\(actual) / \(Format.number(r.targetPct))\(reps ? "" : "%")").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Sets per muscle this week against each muscle's range (Stats, and Home with Weekly sets on Home).
struct MuscleSetsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = Stats.weeklyMuscleSets(model.root, today: model.today, catalog: model.catalog)
        Section {
            ForEach(rows, id: \.slug) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(LocalizedStringKey(model.catalog.muscleName(row.slug)))
                        Spacer()
                        Text("\(Format.number(row.sets)) / \(Int(row.low))–\(Int(row.high))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    Gauge(value: min(row.sets, row.high), in: 0...max(row.high, 1)) {}
                        .gaugeStyle(.linearCapacity)
                        .tint(row.status == "below" ? Color.secondary : Theme.accent)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Sets per muscle this week")
        } footer: {
            Text("Ticked-off work sets, shared out by how much each exercise works a muscle.")
        }
    }
}
