import HexplateCore
import Observation
import SwiftUI

/// In-memory session chat store for AI Coach (never written to `state.json`).
/// Owns the single in-flight request `Task` so closing `CoachSheet` never drops a paid reply
/// or loses pending plan proposals (R12, R13, C4).
@MainActor
@Observable
final class CoachChatStore {
    static let shared = CoachChatStore()
    static let maxMessages = 40

    enum Role {
        case user
        case assistant
    }

    enum ProposalStatus: Equatable {
        case pending
        case applying
        case applied(undoToken: String?)
        case stale
        case dismissed
        case undone
    }

    struct ProposalState {
        let preview: CoachOps.Preview
        let snapshot: CoachContext.Snapshot
        let tokenId: String
        var status: ProposalStatus
        var errorMessage: String?
    }

    enum MessageKind {
        case text
        case thinking
        case stopped
        case error(kind: AIWire.ErrorKind, retryPrompt: String, retryBlockedUntil: Date?)
    }

    struct Message: Identifiable {
        let id: UUID
        let role: Role
        var text: String
        var kind: MessageKind
        var note: String?
        var previewError: String?
        var proposal: ProposalState?
    }

    private(set) var messages: [Message] = []
    private(set) var activeDay: String?

    private var inFlightTask: Task<Void, Never>?
    private var activePendingId: UUID?
    private var stoppedByUser = false

    var isSending: Bool { inFlightTask != nil }
    var canClear: Bool { !messages.isEmpty && !isSending }

    /// Synchronizes thread lifecycle with current calendar day, server availability, and plan revisions.
    func syncLifecycle(today: String, isAvailable: Bool, root: [String: JSONValue]) {
        if !isAvailable {
            if !isSending {
                messages.removeAll()
                activeDay = nil
            }
            return
        }
        if let prev = activeDay, prev != today {
            if !isSending {
                messages.removeAll()
                activeDay = today
                return
            } else {
                markAllPendingStale()
                activeDay = today
            }
        } else if activeDay == nil {
            activeDay = today
        }
        refreshPendingStaleness(root: root, today: today)
    }

    /// Cheap O(pending) digest check triggered by `AppModel.documentRevision` and `onAppear` (C5).
    func refreshPendingStaleness(root: [String: JSONValue], today: String) {
        for idx in messages.indices {
            guard var proposal = messages[idx].proposal, proposal.status == .pending else { continue }
            if proposal.snapshot.today != today {
                proposal.status = .stale
                proposal.errorMessage = nil
                messages[idx].proposal = proposal
                continue
            }
            let drifted = proposal.preview.expectedDigests.contains { date, digest in
                CoachContext.dayDigest(root, date: date, today: today) != digest
            }
            if drifted {
                proposal.status = .stale
                proposal.errorMessage = nil
                messages[idx].proposal = proposal
            }
        }
    }

    func clearChat() {
        guard !isSending else { return }
        messages.removeAll()
    }

    func stop() {
        guard let task = inFlightTask else { return }
        stoppedByUser = true
        if let pendingId = activePendingId,
           let idx = messages.firstIndex(where: { $0.id == pendingId }) {
            messages[idx].kind = .stopped
            messages[idx].text = ""
            messages[idx].note = nil
            messages[idx].previewError = nil
            messages[idx].proposal = nil
        }
        task.cancel()
    }

    /// Builds sanitized multi-turn history from completed `user`/`assistant` text turns only,
    /// excluding the outgoing message, errors, thinking/stopped placeholders, notes, and ops (R13).
    func buildHistory(excluding outgoingId: UUID? = nil) -> [AIWire.CoachChatTurn] {
        var turns: [AIWire.CoachChatTurn] = []
        for msg in messages {
            if msg.id == outgoingId { continue }
            guard case .text = msg.kind, !msg.text.isEmpty else { continue }
            let role = (msg.role == .user) ? "user" : "assistant"
            turns.append(AIWire.CoachChatTurn(role: role, content: msg.text))
        }
        return AIWire.cleanCoachHistory(turns)
    }

