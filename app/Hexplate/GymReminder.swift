import CoreLocation
import HexplateCore
import SwiftUI
import UserNotifications

/* Gym reminder (openGym lib/gym-reminder.js, ios/App/App/GymReminderPlugin.swift): a nudge when
   you walk into your gym, so you never forget to hit Start. The phone watches the places itself
   (region monitoring), so it works with the app closed. The places stay on this phone, never in
   the synced profile. No-nag rules (skipReason): once a day, not after a workout today, not on an
   excused day, not while a session runs. */

@MainActor @Observable
final class GymReminder: NSObject, CLLocationManagerDelegate {
    static let shared = GymReminder()

    struct Gym: Codable, Identifiable, Equatable {
        var id = UUID().uuidString
        var name: String
        var lat: Double, lng: Double
        var radius: Double
    }

    /// Small, medium and large (RADIUS_PRESETS).
    static let radii: [(m: Double, name: LocalizedStringResource)] = [(75, "Small"), (120, "Medium"), (200, "Large")]
    private static let storeKey = "gymReminder", statusKey = "gymReminderStatus", firedKey = "gymReminderFired"
    nonisolated private static let regionPrefix = "gym-"
    static let notificationId = "gym-reminder"

    private(set) var on = false
    private(set) var gyms: [Gym] = []
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var locating = false
    private let manager = CLLocationManager()
    private var fix: ((CLLocation?) -> Void)?

    private override init() {
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode(Store.self, from: data) {
            on = saved.on
            gyms = saved.gyms
        }
    }

    private struct Store: Codable { var on: Bool; var gyms: [Gym] }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(Store(on: on, gyms: gyms)), forKey: Self.storeKey)
        register()
    }

    func setOn(_ value: Bool) {
        on = value
        if value { askAlways() }
        save()
    }

    func add(_ gym: Gym) { gyms.append(gym); save() }
    func update(_ gym: Gym) { if let i = gyms.firstIndex(where: { $0.id == gym.id }) { gyms[i] = gym; save() } }
    func remove(_ id: String) { gyms.removeAll { $0.id == id }; save() }

    /// Where the phone is now, for "Add this place".
    func locate(_ done: @escaping (CLLocation?) -> Void) {
        fix = done
        locating = true
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestLocation()
    }

    /// Region monitoring with the app closed needs Always.
    func askAlways() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// The regions the phone watches: every gym while the reminder is on (iOS allows 20).
    func register() {
        let want: [CLCircularRegion] = on && CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) ? gyms.prefix(20).map { g in
            let r = CLCircularRegion(center: CLLocationCoordinate2D(latitude: g.lat, longitude: g.lng),
                                     radius: min(g.radius, manager.maximumRegionMonitoringDistance), identifier: Self.regionPrefix + g.id)
            r.notifyOnEntry = true
            r.notifyOnExit = false
            return r
        } : []
        for r in manager.monitoredRegions where r.identifier.hasPrefix(Self.regionPrefix) && !want.contains(where: { $0.identifier == r.identifier }) {
            manager.stopMonitoring(for: r)
        }
        for r in want where !manager.monitoredRegions.contains(where: { $0.identifier == r.identifier }) {
            manager.startMonitoring(for: r)
        }
    }

    // MARK: What the rules need, kept current while the app runs (statusOf)

    struct Status: Codable { var trainedOn = "", quietOn = "", activeSince = 0.0 }

    static func remember(_ s: [String: JSONValue], today: String) {
        var st = Status()
        st.trainedOn = Schedule.workouts(s).compactMap { $0["d"]?.stringValue }.max() ?? ""
        st.quietOn = Reminders.excused(s, today) ? today : ""
        if let a = s["active"]?.object, a["editingWorkoutId"] == nil, a["backfill"] == nil, let start = a["start"]?.numberValue, start > 0 {
            st.activeSince = start
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(st), forKey: statusKey)
    }

    /// Why arriving now would not notify, or nil when it should (skipReason, without the time window).
    static func skipReason(now: Date) -> String? {
        let today = Day.iso(now)
        if UserDefaults.standard.string(forKey: firedKey) == today { return "fired" }
        let st = UserDefaults.standard.data(forKey: statusKey).flatMap { try? JSONDecoder().decode(Status.self, from: $0) } ?? Status()
        if st.trainedOn == today { return "trained" }
        if st.quietOn == today { return "quiet" }
        if st.activeSince > 0 && now.timeIntervalSince1970 * 1000 - st.activeSince < 12 * 3600 * 1000 { return "active" }
        return nil
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier.hasPrefix(Self.regionPrefix) else { return }
        Task { @MainActor in
            let now = Date()
            guard self.on, Self.skipReason(now: now) == nil else { return }
            UserDefaults.standard.set(Day.iso(now), forKey: Self.firedKey)
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Gym spotted")
            content.body = String(localized: "Ready for your workout? 💪")
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationId, content: content, trigger: nil))
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            // Asked for while in use first; Always is the second question.
            if self.on && status == .authorizedWhenInUse { self.manager.requestAlwaysAuthorization() }
            self.register()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.locating = false; self.fix?(last); self.fix = nil }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.locating = false; self.fix?(nil); self.fix = nil }
    }
}

/// Settings → Reminders → Gym reminder.
struct GymReminderPage: View {
    @Environment(AppModel.self) private var model
    @State private var reminder = GymReminder.shared
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                Toggle("Gym reminder", isOn: Binding(get: { reminder.on }, set: { reminder.setOn($0) }))
            } footer: {
                Text("A nudge when you walk into your gym. At most once a day, and not after you trained or while a workout runs. Your gyms stay on this phone.")
            }
            Section {
                ForEach(reminder.gyms) { gym in
                    GymRow(gym: gym)
                }
                .onDelete { $0.map { reminder.gyms[$0].id }.forEach(reminder.remove) }
                Button(reminder.locating ? "Finding you…" : "Add the place I’m at now", systemImage: "location.fill") {
                    reminder.locate { loc in
                        guard let loc else { failed = true; return }
                        reminder.add(.init(name: String(localized: "My gym"), lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, radius: 120))
                    }
                }
                .disabled(reminder.locating || reminder.gyms.count >= 20)
            } header: {
                Text("Your gyms")
            } footer: {
                if failed { Text("Your location could not be found. Check that Hexplate may use it in the iPhone’s Settings.") }
            }
            if reminder.on && reminder.authorization != .authorizedAlways {
                Section {
                    Button("Allow location “Always”", systemImage: "gear") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } footer: {
                    Text("To notice your gym with the app closed, Hexplate needs location access set to Always.")
                }
            }
        }
        .navigationTitle("Gym reminder")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GymRow: View {
    let gym: GymReminder.Gym
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $name)
                .onAppear { name = gym.name }
                .onSubmit { var g = gym; g.name = name; GymReminder.shared.update(g) }
            Picker("Size", selection: Binding(get: { gym.radius }, set: { var g = gym; g.radius = $0; GymReminder.shared.update(g) })) {
                ForEach(GymReminder.radii, id: \.m) { Text($0.name).tag($0.m) }
                if !GymReminder.radii.contains(where: { $0.m == gym.radius }) { Text(verbatim: "\(Int(gym.radius)) m").tag(gym.radius) }
            }
            .pickerStyle(.segmented)
        }
    }
}
