import HealthKit
import HexplateCore
import SwiftUI

extension AppModel {
    /// Sets one top-level setting; nil removes it.
    func set(_ key: String, _ value: JSONValue?) { change { $0[key] = value } }

    /// The state file as it is, for "Export JSON".
    var stateFileURL: URL { URL.applicationSupportDirectory.appending(path: "Hexplate/state.json") }

    /// A CSV file in the temporary folder, for the share sheet.
    func csvFile(_ name: String, _ text: String) -> URL? {
        let url = URL.temporaryDirectory.appending(path: "hexplate-\(name)-\(today).csv")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            errorMessage = "The CSV could not be written. \(error.localizedDescription)"
            return nil
        }
    }
}

// MARK: - Apple Health

/// Writes body weight and finished workouts to Apple Health, and reads weights back in.
@MainActor
enum Health {
    static let store = HKHealthStore()
    static let mass = HKQuantityType(.bodyMass)
    static var available: Bool { HKHealthStore.isHealthDataAvailable() }

    static func authorise() async -> Bool {
        guard available else { return false }
        do {
            try await store.requestAuthorization(toShare: [mass, .workoutType()], read: [mass])
            return true
        } catch {
            return false
        }
    }

    static func save(weight: Double, unit: String, at date: Date) {
        guard available else { return }
        let q = HKQuantity(unit: unit == "lb" ? .pound() : .gramUnit(with: .kilo), doubleValue: weight)
        store.save(HKQuantitySample(type: mass, quantity: q, start: date, end: date)) { _, _ in }
    }

