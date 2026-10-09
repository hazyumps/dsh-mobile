import Foundation

/// The logic half of the chat screen: follows one session and folds its frames
/// into renderable messages. No UI, no view state.
///
/// Deliberately takes a ``MuxClient`` rather than a coordinator: the client is
/// what opens a second logical stream on the socket the coordinator already
/// established, and taking it directly keeps this type testable with the stub
/// transport (SPEC §6.5).
///
/// It sends nothing yet. Prompting, paging older history, and the composer's
/// draft handling are the next slice, and each needs its own arguments and its
/// own tests.
public actor ChatSession {
    private let client: MuxClient
    private let sessionId: String
    private let streamId: String
    public private(set) var hasSnapshot = false
    public private(set) var followError: String?

    private var builder = ConversationBuilder()
    private var pump: Task<Void, Never>?
    /// Questions the harness is waiting on. Keyed by question id — two tool calls
    /// cannot ask the same id without one shadowing the other, which is the right
    /// failure for a UI that has to show one card per question anyway.
    private var questions: [String: PendingQuestion] = [:]

    /// - Parameters:
    ///   - client: the mux client for a connected host.
    ///   - sessionId: the session to follow, opaque.
    public init(client: MuxClient, sessionId: String) {
        self.client = client
        self.sessionId = sessionId
        // Generated, never reused: a cancelled stream's id must not be handed to
        // a later consumer, which is the leak rule the mux client tests assert.
        self.streamId = "follow-\(UUID().uuidString)"
    }

    /// Builds a session on an already-connected coordinator's socket.
    ///
    /// Returns `nil` when there is no live connection, which is the honest answer:
    /// a screen should not construct a chat that cannot follow anything, and the
    /// coordinator's `status` is what explains why.
    ///
    /// **Known gap, deliberately left here rather than discovered later:** this
    /// type follows a session over the mux stream, but *sending* a prompt goes
    /// over the unary RPC path (`session/prompt`), which this type does not hold.
    /// So the composer needs either the coordinator passed in alongside, or a
    /// separate prompt-sending type. Reading a conversation and writing to one
    /// are two capabilities, and this type currently has the first.
    public static func connected(
        to coordinator: ConnectionCoordinator,
        sessionId: String
    ) async -> ChatSession? {
        guard let handle = await coordinator.activeStream() else { return nil }
        return ChatSession(client: handle.client, sessionId: sessionId)
    }

    // MARK: - Reading

    public var messages: [ConversationMessage] { builder.messages }

    /// True when a durable seq was skipped, so the UI can say the history has a
    /// hole rather than showing a conversation that looks continuous.
    public var hasGap: Bool { builder.hasGap }

    public var isStreaming: Bool { builder.isStreaming }

    public var unmodelledEvents: [DurableEventEnvelope] { builder.unmodelledEvents }

    // MARK: - Lifecycle

    /// Opens the follow stream and starts folding frames. Idempotent: calling it
    /// twice does not open a second stream.
    public func start() async throws {
        guard pump == nil else { return }

        // The captured shape, not a guess: a named `request` whose required
        // `address` is the session form, and `assistantStream` to get live
        // frames alongside the snapshot.
        let args = JSONValue.object([
            "request": .object([
                "address": .object([
                    "kind": .string("session"),
                    "sessionId": .string(sessionId),
                ]),
                "assistantStream": .bool(true),
            ]),
        ])

        let stream = try await client.open(
            streamId: streamId,
            endpoint: "session/follow",
            args: args
        )

        pump = Task { [weak self] in
            do {
                for try await item in stream {
                    await self?.fold(item.frame)
                }
                if !Task.isCancelled { await self?.recordFollowFailure() }
            } catch {
                // A dead socket ends the stream; the connection's status is the
                // place that failure belongs, not this conversation's contents.
                if !Task.isCancelled { await self?.recordFollowFailure() }
            }
            await self?.clearPump()
        }
    }

    /// Stops following and releases the logical stream. The socket stays open —
    /// other streams share it.
    public func stop() async {
        pump?.cancel()
        pump = nil
        await client.cancel(streamId: streamId)
    }

    // MARK: - Internals

    private func fold(_ frame: MuxFrame) {
        if frame.type == .error {
            followError = ConnectionCoordinator.describe(frame)
        }
        // Questions hide in two places, and missing the first one cost a round:
        // a *fresh* follow receives history as a snapshot whose `records` carry
        // the tool calls, while only events arriving after the follow come as
        // standalone `event` frames. Handling just the latter meant a question
        // asked before you opened the conversation never produced a card.
        if let event = frame.value?.event {
            collectQuestions(from: event)
        }
        if let snapshot = frame.value?.snapshot {
            hasSnapshot = true
            for record in snapshot.records {
                if let event = record.event {
                    collectQuestions(from: event)
                }
            }
        }
        builder.apply(frame)
    }

    private func collectQuestions(from event: DurableEventEnvelope) {
        guard let asked = PendingQuestion.questions(inToolCall: event.data) else { return }
        for question in asked {
            questions[question.id] = question
        }
    }

    /// Questions waiting on an answer, oldest first by id order of arrival.
    public var pendingQuestions: [PendingQuestion] {
        questions.values.sorted { $0.id < $1.id }
    }

    /// Drops a question once its answer has been sent. The host keeps no record
    /// of "answered" that this type can see, so the screen says so explicitly
    /// rather than the card lingering until a reconnect.
    public func markAnswered(questionId: String) {
        questions.removeValue(forKey: questionId)
    }

    private func clearPump() {
        pump = nil
    }

    private func recordFollowFailure() {
        followError = followError ?? "The conversation connection closed."
    }
}
