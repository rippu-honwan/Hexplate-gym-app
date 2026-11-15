import HexplateCore
import SwiftUI
import OSLog
import WatchConnectivity

/// The phone's end of the Apple Watch link (was frontend/ios/App/App/WatchBridgePlugin.swift).
///
/// Phone → watch: the snapshot (HexplateCore WatchLink.snapshot) as the application context, and as
/// a message too when the watch is reachable. Watch → phone: events sent with transferUserInfo.
/// Each is written to a file before the delegate returns (iOS may suspend the app right after),
/// then applied once by its id.
///
/// ponytail: exercise animations are not sent and the watch app is not opened from the phone yet.
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
        guard WCSession.isSupported(), let model, WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        let ends = timer?.end.flatMap { timer?.kind == .rest ? $0.timeIntervalSince1970 * 1000 : nil }
        let snap = WatchLink.snapshot(model.root, today: model.today, restEndsAt: ends, health: UserDefaults.standard.bool(forKey: "health"), catalog: model.catalog)
        guard let data = try? JSONEncoder().encode(JSONValue.object(snap)), let json = String(data: data, encoding: .utf8), json != lastSent else { return }
        let d = UserDefaults.standard
        d.set(model.active?["id"]?.stringValue, forKey: Self.activeKey)
        d.set(model.now, forKey: Self.activeAtKey)
        let payload: [String: Any] = ["snapshot": json, "at": Date().timeIntervalSince1970]
        do {
            try WCSession.default.updateApplicationContext(payload)
            lastSent = json
        } catch {
            return
        }
        if WCSession.default.isReachable { WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil) }
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
        Task { @MainActor in self.drain() }
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
            log.info("watch event \(ev["type"]?.stringValue ?? "?", privacy: .public)")
            model.applyWatch(ev, timer: timer)
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
        case .none:
            break
        }
    }
}