    func send(_ raw: String, model: AppModel, health: HealthService) {
        // C4: strict single-flight enforcement.
        guard inFlightTask == nil else { return }
        let cleaned = AIWire.cleanCoachMessage(raw)
        guard !cleaned.isEmpty else { return }

        activeDay = model.today
        // Capture history BEFORE appending the outgoing user prompt (R13).
        let history = buildHistory()

        let userMsg = Message(
            id: UUID(),
            role: .user,
            text: cleaned,
            kind: .text,
            note: nil,
            previewError: nil,
            proposal: nil
        )
        let pendingId = UUID()
        let placeholder = Message(
            id: pendingId,
            role: .assistant,
            text: "",
            kind: .thinking,
            note: nil,
            previewError: nil,
            proposal: nil
        )
        messages.append(userMsg)
        messages.append(placeholder)
        trimToCap()

        stoppedByUser = false
        activePendingId = pendingId

        let sentSnapshot = buildSnapshot(model: model, health: health)

        inFlightTask = Task { @MainActor [weak self] in
            defer {
                self?.inFlightTask = nil
                self?.activePendingId = nil
            }
            guard let self else { return }

            do {
                let response = try await AIClient.shared.askCoach(
                    message: cleaned,
                    snapshot: sentSnapshot,
                    history: history
                )
                try Task.checkCancellation()
                self.finishSuccess(
                    pendingId: pendingId,
                    response: response,
                    sentSnapshot: sentSnapshot,
                    model: model
                )
            } catch let error as AIWire.ErrorKind {
                if error == .cancelled {
                    self.finishCancellation(pendingId: pendingId, retryPrompt: cleaned)
                    return
                }
                let retryAfter: Int? = switch error {
                case .rateLimited(let s), .busy(let s), .dailyCapReached(let s): s
                default: nil
                }
                let blockedUntil = retryAfter.map { Date().addingTimeInterval(TimeInterval(min($0, 60))) }
                self.finishError(
                    pendingId: pendingId,
                    kind: error,
                    retryPrompt: cleaned,
                    retryBlockedUntil: blockedUntil
                )
            } catch is CancellationError {
                self.finishCancellation(pendingId: pendingId, retryPrompt: cleaned)
            } catch {
                self.finishError(
                    pendingId: pendingId,
                    kind: .networkLost,
                    retryPrompt: cleaned,
                    retryBlockedUntil: nil
                )
            }
        }
    }

