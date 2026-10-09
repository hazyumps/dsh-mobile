import DSHRemoteKit
import SwiftUI

/// One conversation: what the host said, and a place to answer it.
///
/// The screen observes ``ChatSession``'s snapshot stream rather than polling it, so a
/// streamed answer updates the text it is already drawing instead of waiting for a poll
/// tick. Everything it renders comes from one immutable value (SPEC §2), which is also
/// what lets ``ConversationTranscript`` be reviewed without a host.
///
/// Reading a conversation and writing to one remain separate capabilities (SPEC §4): the
/// follow comes from ``ChatSession``, and sending and answering go through ``AppModel``,
/// which owns the no-retry rule for writes.
struct ConversationView: View {
    let sessionId: String

    @Environment(AppModel.self) private var model

    @State private var snapshot = ConversationSnapshot.idle
    @State private var session: ChatSession?
    @State private var draft = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var openError: String?
    @State private var isSubmittingAnswer = false
    @State private var followAttempt = 0
    @State private var didSendLaunchMessage = false

    private struct FollowKey: Hashable {
        let connectionID: UUID?
        let attempt: Int
    }

    var body: some View {
        Group {
            if model.status == .pairingRequired || model.status == .hostUnavailable {
                unavailable
            } else if let openError, !snapshot.hasSnapshot {
                failedToOpen(openError)
            } else {
                conversation
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                StatusBadge(status: model.status)
            }
        }
        .task(id: FollowKey(connectionID: model.connectionID, attempt: followAttempt)) {
            guard let connectionID = model.connectionID else { return }
            await follow(connectionID: connectionID)
        }
    }

    /// Pending approvals for this conversation.
    private var approvalRequests: [InteractionRequest] {
        model.decisions(for: sessionId).filter { $0.event == "approval/request" }
    }

    private var title: String {
        model.browse.session(id: sessionId)?.title ?? "Conversation"
    }

    private var connectionNote: String? {
        if !model.status.isUsable { return model.connectionError ?? model.status.label }
        if let openError { return openError }
        return nil
    }

    private var sendBlockedReason: String? {
        if !model.status.isUsable { return "Offline — reconnect to send." }
        if !snapshot.hasSnapshot { return "Waiting for the conversation to load." }
        return nil
    }

    // MARK: - States

    private var unavailable: some View {
        ContentUnavailableView {
            Label(model.status.label, systemImage: "wifi.exclamationmark")
        } description: {
            Text(model.connectionError ?? "Open the host to check its connection.")
        }
    }

    private func failedToOpen(_ reason: String) -> some View {
        ContentUnavailableView {
            Label("Can't open this conversation", systemImage: "exclamationmark.triangle")
        } description: {
            Text(reason)
        } actions: {
            Button("Try again") { followAttempt += 1 }
                .disabled(!model.status.isUsable)
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DSHMetrics.spaceCard) {
                    if let connectionNote {
                        // A brief reconnect does not replace the conversation with an
                        // error screen (UX spec "Connection and loading behavior").
                        Label(connectionNote, systemImage: "wifi.exclamationmark")
                            .font(.dshMetadata)
                            .foregroundStyle(DSHPalette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !snapshot.hasSnapshot {
                        HStack(spacing: DSHMetrics.space) {
                            ProgressView()
                            Text("Opening conversation…")
                                .foregroundStyle(DSHPalette.secondaryText)
                        }
                        .font(.dshSupporting)
                    }

                    ConversationTranscript(
                        snapshot: snapshot,
                        isSubmitting: isSubmittingAnswer,
                        onLoadOlder: { Task { await session?.loadOlder() } },
                        onAnswer: { answers in Task { await answer(answers) } },
                        approvals: approvalRequests,
                        onApproval: { eventId, isAllow in Task { await decide(eventId, isAllow: isAllow) } }
                    )
                    .id("transcript")
                }
                .padding(.horizontal, DSHMetrics.pageMargin)
                .padding(.vertical, DSHMetrics.spaceCard)
            }
            .background(DSHPalette.canvas)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: snapshot.messages.last?.text) { _, _ in
                // Follow the live tail: the point of watching a reply arrive is to watch
                // it, and the anchor is the transcript itself so a growing answer cannot
                // scroll the view to somewhere that no longer exists.
                guard snapshot.isStreaming else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("transcript", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            composer
        }
    }

    private var composer: some View {
        VStack(spacing: DSHMetrics.spaceSmall) {
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.attention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Composer(
                text: $draft,
                canSend: sendBlockedReason == nil,
                sendBlockedReason: sendBlockedReason,
                isSending: isSending,
                placeholder: "Message",
                onSend: { text in Task { await send(text) } }
            )
            .padding(.horizontal, DSHMetrics.pageMargin)
            .padding(.bottom, DSHMetrics.space)
        }
        .background(.bar)
    }

    // MARK: - Actions

    /// Opens the follow and copies its snapshots into view state until it goes away.
    ///
    /// The ten-second watchdog is what turns "never supplied a snapshot" into an
    /// explanation with a retry, rather than a spinner that never resolves
    /// (UX spec acceptance: "Follow never supplies a snapshot").
    private func follow(connectionID: UUID) async {
        openError = nil
        guard let opened = await model.chatSession(for: sessionId),
              !Task.isCancelled, connectionID == model.connectionID else { return }
        session = opened
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            if await !opened.hasSnapshot, connectionID == model.connectionID {
                openError = "The harness has not sent the conversation yet."
            }
        }
        do {
            try await opened.start()
            for await value in await opened.snapshots() {
                guard !Task.isCancelled, connectionID == model.connectionID else { break }
                snapshot = value
                if value.hasSnapshot {
                    openError = nil
                    watchdog.cancel()
                    await sendLaunchMessageIfAsked()
                }
                if let failure = value.followError {
                    openError = failure
                    break
                }
            }
        } catch {
            if !Task.isCancelled, connectionID == model.connectionID {
                openError = "The harness did not open this conversation."
            }
        }
        watchdog.cancel()
        await opened.stop()
        if session === opened { session = nil }
    }

