import HexplateCore
import SwiftUI

/// The body map: a front or back figure whose muscles are shaded by how much they are worked.
/// Outlines from MuscleMap by Melih Colpan (MIT), as the Capacitor app uses them (see NOTICE.md).
struct BodyMap: View {
    enum Side: String { case front, back }

    let side: Side
    /// 0...1 per muscle; a muscle that is absent is drawn unlit.
    var levels: [String: Double] = [:]
    /// Optional anatomical per-side shading (`left` / `right`) for bilateral limbs; empty leaves
    /// existing whole-slug rendering completely unchanged.
    var sideLevels: [BodyData.PartSide: Double] = [:]
    var female = false
    var onTap: ((String) -> Void)?
    /// Muscles to frame, close up, instead of the whole figure (a filter option's picture).
    var zoom: [String] = []

    var body: some View {
        if let figure = BodyFigure.all[female ? "female" : "male"]?[side.rawValue] {
            let box = frame(figure)
            GeometryReader { geo in
                let scale = min(geo.size.width / box.width, geo.size.height / box.height)
                let move = CGAffineTransform(translationX: -box.minX, y: -box.minY)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(
                        translationX: (geo.size.width - box.width * scale) / 2,
                        y: (geo.size.height - box.height * scale) / 2))
                ZStack {
                    ForEach(figure.parts, id: \.slug) { part in
                        if part.inert {
                            part.path.applying(move).fill(.fill.tertiary)
                        } else {
                            let leftOverride = sideLevels[BodyData.PartSide(slug: part.slug, side: .left)]
                            let rightOverride = sideLevels[BodyData.PartSide(slug: part.slug, side: .right)]
                            if leftOverride != nil || rightOverride != nil {
                                let fallback = levels[part.slug] ?? 0
                                let lLevel = min(1, max(0, leftOverride ?? fallback))
                                let rLevel = min(1, max(0, rightOverride ?? fallback))
                                let lPath = part.leftPath.applying(move)
                                let rPath = part.rightPath.applying(move)
                                ZStack {
                                    lPath.fill(lLevel > 0 ? AnyShapeStyle(.tint.opacity(0.3 + 0.7 * lLevel)) : AnyShapeStyle(.fill.secondary))
                                    rPath.fill(rLevel > 0 ? AnyShapeStyle(.tint.opacity(0.3 + 0.7 * rLevel)) : AnyShapeStyle(.fill.secondary))
                                }
                                .contentShape(part.path.applying(move))
                                .onTapGesture { onTap?(part.slug) }
                                .accessibilityHidden(onTap == nil)
                                .accessibilityLabel(ExerciseCatalog.builtIn.muscleName(part.slug))
                                .accessibilityAddTraits(.isButton)
                            } else {
                                let path = part.path.applying(move)
                                let level = min(1, max(0, levels[part.slug] ?? 0))
                                path.fill(level > 0 ? AnyShapeStyle(.tint.opacity(0.3 + 0.7 * level)) : AnyShapeStyle(.fill.secondary))
                                    .contentShape(path)
                                    .onTapGesture { onTap?(part.slug) }
                                    .accessibilityHidden(onTap == nil)
                                    .accessibilityLabel(ExerciseCatalog.builtIn.muscleName(part.slug))
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                    }
                }
            }
            .aspectRatio(box.width / box.height, contentMode: .fit)
            .clipped()
            .accessibilityElement(children: onTap == nil ? .ignore : .contain)
        }
    }

    /// The whole figure, or a square around the `zoom` muscles with room to see where they sit.
    private func frame(_ figure: BodyFigure) -> CGRect {
        let around = figure.parts.filter { zoom.contains($0.slug) }.map(\.path.boundingRect).reduce(CGRect.null) { $0.union($1) }
        guard !around.isNull else { return figure.box }
        let side = max(around.width, around.height) * 1.6
        return CGRect(x: around.midX - side / 2, y: around.midY - side / 2, width: side, height: side)
    }
}

/// One view of a figure: its drawing box and one path per body part.
struct BodyFigure {
    struct Part {
        let slug: String
        let path: Path
        let leftPath: Path
        let rightPath: Path
        let inert: Bool
    }
    let box: CGRect
    let parts: [Part]