    static func save(workout start: Date, end: Date) async {
        guard available, end > start else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        do {
            try await builder.beginCollection(at: start)
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch {}
    }

    /// Weights logged in Health over the last `days` days, oldest first.
    static func weights(unit: String, days: Int = 90) async -> [(date: Date, weight: Double)] {
        guard available else { return [] }
        let from = Calendar.current.date(byAdding: .day, value: -days, to: .now)
        let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: mass, predicate: HKQuery.predicateForSamples(withStart: from, end: nil))],
                                            sortDescriptors: [SortDescriptor(\.startDate)])
        let samples = (try? await query.result(for: store)) ?? []
        return samples.map { ($0.startDate, $0.quantity.doubleValue(for: unit == "lb" ? .pound() : .gramUnit(with: .kilo))) }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("health") private var health = false
    @AppStorage(Theme.languageKey) private var language = Theme.language
    @State private var importing = false
    @State private var healthNote: String?

    @State private var choosingPlan = false

    /// The root is a short list of pages, grouped the way openGym's Settings groups them (Modules;
    /// Workout, Timer alerts, Reminders; Plan, Units, Equipment; Look; Health, Data, Server).
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ModulesPage() } label: {
                        row("Modules", "square.grid.2x2.fill", .blue, value: "\(Modules.ids.filter { Modules.isOn(model.root, $0) }.count) / \(Modules.ids.count)")
                    }
                }
                Section {
                    page("Workout", "figure.strengthtraining.traditional", Theme.accent) { workout }
                    NavigationLink { AlertsPage() } label: { row("Timer alerts", "speaker.wave.2.fill", .orange) }
                    page("Reminders", "bell.fill", .red) { reminders }
                }
                Section {
                    page("Plan & schedule", "calendar", .orange) { plan }
                    page("Units & language", "globe", .blue, value: language == "en" ? "English" : "中文") { units }
                    NavigationLink { EquipmentPage() } label: { row("Equipment", "scalemass.fill", .indigo) }
                }
                Section {
                    NavigationLink { LookPage() } label: { row("Look & Home", "paintpalette.fill", .purple, value: themeName) }
                }
                Section {
                    if Modules.isOn(model.root, "health") {
                        page("Apple Health", "heart.fill", .pink, value: String(localized: health ? "On" : "Off")) { healthPage }
                    }
                    page("Data & backup", "folder.fill", .blue) { data }
                    page("Server", "server.rack", .gray, value: String(localized: ServerSync.shared.paired ? "Connected" : "Off")) { ServerSection() }
                } footer: {
                    Text(verbatim: "Hexplate \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .frame(maxWidth: .infinity).padding(.top, 12)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.fontWeight(.semibold) }
            .sheet(isPresented: $importing) { ImportView() }
            .sheet(isPresented: $choosingPlan) { StarterPlanSheet() }
        }
    }

    private var themeName: String {
        String(localized: appearance == "light" ? "Light" : appearance == "dark" ? "Dark" : "System")
    }

    // MARK: Pages

    @ViewBuilder private var workout: some View {
        Section("Logging") {
            if Modules.isOn(model.root, "effort") {
                picker("Effort per set", "effort", [("none", "Off"), ("rir", "Reps in reserve"), ("rpe", "RPE")], fallback: "none")
            }
            ProfileToggle(title: "Compare sets with last time", key: "setTrend", fallback: true,
                          subtitle: "A small ↑, = or ↓ on each set you finish, against the same set last time.")
            ProfileToggle(title: "Collapse completed exercises", key: "collapseCompleted", subtitle: "A finished exercise folds into one line.")
        }
        if Modules.isOn(model.root, "plates") {
            Section("Warm-ups") {
                picker("Automatic warm-ups", "warmupAuto", [("off", "Off"), ("compounds", "Compound lifts"), ("all", "All lifts")], fallback: "off")
            }
        }
        Section {
            stepper("Rest timer", "restSec", fallback: 90, range: 0...600, step: 15)
            stepper("Rest-pause rest", "restPauseSec", fallback: 15, range: 5...120, step: 5)
            Picker(selection: Binding(get: { model.root["warmupRestSec"]?.numberValue ?? -1 }, set: { model.set("warmupRestSec", $0 < 0 ? nil : .number($0)) })) {
                Text("Like the work sets").tag(-1.0)
                Text("No timer").tag(0.0)
                ForEach([15.0, 30, 45, 60, 90, 120], id: \.self) { Text(Format.seconds($0)).tag($0) }
            } label: {
                Text("Rest between warm-ups")
                Text("The last warm-up still gets the full rest before your first work set.")
            }
        } header: {
            Text("Rest")
        } footer: {
            Text("Each exercise can have its own rest too. Set it in the exercise settings of a routine.")
        }
        Section("Before and during") {
            if Modules.isOn(model.root, "body") {
                ProfileToggle(title: "Weigh in before workouts", key: "weighIn", fallback: true,
                              subtitle: "Asks for your body weight when a workout starts. Off starts the session straight away.")
            }
            ProfileToggle(title: "Keep screen awake", key: "keepAwake", fallback: true,
                          subtitle: "The screen stays on while a workout is running, so you don’t have to unlock your phone between sets.")
            picker("Exercise animations", "gifSize", [("full", "Full"), ("mini", "Small"), ("off", "Off")], fallback: "full")
        }
        Section("Fine-tuning") {
            picker("Default progression", "progDefault", [("linear", "Linear"), ("double", "Double"), ("greyskull", "Greyskull LP"), ("off", "Off")], fallback: "linear")
            ProfileToggle(title: "Keep timing after target", key: "timedSetOvertime",
                          subtitle: "Timed sets continue up to 15 extra minutes. Tap Done to log the actual duration.")
        }
    }

    @ViewBuilder private var reminders: some View {
        ReminderSection()
        Section {
            NavigationLink { GymReminderPage() } label: {
                LabeledContent("Gym reminder", value: String(localized: GymReminder.shared.on ? "On" : "Off"))
            }
        } footer: {
            Text("A nudge when you walk into your gym.")
        }
        Section {
            Button("Send test notification", systemImage: "bell.badge") { sendTestNotification() }
        } footer: {
            Text("Arrives in five seconds, so you can lock the phone and see how it looks.")
        }
    }

    @ViewBuilder private var plan: some View {
        Section {
            picker("Week starts on", "weekStart", [(1, "Monday"), (0, "Sunday")], fallback: 1)
            if Schedule.scheduleMode(model.root) == "rotation" {
                picker("Workouts per week", "weekTarget", [(0, "Off")] + (1...7).map { ($0, "\($0)") }, fallback: 0, zeroIsNil: true)
            }
        } footer: {
            if Schedule.scheduleMode(model.root) == "rotation" { Text("A countdown of the week’s workouts on Home. Off says nothing.") }
        }
        Section {
            NavigationLink("Weekly sets per muscle") { MuscleTargetsEditor() }
            Button("Load starter plan", systemImage: "list.clipboard") { choosingPlan = true }
        }
    }

    @ViewBuilder private var units: some View {
        Section {
            // ponytail: read at launch (Theme.language), so a switch shows after Hexplate is opened again.
            Picker("Language", selection: $language) {
                Text(verbatim: "中文").tag("zh")
                Text(verbatim: "English").tag("en")
            }
            .onChange(of: language) { Theme.applyLanguage(language) }
            if language == "zh" {
                Toggle(isOn: Binding(get: { model.root["enParens"]?.object?["zh-TW"] != .bool(false) }, set: { v in setNameChoice("enParens", v) })) {
                    Text("English exercise names")
                    Text("Show the English name in parentheses next to the translated one.")
                }
                .disabled(model.root["enOnly"]?.object?["zh-TW"] == .bool(true))
                Toggle(isOn: Binding(get: { model.root["enOnly"]?.object?["zh-TW"] == .bool(true) }, set: { v in setNameChoice("enOnly", v) })) {
                    Text("English names only")
                    Text("Replace the translated names with the original English ones.")
                }
            }
        } footer: {
            if language != Theme.language {
                Text("Close Hexplate and open it again to switch the language.").foregroundStyle(Theme.accent)
            }
        }
        Section {
            picker("Weight unit", "unit", [("kg", "kg"), ("lb", "lb")], fallback: "kg")
            picker("Weight decimals", "wdec", [(1, "1"), (2, "2")], fallback: 1)
            picker("Speed unit", "speedUnit", [("kmh", "km/h"), ("mph", "mph")], fallback: model.settings.speedUnit)
            picker("1RM formula", "oneRmFormula", Stats.formulaNames.sorted { $0.value < $1.value }.map { ($0.key, $0.value) }, fallback: "epley")
        } footer: {
            Text("How precisely weights are shown.")
        }
        Section {
            ProfileToggle(title: "Count warm-ups in volume", key: "volumeWarmups",
                          subtitle: "Handy when you compare with another app. Records ignore warm-ups either way.")
            ProfileToggle(title: "Count body weight in bodyweight lifts", key: "volumeBodyweight",
                          subtitle: "Pull-ups, dips and push-ups add your nearest weigh-in to their volume. Records stay as logged.")
        }
        if Modules.isOn(model.root, "strength") {
            Section {
                picker("Sex", "sex", [("", "Not set"), ("male", "Male"), ("female", "Female")], fallback: "")
                numberRow("Birth year", "birthYear", decimals: 0)
                numberRow("Goal weight (\(model.settings.unit))", "targetW", decimals: 1)
            } header: {
                Text("About you")
            } footer: {
                Text("Sex and age set the strength level standards.")
            }
        }
    }

    /// `enParens` / `enOnly` are kept per language, as openGym keeps them; Hexplate's is "zh-TW".
    private func setNameChoice(_ key: String, _ on: Bool) {
        model.change { s in
            var m = s[key]?.object ?? [:]
            m["zh-TW"] = .bool(on)
            s[key] = .object(m)
            ExerciseNames.style = ExerciseNames.style(language: Theme.language, profile: s)
        }
    }

    @ViewBuilder private var healthPage: some View {
        Section {
            Toggle("Apple Health", isOn: $health)
                .onChange(of: health) {
                    guard health else { return }
                    Task { if !(await Health.authorise()) { health = false; healthNote = String(localized: "Apple Health is not available.") } }
                }
            if health {
                Button("Import weights from Health") { Task { await importWeights() } }
            }
            if let healthNote { Text(healthNote).foregroundStyle(.secondary) }
        } footer: {
            Text("Weigh-ins and finished workouts are written to Health.")
        }
    }

    @ViewBuilder private var data: some View {
        Section {
            ShareLink("Export backup (JSON)", item: model.stateFileURL)
            NavigationLink("Performance report (PDF)") { ReportView() }
            NavigationLink("Export as spreadsheet (CSV)") { CSVExportView() }
            Button("Import backup", systemImage: "square.and.arrow.down") { importing = true }
        } footer: {
            Text("JSON is the openGym format and holds everything. A copy is also kept automatically once a day (the last seven days).")
        }
    }

    // MARK: Rows

    private func row(_ title: LocalizedStringKey, _ icon: String, _ tint: Color, value: String? = nil) -> some View {
        LabeledContent {
            if let value { Text(value) }
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 29, height: 29)
                    .background(tint, in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func page<Content: View>(_ title: LocalizedStringKey, _ icon: String, _ tint: Color, value: String? = nil,
                                     @ViewBuilder _ content: @escaping () -> Content) -> some View {
        NavigationLink {
            Form { content() }
                .keyboardDone()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            row(title, icon, tint, value: value)
        }
    }

    // MARK: Rows bound to the document

    private func picker<T: Hashable>(_ title: LocalizedStringKey, _ key: String, _ options: [(T, String)], fallback: T, zeroIsNil: Bool = false) -> some View {
        let has = { (v: T) in options.contains { $0.0 == v } }
        return Picker(title, selection: Binding<T>(
            get: {
                let v = model.root[key]
                if let s = v?.stringValue as? T, has(s) { return s }
                if let n = v?.numberValue.map(Int.init) as? T, has(n) { return n }
                return fallback
            },
            set: { value in
                if let s = value as? String { model.set(key, s.isEmpty ? nil : .string(s)) }
                if let n = value as? Int { model.set(key, zeroIsNil && n == 0 ? nil : .number(Double(n))) }
            })) {
            ForEach(options, id: \.0) { Text(LocalizedStringKey($0.1)).tag($0.0) }
        }
    }

    private func stepper(_ title: LocalizedStringKey, _ key: String, fallback: Double, range: ClosedRange<Double>, step: Double) -> some View {
        let value = model.root[key]?.numberValue ?? fallback
        return Stepper(value: Binding(get: { value }, set: { model.set(key, .number($0)) }), in: range, step: step) {
            LabeledContent(title, value: Format.seconds(value))
        }
    }

    private func numberRow(_ title: LocalizedStringKey, _ key: String, decimals: Int) -> some View {
        LabeledContent(title) {
            NumberText(value: model.root[key]?.numberValue) { model.set(key, $0.map(JSONValue.number)) }
        }
    }

    private func importWeights() async {
        let unit = model.settings.unit
        let samples = await Health.weights(unit: unit)
        let have = Set(BodyData.weights(model.root).map(\.day))
        let new = samples.filter { !have.contains(Day.iso($0.date)) }
        for s in new { model.logWeight(s.weight, on: Day.iso(s.date), fromHealth: true) }
        healthNote = new.isEmpty ? String(localized: "Nothing new in Health.") : new.count == 1 ? String(localized: "1 weigh-in added.") : String(localized: "\(new.count) weigh-ins added.")
    }
}

/// "Export as spreadsheet (CSV)" (openGym CsvExportSheet): a stretch of days, then the workouts
/// (one row per set) or body weight and measurements (one row per day) as a file to share.
private struct CSVExportView: View {
    @Environment(AppModel.self) private var model
    @State private var range = "all"
    @State private var from = Calendar.current.date(byAdding: .day, value: -27, to: .now) ?? .now
    @State private var to = Date.now
    @State private var files: (workouts: URL?, body: URL?) = (nil, nil)

    /// All days, or a stretch picked the way the report picks it (Report.range).
    private var bounds: (from: String?, to: String?) {
        guard range != "all" else { return (nil, nil) }
        let r = Report.range(range, from: Day.iso(from), to: Day.iso(to), today: model.today)
        return (r.from, r.to)
    }

    var body: some View {
        let (a, b) = bounds
        let n = Export.counts(model.root, catalog: model.catalog, from: a, to: b)
        Form {
            Section {
                Picker("Days", selection: $range) {
                    Text("All").tag("all")
                    Text("3 months").tag("3m")
                    Text("4 weeks").tag("4w")
                    Text("Custom").tag("custom")
                }
                .pickerStyle(.segmented)
                if range == "custom" {
                    DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
                    DatePicker("To", selection: $to, in: from...Date.now, displayedComponents: .date)
                }
            } footer: {
                Text("One row per set, for Excel, Sheets, your coach or another app.")
            }
            Section {
                if let url = files.workouts { ShareLink("Workouts (CSV)", item: url) }
            } footer: {
                Text("\(n.workouts) workouts · \(n.sets) sets")
            }
            Section {
                if let url = files.body { ShareLink("Body weight & measurements (CSV)", item: url) }
            } footer: {
                Text("\(n.weighIns) weigh-ins · \(n.measurements) measurements")
            }
        }
        .navigationTitle("Export as spreadsheet (CSV)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(a ?? "")-\(b ?? "")-\(model.root.count)") {
            files = (model.csvFile("workouts", Export.workoutsCSV(model.root, catalog: model.catalog, from: a, to: b)),
                     model.csvFile("body", Export.bodyCSV(model.root, from: a, to: b)))
        }
    }
}

/// The workout-day reminder and the missed-workout nudge (ReminderSync), kept in the synced profile
/// as openGym keeps them: `reminder = {on, time, tz, nudge, tone}`.
struct ReminderSection: View {
    @Environment(AppModel.self) private var model

    private var r: [String: JSONValue] { model.root["reminder"]?.object ?? [:] }
    private func set(_ key: String, _ v: JSONValue) {
        model.change { s in
            var r = s["reminder"]?.object ?? ["on": .bool(false), "time": .string("08:00"), "nudge": .bool(false), "tone": .string("friendly")]
            r[key] = v
            r["tz"] = .string(TimeZone.current.identifier)
            s["reminder"] = .object(r)
        }
    }
    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { Reminders.truthy(r[key]) }, set: { set(key, .bool($0)) })
    }
    private var time: Binding<Date> {
        Binding(get: {
            let p = (r["time"]?.stringValue ?? "08:00").split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(from: DateComponents(hour: p.first ?? 8, minute: p.count > 1 ? p[1] : 0)) ?? .now
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            set("time", .string(String(format: "%02d:%02d", c.hour ?? 8, c.minute ?? 0)))
        })
    }

    var body: some View {
        Section {
            Toggle("Workout day reminder", isOn: Binding(get: { Reminders.truthy(r["on"]) }, set: { on in
                set("on", .bool(on))
                if on { ReminderSync.sync(model, ask: true) }
            }))
            if Reminders.truthy(r["on"]) {
                DatePicker("Reminder time", selection: time, displayedComponents: .hourAndMinute)
                Toggle("Nudge me when I skip a planned workout", isOn: flag("nudge"))
                if Reminders.truthy(r["nudge"]) {
                    Picker("Nudge tone", selection: Binding(get: { Reminders.tone(r) }, set: { set("tone", .string($0)) })) {
                        Text("Friendly").tag("friendly")
                        Text("Guilt trip").tag("guilt")
                        Text("Drill sergeant").tag("drill")
                    }
                }
            }
            if model.root["modules"]?.object?["motivation"] != .bool(false) {
                Toggle("Your year in Hexplate", isOn: Binding(get: { Wrapped.notifyOn(model.root) }, set: { model.set("wrappedNotify", .bool($0)) }))
            }
        } footer: {
            if Reminders.truthy(r["on"]) {
                Text("Reminds you at this time on days that have a routine planned.")
                    + (Reminders.truthy(r["nudge"]) ? Text(verbatim: " ") + Text("One nudge in the evening of a planned day with nothing logged, between 20:00 and 21:30. After 3 missed days in a row it goes quiet until your next workout.") : Text(verbatim: ""))
            }
            Text("One notification on 1 December when your year is ready.")
        }
    }
}

