import HealthKit
import HexplateCore
import SwiftUI

extension AppModel {
    /// Sets one top-level setting; nil removes it.
    func set(_ key: String, _ value: JSONValue?) { change { $0[key] = value } }

    /// The state file as it is, for "Export JSON".
    var stateFileURL: URL { URL.applicationSupportDirectory.appending(path: "Hexplate/state.json") }

    func csvFile() -> URL? {
        let url = URL.temporaryDirectory.appending(path: "hexplate-workouts-\(today).csv")
        do {
            try Export.workoutsCSV(root, catalog: catalog).write(to: url, atomically: true, encoding: .utf8)
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
    @State private var importing = false
    @State private var csv: URL?
    @State private var healthNote: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Units") {
                    picker("Weight", "unit", ["kg": "kg", "lb": "lb"], fallback: "kg")
                    picker("Weight decimals", "wdec", [1: "1", 2: "2"], fallback: 1)
                    picker("Week starts", "weekStart", [1: "Monday", 0: "Sunday"], fallback: 1)
                }

                Section {
                    picker("Progression", "progDefault", ["linear": "Linear", "double": "Double", "greyskull": "Greyskull LP", "off": "Off"], fallback: "linear")
                    picker("Start sets from", "startFrom", ["plan": "The plan", "last": "Last time"], fallback: "plan")
                    picker("Last time from", "lastFrom", ["routine": "Same routine", "any": "Any routine"], fallback: "routine")
                    picker("One-rep max", "oneRmFormula", Stats.formulaNames, fallback: "epley")
                    picker("Effort", "effort", ["none": "Off", "rir": "Reps in reserve", "rpe": "RPE"], fallback: "none")
                    picker("Warm-up sets", "warmupAuto", ["off": "Off", "compounds": "Compound lifts", "all": "All lifts"], fallback: "off")
                    picker("Exercise animations", "gifSize", ["full": "Full", "mini": "Small", "off": "Off"], fallback: "full")
                } header: {
                    Text("Training")
                }

                Section {
                    stepper("Rest", "restSec", fallback: 90, range: 0...600, step: 15)
                    stepper("Rest-pause", "restPauseSec", fallback: 15, range: 5...120, step: 5)
                    toggle("Sound", "sound", fallback: true)
                    toggle("Flash the screen", "timerFlash", fallback: false)
                } header: {
                    Text("Rest timer")
                } footer: {
                    Text("A notification also tells you when rest is over while Hexplate is in the background.")
                }

                Section {
                    picker("Sex", "sex", ["": "Not set", "male": "Male", "female": "Female"], fallback: "")
                    numberRow("Birth year", "birthYear", decimals: 0)
                    numberRow("Goal weight (\(model.settings.unit))", "targetW", decimals: 1)
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Sex and age set the strength level standards.")
                }

                Section("Tools") {
                    NavigationLink("Plate calculator") { PlateCalculator() }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }

                Section {
                    Toggle("Apple Health", isOn: $health)
                        .onChange(of: health) {
                            guard health else { return }
                            Task { if !(await Health.authorise()) { health = false; healthNote = "Apple Health is not available." } }
                        }
                    if health {
                        Button("Import weights from Health") { Task { await importWeights() } }
                    }
                    if let healthNote { Text(healthNote).foregroundStyle(.secondary) }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Weigh-ins and finished workouts are written to Health.")
                }

                Section {
                    ShareLink("Export JSON", item: model.stateFileURL)
                    if let csv {
                        ShareLink("Export CSV", item: csv)
                    }
                    Button("Import", systemImage: "square.and.arrow.down") { importing = true }
                } header: {
                    Text("Data")
                } footer: {
                    Text("JSON is the openGym format and holds everything. A copy is also kept automatically once a day (the last seven days).")
                }
            }
            .keyboardDone()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.fontWeight(.semibold) }
            .sheet(isPresented: $importing) { ImportView() }
            .onAppear { csv = model.csvFile() }
        }
    }

    // MARK: Rows bound to the document

    private func picker<T: Hashable>(_ title: String, _ key: String, _ options: [T: String], fallback: T) -> some View {
        Picker(title, selection: Binding<T>(
            get: {
                let v = model.root[key]
                if let s = v?.stringValue as? T, options[s] != nil { return s }
                if let n = v?.numberValue.map(Int.init) as? T, options[n] != nil { return n }
                return fallback
            },
            set: { value in
                if let s = value as? String { model.set(key, s.isEmpty ? nil : .string(s)) }
                if let n = value as? Int { model.set(key, .number(Double(n))) }
            })) {
            ForEach(options.sorted { $0.value < $1.value }, id: \.key) { Text($0.value).tag($0.key) }
        }
    }

    private func toggle(_ title: String, _ key: String, fallback: Bool) -> some View {
        Toggle(title, isOn: Binding(get: { model.root[key].map { $0 == .bool(true) } ?? fallback }, set: { model.set(key, .bool($0)) }))
    }

    private func stepper(_ title: String, _ key: String, fallback: Double, range: ClosedRange<Double>, step: Double) -> some View {
        let value = model.root[key]?.numberValue ?? fallback
        return Stepper(value: Binding(get: { value }, set: { model.set(key, .number($0)) }), in: range, step: step) {
            LabeledContent(title, value: Format.seconds(value))
        }
    }

    private func numberRow(_ title: String, _ key: String, decimals: Int) -> some View {
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
        healthNote = new.isEmpty ? "Nothing new in Health." : "\(new.count) \(new.count == 1 ? "weigh-in" : "weigh-ins") added."
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
private struct PlateCalculator: View {
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
                    ForEach(unit == "lb" ? [45.0, 35, 0] : [20.0, 15, 10, 0], id: \.self) { Text($0 == 0 ? "No bar" : "\(Format.number($0)) \(unit)").tag($0) }
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
        .onAppear { bar = unit == "lb" ? 45 : 20 }
    }
}
