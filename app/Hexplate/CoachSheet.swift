import HexplateCore
import SwiftUI

/// Single-sheet stateless AI Coach flow:
/// separate Coach privacy consent -> compose (free text + quick prompts) -> loading/cancel
/// -> phone-validated Before/After DayDiff review -> atomic Accept (LIFO undo stack).
struct CoachSheet: View {
    private enum Phase {
        case consent
        case compose
        case loading(message: String, taskToken: UUID)
        case result(
            message: String,
            answer: String,
            note: String?,
            preview: CoachOps.Preview?,
            snapshot: CoachContext.Snapshot,
            tokenId: String,
            previewError: String?
        )
        case failed(error: AIWire.ErrorKind, message: String, retryBlockedUntil: Date?)
    }

    @Environment(AppModel.self) private var model
    @Environment(HealthService.self) private var health
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    @Binding var deferWeighIn: Bool

    private let ai = AIClient.shared

    @State private var phase: Phase = .compose
    @State private var initialized = false
    @State private var promptText = ""
    @State private var isAccepting = false
    @State private var acceptError: String?

    private var shouldDeferWeighIn: Bool {
        switch phase {
        case .loading:
            return true
        case .result(_, _, _, let preview, _, _, _):
            return preview?.hasChanges == true
        case .consent, .compose, .failed:
            return false
        }
    }

