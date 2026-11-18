import HexplateCore
import SwiftUI
import HealthKit
import OSLog
import WatchConnectivity

/// The phone's end of the Apple Watch link (was frontend/ios/App/App/WatchBridgePlugin.swift).
///
/// Phone → watch: the snapshot (HexplateCore WatchLink.snapshot) as the application context, and as
/// a message too when the watch is reachable. Watch → phone: events sent with transferUserInfo.
/// Each is written to a file before the delegate returns (iOS may suspend the app right after),
/// then applied once by its id.
///
/// ponytail: exercise animations are not sent yet.
final class WatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchBridge()
    private let log = Logger(subsystem: "com.rippuhonwan.mygym", category: "watch")

    private let queue = DispatchQueue(label: "hexplate.watch-events")
    private var lastSent: String?
    @MainActor private weak var model: AppModel?
    @MainActor private weak var timer: RestTimer?

    private static var eventsFile: URL { URL.applicationSupportDirectory.appending(path: "Hexplate/watch-events.json") }
    private static let appliedKey = "watchApplied"
    private static let activeKey = "watchActiveId", activeAtKey = "watchActiveAt"

    @MainActor
    func start(model: AppModel, timer: RestTimer) {
        self.model = model
        self.timer = timer
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: Phone → watch

    @MainActor
    func send() {
        let wc = WCSession.default
        guard WCSession.isSupported(), let model else { return }
        guard wc.activationState == .activated, wc.isPaired, wc.isWatchAppInstalled else {
            note("send skipped: activated \(wc.activationState == .activated) paired \(wc.isPaired) installed \(wc.isWatchAppInstalled)")
            return
        }
        let ends = timer?.end.flatMap { timer?.kind == .rest ? $0.timeIntervalSince1970 * 1000 : nil }
        // The phone's Start set, for a minute (the watch acts on it once).
        let fresh = { (x: AppModel.WatchSet?) -> [String: JSONValue]? in
            x.flatMap { model.now - $0.at < 60_000 ? $0 : nil }
                .map { ["entryIdx": .number(Double($0.entryIdx)), "setIdx": .number(Double($0.setIdx)), "at": .number($0.at)] }
        }
        let snap = WatchLink.snapshot(model.root, today: model.today, restEndsAt: ends, health: UserDefaults.standard.bool(forKey: "health"),
                                      lang: "zh-TW", startSet: fresh(model.watchStart), doneSet: fresh(model.watchDone), catalog: model.catalog)
        guard let data = try? JSONEncoder().encode(JSONValue.object(snap)), let json = String(data: data, encoding: .utf8), json != lastSent else { return }
        let a = snap["active"]?.object
        let done = (a?["entries"]?.arrayValue ?? []).reduce(0) { $0 + ($1.object?["sets"]?.arrayValue ?? []).filter { $0.object?["done"] == .bool(true) }.count }
        let what = a.map { "w=\($0["id"]?.stringValue ?? "-") done=\(done)" } ?? "no workout"
        let d = UserDefaults.standard
        d.set(model.active?["id"]?.stringValue, forKey: Self.activeKey)
        d.set(model.now, forKey: Self.activeAtKey)
        let payload: [String: Any] = ["snapshot": json, "at": Date().timeIntervalSince1970]
        do {
            try wc.updateApplicationContext(payload)
            lastSent = json
        } catch {
            note("snap -> \(what) failed: \(error.localizedDescription) (\(json.utf8.count) bytes)")
            return
        }
        note("snap -> \(what) reachable=\(wc.isReachable) app=\(UIApplication.shared.applicationState == .active ? "open" : "background")")
        if wc.isReachable {
            // @Sendable: WatchConnectivity calls this on its own queue; a main-actor closure traps there.
            wc.sendMessage(payload, replyHandler: nil) { @Sendable [weak self] error in self?.note("snap message failed: \(error.localizedDescription)") }
        }
    }

    // MARK: The link's own log

    /// Last 500 lines of what went between phone and watch (Application Support/Hexplate/watch-link.log),
    /// the phone's half of the watch's watchlog: when a snapshot went out or why not, each event that came in.
    private static var linkLog: URL { URL.applicationSupportDirectory.appending(path: "Hexplate/watch-link.log") }
    private nonisolated func note(_ line: String) {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"
        let stamped = "\(f.string(from: Date())) \(line)"
        log.info("\(stamped, privacy: .public)")
        queue.async {
            let old = (try? String(contentsOf: Self.linkLog, encoding: .utf8))?.split(separator: "\n").suffix(499).map(String.init) ?? []
            try? (old + [stamped]).joined(separator: "\n").appending("\n").write(to: Self.linkLog, atomically: true, encoding: .utf8)
        }
    }

    /// A workout started on the phone opens the watch app (HealthKit launches it with a workout
    /// configuration; Watch/OpenGymWatchApp.swift handle(_:)). Needs leave to share workouts with
    /// Health, asked for here the first time.
    @MainActor
    func openOnWatch() {
        let wc = WCSession.default
        guard WCSession.isSupported(), wc.activationState == .activated, wc.isPaired, wc.isWatchAppInstalled, Health.available else {
            note("watch app not opened: activated \(wc.activationState == .activated) paired \(wc.isPaired) installed \(wc.isWatchAppInstalled) health \(Health.available)")
            return
        }
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        Task {
            try? await Health.store.requestAuthorization(toShare: [.workoutType()], read: [])
            note("open on watch: share workouts \(Health.store.authorizationStatus(for: .workoutType()) == .sharingAuthorized ? "allowed" : "not allowed")")
            do {
                try await Health.store.startWatchApp(toHandle: config)
                note("open on watch: asked")
            } catch {
                note("watch app not opened: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Watch → phone

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let json = userInfo["event"] as? String, let data = json.data(using: .utf8),
              let ev = try? JSONDecoder().decode(JSONValue.self, from: data), ev.object?["id"]?.stringValue != nil else { return }
        queue.sync {
            var events = Self.readEvents()
            if !events.contains(where: { $0.object?["id"] == ev.object?["id"] }) {
                events.append(ev)
                Self.writeEvents(events)
            }
        }
        let o = ev.object ?? [:]
        note("ev <- \(o["type"]?.stringValue ?? "?") w=\(o["wid"]?.stringValue ?? "-") e\(o["entryIdx"]?.numberValue.map { String(Int($0)) } ?? "-")s\(o["setIdx"]?.numberValue.map { String(Int($0)) } ?? "-")")
        Task { @MainActor in self.drain() }
    }

    /// The same event sent as a message when the phone was in reach (the user info copy follows).
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        self.session(session, didReceiveUserInfo: message)
    }

    /// Applies the queued events (each once) and empties the queue.
    @MainActor
    func drain() {
        guard let model else { return }
        let events = queue.sync { Self.readEvents() }
        guard !events.isEmpty else { return }
        var applied = UserDefaults.standard.stringArray(forKey: Self.appliedKey) ?? []
        for ev in events.compactMap(\.object) {
            guard let id = ev["id"]?.stringValue, !applied.contains(id) else { continue }
            let before = model.active?["id"]?.stringValue
            model.applyWatch(ev, timer: timer)
            let wid = ev["wid"]?.stringValue
            let after = model.active?["id"]?.stringValue
            // A set for a workout the phone does not run is the case that lost a whole workout once.
            note("applied \(ev["type"]?.stringValue ?? "?") w=\(wid ?? "-") phone=\(before ?? "none")\(after != before ? " -> \(after ?? "none")" : "")\(wid != nil && wid != before && wid != after ? " NOT OURS" : "")")
            applied.append(id)
        }
        UserDefaults.standard.set(Array(applied.suffix(300)), forKey: Self.appliedKey)
        let ids = Set(events.compactMap { $0.object?["id"]?.stringValue })
        queue.sync { Self.writeEvents(Self.readEvents().filter { !ids.contains($0.object?["id"]?.stringValue ?? "") }) }
        send()
    }

    /// The watch asks before ending a workout it thinks was forgotten: which one runs here, and
    /// when the phone last changed it.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["idleCheck"] != nil else { replyHandler([:]); return }
        let d = UserDefaults.standard
        var answer: [String: Any] = [:]
        if let wid = d.string(forKey: Self.activeKey) { answer["wid"] = wid }
        if d.object(forKey: Self.activeAtKey) != nil { answer["activeAt"] = d.double(forKey: Self.activeAtKey) }
        replyHandler(answer)
    }

    /// A set's motion CSV for the rep counter, kept in Documents/motion (moved before returning:
    /// WatchConnectivity deletes the file afterwards).
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let name = file.metadata?["motion"] as? String, !name.contains("/"), !name.hasPrefix(".") else { return }
        let dir = URL.documentsDirectory.appending(path: "motion")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let to = dir.appending(path: name)
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.moveItem(at: file.fileURL, to: to)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        note("activated \(activationState == .activated)\(error.map { " error: \($0.localizedDescription)" } ?? "")")
        Task { @MainActor in self.lastSent = nil; self.drain(); self.send() }
    }
    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.lastSent = nil; self.send() }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    private static func readEvents() -> [JSONValue] {
        (try? Data(contentsOf: eventsFile)).flatMap { try? JSONDecoder().decode([JSONValue].self, from: $0) } ?? []
    }
    private static func writeEvents(_ events: [JSONValue]) {
        try? FileManager.default.createDirectory(at: eventsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(events).write(to: eventsFile, options: .atomic)
    }
}

