import Charts
import HexplateCore
import PDFKit
import SwiftUI

/// "Performance report (PDF)" (openGym ReportSheet + lib/report-print.js): pick a stretch of days,
/// get its totals, charts, new bests and every set on A4. Opened from Stats and Settings → Data.
struct ReportView: View {
    @Environment(AppModel.self) private var model
    @State private var range = "4w"
    @State private var from = Calendar.current.date(byAdding: .day, value: -27, to: .now) ?? .now
    @State private var to = Date.now
    @State private var pdf: URL?

    var body: some View {
        let r = Report.range(range, from: Day.iso(from), to: Day.iso(to), today: model.today)
        let n = Report.inRange(model.root, r).count
        Form {
            Section {
                Picker("Days", selection: $range) {
                    Text("7 days").tag("7d")
                    Text("4 weeks").tag("4w")
                    Text("3 months").tag("3m")
                    Text("Custom").tag("custom")
                }
                .pickerStyle(.segmented)
                if range == "custom" {
                    DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
                    DatePicker("To", selection: $to, in: from...Date.now, displayedComponents: .date)
                }
            } footer: {
                Text("Your training on paper: totals, charts, new bests and every set. Print it or send it to your coach.")
            }
            Section {
                Button("Create PDF", systemImage: "doc.richtext") {
                    let data = Report.data(model.root, catalog: model.catalog, kind: range, from: Day.iso(from), to: Day.iso(to), today: model.today)
                    pdf = ReportPDF.write(data, model: model)
                }
            } footer: {
                Text(verbatim: ReportPDF.span(r) + " · " + WrappedCards.plural("{0} workout", "{0} workouts", Double(n), n))
            }
        }
        .navigationTitle("Performance report")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { pdf != nil }, set: { if !$0 { pdf = nil } })) {
            if let pdf {
                NavigationStack {
                    PDFPreview(url: pdf)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Performance report")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Done") { self.pdf = nil } }
                            ToolbarItem(placement: .primaryAction) { ShareLink(item: pdf) }
                        }
                }
            }
        }
    }
}

private struct PDFPreview: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(url: url)
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {}
}

/// Draws a report on A4 pages: each block stays whole on a page, a section's heading travels with
/// its first block. ponytail: a single block taller than a page runs off it; every block here is
/// one workout, one chart or a short table, so none comes near.
@MainActor
enum ReportPDF {
    static let page = CGSize(width: 595, height: 842), margin: CGFloat = 40

    static func day(_ iso: String, year: Bool = true) -> String {
        guard let d = Day.date(iso) else { return iso }
        return year ? d.formatted(.dateTime.day().month(.abbreviated).year().locale(Theme.locale))
            : d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Theme.locale))
    }

    static func span(_ r: Report.Range) -> String { r.from == r.to ? day(r.from) : day(r.from) + " – " + day(r.to) }

    static func write(_ r: Report.Data, model: AppModel) -> URL? {
        let url = URL.temporaryDirectory.appending(path: "hexplate-report-\(r.range.from)-\(r.range.to).pdf")
        var box = CGRect(origin: .zero, size: page)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        let width = page.width - 2 * margin
        var y = margin, number = 0

        func draw<V: View>(_ v: V, _ place: (CGSize) -> CGPoint) {
            let renderer = ImageRenderer(content: v.frame(width: width, alignment: .leading).environment(\.colorScheme, .light).environment(\.locale, Theme.locale))
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            renderer.render { size, render in
                let at = place(size)
                ctx.saveGState()
                ctx.translateBy(x: margin, y: page.height - at.y - size.height)
                render(ctx)
                ctx.restoreGState()
            }
        }
        func endPage() {
            draw(Text(verbatim: "Hexplate · \(number)").font(.system(size: 7)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)) { _ in
                CGPoint(x: 0, y: page.height - margin + 14)
            }
            ctx.endPDFPage()
        }
        func newPage() {
            if number > 0 { endPage() }
            ctx.beginPDFPage(nil)
            number += 1
            y = margin
        }

        newPage()
        for block in ReportBlocks(r: r, model: model).all {
            draw(block) { size in
                if y + size.height > page.height - margin && y > margin { newPage() }
                defer { y += size.height + 16 }
                return CGPoint(x: 0, y: y)
            }
        }
        endPage()
        ctx.closePDF()
        return url
    }
}