    func confirmProposal(messageId: UUID, model: AppModel) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }),
              var proposal = messages[idx].proposal,
              proposal.status == .pending else { return }

        proposal.status = .applying
        proposal.errorMessage = nil
        messages[idx].proposal = proposal

        do {
            let record = try model.applyCoachPreview(proposal.preview, tokenId: proposal.tokenId)
            proposal.status = .applied(undoToken: record?.tokenId)
            proposal.errorMessage = nil
            messages[idx].proposal = proposal
            markOtherPendingStale(except: messageId)
        } catch let err as CoachOps.ValidationError {
            switch err.code {
            case "stale_plan", "locked_date", "today_shifted":
                proposal.status = .stale
                proposal.errorMessage = nil
            default:
                proposal.status = .pending
                proposal.errorMessage = AIClient.coachNoteMessage(for: "no_valid_plan_change")
            }
            messages[idx].proposal = proposal
        } catch {
            proposal.status = .pending
            proposal.errorMessage = String(localized: "Could not save the adjusted plan. Nothing was changed.")
            messages[idx].proposal = proposal
        }
    }

    func dismissProposal(messageId: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }),
              var proposal = messages[idx].proposal,
              proposal.status == .pending else { return }
        proposal.status = .dismissed
        proposal.errorMessage = nil
        messages[idx].proposal = proposal
    }

    func undoAppliedProposal(messageId: UUID, model: AppModel) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }),
              var proposal = messages[idx].proposal,
              case .applied(let undoToken) = proposal.status,
              let undoToken,
              model.lastAIUndoRecord?.tokenId == undoToken,
              model.aiUndoStatus == .available else { return }

        proposal.errorMessage = nil
        messages[idx].proposal = proposal

        do {
            _ = try model.undoLastAICoachChange()
            proposal.status = .undone
            proposal.errorMessage = nil
            messages[idx].proposal = proposal
            markOtherPendingStale(except: messageId)
        } catch {
            proposal.errorMessage = String(localized: "Could not undo the AI change. Try again.")
            messages[idx].proposal = proposal
        }
    }

    // MARK: - Internal Helpers

    private func buildSnapshot(model: AppModel, health: HealthService) -> CoachContext.Snapshot {
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

    private func finishSuccess(
        pendingId: UUID,
        response: AIWire.CoachResponse,
        sentSnapshot: CoachContext.Snapshot,
        model: AppModel
    ) {
        guard let idx = messages.firstIndex(where: { $0.id == pendingId }) else { return }

        if response.changes.isEmpty {
            messages[idx].text = response.answer
            messages[idx].kind = .text
            messages[idx].note = response.note
            messages[idx].previewError = nil
            messages[idx].proposal = nil
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
            messages[idx].text = response.answer
            messages[idx].kind = .text
            if !preview.hasChanges {
                messages[idx].note = "net_zero_change"
                messages[idx].previewError = nil
                messages[idx].proposal = nil
            } else {
                messages[idx].note = nil
                messages[idx].previewError = nil
                messages[idx].proposal = ProposalState(
                    preview: preview,
                    snapshot: sentSnapshot,
                    tokenId: UUID().uuidString,
                    status: .pending,
                    errorMessage: nil
                )
            }
        } catch let validationError as CoachOps.ValidationError {
            let code = (validationError.code == "stale_plan" || validationError.code == "today_shifted")
                ? validationError.code
                : "no_valid_plan_change"
            messages[idx].text = response.answer
            messages[idx].kind = .text
            messages[idx].note = nil
            messages[idx].previewError = code
            messages[idx].proposal = nil
        } catch {
            messages[idx].text = response.answer
            messages[idx].kind = .text
            messages[idx].note = nil
            messages[idx].previewError = "no_valid_plan_change"
            messages[idx].proposal = nil
        }
    }

    private func finishCancellation(pendingId: UUID, retryPrompt: String) {
        guard let idx = messages.firstIndex(where: { $0.id == pendingId }) else { return }
        if stoppedByUser {
            messages[idx].kind = .stopped
            messages[idx].text = ""
            messages[idx].note = nil
            messages[idx].previewError = nil
            messages[idx].proposal = nil
        } else {
            // R3: never silently stay stuck on thinking after involuntary cancellation.
            finishError(pendingId: pendingId, kind: .networkLost, retryPrompt: retryPrompt, retryBlockedUntil: nil)
        }
    }

    private func finishError(
        pendingId: UUID,
        kind: AIWire.ErrorKind,
        retryPrompt: String,
        retryBlockedUntil: Date?
    ) {
        guard let idx = messages.firstIndex(where: { $0.id == pendingId }) else { return }
        messages[idx].text = ""
        messages[idx].kind = .error(kind: kind, retryPrompt: retryPrompt, retryBlockedUntil: retryBlockedUntil)
        messages[idx].note = nil
        messages[idx].previewError = nil
        messages[idx].proposal = nil
    }

    private func markOtherPendingStale(except messageId: UUID) {
        for idx in messages.indices where messages[idx].id != messageId {
            guard var proposal = messages[idx].proposal, proposal.status == .pending else { continue }
            proposal.status = .stale
            proposal.errorMessage = nil
            messages[idx].proposal = proposal
        }
    }

    private func markAllPendingStale() {
        for idx in messages.indices {
            guard var proposal = messages[idx].proposal, proposal.status == .pending else { continue }
            proposal.status = .stale
            proposal.errorMessage = nil
            messages[idx].proposal = proposal
        }
    }

    private func trimToCap() {
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }
}

