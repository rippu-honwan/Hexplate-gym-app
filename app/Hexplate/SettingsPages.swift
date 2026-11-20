import HexplateCore
import SwiftUI
import UserNotifications

/* The Settings pages with more than a few rows (openGym views/Settings.jsx, sheets.jsx,
   components/WeeklySets.jsx): modules, timer alerts, equipment, weekly sets per muscle and
   Look & Home. Every choice is stored in the profile under openGym's key, unless noted. */

/// A switch bound to a profile key. `fallback` is what an absent key means (openGym's `!== false`
/// is true, `=== true` is false).
struct ProfileToggle: View {
    @Environment(AppModel.self) private var model
    let title: LocalizedStringKey
    let key: String
    var fallback = false
    var subtitle: LocalizedStringKey?

    var body: some View {
        Toggle(isOn: Binding(get: { model.root[key].map { $0 == .bool(true) } ?? fallback }, set: { model.set(key, .bool($0)) })) {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
    }
}

// MARK: - Modules

struct ModulesPage: View {
    @Environment(AppModel.self) private var model

    static let info: [String: (title: LocalizedStringKey, about: LocalizedStringKey, icon: String)] = [
        "effort": ("Effort", "Rate each set in RIR or RPE, and see in Stats how hard you really push.", "gauge.with.dots.needle.67percent"),
        "plates": ("Plates and warm-ups", "The plates to load under every set, and warm-ups that build themselves.", "circle.circle"),
        "strength": ("Strength levels", "Beginner to Elite for your main lifts, measured against your body weight.", "medal"),
        "body": ("Body", "Weigh-ins, measurements, progress photos and your weight goal.", "scalemass"),
        "health": ("Health", "Apple Health, heart rate and recovery tips.", "heart"),
        "motivation": ("Motivation", "Streaks, challenges, badges, recaps and your year in Hexplate.", "flame"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Modules.ids, id: \.self) { id in
                    let m = Self.info[id]!
                    Toggle(isOn: Binding(get: { Modules.isOn(model.root, id) }, set: { on in model.change { Modules.set(&$0, id, on) } })) {
                        Label { Text(m.title); Text(m.about) } icon: { Image(systemName: m.icon) }
                    }
                }
            } footer: {
                Text("Off hides a part of the app. Nothing is deleted: switched back on, it is all there.")
            }
        }
        .navigationTitle("Modules")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Timer alerts

struct AlertsPage: View {
    @Environment(AppModel.self) private var model

    private var alerts: RestTimer.Alerts { .init(model.root) }

