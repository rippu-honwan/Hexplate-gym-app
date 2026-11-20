import SwiftUI
import UIKit

/// Hexplate's colours. Surfaces and text are the system's (pure black, grey cards and white text
/// in dark mode); the accent is the asset catalogue's AccentColor. What is here are the status
/// colours, one meaning each, the same as the watch app's Theme:
///   yellow   a warm-up set
///   purple   a personal record
///   magenta  a superset
///   red      heart rate
enum Theme {
    static let warmup = Color(red: 1, green: 0xd6 / 255, blue: 0x0a / 255)
    /// Drawn on the warm-up yellow and on the accent.
    static let ink = Color.black
    static let record = adaptive(light: (0x8e, 0x2f, 0xc4), dark: (0xbf, 0x5a, 0xf2))
    static let superset = adaptive(light: (0xc2, 0x1a, 0x9c), dark: (0xff, 0x4f, 0xd8))
    static let heart = Color.red

    /// The app's language, picked in Settings → Units & language: "zh" (Traditional Chinese, the
    /// default) or "en". Read once at launch; `applyLanguage` makes the bundle follow it next launch.
    static let languageKey = "language"
    static let language = UserDefaults.standard.string(forKey: languageKey) == "en" ? "en" : "zh"
    /// SwiftUI looks every Text up by it, and dates and numbers follow it.
    static let locale = Locale(identifier: language == "en" ? "en_HK" : "zh_Hant_HK")

    /// The accent (Settings → Look & Home), per phone and read at launch like the language. Not
    /// the synced `accent`: openGym's default there is green, and Hexplate is black and cyan.
    static let accentKey = "accentColor"
    static let accents: [(id: String, name: LocalizedStringResource, rgb: UInt32)] = [
        ("teal", "Teal", 0x40C8E0), ("sky", "Blue", 0x0A84FF), ("violet", "Purple", 0xBF5AF2), ("pink", "Pink", 0xFF375F),
        ("red", "Red", 0xFF453A), ("orange", "Orange", 0xFF9F0A), ("gold", "Yellow", 0xFFD60A), ("lime", "Green", 0x30D158),
    ]
    static let accentId = UserDefaults.standard.string(forKey: accentKey) ?? "teal"
    /// Teal is the asset's colour, darker in light mode; the others are openGym's swatches.
    static let accent: Color = accents.first { $0.id == accentId && $0.id != "teal" }.map { rgb($0.rgb) } ?? .accentColor
    /// The accent on paper (PDF report): teal is the asset's light-mode shade, the others as they are.
    static let paperAccent: Color = accentId == "teal" ? rgb(0x0B7A90) : accent
    static func rgb(_ v: UInt32) -> Color {
        Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// The bundle picks zh-Hant.lproj or en.lproj (the English keys) from this, whatever the device's language.
    static func applyLanguage(_ lang: String) {
        UserDefaults.standard.set([lang == "en" ? "en" : "zh-Hant"], forKey: "AppleLanguages")
    }

    /// A darker shade in light mode, so the colour still reads as text on white.
    private static func adaptive(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        })
    }
}

extension View {
    /// Dragging the list down hides the keyboard; a tap outside a field does too (KeyboardDismisser),
    /// so the number pad, which has no return key, needs no Done button above it.
    func keyboardDismissal() -> some View {
        scrollDismissesKeyboard(.interactively)
    }
}

/// A tap anywhere outside a text field closes the keyboard, the way people expect: the number pad
/// has no return key. One recogniser per window, which sheets and covers share; it
/// lets every tap through, so the button tapped still works.
@MainActor
final class KeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismisser()

    static func install() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where !(window.gestureRecognizers ?? []).contains(where: { $0.delegate === shared }) {
                let tap = UITapGestureRecognizer(target: shared, action: #selector(close))
                tap.cancelsTouchesInView = false
                tap.delegate = shared
                window.addGestureRecognizer(tap)
            }
        }
    }

    @objc private func close() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let v = view {
            if v is UITextField || v is UITextView { return false }
            view = v.superview
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