    /// figure ("male", "female") → side ("front", "back"), parsed once.
    static let all: [String: [String: BodyFigure]] = {
        struct Raw: Decodable { let vb: String; let p: [String: [String]] }
        guard let url = ExerciseCatalog.bodyPathsURL, let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [String: Raw]].self, from: data) else { return [:] }
        let inert = Set(ExerciseCatalog.builtIn.meta.inert)
        return raw.mapValues { views in
            Dictionary(uniqueKeysWithValues: views.map { sideName, view in
                let n = view.vb.split(separator: " ").compactMap { Double($0) }
                let box = n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : .zero
                let isFront = sideName == "front"
                // The silhouette first, so muscles are drawn (and tapped) on top of it.
                let parts = view.p.map { slug, ds -> Part in
                    var combined = Path()
                    var left = Path()
                    var right = Path()
                    for d in ds {
                        let sub = SVGPath.path(d)
                        combined.addPath(sub)
                        let anatomical = BodyData.anatomicalSide(
                            subpathMidX: Double(sub.boundingRect.midX),
                            boxMidX: Double(box.midX),
                            isFront: isFront
                        )
                        if anatomical == .left {
                            left.addPath(sub)
                        } else {
                            right.addPath(sub)
                        }
                    }
                    return Part(slug: slug, path: combined, leftPath: left, rightPath: right, inert: inert.contains(slug))
                }.sorted { ($0.inert ? 0 : 1, $0.slug) < ($1.inert ? 0 : 1, $1.slug) }
                return (sideName, BodyFigure(box: box, parts: parts))
            })
        }
    }()
}

