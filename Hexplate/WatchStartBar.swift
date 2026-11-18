import HexplateCore
import SwiftUI
import WatchConnectivity

/// MyGym: the workout screen's bottom bar while an Apple Watch is paired (WatchStartBar.jsx).
/// Start set asks the watch to record the next set (its motion for the rep counter), so the
/// watch's own Start need not be pressed; while the watch records, Done ticks that set here.
/// Hidden during a rest or hold (the rest bar has the bottom) and for sets the watch does not
/// record (timed, cardio, legs).
struct WatchStartBar: View {
    @Environment(AppModel.self) private var model
    @Environment(RestTimer.self) private var timer

    static var watchReady: Bool {
        // ponytail: -HexplateFakeWatch YES shows the bar in the simulator for screenshots.
        if UserDefaults.standard.bool(forKey: "HexplateFakeWatch") { return true }
        let wc = WCSession.default
        return WCSession.isSupported() && wc.activationState == .activated && wc.isPaired && wc.isWatchAppInstalled
    }

    var body: some View {
        if !model.isPastSession, Self.watchReady, let next = LiveActivity.watchSet(model.root, catalog: model.catalog, setLine: LiveActivitySync.setLine),
           let e = next["entryIdx"]?.numberValue.map(Int.init), let i = next["setIdx"]?.numberValue.map(Int.init) {
            let name = next["exName"]?.stringValue ?? ""
            let line = next["setLine"]?.stringValue ?? ""
            let rec = model.watchRecording.flatMap { $0.entryIdx == e && $0.setIdx == i && model.now - $0.at < 15 * 60_000 ? $0 : nil }
            let waiting = model.watchStart.map { $0.entryIdx == e && $0.setIdx == i && model.now - $0.at < 5_000 } ?? false
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec != nil ? "Recording on the watch" : waiting ? "Starting on the watch…" : "Next on the watch")
                        .font(.caption.weight(.semibold)).foregroundStyle(rec != nil ? Color.accentColor : .secondary)
                    Text(verbatim: "\(name) · \(line)").font(.subheadline).lineLimit(1)
                }
                Spacer(minLength: 8)
                if rec != nil {
                    Button("Done", systemImage: "checkmark") {
                        model.watchRecording = nil
                        model.tick(entry: e, set: i, at: model.now, timer: timer)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Start", systemImage: "applewatch") {
                        model.watchStart = .init(entryIdx: e, setIdx: i, at: model.now)
                        WatchBridge.shared.send()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(waiting)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .padding(.horizontal, 12).padding(.bottom, 4)
        }
    }
}
