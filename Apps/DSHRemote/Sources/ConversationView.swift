import DSHRemoteKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var claimError: String?
    @State private var isImportingFile = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var followAttempt = 0
    @State private var didSendLaunchMessage = false

    /// What a follow belongs to.
    ///
    /// The session id is part of it, and that is not bookkeeping: SwiftUI reuses one
    /// `ConversationView` when the stack navigates from one conversation to another, so a
    /// key of connection-and-attempt alone left the *old* follow running — and the old
    /// transcript on screen — under the new session's id.
    private struct FollowKey: Hashable {
        let sessionId: String
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
        .task(id: FollowKey(
            sessionId: sessionId,
            connectionID: model.connectionID,
            attempt: followAttempt
        )) {
            guard let connectionID = model.connectionID else { return }
            await follow(connectionID: connectionID)
        }
        .task(id: timedQuestion?.id) {
            guard let question = timedQuestion else { return }
            claimError = await model.attachTimedClaim(
                eventId: question.id,
                agentId: question.sessionId,
                callId: question.callId ?? ""
            )
        }
        .onChange(of: scenePhase) { _, phase in
            // Released on the way out: a claim held through a background has nothing on screen
            // to answer it, and the host would keep its timer paused for nobody.
            if phase != .active { Task { await model.releaseTimedClaim() } }
        }
        .onDisappear {
            Task { await model.releaseTimedClaim() }
        }
        .onAppear {
            #if DEBUG
            if draft.isEmpty,
               let seeded = ProcessInfo.processInfo.environment["DSH_DRAFT"] {
                draft = seeded
            }
            seedAttachmentIfAsked()
            #endif
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            // The only place a security-scoped URL is touched, and only long enough to hand it
            // to the upload: SPEC §9 keeps the scope no longer than the copy.
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            Task { await model.attachFile(at: url, name: url.lastPathComponent, to: sessionId) }
        }
        .onChange(of: draft) { _, text in
            // The visible countdown stops while the answer is being written, which is the
            // local half of the pause SPEC §8 asks for.
            Task {
                if text.isEmpty {
                    await model.resumeTimedClaim()
                } else {
                    await model.pauseTimedClaim()
                }
            }
        }
    }

    /// The timed question this screen holds a foreground claim over, if any.
    ///
    /// SPEC §8: "the native UI owns the foreground claim's lifetime". Attaching pauses the
    /// host's timer, so an unattached claim would let a question expire while its card is on
    /// screen — and a held one with nothing behind it parks the question forever.
    private var timedQuestion: InteractionRequest? {
        model.decisions(for: sessionId).first {
            $0.event == "user-questions/request" && $0.isTimed && $0.state.isActionable
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
            .onChange(of: snapshot.hasSnapshot) { _, ready in
                // A conversation opens at its newest message, not at its oldest. Without
                // this the transcript sat on the harness's own early events and the last
                // exchange — the thing the screen exists for — was a long scroll away.
                guard ready else { return }
                proxy.scrollTo("transcript", anchor: .bottom)
            }
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

    /// Files uploaded for this session and waiting to be cited by the next prompt.
    private var stagedAttachments: [UploadedAttachment] {
        model.stagedAttachments[sessionId] ?? []
    }

    /// The staged files, each removable before the prompt goes out.
    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSHMetrics.space) {
                ForEach(stagedAttachments, id: \.receiptId) { attachment in
                    HStack(spacing: DSHMetrics.spaceSmall) {
                        Image(systemName: "doc")
                            .font(.caption)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(attachment.name.isEmpty ? "Attached file" : attachment.name)
                                .font(.dshMetadata)
                                .foregroundStyle(DSHPalette.primaryText)
                                .lineLimit(1)
                            Text("\(attachment.byteCount) bytes")
                                .font(.caption2)
                                .foregroundStyle(DSHPalette.secondaryText)
                        }
                        Button {
                            model.clearAttachments(for: sessionId)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(DSHPalette.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .padding(.horizontal, DSHMetrics.spaceCard)
                    .padding(.vertical, DSHMetrics.spaceSmall)
                    .background(DSHPalette.card)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(DSHPalette.cardEdge, lineWidth: 1))
                }
            }
            .padding(.horizontal, DSHMetrics.pageMargin)
        }
    }

    /// Commands whose name matches what has been typed after a `/`.
    ///
    /// SPEC §9: typing `/` filters suggestions, and the scope is the session's own list —
    /// an unknown slash word is ordinary prompt text rather than a command to guess at.
    private var commandSuggestions: [CommandEntry] {
        let line = draft.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("/"), !line.contains(" ") else { return [] }
        let typed = line.dropFirst()
        return model.commands[sessionId]?
            .filter { typed.isEmpty || $0.name.hasPrefix(typed) }
            .sorted { $0.name < $1.name } ?? []
    }

    private var commandSuggestionsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(commandSuggestions) { command in
                Button {
                    // The command's own name goes in, with the space that separates it from
                    // whatever the host's hint says it takes.
                    draft = "/\(command.name) "
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: DSHMetrics.spaceSmall) {
                            Text("/\(command.name)")
                                .font(.dshSupporting)
                                .foregroundStyle(DSHPalette.primaryText)
                            if let hint = command.hint {
                                Text(hint)
                                    .font(.dshMetadata)
                                    .foregroundStyle(DSHPalette.secondaryText)
                            }
                        }
                        Text(command.description)
                            .font(.dshMetadata)
                            .foregroundStyle(DSHPalette.secondaryText)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, DSHMetrics.spaceCard)
                    .padding(.vertical, DSHMetrics.spaceSmall + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(DSHPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
        .padding(.horizontal, DSHMetrics.pageMargin)
    }

    private var composer: some View {
        VStack(spacing: DSHMetrics.spaceSmall) {
            if !commandSuggestions.isEmpty { commandSuggestionsView }
            if let message = model.commandMessage {
                Label(message, systemImage: "terminal")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DSHMetrics.pageMargin)
            }
            if let claimError {
                Label(claimError, systemImage: "clock.badge.exclamationmark")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.attention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.attention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !stagedAttachments.isEmpty {
                attachmentChips
            }
            if let attachmentError = model.attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.attention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DSHMetrics.pageMargin)
            }
            Composer(
                text: $draft,
                canSend: sendBlockedReason == nil,
                sendBlockedReason: sendBlockedReason,
                isSending: isSending,
                onAttach: { isImportingFile = true },
                attachmentLabel: "Add a file",
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
        await model.loadCommands(for: sessionId)
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
        defer { isSending = false }

        // A registered slash command goes to `commands/execute`; anything else — including an
        // unknown `/word` — is ordinary prompt text, which is what SPEC §9 asks for rather
        // than silently executing something.
        if model.registeredCommand(for: trimmed, in: sessionId) != nil {
            let outcome = await model.runCommand(trimmed, in: sessionId)
            switch outcome {
            case .ran, .completed:
                // A refusal keeps the line so it can be corrected and sent again; a success
                // clears it. A result with a durable source event is rendered from the
                // transcript, so nothing is echoed here.
                draft = ""
            case .refused:
                sendError = model.commandMessage ?? "The harness refused that command."
            case .none:
                sendError = model.commandMessage ?? "That command did not run."
            }
            return
        }

        do {
            try await model.sendPrompt(trimmed, to: sessionId)
            // Cleared only on acceptance: an uncertain send keeps the text so the user
            // can decide, because this client never resends on its own (SPEC §5).
            draft = ""
        } catch {
            sendError = "That message may not have been sent. It will not be resent."
        }
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

    #if DEBUG
    /// Debug builds only: upload a file a launch named, so the receipt path can be exercised
    /// on a machine that cannot drive a file importer.
    private func seedAttachmentIfAsked() {
        guard stagedAttachments.isEmpty,
              let path = ProcessInfo.processInfo.environment["DSH_ATTACH"],
              !path.isEmpty
        else { return }
        let url = URL(fileURLWithPath: path)
        Task { await model.attachFile(at: url, name: url.lastPathComponent, to: sessionId) }
    }
    #endif

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
        // A launch that attached a file waits for its receipt: the whole point of the receipt
        // is that the prompt cites it, and a race here would send the text without the file.
        if ProcessInfo.processInfo.environment["DSH_ATTACH"] != nil {
            for _ in 0..<60 where stagedAttachments.isEmpty && model.attachmentError == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        await send(message)
    }
}