/// The report's parts, top to bottom (report-print.js reportPrintHTML).
@MainActor
private struct ReportBlocks {
    let r: Report.Data
    let model: AppModel
    var unit: String { model.settings.unit }
    var accent: Color { Theme.paperAccent }

    func name(_ id: String) -> String { model.catalog[id]?.displayName ?? id }
    func num(_ v: Double, _ d: Int = 1) -> String { Format.number(v, decimals: d) }
    func compact(_ v: Double) -> String { v >= 10000 ? num((v / 100).rounded() / 10) + "k" : num(v.rounded(), 0) }
    func signed(_ v: Double) -> String { (v > 0 ? "+" : v < 0 ? "−" : "±") + num(abs(v)) }

    var all: [AnyView] {
        var out: [AnyView] = [AnyView(header), AnyView(summary)]
        if r.totals.workouts > 0 {
            out.append(AnyView(section(r.bucketUnit == "day" ? "Volume per day" : r.bucketUnit == "week" ? "Volume per week" : "Volume per month") { volume }))
            out.append(AnyView(section("Consistency") { consistency }))
            out.append(AnyView(section("Sets per muscle") { muscles }))
            for (i, pair) in stride(from: 0, to: r.lifts.count, by: 2).map({ Array(r.lifts[$0..<min($0 + 2, r.lifts.count)]) }).enumerated() {
                let row = HStack(alignment: .top, spacing: 16) { ForEach(pair, id: \.id) { lift($0) } }
                out.append(i == 0 ? AnyView(section("Estimated 1RM") { row }) : AnyView(row))
            }
        }
        if r.bodyweight.count > 1 { out.append(AnyView(section("Body weight") { bodyweight })) }
        if !r.prs.isEmpty {
            for (i, chunk) in stride(from: 0, to: r.prs.count, by: 12).map({ Array(r.prs[$0..<min($0 + 12, r.prs.count)]) }).enumerated() {
                out.append(i == 0 ? AnyView(section("New bests") { prs(chunk) }) : AnyView(prs(chunk)))
            }
        }
        for (i, w) in r.workouts.enumerated() {
            out.append(i == 0 ? AnyView(section("Every workout") { workout(w) }) : AnyView(workout(w)))
        }
        return out
    }

