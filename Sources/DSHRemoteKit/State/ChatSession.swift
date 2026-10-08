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

    private var builder = ConversationBuilder()
    private var pump: Task<Void, Never>?

    /// - Parameters:
    ///   - client: the mux client for a connected host.
    ///   - sessionId: the session to follow, opaque.
    public init(client: MuxClient, sessionId: String) {
        self.client = client
        self.sessionId = sessionId
        // Generated, never reused: a cancelled stream's id must not be handed to
        // a later consumer, which is the leak rule the mux client tests assert.
        self.streamId = "follow-\(sessionId)"
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
            } catch {
                // A dead socket ends the stream; the connection's status is the
                // place that failure belongs, not this conversation's contents.
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
        builder.apply(frame)
    }

    private func clearPump() {
        pump = nil
    }
}
