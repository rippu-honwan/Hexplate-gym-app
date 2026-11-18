import Foundation

/// Text for numbers, ported from frontend/src/lib/format.js so a logged set reads the same.
public enum Format {
    /// A weight or volume: `decimals` places at most (1 or 2), grouped ("6,186.8"). English only.
    public static func number(_ n: Double, decimals: Int = 1) -> String {
        let p = decimals == 2 ? 100.0 : 10.0
        // Math.round: halves go up, also below zero; `+ 0` there turns -0 into 0.
        let rounded = (n * p + 0.5).rounded(.down) / p + 0
        return rounded.formatted(.number.precision(.fractionLength(0...(decimals == 2 ? 2 : 1))).locale(english))
    }

    private static let english = Locale(identifier: "en_US")

    /// A number the way JavaScript prints it in a template string: "20", "10.5".
    static func plain(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    }

    /// mm:ss for a work duration.
    public static func seconds(_ sec: Double) -> String {
        let n = Int(max(0, (sec + 0.5).rounded(.down)))
        return "\(n / 60):" + String(format: "%02d", n % 60)
    }

    /// "1h 5m" or "20 min"; nil under a minute, where a duration is not known (imported history).
    public static func duration(milliseconds ms: Double) -> String? {
        guard ms >= 60000 else { return nil }
        let m = Int(ms / 60000)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m) min"
    }

    /// Exercise names are stored lower-case; each word starts with a capital on screen.
    public static func capWords(_ s: String) -> String {
        var out = ""
        var boundary = true
        for ch in s {
            out += boundary && ch.isLowercase ? ch.uppercased() : String(ch)
            boundary = ch.isWhitespace || ch == "(" || ch == "-" || ch == "/"
        }
        return out
    }
}