/// MyGym: the paired openGym server (ServerSync).
struct ServerSection: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var code = ""
    @State private var busy = false

    var body: some View {
        @Bindable var sync = ServerSync.shared
        Section {
            if sync.paired {
                LabeledContent("Server", value: sync.host)
                if !sync.status.isEmpty {
                    LabeledContent("Last check") {
                        VStack(alignment: .trailing) {
                            Text(sync.status)
                            if let at = sync.lastCheck { Text(at, style: .relative).foregroundStyle(.secondary) }
                        }
                        .multilineTextAlignment(.trailing)
                    }
                }
                if sync.motionWaiting > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Motion files waiting", value: "\(sync.motionWaiting)")
                        Text("Watch recordings leave this phone once the server has saved and backed them up.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Toggle("Write sync changes", isOn: $sync.writes)
                Button("Sync now") { Task { busy = true; await sync.run(model)?.value; busy = false } }
                    .disabled(busy)
                Button("Disconnect", role: .destructive) { sync.disconnect() }
            } else {
                TextField("Server address", text: $address)
                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Pairing code", text: $code)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button("Connect") { Task { busy = true; await sync.pair(address: address, code: code, model: model); busy = false } }
                    .disabled(busy || address.isEmpty || code.isEmpty)
                if !sync.status.isEmpty { Text(sync.status).foregroundStyle(.secondary) }
            }
        } footer: {
            if sync.paired {
                Text("Off: a sync only works out what it would change and writes it to sync-log.txt. Watch motion files are sent either way.")
            } else {
                Text("On the computer, open openGym, then Settings → Pair the mobile app, and enter the code it shows.")
            }
        }
    }
}

