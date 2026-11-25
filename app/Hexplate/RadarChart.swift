import HexplateCore
import SwiftUI

/// Apple-plain SwiftUI Path 6-axis radar chart (grey rings, single Theme.accent polygon, VoiceOver summary).
struct RadarChart: View {
    let axes: [Stats.RadarAxis]

    @ScaledMetric(relativeTo: .caption) private var horizontalGutter: CGFloat = 58
    @ScaledMetric(relativeTo: .caption) private var verticalGutter: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 216

    private let ringScales: [CGFloat] = [0.25, 0.5, 0.75, 1.0]

    private var hasData: Bool { axes.contains { $0.pct > 0 } }

    private var accessibilitySummary: String {
        guard hasData else { return tr("No sets in the last 4 weeks") }
        return axes.map { "\(tr($0.id)) \(Format.number($0.pct, decimals: 0))%" }.joined(separator: ", ")
    }

    var body: some View {
        if axes.count >= 3 {
            GeometryReader { geo in
                let hGutter = min(horizontalGutter, geo.size.width * 0.34)
                let vGutter = min(verticalGutter, geo.size.height * 0.28)
                let radius = max(16, min((geo.size.width - hGutter * 2) / 2, (geo.size.height - vGutter * 2) / 2))
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

                ZStack {
                    ForEach(ringScales, id: \.self) { scale in
                        polygonPath(center: center, radius: radius * scale, count: axes.count)
                            .stroke(Color.secondary.opacity(0.24), lineWidth: 1)
                    }

                    spokesPath(center: center, radius: radius, count: axes.count)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)

                    if hasData {
                        let dataPath = valuePath(center: center, radius: radius)
                        dataPath.fill(Theme.accent.opacity(0.22))
                        dataPath.stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                        ForEach(Array(axes.enumerated()), id: \.element.id) { index, axis in
                            if axis.pct > 0 {
                                let p = point(center: center, radius: radius * clampedRatio(axis.pct), index: index, count: axes.count)
                                Circle()
                                    .fill(Theme.accent)
                                    .frame(width: 5, height: 5)
                                    .position(p)
                            }
                        }
                    } else {
                        Text("No sets in the last 4 weeks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: max(80, radius * 1.8))
                            .position(center)
                    }

                    ForEach(Array(axes.enumerated()), id: \.element.id) { index, axis in
                        axisLabel(axis: axis, index: index, center: center, radius: radius, size: geo.size)
                    }
                }
            }
            .frame(height: min(chartHeight, 244))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("4-week training balance"))
            .accessibilityValue(accessibilitySummary)
        }
    }

    private func clampedRatio(_ pct: Double) -> CGFloat {
        CGFloat(min(1.0, max(0.0, pct / 100.0)))
    }

    private func angle(index: Int, count: Int) -> Double {
        -.pi / 2 + Double(index) * (2 * .pi / Double(count))
    }

    private func point(center: CGPoint, radius: CGFloat, index: Int, count: Int) -> CGPoint {
        let a = angle(index: index, count: count)
        return CGPoint(x: center.x + CGFloat(cos(a)) * radius, y: center.y + CGFloat(sin(a)) * radius)
    }

    private func polygonPath(center: CGPoint, radius: CGFloat, count: Int) -> Path {
        Path { path in
            for i in 0..<count {
                let p = point(center: center, radius: radius, index: i, count: count)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }
    }

    private func spokesPath(center: CGPoint, radius: CGFloat, count: Int) -> Path {
        Path { path in
            for i in 0..<count {
                path.move(to: center)
                path.addLine(to: point(center: center, radius: radius, index: i, count: count))
            }
        }
    }

    private func valuePath(center: CGPoint, radius: CGFloat) -> Path {
        Path { path in
            for (i, axis) in axes.enumerated() {
                let p = point(center: center, radius: radius * clampedRatio(axis.pct), index: i, count: axes.count)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }
    }

    @ViewBuilder
    private func axisLabel(axis: Stats.RadarAxis, index: Int, center: CGPoint, radius: CGFloat, size: CGSize) -> some View {
        let a = angle(index: index, count: axes.count)
        let cosA = cos(a)
        let sinA = sin(a)
        let vertex = point(center: center, radius: radius, index: index, count: axes.count)
        let label = Text(LocalizedStringKey(axis.id))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)

        if abs(cosA) < 0.05 {
            if sinA < 0 {
                // Top vertex: strictly inside [0, vertex.y - 4], bottom-aligned above the ring.
                let boxHeight = max(12, vertex.y - 4)
                label
                    .frame(width: size.width * 0.6, height: boxHeight, alignment: .bottom)
                    .position(x: center.x, y: boxHeight / 2)
            } else {
                // Bottom vertex: strictly inside [vertex.y + 4, size.height], top-aligned below the ring.
                let topY = vertex.y + 4
                let boxHeight = max(12, size.height - topY)
                label
                    .frame(width: size.width * 0.6, height: boxHeight, alignment: .top)
                    .position(x: center.x, y: topY + boxHeight / 2)
            }
        } else if cosA > 0 {
            // Right-side vertices: bounded within [vertex.x + 6, size.width].
            let leftX = vertex.x + 6
            let boxWidth = max(20, size.width - leftX)
            label
                .frame(width: boxWidth, alignment: .leading)
                .position(x: leftX + boxWidth / 2, y: vertex.y)
        } else {
            // Left-side vertices: bounded within [0, vertex.x - 6].
            let boxWidth = max(20, vertex.x - 6)
            label
                .frame(width: boxWidth, alignment: .trailing)
                .position(x: boxWidth / 2, y: vertex.y)
        }
    }
}