    private func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sendBlockedReason == nil else { return }
        isSending = true
        sendError = nil
        do {
            try await model.sendPrompt(trimmed, to: sessionId)
            // Cleared only on acceptance: an uncertain send keeps the text so the user
            // can decide, because this client never resends on its own (SPEC §5).
            draft = ""
        } catch {
            sendError = "That message may not have been sent. It will not be resent."
        }
        isSending = false
    }

    private func answer(_ answers: [DecisionCard.Answer]) async {
        isSubmittingAnswer = true
        defer { isSubmittingAnswer = false }
        for answer in answers {
            guard let question = snapshot.pendingQuestions.first(where: { $0.id == answer.itemId }) else { continue }
            let reply = QuestionAnswer(id: question.id, selected: answer.selected, custom: answer.custom)

            if let live = model.liveQuestion(callId: question.callId) {
                // SPEC §8's first channel: a current delivery is answered through
                // `$events/result`, which is the only thing that can settle it. Going
                // through `userQuestions/answer` here would queue a steer reply beside a
                // still-open question.
                if let failure = await model.answerLive(live.id, with: [reply]) {
                    sendError = failure
                    continue
                }
            } else {
                do {
                    // The returned `Bool` is not a reliable applied signal: a live
                    // round-trip answered a question successfully while still reporting
                    // `false`. So an accepted call retires the card and the value is not
                    // shown, rather than being used to claim something untrue either way.
                    _ = try await model.answerQuestion(
                        sessionId: sessionId,
                        callId: question.callId,
                        questionId: question.id,
                        selected: answer.selected,
                        custom: answer.custom
                    )
                } catch {
                    sendError = "That answer may not have been sent. It will not be resent."
                    continue
                }
            }
            await session?.markAnswered(questionId: question.id)
        }
    }

    /// Allows or rejects one approval. The card retires on acknowledgement, and the screen
    /// never claims the agent ran anything: another client may have settled it first, and
    /// the host is the authority on what happened next (SPEC §8).
    private func decide(_ eventId: String, isAllow: Bool) async {
        isSubmittingAnswer = true
        defer { isSubmittingAnswer = false }
        let failure = isAllow ? await model.allowOnce(eventId) : await model.deny(eventId)
        if let failure { sendError = failure }
    }

    /// Verification affordance, debug builds only: a launch can send one message.
    ///
    /// Only ever pointed at a scratch session — a duplicate or stray prompt costs real
    /// work, so this must not be aimed at a conversation somebody cares about.
    private func sendLaunchMessageIfAsked() async {
        guard !didSendLaunchMessage, let message = model.launchMessage else { return }
        didSendLaunchMessage = true
        await send(message)
    }
}
