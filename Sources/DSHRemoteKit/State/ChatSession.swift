import Foundation

/// Everything a conversation screen renders, as one value.
///
/// SPEC §2: "Expose immutable `Sendable` snapshots through `AsyncStream` and publish on
/// the main actor." The screen observes this rather than polling the actor, which is what
/// the first version of the chat screen had to do and what made a streamed answer update
/// only as often as the poll.
///
/// It carries the *derived* state a screen would otherwise have to compute — whether
/// there is a snapshot yet, whether the history has a hole, whether older pages remain —
/// so the view makes no decisions about the wire.
public struct ConversationSnapshot: Sendable, Hashable {
    /// Which follow baseline this window belongs to. A screen can hold a snapshot
    /// across a rebaseline and tell that it is looking at a different generation.
    public var generation: Int
    public var messages: [ConversationMessage]
    /// Durable events with no message of their own: tool calls, plan updates,
    /// permission changes. Kept so a card can show them instead of nothing.
    public var unmodelledEvents: [DurableEventEnvelope]
    /// False until the host has sent a baseline. The screen shows loading, not an
    /// empty conversation, which SPEC §3 keeps distinct.
    public var hasSnapshot: Bool
    /// A durable sequence was skipped: the history has a hole and says so.
    public var hasGap: Bool
    public var isStreaming: Bool
    /// Set when the follow stream itself failed, as opposed to a resource load.
    public var followError: String?
    /// Live questions waiting on this user.
    public var pendingQuestions: [PendingQuestion]
    /// The opening baseline's watermark, which paging must use.
    public var cursor: Int64?
    /// Whether the host says older history exists behind this window.
    public var canLoadOlder: Bool
    public var isLoadingOlder: Bool
    /// Why the last older-history load failed, if it did.
    public var pageError: String?

    /// Explicit rather than the memberwise default, so a fixture or a preview can build
    /// one: the properties are public, and a screen that cannot be rendered without a
    /// host is a screen that cannot be reviewed on a machine with no Simulator GUI.
    public init(
        generation: Int = 0,
        messages: [ConversationMessage] = [],
        unmodelledEvents: [DurableEventEnvelope] = [],
        hasSnapshot: Bool = false,
        hasGap: Bool = false,
        isStreaming: Bool = false,
        followError: String? = nil,
        pendingQuestions: [PendingQuestion] = [],
        cursor: Int64? = nil,
        canLoadOlder: Bool = false,
        isLoadingOlder: Bool = false,
        pageError: String? = nil
    ) {
        self.generation = generation
        self.messages = messages
        self.unmodelledEvents = unmodelledEvents
        self.hasSnapshot = hasSnapshot
        self.hasGap = hasGap
        self.isStreaming = isStreaming
        self.followError = followError
        self.pendingQuestions = pendingQuestions
        self.cursor = cursor
        self.canLoadOlder = canLoadOlder
        self.isLoadingOlder = isLoadingOlder
        self.pageError = pageError
    }

    /// Nothing loaded yet: what the screen shows before the first publish.
    public static let idle = ConversationSnapshot()
}

/// One older-history request, in the terms the screen and the store both use.
///
/// `throughSeq` is fixed for a follow generation and `beforeSeq` is exclusive
/// (SPEC §7); both come from the window rather than from the caller.
public struct ConversationPageRequest: Sendable, Hashable {
    public var sessionId: String
    public var throughSeq: Int64
    public var beforeSeq: Int64?
    public var maxMessages: Int

    public init(
        sessionId: String,
        throughSeq: Int64,
        beforeSeq: Int64? = nil,
        maxMessages: Int = ChatSession.pageMessages
    ) {
        self.sessionId = sessionId
        self.throughSeq = throughSeq
        self.beforeSeq = beforeSeq
        self.maxMessages = maxMessages
    }
}

/// One older-history page: durable events in sequence order, and whether the host
/// says there are more behind them.
public struct ConversationPage: Sendable, Hashable {
    public var events: [DurableEventEnvelope]
    public var hasMore: Bool

    public init(events: [DurableEventEnvelope], hasMore: Bool) {
        self.events = events
        self.hasMore = hasMore
    }
}