    func section<V: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Performance report").font(.system(size: 22, weight: .bold))
            Text(verbatim: ReportPDF.span(r.range)).font(.system(size: 11)).foregroundStyle(.secondary)
            Rectangle().fill(accent).frame(height: 2).padding(.top, 6)
        }
    }

    // MARK: Totals

    var summary: some View {
        let t = r.totals, p = r.prev
        let dur = { (ms: Double) in Format.duration(milliseconds: max(60000, ms)) ?? "–" }
        let cards: [(LocalizedStringKey, String, String?)] = [
            ("Workouts", num(Double(t.workouts), 0), delta(Double(t.workouts), Double(p.workouts)) { num($0, 0) }),
            ("Volume", compact(t.volume) + " " + unit, delta(t.volume, p.volume) { compact($0) + " " + unit }),
            ("Work sets", num(Double(t.sets), 0), delta(Double(t.sets), Double(p.sets)) { num($0, 0) }),
            ("Training time", t.ms >= 60000 ? dur(t.ms) : "–", delta(t.ms, p.ms, dur)),
            ("New bests", num(Double(t.prs), 0), delta(Double(t.prs), Double(p.prs)) { num($0, 0) }),
            ("Body weight", t.bwChange.map { signed($0) + " " + unit } ?? t.bwEnd.map { num($0) + " " + unit } ?? "–",
             t.bwChange != nil ? "\(num(t.bwStart!)) → \(num(t.bwEnd!)) \(unit)" : nil),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<2) { row in
                    GridRow {
                        ForEach(0..<3) { col in
                            let c = cards[row * 3 + col]
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.0).font(.system(size: 8)).foregroundStyle(.secondary)
                                Text(verbatim: c.1).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                                Text(verbatim: c.2 ?? " ").font(.system(size: 8)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(white: 0.95), in: .rect(cornerRadius: 6))
                        }
                    }
                }
            }
            if [(Double(t.workouts), Double(p.workouts)), (t.volume, p.volume), (Double(t.sets), Double(p.sets)), (t.ms, p.ms)].contains(where: { $0.0 > 0 || $0.1 > 0 }) {
                Text("Arrows compare with the \(r.range.days) days before.").font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
    }

    /// "▲ +3 · 33%": the change against the stretch before; nil when both are empty (report-print.js delta).
    func delta(_ now: Double, _ before: Double, _ fmt: (Double) -> String) -> String? {
        guard now > 0 || before > 0 else { return nil }
        let d = now - before
        if d == 0 { return "± 0" }
        let pct = before > 0 ? " · \(num((abs(d) / before * 100).rounded(), 0))%" : ""
        return (d > 0 ? "▲ +" : "▼ −") + fmt(abs(d)) + pct
    }

    // MARK: Charts

    func bucketLabel(_ b: Report.Bucket) -> String {
        guard let d = Day.date(b.from) else { return b.from }
        switch r.bucketUnit {
        case "day": return d.formatted(.dateTime.weekday(.abbreviated).locale(Theme.locale))
        case "month": return d.formatted(.dateTime.month(.abbreviated).locale(Theme.locale))
        default: return d.formatted(.dateTime.day().month(.defaultDigits).locale(Theme.locale))
        }
    }

    var volume: some View {
        let last = r.buckets.last?.key
        return VStack(alignment: .leading, spacing: 4) {
            Chart(r.buckets, id: \.key) { b in
                BarMark(x: .value("Period", bucketLabel(b)), y: .value("Volume", b.volume), width: .ratio(0.6))
                    .foregroundStyle(b.key == last ? accent : Color(white: 0.72))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Color(white: 0.88))
                AxisValueLabel { Text(verbatim: compact(v.as(Double.self) ?? 0)).font(.system(size: 7)) }
            } }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 7)) } }
            .frame(height: 130)
            Text("\(unit) · Work sets only, warm-ups left out.").font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }

    var consistency: some View {
        let lead = r.calendar.first.flatMap { Day.date($0.d) }.map { (Calendar(identifier: .gregorian).component(.weekday, from: $0) - 1 - r.weekStart + 7) % 7 } ?? 0
        let cells: [Report.CalendarDay?] = Array(repeating: nil, count: lead) + r.calendar.map { $0 }
        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
        let shade = { (l: Int) in l == 0 ? Color(white: 0.9) : accent.opacity([0, 0.3, 0.5, 0.75, 1][l]) }
        let s = r.streak
        return HStack(alignment: .top, spacing: 24) {
            // Weeks as columns, the profile's first weekday on top.
            HStack(alignment: .top, spacing: 3) {
                ForEach(weeks.indices, id: \.self) { i in
                    VStack(spacing: 3) {
                        ForEach(0..<7) { j in
                            let c = j < weeks[i].count ? weeks[i][j] : nil
                            RoundedRectangle(cornerRadius: 2).fill(c.map { shade($0.level) } ?? .clear).frame(width: 10, height: 10)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                fact("Active days", "\(s.activeDays) / \(r.range.days)")
                fact("Workouts per week", num(r.perWeek))
                fact("Most days in a row", "\(s.longestDays)")
                fact("Week streak", "\(s.weeks ?? s.longestWeeks)")
            }
            .font(.system(size: 9))
        }
    }

    func fact(_ k: LocalizedStringKey, _ v: String) -> some View {
        HStack(spacing: 4) { Text(k).foregroundStyle(.secondary); Text(verbatim: v).bold() }
    }

    var muscles: some View {
        let list = r.worked.prefix(18), top = r.worked.first?.sets ?? 1
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(list.enumerated()), id: \.element.slug) { i, m in
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(model.catalog.muscleName(m.slug))).frame(width: 110, alignment: .leading)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 2).fill(i == 0 ? accent : Color(white: 0.72))
                            .frame(width: max(2, g.size.width * m.sets / top), height: 6).frame(maxHeight: .infinity)
                    }
                    Text(verbatim: m.sets >= 0.5 ? num(m.sets.rounded(), 0) : "<1").monospacedDigit().frame(width: 30, alignment: .trailing)
                }
                .frame(height: 12)
            }
            if !r.missed.isEmpty {
                Text("Not trained:") + Text(verbatim: " " + r.missed.map { String(localized: String.LocalizationValue(model.catalog.muscleName($0))) }.joined(separator: ", "))
            }
            Text("Effective sets: a set counts fully for its main muscle and partly for the ones that help.").foregroundStyle(.secondary)
        }
        .font(.system(size: 9))
    }

    func lift(_ l: Report.Lift) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: name(l.id)).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            Text(verbatim: [l.change.map { signed($0) + " " + unit }, l.best.map { String(localized: "Best:") + " " + num($0.estimate) + " " + unit }]
                .compactMap { $0 }.joined(separator: " · ")).font(.system(size: 8)).foregroundStyle(.secondary)
            if l.points.count > 1 {
                line(l.points.map { ($0.day, $0.estimate) }, best: l.best?.estimate).frame(height: 90)
            } else {
                Text("One session in this period.").font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One thin line over the range's days, the best point marked.
    func line(_ pts: [(d: String, y: Double)], best: Double?) -> some View {
        let start = Day.date(r.range.from) ?? .now, end = Day.date(r.range.to) ?? .now
        let lo = pts.map(\.y).min() ?? 0, hi = pts.map(\.y).max() ?? 1, pad = max(1, (hi - lo) * 0.15)
        return VStack(spacing: 2) { Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Day", Day.date(p.d) ?? start), y: .value("Value", p.y)).foregroundStyle(accent).lineStyle(StrokeStyle(lineWidth: 1.5))
                if p.y == best {
                    PointMark(x: .value("Day", Day.date(p.d) ?? start), y: .value("Value", p.y)).foregroundStyle(accent).symbolSize(24)
                }
            }
        }
        .chartXScale(domain: start...max(end, start.addingTimeInterval(86400)))
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
            AxisGridLine().foregroundStyle(Color(white: 0.88))
            AxisValueLabel { Text(verbatim: num(v.as(Double.self) ?? 0, 0)).font(.system(size: 7)) }
        } }
        .chartXAxis(.hidden)
            // The range's two ends under the plot (Charts drops a label sitting on the last edge).
            HStack {
                Text(start, format: .dateTime.day().month(.abbreviated)); Spacer(); Text(end, format: .dateTime.day().month(.abbreviated))
            }
            .font(.system(size: 7)).foregroundStyle(.secondary).padding(.leading, 24)
        }
    }

    var bodyweight: some View {
        line(r.bodyweight.map { ($0.d, $0.w) }, best: nil).frame(height: 110)
    }

    // MARK: Lists

    func prs(_ list: [Report.Record]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Date"); Text("Exercise")
                Text("Best set").gridColumnAlignment(.trailing); Text("Est. 1RM").gridColumnAlignment(.trailing)
            }
            .foregroundStyle(.secondary)
            ForEach(Array(list.enumerated()), id: \.offset) { _, p in
                GridRow {
                    Text(verbatim: ReportPDF.day(p.d, year: false))
                    Text(verbatim: name(p.id)).lineLimit(1)
                    Text(verbatim: p.best.map { "\(num($0.weight)) \(unit) × \(Int($0.reps))" } ?? "–")
                    Text(verbatim: p.best.map { num($0.estimate) + " " + unit } ?? "–")
                }
            }
        }
        .font(.system(size: 9))
        .monospacedDigit()
    }

    func workout(_ raw: [String: JSONValue]) -> some View {
        let history = model.history
        let w = try? JSONValue.object(raw).decoded(as: Workout.self)
        let prs = Set((raw["prs"]?.arrayValue ?? []).compactMap(\.stringValue))
        let facts = [w.flatMap { history?.durationText($0) }, w.flatMap { history?.volumeText($0) }].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: ReportPDF.day(raw["d"]?.stringValue ?? "", year: false)).bold()
                Text(verbatim: raw["name"]?.stringValue ?? "")
                Spacer()
                Text(verbatim: facts.joined(separator: " · ")).foregroundStyle(.secondary)
            }
            .font(.system(size: 10))
            ForEach(Array((w?.entries ?? []).enumerated()), id: \.offset) { _, e in
                let rows = history?.rows(of: e) ?? []
                if !rows.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: (prs.contains(e.exerciseId) ? "★ " : "") + (history?.name(of: e) ?? e.exerciseId))
                            .font(.system(size: 9, weight: .medium)).frame(width: 150, alignment: .leading)
                        Text(verbatim: rows.map { ($0.isWarmup ? "W " : "") + $0.label }.joined(separator: "  ·  "))
                            .font(.system(size: 9)).foregroundStyle(Color(white: 0.3))
                    }
                }
            }
            Divider()
        }
    }
}
