import Charts
import HexplateCore
import SwiftUI

// The workout as a list of today's exercises, each opening a card (MyGym's workout redesign):
// the list's header shows how far the session is and what it trains; a card holds the exercise
// itself, its numbers today and its record so far, and swiping across cards moves between
// exercises, taking the watch's next set along.

// MARK: - The list's header

/// How far the session is (sets done of planned), what it moved and burned, and which muscles it
/// trains, darker for more of today's sets.
struct WorkoutHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = model.activeEntries
        let p = ExerciseRecords.progress(entries)
        let unit = model.settings.unit
        let volume = entries.reduce(0) { $0 + ExerciseRecords.metrics([$1]).session }
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(p.total > 0 ? "\(Int((Double(p.done) / Double(p.total) * 100).rounded()))%" : "–")
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    Text("done").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if let start = model.active?["start"]?.numberValue, !model.isPastSession {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Label(Format.seconds(Date.now.timeIntervalSince1970 - start / 1000), systemImage: "timer")
                                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .tint(Theme.accent)
                    .accessibilityLabel("Sets done")
                    .accessibilityValue(tr("{0} of {1}", p.done, p.total))
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    stat("Lifted", Text(verbatim: "\(Format.number(volume)) \(unit)"))
                    stat("Calories", calories)
                    stat("Sets done", Text(verbatim: "\(p.done) / \(p.total)"))
                }
                Spacer(minLength: 8)
                let levels = ExerciseRecords.sessionMuscles(entries, catalog: model.catalog)
                HStack(spacing: 2) {
                    BodyMap(side: .front, levels: levels, female: model.root["body"] == .string("female"))
                    BodyMap(side: .back, levels: levels, female: model.root["body"] == .string("female"))
                }
                .frame(width: 132, height: 136)
                .accessibilityElement()
                .accessibilityLabel(muscleSummary(levels))
            }
        }
        .padding(.vertical, 6)
    }

    private func stat(_ title: LocalizedStringKey, _ value: Text) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            value.font(.headline).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// The watch's active calories when it sends them; else an estimate from the time so far and
    /// your weight. ponytail: MET 5 for weight training, about what Apple Health counts for it.
    private var calories: Text {
        if let k = model.watchKcal, k.wid == model.active?["id"]?.stringValue {
            return Text(verbatim: "\(Int(k.kcal)) kcal")
        }
        guard let start = model.active?["start"]?.numberValue, !model.isPastSession else { return Text(verbatim: "–") }
        let kg = BodyData.weights(model.root).last.map { model.settings.unit == "lb" ? $0.weight * 0.4536 : $0.weight } ?? 70
        let hours = max(0, Date.now.timeIntervalSince1970 - start / 1000) / 3600
        return Text(verbatim: "≈ \(Int((5 * kg * hours).rounded())) kcal")
    }

    private func muscleSummary(_ levels: [String: Double]) -> String {
        let names = levels.sorted { $0.value > $1.value }.prefix(4).map { model.catalog.muscleName($0.key) }
        return names.isEmpty ? String(localized: "No muscles yet") : tr("Trains most: {0}", names.joined(separator: ", "))
    }
}

// MARK: - A row of the list

/// One exercise of today in the workout list: its picture, name and plan, how many sets are done, and its ⋯ menu.
/// Tapping the row opens its card.
struct WorkoutEntryRow: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let entry: AppModel.Object
    let open: () -> Void
    let onAction: (EntryAction) -> Void

    var body: some View {
        let id = entry["id"]?.stringValue ?? ""
        let work = (entry["sets"]?.arrayValue ?? []).filter { !Session.isWarmup($0) }
        let done = work.filter(Session.hasCompletedWork).count
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 12) {
                    ExerciseThumb(id: id)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.catalog[id]?.displayName ?? id).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        HStack(spacing: 6) {
                            if let sg = entry["sg"]?.stringValue, !sg.isEmpty {
                                Text("Superset").font(.caption.bold()).foregroundStyle(Theme.superset)
                            }
                            Text(verbatim: plan(work)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if !work.isEmpty && done == work.count {
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.tint)
                            .accessibilityLabel("All sets done")
                    } else if done > 0 {
                        Text(verbatim: "\(done)/\(work.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens the exercise"))
            EntryMenu(index: index, entry: entry, onAction: onAction)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    /// "3 sets · 60 kg × 8", "3 sets · 45 s", from the next set still to do (else the last).
    private func plan(_ work: [JSONValue]) -> String {
        guard let row = (work.first { !Session.hasCompletedWork($0) } ?? work.last)?.object else { return "" }
        let sets = tr(work.count == 1 ? "{0} set" : "{0} sets", work.count)
        let w = row["w"]?.numberValue ?? 0, r = row["r"]?.numberValue ?? 0
        if let sec = row["sec"]?.numberValue, sec > 0 { return "\(sets) · \(Int(sec)) s" }
        if let min = row["min"]?.numberValue, min > 0 { return "\(sets) · \(Format.number(min)) min" }
        return w > 0 ? "\(sets) · \(Format.number(w)) \(model.settings.unit) × \(Int(r))" : r > 0 ? "\(sets) · × \(Int(r))" : sets
    }
}

