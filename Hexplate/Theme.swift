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

    /// Dates read in English like the rest of the app, day before month.
    static let locale = Locale(identifier: "en_GB")

    /// A darker shade in light mode, so the colour still reads as text on white.
    private static func adaptive(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        })
    }
}

extension View {
    /// A Done button above the keyboard, and dragging the list down hides it: the number pad
    /// has no return key, so without these it never closes.
    func keyboardDone() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .fontWeight(.semibold)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// A tap anywhere outside a text field closes the keyboard, the way people expect when the number
/// pad's Done above it goes unseen. One recogniser per window, which sheets and covers share; it
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