/// The logic half of the chat screen: follows one session and folds its frames
/// into renderable messages. No UI, no view state.
///
/// Deliberately takes a ``MuxClient`` rather than a coordinator: the client is
/// what opens a second logical stream on the socket the coordinator already
/// established, and taking it directly keeps this type testable with the stub
/// transport (SPEC §6.5).
///
/// Reading a conversation and writing to one are separate capabilities (SPEC §4).
/// This type holds the first: it follows, folds, and pages. Sending a prompt stays
/// with the coordinator, which is where the no-retry rule for writes lives.
public actor ChatSession {
    /// How many durable messages one follow baseline or older page asks for.
    ///
    /// **Measured, not chosen.** `URLSessionWebSocketTask` fails an inbound message it
    /// cannot hold with `NSPOSIXErrorDomain 40` ("Message too long"), which presents as a
    /// dead socket rather than as a large reply. Against the installed host on
    /// 2026-10-09, one `session/follow` baseline measured:
    ///
    /// | `maxMessages` | snapshot frame |
    /// | --- | --- |
    /// | 5 | 262 KB |
    /// | 10 | 366 KB |
    /// | 20 | 619 KB — received |
    /// | 60 | 1.28 MB — **rejected**, socket closed |
    ///
    /// So the spec's suggested 60 is a host-side figure this client cannot receive, and 20
    /// is the largest measured value that arrives with room to spare. A longer
    /// conversation is reached by paging, never by one enormous baseline.
    ///
    /// The residual risk is a *single* message larger than the limit — a tool result of
    /// megabytes — which no `maxMessages` value can bound. That ends the stream and
    /// surfaces as a failed follow rather than a truncated history, which is the honest
    /// failure; a transport without this ceiling is the real fix if it ever bites.
    public static let pageMessages = 20

    /// How an older page is fetched. Injected so this type can be exercised without a
    /// socket, and so the RPC path stays in one place.
    public typealias PageLoader = @Sendable (ConversationPageRequest) async throws -> ConversationPage

    private let client: MuxClient
    private let sessionId: String
    private let streamId: String
    private let loadPage: PageLoader?
    public private(set) var hasSnapshot = false
    public private(set) var followError: String?

    private var builder = ConversationBuilder()
    private var pump: Task<Void, Never>?
    /// Questions the harness is waiting on. Keyed by question id — two tool calls
    /// cannot ask the same id without one shadowing the other, which is the right
    /// failure for a UI that has to show one card per question anyway.
    private var questions: [String: PendingQuestion] = [:]
    /// Whether the host says older history exists. Seeded from the baseline's own
    /// `hasMore`, then governed by each page's answer — SPEC §7 makes that value the
    /// authority rather than an inference from how many records a page held.
    private var canLoadOlder = false
    private var isLoadingOlder = false
    private var pageError: String?
    private var subscribers: [UUID: AsyncStream<ConversationSnapshot>.Continuation] = [:]

    /// - Parameters:
    ///   - client: the mux client for a connected host.
    ///   - sessionId: the session to follow, opaque.
    ///   - loadPage: fetches older history. Optional because a session that is only
    ///     being read does not need it, and a caller that never pages gets a
    ///     ``snapshot`` with `canLoadOlder` false rather than a silent no-op.
    public init(client: MuxClient, sessionId: String, loadPage: PageLoader? = nil) {
        self.client = client
        self.sessionId = sessionId
        self.loadPage = loadPage
        // Generated, never reused: a cancelled stream's id must not be handed to
        // a later consumer, which is the leak rule the mux client tests assert.
        self.streamId = "follow-\(UUID().uuidString)"
    }

    /// Builds a session on an already-connected coordinator's socket, with paging
    /// wired to the same connection.
    ///
    /// Returns `nil` when there is no live connection, which is the honest answer:
    /// a screen should not construct a chat that cannot follow anything, and the
    /// coordinator's `status` is what explains why.
    public static func connected(
        to coordinator: ConnectionCoordinator,
        sessionId: String
    ) async -> ChatSession? {
        guard let handle = await coordinator.activeStream() else { return nil }
        return ChatSession(
            client: handle.client,
            sessionId: sessionId,
            loadPage: { request in
                // Through the coordinator, so a page inherits the connection's own
                // status classification and the read path's retry policy.
                try await coordinator.page(request)
            }
        )
    }

    // MARK: - Reading

    public var messages: [ConversationMessage] { builder.messages }

    /// True when a durable seq was skipped, so the UI can say the history has a
    /// hole rather than showing a conversation that looks continuous.
    public var hasGap: Bool { builder.hasGap }

    public var isStreaming: Bool { builder.isStreaming }

    public var unmodelledEvents: [DurableEventEnvelope] { builder.unmodelledEvents }

    /// The current state as one value.
    public func snapshot() -> ConversationSnapshot {
        ConversationSnapshot(
            generation: builder.generation,
            messages: builder.messages,
            unmodelledEvents: builder.unmodelledEvents,
            hasSnapshot: hasSnapshot,
            hasGap: builder.hasGap,
            isStreaming: builder.isStreaming,
            followError: followError,
            pendingQuestions: pendingQuestions,
            cursor: builder.cursor,
            canLoadOlder: canLoadOlder && loadPage != nil,
            isLoadingOlder: isLoadingOlder,
            pageError: pageError
        )
    }

    /// Every state from now on, starting with the current one.
    ///
    /// Buffered newest-only: a token-by-token stream would otherwise queue a snapshot
    /// per frame, and a slow screen would fall further behind the reply it is drawing
    /// (SPEC §2: "Coalesce rapid text updates for rendering, but deliver cancellation,
    /// errors, settlement, and user-input events immediately"). Every snapshot is the
    /// whole state, so a skipped intermediate one costs nothing but an intermediate
    /// frame; errors and settlements are still present in the next value.
    public func snapshots() -> AsyncStream<ConversationSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ConversationSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        subscribers[id] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func publish() {
        guard !subscribers.isEmpty else { return }
        let value = snapshot()
        for continuation in subscribers.values { continuation.yield(value) }
    }

    // MARK: - Lifecycle

    /// Opens the follow stream and starts folding frames. Idempotent: calling it
    /// twice does not open a second stream.
    public func start() async throws {
        guard pump == nil else { return }

        // The captured shape, not a guess: a named `request` whose required
        // `address` is the session form, and `assistantStream` to get live
        // frames alongside the snapshot.
        //
        // `maxMessages` is what keeps the baseline receivable. It is optional on the
        // wire, and leaving it out asks the host for the whole transcript — 1.28 MB for a
        // real session here, which destroys the socket (see ``pageMessages``).
        let args = JSONValue.object([
            "request": .object([
                "address": .object([
                    "kind": .string("session"),
                    "sessionId": .string(sessionId),
                ]),
                "assistantStream": .bool(true),
                "maxMessages": .int(Int64(Self.pageMessages)),
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
        publish()
    }

    // MARK: - Older history

    /// Loads one page of older history, if the host says there is any.
    ///
    /// The page is fetched against this window's generation, so one that raced a
    /// rebaseline is dropped rather than spliced into a conversation it does not
    /// describe (SPEC §7). Concurrent duplicate loads are refused here rather than
    /// left to the caller.
    @discardableResult
    public func loadOlder() async -> Bool {
        guard let loadPage, !isLoadingOlder, canLoadOlder, let throughSeq = builder.cursor else {
            return false
        }
        let generation = builder.generation
        let request = ConversationPageRequest(
            sessionId: sessionId,
            throughSeq: throughSeq,
            beforeSeq: builder.oldestSeq
        )
        isLoadingOlder = true
        pageError = nil
        publish()
        defer { isLoadingOlder = false }

        do {
            let page = try await loadPage(request)
            // A page that completed after a rebaseline names an older generation and
            // `merge` drops it; the `hasMore` answer is dropped with it.
            guard generation == builder.generation else { return false }
            builder.merge(page: page.events, generation: generation)
            canLoadOlder = page.hasMore
        } catch {
            pageError = Self.reason(for: error)
        }
        publish()
        return true
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
            // The baseline's own `hasMore` is the opening answer; a later page's is
            // authoritative from then on.
            canLoadOlder = snapshot.hasMore
            for record in snapshot.records {
                if let event = record.event {
                    collectQuestions(from: event)
                }
            }
        }
        builder.apply(frame)
        publish()
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
        publish()
    }

    private func clearPump() {
        pump = nil
        publish()
    }

    private func recordFollowFailure() {
        followError = followError ?? "The conversation connection closed."
        publish()
    }

    /// The user-facing reason for a failed page, from the error's own readable text.
    static func reason(for error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        if let failure = error as? DshRPCError {
            return failure.readableReason ?? "the host refused the request"
        }
        return String(describing: error)
    }
}