// MARK: - The cards

/// The exercise cards, one per entry, swiped across like pages; the watch's next set follows the
/// card on screen.
struct ExerciseCards: View {
    @Environment(AppModel.self) private var model
    @Environment(RestTimer.self) private var timer
    @State private var index: Int
    let onAction: (EntryAction) -> Void

    init(start: Int, onAction: @escaping (EntryAction) -> Void) {
        _index = State(initialValue: start)
        self.onAction = onAction
    }

    var body: some View {
        let entries = model.activeEntries
        TabView(selection: $index) {
            ForEach(entries.indices, id: \.self) { i in
                ExerciseCard(index: i, entry: entries[i], next: supersetNext(after: i, in: entries), onAction: onAction)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(verbatim: entries.indices.contains(index) ? (entries[index]["id"]?.stringValue).map { model.catalog[$0]?.displayName ?? $0 } ?? "" : "")
                        .font(.headline).lineLimit(1)
                    Text(tr("{0} of {1}", index + 1, entries.count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if entries.indices.contains(index) {
                ToolbarItem(placement: .topBarTrailing) { EntryMenu(index: index, entry: entries[index], onAction: onAction) }
            }
        }
        .safeAreaInset(edge: .bottom) { if timer.end != nil { RestBar() } else { WatchStartBar(card: index) } }
        .onAppear { follow(index) }
        .onChange(of: index) { _, i in follow(i) }
    }

    /// The watch's next set comes from the card on screen (`cur`), unless it is recording one.
    private func follow(_ i: Int) {
        guard model.watchRecording == nil, model.activeEntries.indices.contains(i),
              model.active?["cur"]?.numberValue != Double(i) else { return }
        model.changeActive { $0["cur"] = .number(Double(i)) }
    }
}

/// One exercise: its picture and sets (EntrySection), today's numbers, its record so far and its
/// last sessions.
private struct ExerciseCard: View {
    let index: Int
    let entry: AppModel.Object
    let next: Int?
    let onAction: (EntryAction) -> Void

    var body: some View {
        List {
            EntrySection(index: index, entry: entry, next: next, card: true, onAction: onAction)
            ExerciseRecordSections(id: entry["id"]?.stringValue ?? "", entry: entry)
        }
        .listSectionSpacing(.compact)
        .keyboardDone()
    }
}

// MARK: - Records

/// Today's four numbers against the best before, a chart of one of them over a chosen time, and
/// the last fourteen sessions.
private struct ExerciseRecordSections: View {
    @Environment(AppModel.self) private var model
    let id: String
    let entry: AppModel.Object
    @State private var metric = Metric.oneRM
    @State private var span = Span.months3

    enum Metric: String, CaseIterable, Identifiable {
        case heaviest, oneRM, bestSet, session
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .heaviest: "Heaviest weight"
            case .oneRM: "Best 1RM"
            case .bestSet: "Best set volume"
            case .session: "Session volume"
            }
        }
        var short: LocalizedStringKey {
            switch self {
            case .heaviest: "Weight"
            case .oneRM: "1RM"
            case .bestSet: "Set vol."
            case .session: "Session vol."
            }
        }
        func value(_ m: ExerciseRecords.Metrics) -> Double {
            switch self {
            case .heaviest: m.heaviest
            case .oneRM: m.best1RM
            case .bestSet: m.bestSet
            case .session: m.session
            }
        }
    }

    enum Span: String, CaseIterable, Identifiable {
        case month, months3, months6, year, all
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .month: "1M"
            case .months3: "3M"
            case .months6: "6M"
            case .year: "1Y"
            case .all: "All"
            }
        }
        var days: Int? { switch self { case .month: 31; case .months3: 92; case .months6: 183; case .year: 366; case .all: nil } }
    }

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let today: Bool
    }

    var body: some View {
        let formula = Stats.formula(model.root)
        let unit = model.settings.unit
        let now = ExerciseRecords.metrics([entry], formula: formula)
        let past = ExerciseRecords.history(model.root, exerciseId: id, formula: formula)
        let best = { (m: Metric) in past.map { m.value($0.metrics) }.max() ?? 0 }

        Section {
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow { tile(.heaviest, now, best(.heaviest), unit); tile(.oneRM, now, best(.oneRM), unit) }
                GridRow { tile(.bestSet, now, best(.bestSet), unit); tile(.session, now, best(.session), unit) }
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .listRowBackground(Color.clear)
        } header: {
            Text("This session’s numbers")
        }

        Section {
            let points = chartPoints(past, now)
            VStack(alignment: .leading, spacing: 12) {
                Picker("Number", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.short).tag($0) }
                }
                .pickerStyle(.segmented)
                if let top = points.max(by: { $0.value < $1.value }) {
                    Text(tr("Best {0} on {1} · {2} sessions", "\(Format.number(top.value)) \(unit)",
                            top.date.formatted(.dateTime.day().month().locale(Theme.locale)), points.count))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                chart(points, unit: unit)
                Picker("Time", selection: $span) {
                    ForEach(Span.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Records so far")
        }

        Section {
            if past.isEmpty {
                Text("No earlier sessions yet.").foregroundStyle(.secondary)
            }
            ForEach(past.suffix(14).reversed(), id: \.workoutId) { s in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Day.date(s.day)?.formatted(.dateTime.weekday(.abbreviated).day().month().locale(Theme.locale)) ?? s.day)
                            .font(.subheadline)
                        Text(verbatim: s.metrics.top.map { "\(Format.number($0.w)) \(unit) × \(Int($0.r))" } ?? "–")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: s.metrics.best1RM > 0 ? "1RM \(Format.number(s.metrics.best1RM))" : "–").font(.subheadline).monospacedDigit()
                        Text(verbatim: "\(Format.number(s.metrics.session)) \(unit)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Last 14 sessions")
        }
    }

    /// A number today against the best before: a record shows as one.
    private func tile(_ m: Metric, _ now: ExerciseRecords.Metrics, _ best: Double, _ unit: String) -> some View {
        let v = m.value(now)
        let record = v > 0 && v > best
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(m.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if record {
                    Text("PR").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.18), in: .capsule).foregroundStyle(Theme.accent)
                }
            }
            Text(verbatim: v > 0 ? Format.number(v) : "–").font(.title2.weight(.semibold)).monospacedDigit()
                + Text(verbatim: v > 0 ? " \(unit)" : "").font(.subheadline).foregroundStyle(.secondary)
            Text(best > 0 ? tr("Best before {0}", "\(Format.number(best)) \(unit)") : String(localized: "First time"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private func chartPoints(_ past: [ExerciseRecords.Session], _ now: ExerciseRecords.Metrics) -> [Point] {
        let cutoff = span.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: .now) }
        var out = past.compactMap { s -> Point? in
            guard let d = Day.date(s.day), cutoff.map({ d >= $0 }) ?? true, metric.value(s.metrics) > 0 else { return nil }
            return Point(id: s.workoutId, date: d, value: metric.value(s.metrics), today: false)
        }
        if metric.value(now) > 0 { out.append(Point(id: "today", date: .now, value: metric.value(now), today: true)) }
        return out
    }

    /// One series: a 2 pt line through the sessions, today's point in the accent colour.
    @ViewBuilder
    private func chart(_ points: [Point], unit: String) -> some View {
        if points.count < 2 {
            Text(points.isEmpty ? "No sessions in this time." : "One session so far.")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Chart(points) { p in
                LineMark(x: .value("Date", p.date), y: .value("Value", p.value))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Theme.accent.opacity(0.75))
                PointMark(x: .value("Date", p.date), y: .value("Value", p.value))
                    .symbolSize(p.today ? 70 : 28)
                    .foregroundStyle(p.today ? Theme.accent : Theme.accent.opacity(0.75))
                    .accessibilityLabel(p.today ? Text("Today") : Text(p.date, format: .dateTime.day().month()))
                    .accessibilityValue(Text(verbatim: "\(Format.number(p.value)) \(unit)"))
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel(format: .dateTime.day().month()) } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
            .frame(height: 170)
        }
    }
}
