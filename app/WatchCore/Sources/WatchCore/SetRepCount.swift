import Foundation

/// Counts a finished set's reps from its whole userAccel window: the "peaks" method of
/// analysis/rep_count.py, number for number (Tests: SetRepCountTests against its golden output).
///
/// Band-pass 0.1-0.8 Hz forward and backward, clip each axis at 2x its 90th percentile of |x|
/// (grabbing and letting go of the handle), project on the main axis, then count peaks and troughs
/// at least 1.25 s apart that stand out by 0.7 of the 5-95 percentile range.
/// Held out on 65 of the user's sets (analysis/rep-count-results.md): MAE 1.48, exact 34%,
/// against 1.93 and 20% for the live count. It needs the whole set, so it runs when the set ends.
public enum SetRepCount {
    static let lo = 0.1, hi = 0.8, pad = 3.0, clip = 2.0, prominence = 0.7

    /// `t` in seconds; `axes` = [ax, ay, az] in g, each as long as `t`.
    public static func count(t: [Double], axes: [[Double]]) -> Int {
        guard let (s, hz) = project(t: t, axes: axes) else { return 0 }
        let amp = percentile(s, 95) - percentile(s, 5)
        let distance = max(1, Int(hz / hi))
        let n = [s, s.map { -$0 }].map { v in prominences(v, peaks(v, distance: distance)).filter { $0 >= prominence * amp }.count }
        return Int((Double(n[0] + n[1]) / 2).rounded(.toNearestOrEven))   // Python's round()
    }

    /// The filtered, clipped signal on its main axis, and the sample rate; nil when there is none.
    static func project(t: [Double], axes: [[Double]]) -> ([Double], Double)? {
        guard t.count >= 3, let first = t.first, let last = t.last, last > first else { return nil }
        let hz = Double(t.count - 1) / (last - first)
        let x = axes.map { a -> [Double] in
            let mean = a.reduce(0, +) / Double(a.count)
            let f = zeroPhase(a.map { $0 - mean }, hz: hz)
            let lim = clip * percentile(f.map(abs), 90)
            return f.map { min(max($0, -lim), lim) }
        }
        // Main axis: the top eigenvector of XᵀX by power iteration, from its largest column.
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { m[i][j] = zip(x[i], x[j]).reduce(0) { $0 + $1.0 * $1.1 } } }
        var v = m.max { norm($0) < norm($1) }!
        guard norm(v) > 0 else { return nil }
        for _ in 0..<200 {
            let w = (0..<3).map { i in (0..<3).reduce(0) { $0 + m[i][$1] * v[$1] } }
            guard norm(w) > 0 else { return nil }
            v = w.map { $0 / norm(w) }
        }
        return ((0..<t.count).map { k in x[0][k] * v[0] + x[1][k] * v[1] + x[2][k] * v[2] }, hz)
    }

    private static func norm(_ v: [Double]) -> Double { sqrt(v.reduce(0) { $0 + $1 * $1 }) }

    /// 2nd-order Butterworth high-pass at `lo` then low-pass at `hi` (bilinear, prewarped), run
    /// forward then backward over an odd reflection of `pad` seconds at each end.
    static func zeroPhase(_ x: [Double], hz: Double) -> [Double] {
        let kl = tan(.pi * lo / hz), kh = tan(.pi * hi / hz)
        let nl = 1 / (1 + 2.squareRoot() * kl + kl * kl), nh = 1 / (1 + 2.squareRoot() * kh + kh * kh)
        let sections: [([Double], [Double])] = [
            ([nl, -2 * nl, nl], [2 * (kl * kl - 1) * nl, (1 - 2.squareRoot() * kl + kl * kl) * nl]),
            ([kh * kh * nh, 2 * kh * kh * nh, kh * kh * nh], [2 * (kh * kh - 1) * nh, (1 - 2.squareRoot() * kh + kh * kh) * nh]),
        ]
        let n = x.count, p = min(n - 1, Int(pad * hz))
        var y = (0..<p).map { 2 * x[0] - x[p - $0] } + x + (0..<p).map { 2 * x[n - 1] - x[n - 2 - $0] }
        for _ in 0..<2 {
            for (b, a) in sections {   // direct form II transposed, from rest (scipy's lfilter)
                var z1 = 0.0, z2 = 0.0
                for i in y.indices {
                    let u = y[i], o = b[0] * u + z1
                    z1 = b[1] * u - a[0] * o + z2
                    z2 = b[2] * u - a[1] * o
                    y[i] = o
                }
            }
            y.reverse()
        }
        return Array(y[p..<(p + n)])
    }

    /// numpy's default (linear) percentile.
    static func percentile(_ a: [Double], _ q: Double) -> Double {
        let s = a.sorted(), r = Double(s.count - 1) * q / 100, i = Int(r)
        return i + 1 < s.count ? s[i] + (r - Double(i)) * (s[i + 1] - s[i]) : s[i]
    }

    /// scipy's find_peaks: local maxima (a plateau's middle), then the highest first, dropping
    /// any peak closer than `distance` samples to one already kept.
    static func peaks(_ x: [Double], distance: Int) -> [Int] {
        var found: [Int] = []
        var i = 1
        while i < x.count - 1 {
            if x[i - 1] < x[i] {
                var ahead = i + 1
                while ahead < x.count - 1 && x[ahead] == x[i] { ahead += 1 }
                if x[ahead] < x[i] {
                    found.append((i + ahead - 1) / 2)
                    i = ahead
                }
            }
            i += 1
        }
        var keep = [Bool](repeating: true, count: found.count)
        for j in found.indices.sorted(by: { x[found[$0]] > x[found[$1]] }) where keep[j] {
            var k = j - 1
            while k >= 0 && found[j] - found[k] < distance { keep[k] = false; k -= 1 }
            k = j + 1
            while k < found.count && found[k] - found[j] < distance { keep[k] = false; k += 1 }
        }
        return found.indices.filter { keep[$0] }.map { found[$0] }
    }

    /// scipy's peak_prominences over the whole signal.
    static func prominences(_ x: [Double], _ peaks: [Int]) -> [Double] {
        peaks.map { p in
            var left = x[p], i = p
            while i >= 0 && x[i] <= x[p] { left = min(left, x[i]); i -= 1 }
            var right = x[p]
            i = p
            while i < x.count && x[i] <= x[p] { right = min(right, x[i]); i += 1 }
            return x[p] - max(left, right)
        }
    }
}