/// A number typed in place; empty clears it.
private struct NumberText: View {
    let value: Double?
    let commit: (Double?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("–", text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onAppear { text = value.map { Format.number($0) } ?? "" }
            .onChange(of: focused) {
                guard !focused else { return }
                let v = Double(text.replacingOccurrences(of: ",", with: "."))
                if v != value { commit(v) }
            }
    }
}

/// Which plates go on each side of the bar.
struct PlateCalculator: View {
    @Environment(AppModel.self) private var model
    @State private var target = ""
    @State private var bar: Double = 20

    var body: some View {
        let unit = model.settings.unit
        let total = Double(target.replacingOccurrences(of: ",", with: ".")) ?? 0
        let perSide = max(0, (total - bar) / 2)
        let inv = Plates.inventory(model.root)
        let result = Plates.stack(perSide, inv)
        Form {
            Section {
                LabeledContent("Weight (\(unit))") {
                    TextField("–", text: $target).keyboardType(.decimalPad).multilineTextAlignment(.trailing).font(.title3.monospacedDigit())
                }
                Picker("Bar", selection: $bar) {
                    // Your barbell first (Equipment → Your bars), then the usual others.
                    ForEach(Array(Set([Equipment.barWeight(model.root, "barbell")] + (unit == "lb" ? [45.0, 35, 0] : [20.0, 15, 10, 0]))).sorted(by: >), id: \.self) {
                        Text($0 == 0 ? "No bar" : "\(Format.number($0)) \(unit)").tag($0)
                    }
                }
            }
            if total > 0 {
                Section {
                    if result.plates.isEmpty {
                        Text(total <= bar ? "Just the bar." : "No plates fit.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(Dictionary(grouping: result.plates, by: { $0 }).sorted { $0.key > $1.key }), id: \.key) { w, list in
                            LabeledContent("\(Format.number(w, decimals: 2)) \(unit)", value: "× \(list.count)")
                        }
                    }
                    if result.missing > 0.001 {
                        Text("\(Format.number(result.missing * 2, decimals: 2)) \(unit) short with your plates.").foregroundStyle(.orange)
                    }
                } header: {
                    Text("Each side")
                }
            }
        }
        .keyboardDone()
        .navigationTitle("Plate calculator")
        .onAppear { bar = Equipment.barWeight(model.root, "barbell") }
    }
}
