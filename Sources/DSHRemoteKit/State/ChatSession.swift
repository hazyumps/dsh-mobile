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
    /// Which conversation the page belongs to. A subagent needs its parent address, not its id,
    /// so the address travels with the window rather than being rebuilt from an id at the call.
    public var address: SessionAddress
    public var throughSeq: Int64
    public var beforeSeq: Int64?
    public var maxMessages: Int

    /// The session the window is over: the child's id for a subagent.
    public var sessionId: String { address.sessionId }

    public init(
        address: SessionAddress,
        throughSeq: Int64,
        beforeSeq: Int64? = nil,
        maxMessages: Int = ChatSession.pageMessages
    ) {
        self.address = address
        self.throughSeq = throughSeq
        self.beforeSeq = beforeSeq
        self.maxMessages = maxMessages
    }

    /// An ordinary session's window, which is the only shape that existed before #13.
    public init(
        sessionId: String,
        throughSeq: Int64,
        beforeSeq: Int64? = nil,
        maxMessages: Int = ChatSession.pageMessages
    ) {
        self.init(
            address: .session(sessionId),
            throughSeq: throughSeq,
            beforeSeq: beforeSeq,
            maxMessages: maxMessages
        )
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
    /// Where this conversation is read from. A subagent child needs its parent address, so the
    /// address is what this type holds — not an id it would have to turn back into one
    /// (``SessionAddress``).
    private let address: SessionAddress
    private let streamId: String
    private let loadPage: PageLoader?
    /// Stops the turn this session is running. Optional for the same reason `loadPage` is: a
    /// session folded from fixtures has no transport, and a cancel that cannot be attempted has
    /// to say so rather than look like one that worked.
    private let cancelRun: (() async throws -> Void)?
    public private(set) var hasSnapshot = false
    public private(set) var followError: String?

    private var builder = ConversationBuilder()
    private var pump: Task<Void, Never>?
    /// Questions the harness is waiting on. Keyed by question id — two tool calls
    /// cannot ask the same id without one shadowing the other, which is the right
    /// failure for a UI that has to show one card per question anyway.
    private var questions: [String: PendingQuestion] = [:]
    /// The `(turn, step)` each pending question came from, so the event that settles it can be
    /// recognised. The host does not repeat the call id on the result.
    private var questionScope: [String: (turn: Int64, step: Int64)] = [:]
    /// Whether the host says older history exists. Seeded from the baseline's own
    /// `hasMore`, then governed by each page's answer — SPEC §7 makes that value the
    /// authority rather than an inference from how many records a page held.
    private var canLoadOlder = false
    private var isLoadingOlder = false
    private var pageError: String?
    private var subscribers: [UUID: AsyncStream<ConversationSnapshot>.Continuation] = [:]

    /// - Parameters:
    ///   - client: the mux client for a connected host.
    ///   - address: the conversation to follow. A subagent's address carries its parent and mode;
    ///     the session form is refused for a child (`session/agent-busy`).
    ///   - loadPage: fetches older history. Optional because a session that is only
    ///     being read does not need it, and a caller that never pages gets a
    ///     ``snapshot`` with `canLoadOlder` false rather than a silent no-op.
    public init(
        client: MuxClient,
        address: SessionAddress,
        loadPage: PageLoader? = nil,
        cancelRun: (() async throws -> Void)? = nil
    ) {
        self.client = client
        self.address = address
        self.loadPage = loadPage
        self.cancelRun = cancelRun
        // Generated, never reused: a cancelled stream's id must not be handed to
        // a later consumer, which is the leak rule the mux client tests assert.
        self.streamId = "follow-\(UUID().uuidString)"
    }

    /// An ordinary session's conversation. The shape every caller before #13 used.
    public init(
        client: MuxClient,
        sessionId: String,
        loadPage: PageLoader? = nil,
        cancelRun: (() async throws -> Void)? = nil
    ) {
        self.init(
            client: client,
            address: .session(sessionId),
            loadPage: loadPage,
            cancelRun: cancelRun
        )
    }

    /// The session this conversation orbits: the child's id for a subagent.
    public var sessionId: String { address.sessionId }

    /// Builds a session on an already-connected coordinator's socket, with paging
    /// wired to the same connection.
    ///
    /// Returns `nil` when there is no live connection, which is the honest answer:
    /// a screen should not construct a chat that cannot follow anything, and the
    /// coordinator's `status` is what explains why.
    public static func connected(
        to coordinator: ConnectionCoordinator,
        address: SessionAddress
    ) async -> ChatSession? {
        guard let handle = await coordinator.activeStream() else { return nil }
        return ChatSession(
            client: handle.client,
            address: address,
            loadPage: { request in
                // Through the coordinator, so a page inherits the connection's own
                // status classification and the read path's retry policy.
                try await coordinator.page(request)
            },
            cancelRun: {
                try await coordinator.cancelSession(address.sessionId)
            }
        )
    }

    /// An ordinary session's conversation, on an already-connected coordinator.
    public static func connected(
        to coordinator: ConnectionCoordinator,
        sessionId: String
    ) async -> ChatSession? {
        await connected(to: coordinator, address: .session(sessionId))
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
        //
        // STUB: `address.wire` is the session member for every address, so a subagent follow
        // sends the form the host refuses. See the plan's AC7.
        let args = JSONValue.object([
            "request": .object([
                "address": address.wire,
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
    /// Stops the running turn, which is the only way out of a question nobody wants to answer.
    ///
    /// `userQuestions` offers `answer` and `attachWait` and nothing else — there is no dismiss and
    /// no decline — so a parked question is released by stopping the turn it belongs to. On
    /// success every question this session was holding is cleared: the host stopped the work, so
    /// nothing will ever answer them, and leaving the cards up would offer controls whose every
    /// press is refused.
    ///
    /// Returns a message when the turn could not be stopped; `nil` when it was.
    public func cancel() async -> String? {
        guard let cancelRun else {
            return "This session has no way to stop its turn."
        }
        do {
            try await cancelRun()
        } catch {
            return Self.readableFailure(error)
        }
        for id in questions.keys { questions.removeValue(forKey: id) }
        publish()
        return nil
    }

    /// The host's own description where there is one, so a refusal is not flattened into a
    /// generic sentence.
    static func readableFailure(_ error: any Error) -> String {
        if let refusal = error as? InteractionRefusal { return String(describing: refusal) }
        return String(describing: error)
    }

    public func loadOlder() async -> Bool {
        guard let loadPage, !isLoadingOlder, canLoadOlder, let throughSeq = builder.cursor else {
            return false
        }
        let generation = builder.generation
        let request = ConversationPageRequest(
            address: address,
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
            resolveQuestions(from: event)
        }
        if let snapshot = frame.value?.snapshot {
            hasSnapshot = true
            // The baseline's own `hasMore` is the opening answer; a later page's is
            // authoritative from then on.
            canLoadOlder = snapshot.hasMore
            for record in snapshot.records {
                if let event = record.event {
                    collectQuestions(from: event)
                    resolveQuestions(from: event)
                }
            }
        }
        builder.apply(frame)
        publish()
    }

    private func collectQuestions(from event: DurableEventEnvelope) {
        guard let asked = PendingQuestion.questions(inToolCall: event.data) else { return }
        let scope = Self.scope(of: event.data)
        for question in asked {
            questions[question.id] = question
            questionScope[question.id] = scope
        }
    }

    /// The `(turn, step)` an event belongs to.
    ///
    /// This is how a question is matched to the result that settled it: a `tool/result` carries
    /// no `callId` — the captured payload is `{error, message, step, turn}` — so the call id
    /// cannot be the join. Do not "fix" this by looking for a call id; there is not one.
    private static func scope(of data: JSONValue) -> (turn: Int64, step: Int64)? {
        guard let turn = data["turn"]?.intValue, let step = data["step"]?.intValue else {
            return nil
        }
        return (turn, step)
    }

    /// Drops the question a `tool/result` settles.
    ///
    /// The host's result for the call that asked is the durable record that the question is over
    /// — whether it was answered, cancelled, or abandoned. Nothing else marks it: the log after a
    /// cancelled question reads `tool/call`, `tool/result`, `step/end`, `turn/end`. Without this
    /// the fold kept every question it had ever seen and put the card back as *live* on the next
    /// load, offering a Submit whose every press the host would refuse.
    private func resolveQuestions(from event: DurableEventEnvelope) {
        switch event.type {
        case "tool/result":
            // The result for the step that asked settles it, whatever it says: answered,
            // refused, or errored.
            guard let scope = Self.scope(of: event.data) else { return }
            drop { self.questionScope[$0]?.turn == scope.turn && self.questionScope[$0]?.step == scope.step }
        case "turn/end":
            // A turn cannot end while the agent is parked on a question, so a turn that ends
            // with one still open is a turn that was stopped. Captured after cancelling a parked
            // question: `{"turn":1,"reason":{"kind":"aborted","reason":{"kind":"user"}}}`.
            guard let turn = event.data["turn"]?.intValue else { return }
            drop { self.questionScope[$0]?.turn == turn }
        default:
            break
        }
    }

    private func drop(where matches: (String) -> Bool) {
        for id in questions.keys where matches(id) {
            questions.removeValue(forKey: id)
            questionScope.removeValue(forKey: id)
        }
    }

    /// Questions waiting on an answer, oldest first by id order of arrival.
    public var pendingQuestions: [PendingQuestion] {
        questions.values.sorted { $0.id < $1.id }
    }

    /// Drops a question the moment its answer goes up, without waiting for the host's result to
    /// come back down the stream. The result does arrive and clears it too (see
    /// ``resolveQuestions(from:)``); this is what stops the card sitting there live for a round
    /// trip.
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