    var body: some View {
        Form {
            Section {
                ProfileToggle(title: "Play a sound", key: "sound", fallback: true)
                if alerts.sound {
                    Picker("Sound", selection: Binding(get: { alerts.kind }, set: { id in
                        model.change { $0["restSound"] = .string(id); $0["classicChime"] = .bool(id == "classic") }
                        AlertAudio.tone(id, onSilent: true)
                    })) {
                        ForEach(AlertAudio.sounds, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    ProfileToggle(title: "Play even on silent", key: "soundOnSilent", subtitle: "The sound plays even with the ring switch off. Music only turns down for it.")
                }
            } header: {
                Text("When a rest ends")
            } footer: {
                Text("A notification also tells you when rest is over while Hexplate is in the background.")
            }
            Section {
                ProfileToggle(title: "Vibrate", key: "vibrate", fallback: true)
                ProfileToggle(title: "Flash the screen", key: "timerFlash")
            }
            Section {
                ProfileToggle(title: "Spoken cues", key: "spokenCues", subtitle: "Says your next set, “10 seconds” and “Rest is over”, and counts holds down.")
                if alerts.speak {
                    Picker("Speaking rate", selection: Binding(get: { model.root["speechRate"]?.stringValue ?? "normal" }, set: { model.set("speechRate", .string($0)) })) {
                        Text("Slow").tag("slow")
                        Text("Normal").tag("normal")
                        Text("Fast").tag("fast")
                    }
                    .pickerStyle(.segmented)
                    Button("Try it", systemImage: "play.fill") {
                        let unit = model.settings.unit
                        AlertAudio.say(tr("Set {0}", 1) + ", " + WrappedCards.plural(unit == "lb" ? "{0} pound" : "{0} kilo", unit == "lb" ? "{0} pounds" : "{0} kilos", 60, "60")
                                       + ", " + WrappedCards.plural("{0} rep", "{0} reps", 8, 8), rate: alerts.rate, onSilent: alerts.onSilent, flush: true)
                    }
                }
            } footer: {
                Text("Only while the app is on screen. Music turns down for a moment, it never stops.")
            }
        }
        .navigationTitle("Timer alerts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Equipment

struct EquipmentPage: View {
    @Environment(AppModel.self) private var model
    @State private var removing: [String: JSONValue]?

    var body: some View {
        let gyms = Gyms.all(model.root), gym = Gyms.active(model.root)
        Form {
            if !gyms.isEmpty {
                Section {
                    Picker("Active gym", selection: Binding(get: { gyms.firstIndex { $0["id"] == gym?["id"] } ?? -1 }, set: { i in
                        guard gyms.indices.contains(i), let id = gyms[i]["id"] else { return }
                        let now = model.now
                        model.change { Gyms.switchTo(&$0, id, now: now) }
                    })) {
                        if gym == nil { Text("Pick a gym").tag(-1) }
                        ForEach(gyms.indices, id: \.self) { i in Text(verbatim: Gyms.label(gyms[i])).tag(i) }
                    }
                } header: {
                    Text("Your gym")
                } footer: {
                    Text("Plates, dumbbells and bars are kept per gym. Switch gyms and all of it switches.")
                }
            }
            Section {
                NavigationLink { PlatesEditor() } label: {
                    LabeledContent("Plates", value: Equipment.ownsPlates(model.root) ? String(localized: "Your own") : String(localized: "Standard set"))
                }
                NavigationLink { DumbbellsEditor() } label: {
                    LabeledContent("Dumbbells", value: Equipment.ownsNoDumbbells(model.root) ? String(localized: "None")
                                   : Equipment.dumbbells(model.root).isEmpty ? String(localized: "Any weight") : tr("{0} weights", Equipment.dumbbells(model.root).count))
                }
                NavigationLink("Your bars") { BarsEditor() }
            } header: {
                if let gym { Text("Equipment at \(Gyms.label(gym))") }
            } footer: {
                Text("What your gym has. Warm-ups and the plate calculator load from it.")
            }
            Section {
                if !gyms.isEmpty {
                    ProfileToggle(title: "Filter by equipment", key: "equipFilterOn",
                                  subtitle: "The exercise library and picker show only what the active gym can do.")
                }
                ForEach(gyms.indices, id: \.self) { i in
                    NavigationLink { GymEditor(id: gyms[i]["id"]) } label: {
                        LabeledContent(Gyms.label(gyms[i]), value: tr("{0} equipment types", ExerciseCatalog.equipment(of: gyms[i]).count))
                    }
                    .swipeActions { Button("Delete", role: .destructive) { removing = gyms[i] } }
                }
                NavigationLink { GymEditor(id: nil) } label: { Label("Add a gym", systemImage: "plus") }
            } header: {
                Text("Gyms")
            } footer: {
                if gyms.isEmpty { Text("Train in more than one place? Add a gym for each, and each keeps its own plates, dumbbells and bars.") }
            }
            Section {
                NavigationLink("Plate calculator") { PlateCalculator().navigationTitle("Plate calculator").navigationBarTitleDisplayMode(.inline) }
            }
        }
        .navigationTitle("Equipment")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this gym?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = removing?["id"] { let now = model.now; model.change { Gyms.remove(&$0, id, now: now) } }
                removing = nil
            }
        } message: {
            Text("\(Gyms.label(removing)) and its equipment lists will be removed.")
        }
    }
}

/// A gym's name and what it has (openGym EquipmentProfileSheet). A new one starts with the plates,
/// dumbbells and bars set now.
private struct GymEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: JSONValue?
    @State private var name = ""
    @State private var have: Set<String> = []
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Name, like Home or Gym", text: $name)
            } footer: {
                Text(id == nil ? "It starts with the plates, dumbbells and bars you have set now. Change them once it is the active gym."
                     : "Name it after where you train, then tick what you have there.")
            }
            Section {
                ForEach(model.catalog.meta.equipment, id: \.self) { eq in
                    Button { if have.contains(eq) { have.remove(eq) } else { have.insert(eq) } } label: {
                        HStack {
                            Text(verbatim: Format.capWords(tr(eq)))
                            Spacer()
                            if have.contains(eq) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Equipment")
            } footer: {
                Text("Body-weight exercises are always available, unless they need a pull-up bar or a bench.")
            }
        }
        .navigationTitle(id == nil ? "Add a gym" : "Edit gym")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Save") {
                let n = name.trimmingCharacters(in: .whitespaces), eq = model.catalog.meta.equipment.filter(have.contains), now = model.now
                model.change { s in
                    if let id { Gyms.edit(&s, id, name: n, equipment: eq) } else { Gyms.add(&s, name: n, equipment: eq, now: now) }
                }
                dismiss()
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let p = Gyms.all(model.root).first { $0["id"] == id }
            name = p?["name"]?.stringValue ?? ""
            have = Set(p.map { ExerciseCatalog.equipment(of: $0) } ?? [])
        }
    }
}

private struct PlatesEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let unit = model.settings.unit
        let have = Dictionary(Plates.inventory(model.root).map { (Format.number($0.w, decimals: 2), $0.n) }, uniquingKeysWith: { a, _ in a })
        Form {
            Section {
                ForEach(Equipment.plateSizes[unit] ?? [], id: \.self) { w in
                    let n = have[Format.number(w, decimals: 2)] ?? 0
                    Stepper(value: Binding(get: { n }, set: { v in let now = model.now; model.change { Equipment.settingPlates(&$0, w, v, now: now) } }), in: 0...20) {
                        LabeledContent("\(Format.number(w, decimals: 2)) \(unit)", value: tr(n == 1 ? "{0} pair" : "{0} pairs", n))
                    }
                }
            } footer: {
                Text("Pairs of each plate. Without a list of your own, a standard rack of six pairs is assumed.")
            }
            if Equipment.ownsPlates(model.root) {
                Section {
                    Button("Back to the standard set", systemImage: "arrow.counterclockwise") { let now = model.now; model.change { Equipment.standardPlates(&$0, now: now) } }
                }
            }
        }
        .navigationTitle("Plates")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DumbbellsEditor: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        let unit = model.settings.unit
        let list = Equipment.dumbbells(model.root)
        let save = { (ws: [Double]) in let now = model.now; model.change { Equipment.settingDumbbells(&$0, ws, now: now) } }
        Form {
            Section {
                Toggle(isOn: Binding(get: { Equipment.ownsNoDumbbells(model.root) }, set: { on in let now = model.now; model.change { Equipment.settingNoDumbbells(&$0, on, now: now) } })) {
                    Text("I own no dumbbells")
                    Text("Dumbbell lifts stay out of the library and the picker.")
                }
            }
            if !Equipment.ownsNoDumbbells(model.root) {
                Section {
                    if list.isEmpty { Text("No list yet, so dumbbell lifts step by their increment as usual.").foregroundStyle(.secondary) }
                    ForEach(list, id: \.self) { w in Text(verbatim: "\(Format.number(w, decimals: 2)) \(unit)") }
                        .onDelete { idx in save(list.enumerated().filter { !idx.contains($0.offset) }.map(\.element)) }
                    HStack {
                        TextField(tr("Weight ({0})", unit), text: $draft).keyboardType(.decimalPad)
                        Button("Add") {
                            if let w = Double(draft.replacingOccurrences(of: ",", with: ".")), w > 0 { save(list + [w]); draft = "" }
                        }
                    }
                } footer: {
                    Text("The weights you own, one bell each.")
                }
                Section {
                    let preset = Equipment.dumbbellPreset(model.root)
                    Button(tr("Fill in {0} to {1} {2}, every {3}", Format.number(preset[0]), Format.number(preset.last!), unit, Format.number(preset[1] - preset[0]))) { save(preset) }
                    if !list.isEmpty { Button("Clear the list", role: .destructive) { save([]) } }
                }
            }
        }
        .keyboardDismissal()
        .navigationTitle("Dumbbells")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BarsEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let unit = model.settings.unit
        Form {
            Section {
                ForEach(Equipment.barTypes, id: \.self) { eq in
                    let w = Equipment.barWeight(model.root, eq)
                    Stepper(value: Binding(get: { w }, set: { v in model.change { Equipment.settingBar(&$0, eq, v) } }), in: 0...100, step: unit == "lb" ? 5 : 2.5) {
                        LabeledContent(Format.capWords(tr(eq)), value: "\(Format.number(w)) \(unit)")
                    }
                }
            } footer: {
                Text("What the bars at your gym weigh. Every exercise with that bar counts plates from it, unless you gave the exercise its own. Logged weights stay totals.")
            }
            if model.root["barDefaults"]?.object?[unit] != nil {
                Section {
                    Button("Back to the standard bars", systemImage: "arrow.counterclockwise") {
                        model.change { s in for eq in Equipment.barTypes { Equipment.settingBar(&s, eq, 0) } }
                    }
                }
            }
        }
        .navigationTitle("Your bars")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Weekly sets per muscle

struct MuscleTargetsEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let own = model.root["muscleTargets"]?.object ?? [:]
        Form {
            Section {
                ForEach(Stats.defaultTargets, id: \.slug) { slug, def in
                    let range = own[slug]?.arrayValue?.compactMap(\.numberValue) ?? def
                    let lo = range.first ?? def[0], hi = range.count > 1 ? range[1] : def[1]
                    VStack(alignment: .leading) {
                        Text(LocalizedStringKey(model.catalog.muscleName(slug))).font(.headline)
                        Stepper(value: Binding(get: { lo }, set: { set(slug, [$0, hi], def) }), in: 0...40) { LabeledContent("Low end", value: "\(Int(lo))") }
                        Stepper(value: Binding(get: { hi }, set: { set(slug, [lo, $0], def) }), in: 0...40) { LabeledContent("High end", value: "\(Int(hi))") }
                    }
                }
            } footer: {
                Text("Starting points from hypertrophy research: below the low end is room for more, past the high end extra sets stop paying.")
            }
            if !own.isEmpty {
                Section { Button("Back to the defaults", systemImage: "arrow.counterclockwise") { model.set("muscleTargets", nil) } }
            }
        }
        .navigationTitle("Weekly sets per muscle")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// muscle-targets.js withTarget: kept in order, dropped again when it is the default.
    private func set(_ slug: String, _ range: [Double], _ def: [Double]) {
        var r = range.map { max(0, min(40, $0.rounded())) }
        if r[1] < r[0] { r.swapAt(0, 1) }
        model.change { s in
            var all = s["muscleTargets"]?.object ?? [:]
            all[slug] = r == def ? nil : .array(r.map { .number($0) })
            s["muscleTargets"] = all.isEmpty ? nil : .object(all)
        }
    }
}

// MARK: - Look & Home

struct LookPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(Theme.accentKey) private var accent = Theme.accentId
    @State private var icon = UIApplication.shared.alternateIconName