/// Multi-turn chatbox AI Coach sheet:
/// separate Coach privacy consent -> scrollable chat conversation with inline Before/After plan
/// diff cards and Confirm / Dismiss buttons directly below AI suggestions.
struct CoachSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(HealthService.self) private var health
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    private let ai = AIClient.shared
    private let store = CoachChatStore.shared

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

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
                if !ai.hasCoachPrivacyConsent {
                    consentView
                } else {
                    chatView
                }
            }
            .navigationTitle("AI Coach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if ai.hasCoachPrivacyConsent {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New chat", systemImage: "square.and.pencil") {
                            store.clearChat()
                        }
                        .disabled(!store.canClear)
                    }
                }
            }
        }
        .onAppear {
            store.syncLifecycle(today: model.today, isAvailable: ai.isAvailableForCoach, root: model.root)
        }
        .onChange(of: model.documentRevision) {
            store.refreshPendingStaleness(root: model.root, today: model.today)
        }
        .onChange(of: model.today) {
            store.syncLifecycle(today: model.today, isAvailable: ai.isAvailableForCoach, root: model.root)
        }
    }

    // MARK: - Consent Step (Separate Key: aiCoachPrivacyConsentAccepted, R11)

    private var consentView: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AI Coach privacy").font(.headline)
                        Text("When you ask AI Coach, your question, earlier messages from this chat, 15-day workout plan, 14-day workout summary, readiness signals, today’s nutrition totals, and routine and exercise names in that context are sent to your Hexplate server and forwarded to its configured AI provider.")
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
                }
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Chatbox Conversation View

    private var chatView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.messages.isEmpty {
                        welcomeCard
                    }

                    ForEach(store.messages) { msg in
                        messageRow(msg)
                            .id(msg.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("coach-chat-bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerBar
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: store.messages.count) {
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: store.isSending) {
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: composerFocused) { _, focused in
                if focused {
                    scrollToBottom(proxy, animated: true)
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("coach-chat-bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("coach-chat-bottom", anchor: .bottom)
        }
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("AI Coach", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text("Ask about your recovery, muscle balance, or upcoming workouts. When I recommend a plan adjustment, you can review and confirm it directly below my reply.")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: typeSize.isAccessibilitySize ? 12 : 40)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Quick prompts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)

                ForEach(quickPrompts, id: \.self) { suggestion in
                    Button {
                        sendMessage(suggestion)
                    } label: {
                        HStack(spacing: 8) {
                            Text(suggestion)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.circle")
                                .foregroundStyle(.tint)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!ai.isAvailableForCoach || store.isSending)
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ msg: CoachChatStore.Message) -> some View {
        if msg.role == .user {
            HStack {
                Spacer(minLength: typeSize.isAccessibilitySize ? 20 : 48)
                Text(verbatim: msg.text)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else {
            HStack(alignment: .top) {
                assistantBubble(msg)
                Spacer(minLength: typeSize.isAccessibilitySize ? 12 : 36)
            }
        }
    }

    @ViewBuilder
    private func assistantBubble(_ msg: CoachChatStore.Message) -> some View {
        switch msg.kind {
        case .thinking:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("AI Coach is thinking…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Stop", systemImage: "stop.circle") {
                    store.stop()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        case .stopped:
            Label("Stopped", systemImage: "stop.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        case .error(let kind, let retryPrompt, let blockedUntil):
            let blocked = blockedUntil.map { $0 > Date.now } ?? false
            let canRetry = kind.isRetryable && !blocked && !store.isSending

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Could not reach AI Coach")
                            .font(.subheadline.weight(.semibold))
                        Text(AIClient.coachUserMessage(for: kind))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }

                if kind.isRetryable {
                    Button("Try again", systemImage: "arrow.clockwise") {
                        sendMessage(retryPrompt)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canRetry)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        case .text:
            let infoCode = msg.previewError ?? msg.note
            VStack(alignment: .leading, spacing: 10) {
                // Render strictly verbatim so untrusted LLM text is never parsed as Markdown or links.
                VStack(alignment: .leading, spacing: 6) {
                    Label("AI Coach", systemImage: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text(verbatim: msg.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                if let infoCode {
                    Label {
                        Text(AIClient.coachNoteMessage(for: infoCode))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let proposal = msg.proposal {
                    proposalCard(messageId: msg.id, proposal: proposal)
                }
            }
        }
    }

    @ViewBuilder
    private func proposalCard(messageId: UUID, proposal: CoachChatStore.ProposalState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Proposed schedule changes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(proposal.preview.dayDiffs) { diff in
                CoachDayDiffCard(diff: diff, snapshot: proposal.snapshot)
                if diff.id != proposal.preview.dayDiffs.last?.id {
                    Divider()
                }
            }

            if let errMsg = proposal.errorMessage {
                Label {
                    Text(errMsg)
                        .font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            proposalFooter(messageId: messageId, status: proposal.status)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    proposal.status == .pending ? Theme.accent.opacity(0.45) : Color.secondary.opacity(0.2),
                    lineWidth: 1
                )
        }
    }

    @ViewBuilder
    private func proposalFooter(messageId: UUID, status: CoachChatStore.ProposalStatus) -> some View {
        switch status {
        case .pending, .applying:
            let isApplying = (status == .applying)
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Button {
                    store.confirmProposal(messageId: messageId, model: model)
                } label: {
                    Text(isApplying ? "Applying…" : "Confirm & apply changes")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Theme.ink)
                .disabled(isApplying)

                Button("Dismiss") {
                    store.dismissProposal(messageId: messageId)
                }
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
                .buttonStyle(.bordered)
                .disabled(isApplying)
            }

        case .applied(let undoToken):
            // R13: derive Undo button strictly from live `model.lastAIUndoRecord` and `aiUndoStatus`.
            let canUndo = undoToken != nil
                && model.lastAIUndoRecord?.tokenId == undoToken
                && model.aiUndoStatus == .available
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Label("Changes applied", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                if !typeSize.isAccessibilitySize {
                    Spacer(minLength: 4)
                }
                if canUndo {
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        store.undoAppliedProposal(messageId: messageId, model: model)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

        case .stale:
            Label("Plan changed — ask again", systemImage: "clock.arrow.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)

        case .dismissed:
            Label("Suggestion dismissed", systemImage: "xmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)

        case .undone:
            Label("Changes undone", systemImage: "arrow.uturn.backward.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pinned Chat Composer

    private var composerBar: some View {
        let cleaned = AIWire.cleanCoachMessage(draft)
        let canSend = !cleaned.isEmpty && ai.isAvailableForCoach && !store.isSending

        return VStack(spacing: 8) {
            Divider()

            if !ai.isAvailableForCoach {
                Label {
                    Text("Connect to your server in Profile → Settings → Server to ask AI Coach.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "wifi.slash").foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message AI Coach…", text: $draft, axis: .vertical)
                    .lineLimit(1...(typeSize.isAccessibilitySize ? 2 : 4))
                    .focused($composerFocused)
                    .disabled(!ai.isAvailableForCoach || store.isSending)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                if store.isSending {
                    Button {
                        store.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button {
                        sendMessage(draft)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(.bar)
    }

    private func sendMessage(_ raw: String) {
        let cleaned = AIWire.cleanCoachMessage(raw)
        guard !cleaned.isEmpty, ai.isAvailableForCoach, !store.isSending else { return }
        draft = ""
        composerFocused = false
        store.send(cleaned, model: model, health: health)
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