extension AppModel {
    /// One event from the watch: into the document, then what the phone must still do.
    func applyWatch(_ ev: [String: JSONValue], timer: RestTimer?) {
        // MyGym: the watch started (on) or stopped recording a set: the Start set bar shows it.
        if ev["type"] == .string("recording") {
            let e = ev["entryIdx"]?.numberValue, i = ev["setIdx"]?.numberValue
            watchRecording = ev["on"] == .bool(true) && e != nil && i != nil ? WatchSet(entryIdx: Int(e!), setIdx: Int(i!), at: ev["at"]?.numberValue ?? now) : nil
            watchStart = nil
            if ev["on"] != .bool(true) { watchDone = nil }
        }
        var effect = WatchLink.Effect.none
        let (day, at, id) = (today, now, RoutineOps.newId(now: now))
        change { effect = WatchLink.apply(ev, to: &$0, today: day, now: at, newId: id, catalog: catalog) }
        switch effect {
        case .finish:
            timer?.stop()
            _ = finishWorkout()
            showWorkout = false
        case .discard:
            timer?.stop()
            discardWorkout()
            showWorkout = false
        case .rest(let endsAt):
            guard let timer, timer.end != nil, timer.kind == .rest else { return }
            let alerts = RestTimer.Alerts(sound: root["sound"] != .bool(false), flash: root["timerFlash"] == .bool(true))
            if let endsAt, let end = timer.end {
                let sec = ((endsAt / 1000 - end.timeIntervalSince1970)).rounded()
                if sec != 0 && endsAt / 1000 > Date.now.timeIntervalSince1970 { timer.add(sec, alerts: alerts) }
            } else {
                timer.stop()
            }
        case .tick(let i, let at):
            // The rest runs from when the set was done on the watch.
            guard let timer, let rest = restSeconds(after: i) else { return }
            let left = rest - max(0, (now - (at ?? now)) / 1000)
            let alerts = RestTimer.Alerts(sound: root["sound"] != .bool(false), flash: root["timerFlash"] == .bool(true))
            if left > 0 { timer.start(left, alerts: alerts) }
        case .none:
            break
        }
    }
}