    private var quickPrompts: [String] {
        [
            String(localized: "I skipped yesterday"),
            String(localized: "Arms are tired, no arms today"),
            String(localized: "Short on time"),
        ]
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .consent:
                    consentView
                case .compose:
                    composeView
                case .loading(let message, let token):
                    loadingView(message: message, token: token)
                case .result(let message, let answer, let note, let preview, let snapshot, let tokenId, let previewError):
                    resultView(
                        message: message,
                        answer: answer,
                        note: note,
                        preview: preview,
                        snapshot: snapshot,
                        tokenId: tokenId,
                        previewError: previewError
                    )
                case .failed(let error, let message, let blockedUntil):
                    failedView(error: error, message: message, retryBlockedUntil: blockedUntil)
                }
            }
            .navigationTitle("AI Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            if !initialized {
                initialized = true
                phase = ai.hasCoachPrivacyConsent ? .compose : .consent
            }
            deferWeighIn = shouldDeferWeighIn
        }
        .onChange(of: shouldDeferWeighIn) { _, newValue in
            deferWeighIn = newValue
        }
        .onDisappear {
            deferWeighIn = false
        }
    }

    // MARK: - Consent Step (Separate Key: aiCoachPrivacyConsentAccepted)

    private var consentView: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AI Coach privacy").font(.headline)
                        Text("When you ask AI Coach, your question, 15-day workout plan, 14-day workout summary, readiness signals, today’s nutrition totals, and routine and exercise names in that context are sent to your Hexplate server and forwarded to its configured AI provider.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Your schedule is never changed automatically — every suggested adjustment is verified on this device and requires your approval.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(.tint)
                }
                .padding(.vertical, 4)
            }

            Section {
                Button("Continue") {
                    ai.acceptCoachPrivacyConsent()
                    phase = .compose
                }
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Compose Step

    private var composeView: some View {
        let cleaned = AIWire.cleanCoachMessage(promptText)

        return Form {
            if !ai.isAvailableForCoach {
                Section {
                    Label {
                        Text("Connect to your server in Profile → Settings → Server to ask AI Coach.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "wifi.slash").foregroundStyle(.orange)
                    }
                }
            }

            Section("Your question") {
                TextField("Ask about your schedule, fatigue, or exercises...", text: $promptText, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section {
                Button {
                    sendPrompt(cleaned)
                } label: {
                    Label("Ask AI Coach", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .disabled(cleaned.isEmpty || !ai.isAvailableForCoach)
            }

            Section("Quick prompts") {
                ForEach(quickPrompts, id: \.self) { suggestion in
                    Button {
                        promptText = suggestion
                        if ai.isAvailableForCoach {
                            sendPrompt(suggestion)
                        }
                    } label: {
                        HStack {
                            Text(suggestion)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.circle")
                                .foregroundStyle(.tint)
                        }
                    }
                    .disabled(!ai.isAvailableForCoach)
                }
            }
        }
    }

    // MARK: - Loading Step

    private func loadingView(message: String, token: UUID) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Asking AI Coach...")
                .font(.headline)
            Text(verbatim: message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal)
            Spacer()
        }
        .padding()
        .task(id: token) {
            await executeCoachRequest(message: message)
        }
    }

    // MARK: - Result Step (Phone-Validated Preview & Accept)

    private func resultView(
        message: String,
        answer: String,
        note: String?,
        preview: CoachOps.Preview?,
        snapshot: CoachContext.Snapshot,
        tokenId: String,
        previewError: String?
    ) -> some View {
        let infoCode = previewError ?? note
        let hasChanges = preview?.hasChanges == true

        return List {
            Section("Coach reply") {
                // Render strictly verbatim so untrusted LLM text is never parsed as Markdown or links.
                Text(verbatim: answer)
                    .font(.body)
                    .textSelection(.enabled)
            }

            if let infoCode {
                Section {
                    Label {
                        Text(AIClient.coachNoteMessage(for: infoCode))
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
            }

            if let preview, hasChanges {
                Section("Proposed schedule changes") {
                    ForEach(preview.dayDiffs) { diff in
                        CoachDayDiffCard(diff: diff, snapshot: snapshot)
                    }
                }

                if let acceptError {
                    Section {
                        Label {
                            Text(acceptError)
                                .font(.subheadline)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Button {
                        acceptPreview(preview, tokenId: tokenId)
                    } label: {
                        Text("Accept changes")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.ink)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                    .disabled(isAccepting)

                    Button("Ask again") {
                        promptText = message
                        acceptError = nil
                        isAccepting = false
                        phase = .compose
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                Section {
                    Button("Ask again") {
                        promptText = message
                        acceptError = nil
                        phase = .compose
                    }
                    .frame(maxWidth: .infinity)

                    Button("Done") { dismiss() }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Failed Step

    private func failedView(error: AIWire.ErrorKind, message: String, retryBlockedUntil: Date?) -> some View {
        let now = Date()
        let blocked = retryBlockedUntil.map { $0 > now } ?? false
        let canRetry = error.isRetryable && !blocked

        return List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Could not reach AI Coach").font(.headline)
                        Text(AIClient.coachUserMessage(for: error))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 4)
            }

            Section {
                if error.isRetryable {
                    Button("Try again") {
                        sendPrompt(message)
                    }
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
                    .disabled(!canRetry)
                }

                Button("Edit question") {
                    promptText = message
                    phase = .compose
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Pipeline Actions (Phone Is Final Authority)

    private func sendPrompt(_ raw: String) {
        let cleaned = AIWire.cleanCoachMessage(raw)
        guard !cleaned.isEmpty else { return }
        acceptError = nil
        isAccepting = false
        phase = .loading(message: cleaned, taskToken: UUID())
    }

    private func buildSnapshot() -> CoachContext.Snapshot {
        let todayCtx = health.evaluateTodaySnapshot(
            root: model.root,
            today: model.today,
            now: model.now,
            catalog: model.catalog
        )
        return CoachContext.build(
            root: model.root,
            today: model.today,
            timezone: TimeZone.current.identifier,
            readiness: todayCtx.readiness,
            readinessSignals: todayCtx.signals,
            liveExternalNutrition: todayCtx.externalToday,
            catalog: model.catalog,
            now: model.now
        )
    }

    private func executeCoachRequest(message: String) async {
        let sentSnapshot = buildSnapshot()
        let tokenId = UUID().uuidString

        do {
            let response = try await ai.askCoach(message: message, snapshot: sentSnapshot)
            guard !Task.isCancelled else { return }

            if response.changes.isEmpty {
                phase = .result(
                    message: message,
                    answer: response.answer,
                    note: response.note,
                    preview: nil,
                    snapshot: sentSnapshot,
                    tokenId: tokenId,
                    previewError: nil
                )
                return
            }

            // Phone is the final gate: parse + simulate against the exact Snapshot that was sent.
            do {
                let parsedOps = try CoachOps.parseSchemaOps(response.changes)
                let preview = try CoachOps.preview(
                    ops: parsedOps,
                    snapshot: sentSnapshot,
                    root: model.root,
                    today: model.today,
                    catalog: model.catalog
                )
                if !preview.hasChanges {
                    phase = .result(
                        message: message,
                        answer: response.answer,
                        note: "net_zero_change",
                        preview: nil,
                        snapshot: sentSnapshot,
                        tokenId: tokenId,
                        previewError: nil
                    )
                } else {
                    phase = .result(
                        message: message,
                        answer: response.answer,
                        note: nil,
                        preview: preview,
                        snapshot: sentSnapshot,
                        tokenId: tokenId,
                        previewError: nil
                    )
                }
            } catch let validationError as CoachOps.ValidationError {
                let code = (validationError.code == "stale_plan" || validationError.code == "today_shifted")
                    ? validationError.code
                    : "no_valid_plan_change"
                phase = .result(
                    message: message,
                    answer: response.answer,
                    note: nil,
                    preview: nil,
                    snapshot: sentSnapshot,
                    tokenId: tokenId,
                    previewError: code
                )
            } catch {
                phase = .result(
                    message: message,
                    answer: response.answer,
                    note: nil,
                    preview: nil,
                    snapshot: sentSnapshot,
                    tokenId: tokenId,
                    previewError: "no_valid_plan_change"
                )
            }
        } catch let error as AIWire.ErrorKind {
            if error == .cancelled || Task.isCancelled { return }
            let retryAfter: Int? = switch error {
            case .rateLimited(let s), .busy(let s), .dailyCapReached(let s): s
            default: nil
            }
            let blockedUntil = retryAfter.map { Date().addingTimeInterval(TimeInterval(min($0, 60))) }
            phase = .failed(error: error, message: message, retryBlockedUntil: blockedUntil)
        } catch {
            if Task.isCancelled { return }
            phase = .failed(error: .networkLost, message: message, retryBlockedUntil: nil)
        }
    }

    private func acceptPreview(_ preview: CoachOps.Preview, tokenId: String) {
        guard !isAccepting else { return }
        isAccepting = true
        acceptError = nil
        do {
            _ = try model.applyCoachPreview(preview, tokenId: tokenId)
            dismiss()
        } catch let err as CoachOps.ValidationError {
            isAccepting = false
            switch err.code {
            case "stale_plan", "locked_date":
                acceptError = AIClient.coachNoteMessage(for: "stale_plan")
            case "today_shifted":
                acceptError = AIClient.coachNoteMessage(for: "today_shifted")
            default:
                acceptError = AIClient.coachNoteMessage(for: "no_valid_plan_change")
            }
        } catch {
            isAccepting = false
            acceptError = String(localized: "Could not save the adjusted plan. Nothing was changed.")
        }
    }
}

// MARK: - Before / After DayDiff Card (Display Names Resolved on @MainActor)

private struct CoachDayDiffCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    let diff: CoachOps.DayDiff
    let snapshot: CoachContext.Snapshot

    private var formattedDate: String {
        Day.date(diff.date)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Theme.locale)) ?? diff.date
    }

    private func routineTitle(_ summary: CoachOps.DaySummary) -> String {
        if summary.isRest || summary.routineId == nil {
            return String(localized: "Rest day")
        }
        guard let rid = summary.routineId else { return String(localized: "Rest day") }
        if let live = model.routine(rid)?.name, !live.isEmpty {
            return live
        }
        if let aliased = snapshot.routineAliases.first(where: { $0.id == rid })?.name, !aliased.isEmpty {
            return aliased
        }
        return String(localized: "Workout")
    }

    private func exerciseTitle(_ id: String) -> String {
        if let ex = model.catalog[id] {
            return ex.displayName
        }
        if let aliased = snapshot.exerciseAliases.first(where: { $0.id == id })?.name, !aliased.isEmpty {
            return aliased
        }
        return id
    }

    private func loadSeedText(_ seed: CoachOps.LoadSeed) -> String {
        switch seed {
        case .prefill(let weight, let unit):
            String(localized: "Starting load: \(Format.number(weight, decimals: model.settings.weightDecimals)) \(unit)")
        case .bodyweight:
            String(localized: "Bodyweight")
        case .blank:
            String(localized: "No prior load history")
        }
    }

    private var aiAdjustedBadge: some View {
        Text("AI-adjusted")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.14), in: Capsule())
    }

    var body: some View {
        let beforeTitle = routineTitle(diff.before)
        let afterTitle = routineTitle(diff.after)

        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(formattedDate)
                        .font(.subheadline.weight(.semibold))
                    if diff.after.isAIClone {
                        aiAdjustedBadge
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(formattedDate)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if diff.after.isAIClone {
                        aiAdjustedBadge
                    }
                }
            }

            if beforeTitle != afterTitle {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(beforeTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .strikethrough()
                        Label(afterTitle, systemImage: "arrow.down")
                            .font(.subheadline.weight(.medium))
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(beforeTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .strikethrough()
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(afterTitle)
                            .font(.subheadline.weight(.medium))
                    }
                }
            } else {
                Text(afterTitle)
                    .font(.subheadline.weight(.medium))
            }

            if diff.programmeWeekChanged {
                Label("Programme week changes on the new date.", systemImage: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(Array(diff.slotChanges.enumerated()), id: \.offset) { _, change in
                slotChangeRow(change)
            }

            ForEach(diff.reasons, id: \.self) { reason in
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func slotChangeRow(_ change: CoachOps.SlotChange) -> some View {
        switch change {
        case .swapped(_, let fromId, let toId, let sets, let reps, let droppedPct, let gainedPct, let seed):
            VStack(alignment: .leading, spacing: 4) {
                Text("\(exerciseTitle(fromId)) → \(exerciseTitle(toId))")
                    .font(.footnote.weight(.medium))
                Text(reps.map { String(localized: "\(sets) sets × \($0) reps") } ?? (sets == 1 ? String(localized: "1 set") : String(localized: "\(sets) sets")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(loadSeedText(seed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let droppedPct {
                    Label(
                        String(localized: "Programme target (\(Format.number(droppedPct, decimals: 0))% 1RM) removed."),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                if let gainedPct {
                    Label(
                        String(localized: "Programme target (\(Format.number(gainedPct, decimals: 0))% 1RM) applied."),
                        systemImage: "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.tint)
                }
            }
            .padding(.leading, 4)

        case .setsChanged(_, let exId, let beforeSets, let afterSets, let beforeReps, let afterReps):
            VStack(alignment: .leading, spacing: 2) {
                Text(exerciseTitle(exId))
                    .font(.footnote.weight(.medium))
                if beforeSets != afterSets {
                    Text(String(localized: "Sets: \(beforeSets) → \(afterSets)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let afterReps, beforeReps != afterReps {
                    if let beforeReps {
                        Text(String(localized: "Reps: \(beforeReps) → \(afterReps)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text(String(localized: "Reps: \(afterReps)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.leading, 4)

        case .added(_, let exId, let sets, let reps, let seed):
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Add \(exerciseTitle(exId))"))
                    .font(.footnote.weight(.medium))
                Text(reps.map { String(localized: "\(sets) sets × \($0) reps") } ?? (sets == 1 ? String(localized: "1 set") : String(localized: "\(sets) sets")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(loadSeedText(seed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
        }
    }
}
