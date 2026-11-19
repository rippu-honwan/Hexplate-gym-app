import HexplateCore
import SwiftUI
import WatchConnectivity

/// MyGym: the workout screen's bottom bar while an Apple Watch is paired (WatchStartBar.jsx).
/// Start asks the watch to open the exercise and record its next set (motion for the rep
/// counter); while it records, Done asks the watch to press its own Done, so the reps it counted
/// and the RIR asked there are what gets logged. The exercise card on screen picks the exercise.
/// Hidden during a rest or hold (the rest bar has the bottom), for sets the watch does not
/// record (timed, cardio, legs), and when the next set belongs to another card (this card's
/// sets are all done), unless the watch is recording it.
struct WatchStartBar: View {
    @Environment(AppModel.self) private var model
    /// The entry of the card on screen.
    let card: Int

    static var watchReady: Bool {
        // ponytail: -HexplateFakeWatch YES shows the bar in the simulator for screenshots.
        if UserDefaults.standard.bool(forKey: "HexplateFakeWatch") { return true }
        let wc = WCSession.default
        return WCSession.isSupported() && wc.activationState == .activated && wc.isPaired && wc.isWatchAppInstalled
    }

    var body: some View {
        if !model.isPastSession, Self.watchReady,
           let next = LiveActivity.watchSet(model.root, catalog: model.catalog, setLine: LiveActivitySync.setLine),
           let e = next["entryIdx"]?.numberValue.map(Int.init), let i = next["setIdx"]?.numberValue.map(Int.init) {
            let line = next["setLine"]?.stringValue ?? ""
            let fresh = { (x: AppModel.WatchSet?, ms: Double) in x.map { $0.entryIdx == e && $0.setIdx == i && model.now - $0.at < ms } ?? false }
            // ponytail: Start alone shows Done, so a late "recording" event from the watch never
            // hides it; a Done the watch did not start is ignored there.
            let recording = fresh(model.watchRecording, 15 * 60_000) || fresh(model.watchStart, 15 * 60_000)
            let ending = fresh(model.watchDone, 30_000)
            let units = ActiveEdit.units(model.active?["entries"]?.arrayValue ?? [])
            if recording || units.contains(where: { $0.contains(card) && $0.contains(e) }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ending ? "Waiting for the watch…" : recording ? "Recording on the watch" : "Next on the watch")
                        .font(.caption.weight(.semibold)).foregroundStyle(recording ? Theme.accent : .secondary)
                    // No picker: the exercise card on screen picks the exercise (ExerciseCards sets "cur").
                    Text(verbatim: "\(next["exName"]?.stringValue ?? "") · \(line)").font(.subheadline).lineLimit(1)
                }
                Spacer(minLength: 8)
                if recording {
                    Button("Done", systemImage: "checkmark") {
                        model.watchDone = .init(entryIdx: e, setIdx: i, at: model.now)
                        WatchBridge.shared.send()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ending)
                } else {
                    Button("Start", systemImage: "applewatch") {
                        model.watchStart = .init(entryIdx: e, setIdx: i, at: model.now)
                        WatchBridge.shared.send()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .padding(.horizontal, 12).padding(.bottom, 4)
            }
        }
    }
}
