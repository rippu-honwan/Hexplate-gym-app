import Foundation

/// A routine's icon. The document stores openGym's glyph names (frontend/src/lib/glyphs.js);
/// each is drawn with the nearest SF Symbol.
enum Glyph {
    static let groups: [(title: String, names: [String])] = [
        ("Strength", ["figureStrength", "arm", "abs", "legs", "pullup"]),
        ("Equipment", ["dumbbell", "barbell", "kettlebell", "plate", "machine"]),
        ("Cardio", ["figureRun", "bike", "swim", "boxing", "timer"]),
        ("Recovery", ["stretch", "moon", "heart", "flame", "bolt"]),
    ]

    private static let symbols: [String: String] = [
        "figureStrength": "figure.strengthtraining.traditional", "arm": "figure.strengthtraining.functional",
        "abs": "figure.core.training", "legs": "figure.step.training", "pullup": "figure.climbing",
        "dumbbell": "dumbbell.fill", "barbell": "dumbbell", "kettlebell": "figure.cross.training",
        "plate": "circle.circle", "machine": "gearshape.2.fill",
        "figureRun": "figure.run", "bike": "figure.outdoor.cycle", "swim": "figure.pool.swim",
        "boxing": "figure.boxing", "timer": "timer",
        "stretch": "figure.flexibility", "moon": "moon.fill", "heart": "heart.fill", "flame": "flame.fill", "bolt": "bolt.fill",
        "trophy": "trophy.fill", "medal": "medal.fill", "crown": "crown.fill", "flag": "flag.fill", "star": "star.fill",
        "target": "target", "shield": "shield.fill",
    ]

    /// The SF Symbol for a stored glyph name; anything unknown (an old emoji) reads as the default.
    static func symbol(_ name: String?) -> String {
        symbols[name ?? ""] ?? symbols["figureStrength"]!
    }

    static func title(_ name: String) -> String {
        ["figureStrength": "Strength", "figureRun": "Running", "pullup": "Pull-up"][name] ?? name.capitalized
    }
}
