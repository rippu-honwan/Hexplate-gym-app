import AVFoundation
import SwiftUI
import UIKit

/// An exercise's still or looping clip from the bundled 180 px media (catalogue/media).
/// The media are licensed separately from the code (NOTICE.md); only the 180 px size is bundled.
enum ExerciseMedia {
    /// Screens drawn for a screenshot leave the licensed media out (launch argument
    /// `-HexplateHideMedia YES`).
    static let hidden = UserDefaults.standard.bool(forKey: "HexplateHideMedia")

    static func stillURL(_ id: String) -> URL? {
        hidden ? nil : Bundle.main.url(forResource: id, withExtension: "webp", subdirectory: "still")
    }
    static func clipURL(_ id: String) -> URL? {
        hidden ? nil : Bundle.main.url(forResource: id, withExtension: "mp4", subdirectory: "clip")
    }
}

/// The still, as a small rounded tile; a quiet placeholder when there is none.
struct ExerciseThumb: View {
    let id: String
    @ScaledMetric(relativeTo: .body) private var size = 48.0

    var body: some View {
        Group {
            if let url = ExerciseMedia.stillURL(id), let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit().background(.white)
            } else {
                Image(systemName: "figure.strengthtraining.traditional")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.fill.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

/// The clip, looping without sound; the still when there is no clip.
struct ExerciseClip: View {
    let id: String

    var body: some View {
        if let url = ExerciseMedia.clipURL(id) {
            LoopingPlayer(url: url)
                .aspectRatio(1, contentMode: .fit)
                .background(.white)
                .clipShape(.rect(cornerRadius: 16))
                .accessibilityLabel("Animation of the exercise")
        } else if let url = ExerciseMedia.stillURL(id), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFit().background(.white).clipShape(.rect(cornerRadius: 16))
                .accessibilityLabel("Picture of the exercise")
        }
    }
}

/// The animation at the top of an exercise in a workout, as openGym draws it: a white 320 pt tile
/// (120 pt in a superset), tap to pause, and a Minimise pill that switches every exercise to a
/// small picture beside its name (setting `gifSize`: "full", "mini" or "off").
struct WorkoutMedia: View {
    @Environment(AppModel.self) private var model
    let id: String
    var compact = false
    /// The exercise card always shows the full picture: no Minimise there.
    var minimisable = true
    @State private var playing = true

    var body: some View {
        let still = ExerciseMedia.stillURL(id).flatMap { UIImage(contentsOfFile: $0.path) }
        // A screenshot build draws a grey stand-in of the same size, so the layout still shows.
        if still != nil || ExerciseMedia.hidden {
            let clip = ExerciseMedia.clipURL(id)
            ZStack(alignment: .bottom) {
                Group {
                    if let clip { LoopingPlayer(url: clip, playing: playing) }
                    else if let still { Image(uiImage: still).resizable().scaledToFit() }
                    else { Image(systemName: "figure.strengthtraining.traditional").font(.largeTitle).foregroundStyle(.gray) }
                }
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 120 : 320)
                .background(.white)
                .contentShape(.rect)
                .onTapGesture { playing.toggle() }
                HStack {
                    if minimisable { Button("Minimise", systemImage: "arrow.down.right.and.arrow.up.left") { model.set("gifSize", .string("mini")) } }
                    Spacer()
                    if clip != nil || ExerciseMedia.hidden {
                        Label(playing ? "tap to pause" : "tap to play", systemImage: playing ? "pause.fill" : "play.fill")
                            .allowsHitTesting(false)
                    }
                }
                .labelStyle(Pill())
                .buttonStyle(.plain)
                .padding(9)
            }
            .clipShape(.rect(cornerRadius: 16))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Animation of the exercise")
        }
    }

    private struct Pill: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 4) { configuration.icon.font(.caption2); configuration.title }
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.vertical, 5).padding(.horizontal, 11)
                .background(.black.opacity(0.45), in: .capsule)
        }
    }
}

/// Small mode: the still beside the name; a tap brings the full animation back.
struct WorkoutThumb: View {
    @Environment(AppModel.self) private var model
    let id: String

    var body: some View {
        if ExerciseMedia.stillURL(id) != nil || ExerciseMedia.hidden {
            Button { model.set("gifSize", .string("full")) } label: { ExerciseThumb(id: id) }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand")
        }
    }
}

private struct LoopingPlayer: UIViewRepresentable {
    let url: URL
    var playing = true

    func makeUIView(context: Context) -> PlayerView { PlayerView(url: url) }
    func updateUIView(_ view: PlayerView, context: Context) { view.setPlaying(playing) }

    final class PlayerView: UIView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?

        override class var layerClass: AnyClass { AVPlayerLayer.self }

        init(url: URL) {
            super.init(frame: .zero)
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.isMuted = true
            // A silent loop must not stop the user's music.
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
            (layer as? AVPlayerLayer)?.player = player
            (layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
            player.play()
        }

        func setPlaying(_ on: Bool) { on ? player.play() : player.pause() }

        required init?(coder: NSCoder) { fatalError("not used") }
    }
}
