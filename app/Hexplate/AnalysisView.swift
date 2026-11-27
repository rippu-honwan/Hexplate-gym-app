import HexplateCore
import SwiftUI

/// The Analysis tab: AI Coach with persistent LIFO Undo banner, interactive Front/Back muscle
/// fatigue BodyMap with recovery detail sheet, and the existing StatsContent sections.
struct AnalysisView: View {
    private enum AnalysisSheet: Identifiable {
        case coach
        case muscle(String)
        case stats(StatsSheet)

        var id: String {
            switch self {
            case .coach: "coach"
            case .muscle(let slug): "muscle-\(slug)"
            case .stats(let s): "stats-\(s.id)"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    private let ai = AIClient.shared

    @State private var sheet: AnalysisSheet?
    @State private var fatigueSide: BodyMap.Side = .front
    @State private var undoFeedback: String?
    @State private var undoError: String?

    private var isFemaleFigure: Bool {
        model.root["body"] == .string("female")
    }

    private func present(_ next: AnalysisSheet) {
        model.analysisSheetOpen = true
        sheet = next
    }

    private var statsSheetBinding: Binding<StatsSheet?> {
        Binding(
            get: {
                if case .stats(let s) = sheet { return s }
                return nil
            },
            set: { next in
                if let next {
                    present(.stats(next))
                } else if case .stats = sheet {
                    sheet = nil
                }
            }
        )
    }

    var body: some View {
        let load = Recovery.loadSummary(model.root, now: model.now, catalog: model.catalog)
        let fatigued = load.muscles
            .filter { $0.value.fatigue >= 0.15 }
            .sorted { a, b in
                if abs(a.value.fatigue - b.value.fatigue) > 1e-6 { return a.value.fatigue > b.value.fatigue }
                return a.key < b.key
            }
        let recoveringCount = load.muscles.values.filter { $0.fatigue >= 0.5 }.count

        NavigationStack {
            List {
                // MARK: AI Coach & Persistent Undo Banner

                Section {
                    if let record = model.lastAIUndoRecord,
                       let status = model.aiUndoStatus,
                       status != .expired {
                        undoBanner(record: record, status: status)
                    }

                    if let feedback = undoFeedback {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.tint)
                            Text(feedback)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Button("Dismiss", systemImage: "xmark") {
                                undoFeedback = nil
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if let error = undoError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    Button {
                        undoFeedback = nil
                        undoError = nil
                        present(.coach)
                    } label: {
                        Label("Ask AI Coach", systemImage: "sparkles")
                    }
                    .disabled(!ai.isAvailableForCoach)
                } header: {
                    Text("AI Coach")
                } footer: {
                    if !ai.isAvailableForCoach {
                        Text("Connect to your server in Profile → Settings → Server to ask AI Coach.")
                    } else {
                        Text("Review recovery, ask training questions, and preview safe adjustments to your upcoming plan.")
                    }
                }

                // MARK: Muscle Fatigue BodyMap

                Section {
                    VStack(spacing: 12) {
                        fatigueMapView(levels: load.fatigueMap)

                        if typeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 4) {
                                fatigueSummaryText(recoveringCount: recoveringCount)
                                fatigueLegend
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack {
                                fatigueSummaryText(recoveringCount: recoveringCount)
                                Spacer()
                                fatigueLegend
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    ForEach(Array(fatigued.prefix(4)), id: \.key) { slug, detail in
                        Button {
                            present(.muscle(slug))
                        } label: {
                            muscleQuickRow(slug: slug, detail: detail)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Muscle fatigue")
                } footer: {
                    Text("Tap any muscle to inspect fatigue, last session sets, and estimated hours until recovered.")
                }

                // MARK: More (Existing StatsContent)

                StatsContent(sheet: statsSheetBinding)
            }
            .navigationTitle("Analysis")
            .sheet(item: $sheet, onDismiss: {
                model.analysisSheetOpen = false
            }) { activeSheet in
                switch activeSheet {
                case .coach:
                    CoachSheet()
                case .muscle(let slug):
                    let detail = load.muscles[slug] ?? Recovery.MuscleDetail(fatigue: 0, lastSessionSets: 0, hoursToRecovered: 0)
                    MuscleFatigueDetailSheet(slug: slug, detail: detail)
                case .stats(let s):
                    switch s {
                    case .weight:
                        WeightEntry()
                    case .composition:
                        MeasurementEntry(title: "Body composition", fields: BodyData.compositionFields, withWeight: true)
                    case .tape:
                        MeasurementEntry(title: "Measurements", fields: BodyData.tapeFields, withWeight: false)
                    }
                }
            }
            .navigationDestination(for: LiftLink.self) { OneRepMaxView(id: $0.id) }
            .onChange(of: model.weighInRequested) {
                // CoachChatStore owns in-flight requests and pending proposals across dismissal.
                if model.weighInRequested, sheet != nil {
                    sheet = nil
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func undoBanner(record: AIUndoRecord, status: AIUndo.Status) -> some View {
        let dayCount = record.touchedDates.count
        let depth = model.aiUndoStack.count

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.tint)
                Text("AI plan adjustment active")
                    .font(.subheadline.weight(.semibold))
                if depth > 1 {
                    Text("\(depth)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.16), in: Capsule())
                        .accessibilityLabel(String(localized: "\(depth) undoable AI changes"))
                }
            }

            switch status {
            case .available:
                Text(dayCount == 1
                    ? String(localized: "1 day updated by AI Coach today.")
                    : String(localized: "\(dayCount) days updated by AI Coach today."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    performUndo()
                } label: {
                    Label("Undo AI change", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            case .blockedByActive:
                Text("Undo is locked while a workout is running on an adjusted day.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Dismiss", role: .destructive) {
                    model.dismissTopAIUndoBanner()
                }
                .font(.footnote)

            case .blockedByLoggedWorkout:
                Text("Undo is locked because a workout was already logged on an adjusted day.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Dismiss", role: .destructive) {
                    model.dismissTopAIUndoBanner()
                }
                .font(.footnote)

            case .expired:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }

    private func performUndo() {
        undoFeedback = nil
        undoError = nil
        do {
            guard let outcome = try model.undoLastAICoachChange() else { return }
            let skippedDays = outcome.skippedDates.count
            let skippedClones = outcome.skippedCloneIds.count
            if skippedDays > 0 {
                undoFeedback = skippedDays == 1
                    ? String(localized: "1 day was kept because it changed after the AI edit.")
                    : String(localized: "\(skippedDays) days were kept because they changed after the AI edit.")
            } else if skippedClones > 0 {
                undoFeedback = String(localized: "Restored your schedule; a modified AI workout copy was kept.")
            }
        } catch {
            undoError = String(localized: "Could not undo the AI change. Try again.")
        }
    }

    @ViewBuilder
    private func fatigueMapView(levels: [String: Double]) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 10) {
                Picker("Body side", selection: $fatigueSide) {
                    Text("Front").tag(BodyMap.Side.front)
                    Text("Back").tag(BodyMap.Side.back)
                }
                .pickerStyle(.segmented)

                BodyMap(
                    side: fatigueSide,
                    levels: levels,
                    female: isFemaleFigure,
                    onTap: { present(.muscle($0)) }
                )
                .frame(height: 220)
            }
        } else {
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    BodyMap(
                        side: .front,
                        levels: levels,
                        female: isFemaleFigure,
                        onTap: { present(.muscle($0)) }
                    )
                    .frame(height: 205)
                    Text("Front")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 4) {
                    BodyMap(
                        side: .back,
                        levels: levels,
                        female: isFemaleFigure,
                        onTap: { present(.muscle($0)) }
                    )
                    .frame(height: 205)
                    Text("Back")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func fatigueSummaryText(recoveringCount: Int) -> some View {
        Text(recoveringCount == 0
            ? String(localized: "All muscles recovered")
            : recoveringCount == 1
                ? String(localized: "1 muscle recovering")
                : String(localized: "\(recoveringCount) muscles recovering"))
            .font(.footnote.weight(.medium))
            .foregroundStyle(recoveringCount > 0 ? .primary : .secondary)
    }

    private var fatigueLegend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Circle().fill(.tint).frame(width: 8, height: 8)
                Text("Recovering")
            }
            HStack(spacing: 4) {
                Circle().fill(.fill.secondary).frame(width: 8, height: 8)
                Text("Fresh")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func muscleQuickRow(slug: String, detail: Recovery.MuscleDetail) -> some View {
        let pct = Int((detail.fatigue * 100).rounded())
        let recovering = detail.fatigue >= 0.5
        let hoursText = detail.hoursToRecovered <= 0.05
            ? String(localized: "Recovered")
            : String(localized: "~\(max(1, Int(detail.hoursToRecovered.rounded()))) h")

        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(model.catalog.muscleName(slug)))
                    .font(.subheadline.weight(.medium))
                Text("\(pct)% · \(hoursText)")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(recovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        } else {
            HStack {
                Text(LocalizedStringKey(model.catalog.muscleName(slug)))
                    .font(.subheadline)
                Spacer()
                Text("\(pct)%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(recovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Text("· \(hoursText)")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Detail sheet opened when tapping any muscle on the Analysis fatigue BodyMap or quick-list.
private struct MuscleFatigueDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let slug: String
    let detail: Recovery.MuscleDetail

    private var fatiguePercent: Int {
        Int((min(1, max(0, detail.fatigue)) * 100).rounded())
    }

    private var isRecovering: Bool {
        detail.fatigue >= 0.5
    }

    private var hoursText: String {
        if detail.hoursToRecovered <= 0.05 {
            return String(localized: "Recovered")
        }
        return String(localized: "~\(max(1, Int(detail.hoursToRecovered.rounded()))) h")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(isRecovering ? "Recovering" : "Fresh")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isRecovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                isRecovering ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.fill.tertiary),
                                in: Capsule()
                            )
                    }

                    LabeledContent("Fatigue") {
                        Text("\(fatiguePercent)%").monospacedDigit()
                    }

                    LabeledContent("Last session sets") {
                        Text(Format.number(detail.lastSessionSets, decimals: 1)).monospacedDigit()
                    }

                    LabeledContent("Estimated recovery") {
                        Text(hoursText).monospacedDigit()
                    }
                } footer: {
                    Text("Fatigue above 50% counts as recovering. Recovery time estimates hours until fatigue drops below 50%.")
                }
            }
            .navigationTitle(LocalizedStringKey(model.catalog.muscleName(slug)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