/// Reads an SVG path's `d` attribute into a SwiftUI path: M L H V C S Q T A Z, absolute and relative.
enum SVGPath {
    static func path(_ d: String) -> Path {
        var p = Path()
        var s = Scanner(bytes: Array(d.utf8))
        var cmd: UInt8 = 0
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?   // of the previous curve, for the smooth commands S and T
        var lastWasCubic = false

        while true {
            if let c = s.command() { cmd = c } else if s.atEnd || cmd == 0 { break }
            let rel = cmd >= 97   // lower case: relative to the current point
            let at = { (x: CGFloat, y: CGFloat) in rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            var control: CGPoint?
            var cubic = false

            switch cmd | 0x20 {   // the command, lower-cased
            case UInt8(ascii: "z"):
                p.closeSubpath()
                cur = start
                cmd = 0
            case UInt8(ascii: "m"):
                guard let x = s.number(), let y = s.number() else { return p }
                cur = at(x, y); start = cur
                p.move(to: cur)
                cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")   // further pairs are lines
            case UInt8(ascii: "l"):
                guard let x = s.number(), let y = s.number() else { return p }
                cur = at(x, y)
                p.addLine(to: cur)
            case UInt8(ascii: "h"):
                guard let x = s.number() else { return p }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
                p.addLine(to: cur)
            case UInt8(ascii: "v"):
                guard let y = s.number() else { return p }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
                p.addLine(to: cur)
            case UInt8(ascii: "c"):
                guard let x1 = s.number(), let y1 = s.number(), let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { return p }
                let c1 = at(x1, y1), c2 = at(x2, y2), end = at(x, y)
                p.addCurve(to: end, control1: c1, control2: c2)
                cur = end; control = c2; cubic = true
            case UInt8(ascii: "s"):
                guard let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { return p }
                let c1 = lastWasCubic ? reflect(lastControl, about: cur) : cur
                let c2 = at(x2, y2), end = at(x, y)
                p.addCurve(to: end, control1: c1, control2: c2)
                cur = end; control = c2; cubic = true
            case UInt8(ascii: "q"):
                guard let x1 = s.number(), let y1 = s.number(), let x = s.number(), let y = s.number() else { return p }
                let c = at(x1, y1), end = at(x, y)
                p.addQuadCurve(to: end, control: c)
                cur = end; control = c
            case UInt8(ascii: "t"):
                guard let x = s.number(), let y = s.number() else { return p }
                let c = lastWasCubic ? cur : reflect(lastControl, about: cur)
                let end = at(x, y)
                p.addQuadCurve(to: end, control: c)
                cur = end; control = c
            case UInt8(ascii: "a"):
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(), let large = s.flag(), let sweep = s.flag(), let x = s.number(), let y = s.number() else { return p }
                let end = at(x, y)
                arc(&p, from: cur, to: end, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = end
            default:
                return p
            }
            lastControl = control
            lastWasCubic = cubic
        }
        return p
    }

    private static func reflect(_ c: CGPoint?, about p: CGPoint) -> CGPoint {
        guard let c else { return p }
        return CGPoint(x: 2 * p.x - c.x, y: 2 * p.y - c.y)
    }

    /// An elliptical arc as cubic curves (SVG 1.1 implementation notes, F.6.5).
    private static func arc(_ p: inout Path, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { p.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let k = (large == sweep ? -1 : 1) * sqrt(max(0, num / den))
        let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2, cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        let angle = { (ux: CGFloat, uy: CGFloat, vx: CGFloat, vy: CGFloat) -> CGFloat in
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let pieces = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(pieces), t = 4 / 3 * tan(step / 4)
        let point = { (a: CGFloat) in CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP) }
        let tangent = { (a: CGFloat) in CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP) }
        for i in 0..<pieces {
            let a0 = theta + CGFloat(i) * step, a1 = a0 + step
            let s = point(a0), e = point(a1), d0 = tangent(a0), d1 = tangent(a1)
            p.addCurve(to: e, control1: CGPoint(x: s.x + t * d0.x, y: s.y + t * d0.y), control2: CGPoint(x: e.x - t * d1.x, y: e.y - t * d1.y))
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var i = 0

        var atEnd: Bool { mutating get { skip(); return i >= bytes.count } }

        private mutating func skip() {
            while i < bytes.count, bytes[i] == 32 || bytes[i] == 44 || bytes[i] == 10 || bytes[i] == 13 || bytes[i] == 9 { i += 1 }
        }

        mutating func command() -> UInt8? {
            skip()
            guard i < bytes.count else { return nil }
            let c = bytes[i] | 0x20
            guard c >= 97, c <= 122, c != 101 else { return nil }   // a letter, but not an exponent's e
            defer { i += 1 }
            return bytes[i]
        }

        /// One number; SVG lets them run together ("1.5.5", "10-4").
        mutating func number() -> CGFloat? {
            skip()
            let from = i
            if i < bytes.count, bytes[i] == 43 || bytes[i] == 45 { i += 1 }
            var dot = false
            while i < bytes.count {
                let c = bytes[i]
                if c >= 48 && c <= 57 { i += 1 }
                else if c == 46 && !dot { dot = true; i += 1 }
                else if (c == 101 || c == 69), i + 1 < bytes.count, (bytes[i + 1] >= 48 && bytes[i + 1] <= 57) || bytes[i + 1] == 45 || bytes[i + 1] == 43 { i += 2 }
                else { break }
            }
            guard i > from, let v = Double(String(decoding: bytes[from..<i], as: UTF8.self)) else { return nil }
            return CGFloat(v)
        }

        /// An arc's 0 or 1, which may be written with no space after it.
        mutating func flag() -> Bool? {
            skip()
            guard i < bytes.count, bytes[i] == 48 || bytes[i] == 49 else { return nil }
            defer { i += 1 }
            return bytes[i] == 49
        }
    }
}
