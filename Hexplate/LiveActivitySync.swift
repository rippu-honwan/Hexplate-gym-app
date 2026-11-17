import ActivityKit
import HexplateCore
import SwiftUI

/// The running workout's Live Activity (lib/live-activity.js startLiveActivitySync): started,
/// updated and ended as the session and its rest change, and its buttons' taps applied here.
/// Local updates only: a free team has no push.
@MainActor
enum LiveActivitySync {
    private static var restOver: Task<Void, Never>?

    static func start(model: AppModel, timer: RestTimer) {
        // The intents run in this process and wait for this before they return.
        LiveActivityQueue.onEvent = { @MainActor in
            drain(model, timer)
            await queue?.value
        }
        drain(model, timer)
        update(model, timer)
    }

    static func update(_ model: AppModel, _ timer: RestTimer) {
        let clock = timer.end.flatMap { $0 > .now ? LiveActivity.Clock(endsAt: $0.timeIntervalSince1970 * 1000, total: timer.total) : nil }
        let state = model.isPastSession ? nil
            : LiveActivity.state(model.root, rest: timer.kind == .rest ? clock : nil, hold: timer.kind == .hold ? clock : nil, catalog: model.catalog)
                .flatMap { try? JSONEncoder().encode(JSONValue.object($0)) }
                .flatMap { try? JSONDecoder().decode(WorkoutActivityAttributes.ContentState.self, from: $0) }
        let wid = model.active?["id"]?.stringValue ?? ""
        // A rest running out changes the Lock Screen, and nothing else says so.
        restOver?.cancel()
        if timer.kind == .rest, let end = timer.end, end > .now {
            restOver = Task {
                try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow + 0.5))
                if !Task.isCancelled { update(model, timer) }
            }
        }
        // One after another, so two quick changes never start two activities.
        let start = model.active?["start"]?.numberValue
        queue = Task { [queue] in
            await queue?.value
            await apply(state, wid: wid, start: start)
        }
    }

    private static var queue: Task<Void, Never>?

    private nonisolated static func apply(_ state: WorkoutActivityAttributes.ContentState?, wid: String, start: Double?) async {
        for a in Activity<WorkoutActivityAttributes>.activities {
            if let state, a.attributes.wid == wid {
                if a.content.state != state { await a.update(ActivityContent(state: state, staleDate: nil)) }
            } else {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
        guard let state, !Activity<WorkoutActivityAttributes>.activities.contains(where: { $0.attributes.wid == wid }),
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Fails in the background (iOS starts activities from the front only): the next change tries again.
        _ = try? Activity.request(attributes: WorkoutActivityAttributes(wid: wid, start: start), content: ActivityContent(state: state, staleDate: nil))
    }

    /// Applies the queued taps, then takes them out (the document is saved by then).
    static func drain(_ model: AppModel, _ timer: RestTimer) {
        let events = LiveActivityQueue.all()
        guard !events.isEmpty, let data = try? JSONSerialization.data(withJSONObject: events),
              let list = try? JSONDecoder().decode([JSONValue].self, from: data) else { return }
        for ev in list.compactMap(\.object) { model.applyLive(ev, timer: timer) }
        LiveActivityQueue.remove(ids: Set(list.compactMap { $0.object?["id"]?.stringValue }))
        // In the background SwiftUI's onChange hooks wait for the next frame, and an update they
        // queued earlier could land after the tap: send the state now, last.
        update(model, timer)
    }
}

extension AppModel {
    /// One tap on the Live Activity, done as the workout screen does it (applyLiveEvents). Taps
    /// about another workout, a set already ticked or a rest already over do nothing.
    func applyLive(_ ev: [String: JSONValue], timer: RestTimer) {
        guard let a = active, !isPastSession, ev["wid"]?.stringValue == a["id"]?.stringValue else { return }
        let at = ev["at"]?.numberValue ?? now
        let entries = activeEntries
        switch ev["type"]?.stringValue {
        case "setDone":
            let exId = ev["exId"]?.stringValue, e = Int(ev["entryIdx"]?.numberValue ?? -1), s = Int(ev["setIdx"]?.numberValue ?? -1)
            let i = entries.indices.contains(e) && entries[e]["id"]?.stringValue == exId ? e : entries.firstIndex { $0["id"]?.stringValue == exId }
            guard let i, let row = entries[i]["sets"]?.arrayValue?[safe: s], row.object?["done"] != .bool(true) else { return }
            changeSets(i) { $0[s] = Session.settingDone($0[s], true, at: at) }
            // The rest runs from the tap, not from when the app heard of it.
            if let rest = restAfter(entry: i, set: s) {
                let left = rest - max(0, (now - at) / 1000)
                let alerts = RestTimer.Alerts(sound: root["sound"] != .bool(false), flash: root["timerFlash"] == .bool(true))
                if left > 0 { timer.start(left, alerts: alerts) }
            }
        case "next":
            if let to = LiveActivity.nextExerciseTarget(a, from: Int(ev["fromEntryIdx"]?.numberValue ?? -1)) {
                changeActive { $0["cur"] = .number(Double(to)) }
            }
        case "restSkip":
            // A rest started after the tap is a new one (restSkipApplies), with a second of slack.
            if timer.kind == .rest, let end = timer.end, (end.timeIntervalSince1970 - timer.total) * 1000 <= at + 1000 { timer.stop() }
        default:
            break
        }
    }
}
