import HexplateCore
import SwiftUI
import WidgetKit

/// Keeps the widgets current: the snapshot (HexplateCore WidgetData) as widget.json in the App
/// Group the extension reads, written when it changed, and the links a widget tap opens.
@MainActor
enum WidgetSync {
    static let group = "group.com.rippuhonwan.mygym"
    private static var last: Data?

    static func write(_ model: AppModel) {
        guard let history = model.history,
              let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        let snap = WidgetData.snapshot(model.root, history: history, today: model.today, catalog: model.catalog)
        guard let data = try? JSONEncoder().encode(JSONValue.object(snap)), data != last else { return }
        do {
            try data.write(to: dir.appending(path: "widget.json"), options: .atomic)
            last = data
            WidgetCenter.shared.reloadAllTimelines()
        } catch {}
    }

    /// opengym://start?r=a,b (the running workout, else these routines), stats, analysis,
    /// weigh-in, home, today, plan, programmes, exercises, gym, nutrition, history, profile.
    static func open(_ url: URL, _ model: AppModel) {
        guard url.scheme == "opengym" else { return }
        let host = url.host()?.lowercased() ?? ""

        if host == "start" {
            model.pendingCoverWeighIn = false
            model.weighInRequested = false
            if model.active == nil {
                let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "r" }?.value?
                    .split(separator: ",").map(String.init).filter { model.routine($0) != nil } ?? []
                guard !ids.isEmpty else { model.tab = "today"; return }
                model.startWorkout(routineIds: ids)
            }
            model.showWorkout = true
            return
        }

        // Cancel any stale weigh-in request when routing to a new destination.
        model.pendingCoverWeighIn = false
        model.weighInRequested = false

        if host == "weigh-in" {
            model.tab = "profile"
            if model.showWorkout || model.wrappedYear != nil {
                model.pendingCoverWeighIn = true
                model.showWorkout = false
                model.wrappedYear = nil
            } else {
                model.weighInRequested = true
            }
            return
        }

        // Minimise any open full-screen cover so the target tab is visible without ending an active workout.
        if model.showWorkout { model.showWorkout = false }
        if model.wrappedYear != nil { model.wrappedYear = nil }

        switch host {
        case "stats", "analysis":
            model.tab = "analysis"
        case "plan":
            model.gymSegment = .plan
            model.gymResetToken += 1
            model.tab = "gym"
        case "programmes":
            model.gymSegment = .programmes
            model.gymResetToken += 1
            model.tab = "gym"
        case "exercises":
            model.gymSegment = .exercises
            model.gymResetToken += 1
            model.tab = "gym"
        case "gym":
            model.gymResetToken += 1
            model.tab = "gym"
        case "nutrition":
            model.tab = "nutrition"
        case "history", "profile":
            model.tab = "profile"
        default:
            model.tab = "today"
        }
    }
}
