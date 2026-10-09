import DSHRemoteKit
import SwiftUI

/// One conversation: what the host said, and a place to answer it.
///
/// SPEC §3.4: reading a session and sending to it are separate capabilities. The
/// view reaches both through ``AppModel`` — `chatSession(for:)` to follow, and
/// `sendPrompt(_:to:)` to write — so it never holds the coordinator itself.
///
/// The messages are polled rather than observed, because ``ChatSession`` is an
/// actor and SwiftUI cannot observe one. That is a deliberate v1 trade: a proper
/// observation hook (`AsyncStream` of rendered messages) belongs in the kit, and
/// polling a value a few times a second is what it costs to not have it yet.
struct ChatView: View {
    let sessionId: String

    @Environment(AppModel.self) private var model

    @State private var session: ChatSession?
    @State private var messages: [ConversationMessage] = []
    @State private var hasGap = false
    @State private var isStreaming = false
    @State private var draft = ""
    @State private var questions: [PendingQuestion] = []
    @State private var isSending = false
    @State private var sendError: String?
    @State private var openError: String?
    @State private var isOpen = false
    @State private var isRefreshingConversation = true
    @State private var followAttempt = 0
    @State private var didSendLaunchMessage = false

    private struct FollowKey: Hashable {
        let connectionID: UUID?
        let attempt: Int
    }

    var body: some View {
        Group {
            if isOpen {
                conversation
            } else if model.status == .pairingRequired || model.status == .hostUnavailable {
                ContentUnavailableView {
                    Label(model.status.label, systemImage: "wifi.exclamationmark")
                } description: {
                    Text(model.connectionError ?? "Open the host to check its connection.")
                }
            } else if let openError {
                // Before this, a failed open showed a spinner forever: the error
                // was only rendered inside the composer, which does not exist
                // until the conversation is open. A dead end with no explanation
                // and no way forward.
                ContentUnavailableView {
                    Label("Can't open this conversation", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(openError)
                } actions: {
                    Button("Try again") { followAttempt += 1 }
                        .disabled(!model.status.isUsable)
                }
            } else {
                ProgressView(model.status.isUsable ? "Opening conversation…" : model.status.label)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                StatusBadge(status: model.status)
            }
        }
        .task(id: FollowKey(connectionID: model.connectionID, attempt: followAttempt)) {
            guard let connectionID = model.connectionID else { return }
            await open(connectionID: connectionID)
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            if !model.status.isUsable {
                Label(model.connectionError ?? model.status.label, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else if let openError {
                HStack {
                    Text(openError)
                    Button("Retry") { followAttempt += 1 }
                }
                .font(.footnote)
                .padding(8)
            } else if isRefreshingConversation {
                ProgressView("Updating conversation…")
                    .font(.footnote)
                    .padding(8)
            }
            if hasGap {
                // SPEC §6.9: a hole in the history is said out loud rather than
                // shown as a conversation that looks continuous.
                Label("Some of this conversation is missing.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages, id: \.id) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                        if isStreaming {
                            HStack(spacing: 6) {
                                ProgressView()
                                Text("Working…").foregroundStyle(.secondary)
                            }
                            .font(.footnote)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) {
                    guard let last = messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            // A question the harness is waiting on. Without this the session
            // stalls until somebody reaches a computer, which is the one thing
            // the app's own empty state promises it will not do.
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = question.header {
                        Text(header).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(question.question).font(.callout)
                    ForEach(question.options) { option in
                        Button(option.label) {
                            Task { await answer(question, selecting: [option.label]) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!model.status.isUsable || isRefreshingConversation)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            composer
        }
    }

    /// Sends one answer and drops the card, whichever way it went — a failed
    /// answer is reported rather than left sitting under a dead button.
    private func answer(_ question: PendingQuestion, selecting selected: [String]) async {
        do {
            // The returned Bool is NOT a reliable "applied" signal: a live
            // round-trip answered a question successfully — the tool returned and
            // the agent continued — while still reporting `false`. So an accepted
            // call clears the card, and the value is not shown to the user rather
            // than being used to claim something untrue in either direction.
            _ = try await model.answerQuestion(
                sessionId: sessionId,
                callId: question.callId,
                questionId: question.id,
                selected: selected
            )
            await session?.markAnswered(questionId: question.id)
        } catch {
            sendError = "That answer may not have been sent. It will not be resent."
        }
        questions = await session?.pendingQuestions ?? []
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                Button {
                    Task { await send() }
                } label: {
                    if isSending {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending
                          || !model.status.isUsable || isRefreshingConversation)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Opens the conversation, or records why it could not be opened. Extracted
    /// so the error state's retry runs the same path the first attempt did.
    private func open(connectionID: UUID) async {
        openError = nil
        isRefreshingConversation = true
        guard let opened = await model.chatSession(for: sessionId),
              !Task.isCancelled, connectionID == model.connectionID else { return }
        session = opened
        do {
            try await opened.start()
            await watch(opened, connectionID: connectionID)
        } catch {
            if !Task.isCancelled, connectionID == model.connectionID {
                openError = "The harness did not open this conversation."
            }
        }
        await opened.stop()
        if session === opened { session = nil }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, model.status.isUsable, !isRefreshingConversation else { return }
        isSending = true
        sendError = nil
        do {
            try await model.sendPrompt(text, to: sessionId)
            draft = ""
        } catch {
            // SPEC §3.4: the send is not repeated. The draft stays so the user can
            // decide what to do about a prompt whose fate is unknown.
            sendError = "That message may not have been sent. It will not be resent."
        }
        isSending = false
    }

    /// Copies the session's state into view state until the screen goes away.
    private func watch(_ session: ChatSession, connectionID: UUID) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !Task.isCancelled, connectionID == model.connectionID {
            let ready = await session.hasSnapshot
            let next = await session.messages
            let failure = await session.followError
            let gap = await session.hasGap
            let streaming = await session.isStreaming
            let pending = await session.pendingQuestions
            guard !Task.isCancelled, connectionID == model.connectionID else { return }
            // Preserve the cached conversation until a complete new baseline
            // arrives, including replacements with the same number of messages.
            if ready {
                if next != messages { messages = next }
                isOpen = true
                isRefreshingConversation = false
            }
            if let error = failure {
                isRefreshingConversation = true
                openError = error
                return
            }
            if !ready, ContinuousClock.now >= deadline {
                openError = "The harness has not sent the conversation yet."
                return
            }
            hasGap = gap
            isStreaming = streaming
            if ready { questions = pending }
            if ready, !didSendLaunchMessage, let message = model.launchMessage {
                didSendLaunchMessage = true
                draft = message
                await send()
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

private struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                Text(Self.rendered(reasoning))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(Self.rendered(message.text))
                .foregroundStyle(message.isProvisional ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(message.isProvisional ? Color.secondary.opacity(0.1) : Color.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .textSelection(.enabled)
    }

    /// Agent output is markdown, and until this it arrived as literal `##` and
    /// `**` — visible in the first real conversation the app rendered.
    ///
    /// Inline-only **on purpose, and this is the second attempt**. Full block
    /// parsing renders headings and lists properly, but it also swallows the line
    /// breaks, turning a structured answer into one wall of text — measurably
    /// worse to read than the literal markers it replaced. Inline-only keeps
    /// emphasis, code spans and paragraph structure; the cost is that a line
    /// starting with `#` shows its hashes.
    private static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}
