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

private struct LoopingPlayer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView { PlayerView(url: url) }
    func updateUIView(_ view: PlayerView, context: Context) {}

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

        required init?(coder: NSCoder) { fatalError("not used") }
    }
}