    static let icons: [(id: String?, name: LocalizedStringResource, preview: String)] = [
        (nil, "Original", "IconPreview-Original"), ("AppIcon-Light", "Light", "IconPreview-Light"), ("AppIcon-Mono", "Mono", "IconPreview-Mono"),
        ("AppIcon-Blue", "Blue", "IconPreview-Blue"), ("AppIcon-Orange", "Orange", "IconPreview-Orange"),
        ("AppIcon-Pink", "Pink", "IconPreview-Pink"), ("AppIcon-Purple", "Purple", "IconPreview-Purple"),
    ]

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 14) {
                    ForEach(Theme.accents, id: \.id) { a in
                        Button { accent = a.id } label: {
                            Circle().fill(Theme.rgb(a.rgb)).frame(width: 40, height: 40)
                                .overlay { if accent == a.id { Image(systemName: "checkmark").font(.headline).foregroundStyle(.black) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(a.name))
                        .accessibilityAddTraits(accent == a.id ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Accent color")
            } footer: {
                Text(accent != Theme.accentId ? "Close Hexplate and open it again to see the new colour." : "Just for this phone.")
            }
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Self.icons, id: \.preview) { v in
                            Button {
                                UIApplication.shared.setAlternateIconName(v.id) { _ in icon = UIApplication.shared.alternateIconName }
                            } label: {
                                VStack(spacing: 6) {
                                    Image(v.preview).resizable().frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 14))
                                        .overlay { RoundedRectangle(cornerRadius: 14).stroke(icon == v.id ? Theme.accent : .clear, lineWidth: 3) }
                                    Text(v.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(icon == v.id ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                Text("App icon")
            } footer: {
                Text("Just for this phone.")
            }
            Section {
                if Modules.isOn(model.root, "body") {
                    ProfileToggle(title: "Body weight", key: "showWeightCard", fallback: true, subtitle: "Your latest weigh-in and a quick way to log today’s.")
                }
                if Modules.isOn(model.root, "health") {
                    ProfileToggle(title: "Recovery tips", key: "recoveryHint", fallback: true, subtitle: "Which muscles are still recovering and what to train instead.")
                }
                ProfileToggle(title: "Weekly sets on Home", key: "homeMuscleSets", subtitle: "Sets per muscle this week, against the range each aims for.")
                if Modules.isOn(model.root, "motivation") {
                    ProfileToggle(title: "Monthly challenges", key: "monthlyChallenges", fallback: true)
                }
            } header: {
                Text("On Home")
            }
        }
        .navigationTitle("Look & Home")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings → Reminders → Send test notification: one in five seconds, the app closed or not.
func sendTestNotification() {
    Task {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Workout day")
        content.body = String(localized: "This is how your reminders will look.")
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "test-notification", content: content,
                                                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
    }
}
