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

    /// opengym://start?r=a,b (the running workout, else these routines), stats, home, weigh-in.
    static func open(_ url: URL, _ model: AppModel) {
        guard url.scheme == "opengym" else { return }
        switch url.host() {
        case "start":
            if model.active == nil {
                let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "r" }?.value?
                    .split(separator: ",").map(String.init).filter { model.routine($0) != nil } ?? []
                guard !ids.isEmpty else { model.tab = "today"; return }
                model.startWorkout(routineIds: ids)
            }
            model.showWorkout = true
        case "stats": model.tab = "stats"
        default: model.tab = "today"
        }
    }
}
