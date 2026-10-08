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
    @State private var isSending = false
    @State private var sendError: String?
    @State private var isOpen = false

    var body: some View {
        Group {
            if isOpen {
                conversation
            } else {
                ProgressView("Opening conversation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard session == nil else { return }
            let opened = await model.chatSession(for: sessionId)
            session = opened
            guard let opened else { return }
            do {
                try await opened.start()
                isOpen = true
                await watch(opened)
            } catch {
                sendError = "Could not follow this conversation."
            }
        }
        .onDisappear {
            let closing = session
            session = nil
            Task { await closing?.stop() }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
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

            composer
        }
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
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
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
    private func watch(_ session: ChatSession) async {
        while !Task.isCancelled {
            let next = await session.messages
            if next.count != messages.count { messages = next }
            hasGap = await session.hasGap
            isStreaming = await session.isStreaming
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

private struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                Text(reasoning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(message.text)
                .foregroundStyle(message.isProvisional ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(message.isProvisional ? Color.secondary.opacity(0.1) : Color.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .textSelection(.enabled)
    }
}
