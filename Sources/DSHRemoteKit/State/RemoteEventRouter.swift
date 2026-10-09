import Foundation

/// The one consumer of a ready generation's `$events` stream.
///
/// SPEC §2 gives this type exactly one reason to exist: the coordinator's post-ready
/// `$events` reader used to *discard* every frame, which kept the socket alive but lost
/// every approval and question the host sent. This replaces that loop.
///
/// ```
/// | `RemoteEventRouter` | One ready generation, actor | Single `$events` consumer,
///   typed remote events, cancellation, pending event correlation |
///   A second competing iterator on `$events` |
/// ```
///
/// ## Identity is the isolation
///
/// There is one router per ready generation, and it is never reused. A consumer holds
/// the router it subscribed to, so a frame from an abandoned socket cannot reach a
/// consumer of the generation that replaced it — the SPEC §2 "connectivity generation"
/// guard, expressed structurally rather than as a field every callback must remember to
/// check. Retiring the old router retires every subscription with it.
///
/// The host may replay the **same `eventId`** to a new client after a reconnect
/// (`openRemoteEvents` re-delivers every pending event to the client that just
/// connected). Because the replay lands in the new generation's router, the old
/// correlation is simply gone; nothing has to compare event IDs to notice.
///
/// ## Not losing the first event
///
/// `openRemoteEvents` delivers pending events *before* the ready frame it was opened
/// for, and stores mount only after the handshake returns. Frames in that window are
/// buffered here and flushed to the first subscriber, which is what makes SPEC §3's
/// "An event arriving immediately after ready must not be lost while stores mount"
/// true rather than aspirational.
///
/// The pre-attach buffer is bounded. Once a subscriber exists, events are delivered
/// live; a subscriber that stops consuming grows its own queue, and bounding *that* is
/// the rendering coalescing SPEC §2 describes, which lands with the conversation
/// renderer rather than here.
public actor RemoteEventRouter {
    /// Which ready generation this router speaks for, and the `clientId` that addresses
    /// its results. Together they are the correlation tuple SPEC §2 lists as
    /// "Ready `clientId` + remote `eventId`".
    public struct Identity: Sendable, Hashable {
        public var generation: ConnectionCoordinator.Generation
        /// The `clientId` from the ready frame. Every `$events/result` for an event this
        /// router delivered must carry it, or the host ignores the result:
        ///
        /// ```js
        /// const pending = this.pendingRemoteEvents.get(result.eventId);
        /// if (pending === void 0 || !pending.deliveries.has(client)) return;
        /// ```
        public var clientId: String

        public init(generation: ConnectionCoordinator.Generation, clientId: String) {
            self.generation = generation
            self.clientId = clientId
        }
    }

    /// How many frames may wait for the first subscriber before the oldest are dropped.
    ///
    /// The window is the handful of frames the host replays ahead of the ready frame, so
    /// this is a leak guard rather than a queue depth. Reaching it means subscribers never
    /// mounted, which is a bug worth surfacing instead of a memory ceiling worth tuning.
    public static let preAttachCapacity = 256

    /// This router's generation and `clientId`.
    ///
    /// `nonisolated` so a consumer can correlate, log, or compare identities without
    /// hopping onto the actor — the value is fixed for the router's whole life, which is
    /// what makes it usable as an owner token.
    public nonisolated let identity: Identity

    /// Every `waterfall` currently delivered to this generation and not yet retired,
    /// keyed by `eventId`.
    ///
    /// SPEC §8's rule that an answer must not be replayed rests on knowing what is still
    /// open: `cancel` retires a delivery, and a settled request's delivery is retired
    /// **before** its `cancel` frame is sent (`finishRemoteEvent` calls
    /// `removeRemoteEventDelivery` for every client and then queues the cancellation), so
    /// a delivered-but-unretired event is the only one that can still be answered.
    public private(set) var pendingDeliveries: [String: RemoteWaterfall] = [:]

    /// Frames dropped before the first subscriber arrived, if any. Non-zero means the
    /// consumer missed events and should reconcile rather than assume it saw everything.
    public private(set) var droppedBeforeAttach = 0

    /// Whether a consumer has started. Guards against the second competing iterator
    /// SPEC §2 forbids.
    public private(set) var isRunning = false

    private var subscribers: [UUID: AsyncStream<RemoteEvent>.Continuation] = [:]
    private var buffer: [RemoteEvent] = []
    private var hasEverAttached = false
    private var isFinished = false
    private var consumeTask: Task<Void, Never>?
    private let onEnded: @Sendable (any Error) async -> Void

    /// - Parameter onEnded: Called when the stream ends or fails, so recovery runs once.
    ///   `ConnectionCoordinator` supplies its `streamEnded(generation:error:)`, which
    ///   guards on the generation itself — a late report from a torn-down router cannot
    ///   demote the connection that replaced it.
    public init(
        identity: Identity,
        onEnded: @escaping @Sendable (any Error) async -> Void
    ) {
        self.identity = identity
        self.onEnded = onEnded
    }

    // MARK: - Subscribing

    /// A stream of this generation's events.
    ///
    /// Includes the current state so a subscriber that attaches after the buffer flush
    /// still sees everything the host sent before it mounted.
    ///
    /// Cancelling the returned stream removes the subscription, which is what lets a
    /// navigating-away screen stop receiving without touching the socket.
    ///
    /// A subscriber that arrives **after** this router was retired gets the buffered prefix
    /// and then an immediately finished stream. Without that, `for await` over a retired
    /// router's events parks forever — the router never finishes a subscription it never
    /// saw — so a screen that mounted one frame late would hang instead of finding nothing.
    /// It is a race, which is why it surfaced under load: the reconnect test caught it.
    public func events() -> AsyncStream<RemoteEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RemoteEvent>.makeStream()
        let prefix = drainBufferForFirstSubscriber()
        if isFinished {
            for event in prefix { continuation.yield(event) }
            continuation.finish()
            return stream
        }
        subscribers[id] = continuation
        for event in prefix { continuation.yield(event) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// The buffered prefix, handed to the first subscriber only.
    ///
    /// Deliberately one-shot: a second subscriber must not receive a replay of frames the
    /// first one has already acted on. Two screens showing the same approval is the
    /// duplicate-decision hazard SPEC §3.5 rules out.
    private func drainBufferForFirstSubscriber() -> [RemoteEvent] {
        guard !hasEverAttached else { return [] }
        hasEverAttached = true
        let events = buffer
        buffer.removeAll()
        return events
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    /// How many subscribers are attached. Diagnostics and tests.
    public var subscriberCount: Int { subscribers.count }

    // MARK: - Running

    /// Consumes `$events` until it ends, fails, or ``cancel()`` stops it.
    ///
    /// Must be called exactly once, by the coordinator that owns the stream. A second
    /// call is refused rather than served, because two iterators on one
    /// `AsyncThrowingStream` silently split the frames between them — the failure SPEC §2
    /// names explicitly.
    ///
    /// The loop is owned by the router rather than by the caller, so ``cancel()`` can
    /// always stop it. That matters: a caller that had to cancel the task *and* retire the
    /// router could get the order wrong, and a loop left suspended on a stream nobody will
    /// feed again is a leak that looks like a hang. This is the same shape
    /// ``MuxClient``'s receive loop uses.
    ///
    /// Failures are reported through `onEnded` rather than thrown, so recovery has one
    /// entry point and nothing has to catch out of a detached task.
    public func start(_ stream: AsyncThrowingStream<MuxStreamItem, any Error>) {
        guard !isRunning, !isFinished else { return }
        isRunning = true
        consumeTask = Task { [weak self] in
            await self?.consume(stream)
        }
    }

    private func consume(_ stream: AsyncThrowingStream<MuxStreamItem, any Error>) async {
        do {
            for try await item in stream {
                if Task.isCancelled { return await finish(silently: true) }
                if case .stop(let error) = receive(item) {
                    return await finish(with: error)
                }
            }
            // A cancelled `AsyncThrowingStream` iteration can end without throwing, so the
            // cancellation check is repeated here. Without it, a deliberate teardown would
            // report a spurious transport interruption and trigger a pointless reconnect.
            if Task.isCancelled { return await finish(silently: true) }
            // The sequence ended without a frame saying so. A logical end is a lost
            // connection: SPEC §2 requires treating an ended event stream as one.
            await finish(with: ConnectionCoordinator.ConnectError.transportInterruption(
                detail: "the events stream ended"
            ))
        } catch {
            if Task.isCancelled { return await finish(silently: true) }
            await finish(with: error)
        }
    }

    /// Whether the loop should keep reading.
    private enum Disposition {
        case keepGoing
        case stop(any Error)
    }

    /// Decodes one frame and dispatches it.
    private func receive(_ item: MuxStreamItem) -> Disposition {
        switch item.frame.type {
        case .item:
            guard let value = item.frame.value, let event = RemoteEvent(value) else {
                return .keepGoing
            }
            dispatch(event)
            return .keepGoing

        case .error:
            // The host refused or failed this stream. Waiting for more frames would only
            // delay the same answer, so this ends the connection with what the host said.
            return .stop(ConnectionCoordinator.ConnectError.streamRejected(
                streamId: ConnectionCoordinator.eventsStreamID(for: identity.generation),
                detail: ConnectionCoordinator.describe(item.frame)
            ))

        case .end:
            return .stop(ConnectionCoordinator.ConnectError.transportInterruption(
                detail: "the host ended the events stream"
            ))

        case .unknown:
            // A frame type this build does not model. Ignored rather than fatal: the
            // socket is still the same socket, and SPEC §5 keeps unknown shapes readable
            // instead of letting one end the stream.
            return .keepGoing
        }
    }

    private func dispatch(_ event: RemoteEvent) {
        // Correlation first, so a subscriber that reacts by submitting a result finds the
        // delivery already recorded.
        switch event {
        case .waterfall(let waterfall):
            pendingDeliveries[waterfall.eventId] = waterfall
        case .cancel(let eventId):
            // Retiring on cancel is correct for every reason a cancel arrives — answered
            // here, answered elsewhere, or aborted. The frame carries no reason and this
            // type does not invent one.
            pendingDeliveries.removeValue(forKey: eventId)
        case .ready, .emit, .unknown:
            break
        }

        guard hasEverAttached else {
            if buffer.count >= Self.preAttachCapacity {
                buffer.removeFirst()
                droppedBeforeAttach += 1
            }
            buffer.append(event)
            return
        }

        for continuation in subscribers.values { continuation.yield(event) }
    }

    /// Ends the router: retires deliveries, closes every subscriber, reports once.
    private func finish(with error: any Error? = nil, silently: Bool = false) async {
        guard !isFinished else { return }
        isFinished = true

        // Nothing delivered by this generation can be answered once it is gone, and the
        // host retires the deliveries on its side too (`removeRemoteEventClient`).
        pendingDeliveries.removeAll()
        buffer.removeAll()
        let open = subscribers
        subscribers.removeAll()
        for continuation in open.values { continuation.finish() }

        // An explicit teardown is not a failure to recover from. A *logical end* is:
        // `consume` passes an error for that case, so only the cancelled path stays silent.
        if !silently, let error { await onEnded(error) }
    }

    /// Whether `eventId` is still answerable by this generation.
    ///
    /// The check that stops an answer being submitted for a request some other client
    /// already settled.
    public func isDelivered(_ eventId: String) -> Bool {
        pendingDeliveries[eventId] != nil
    }

    /// Ends the router deliberately: stops the consumer, retires every delivery, closes
    /// every subscriber, and reports nothing.
    ///
    /// Safe to call at any time, including before ``start(_:)``, more than once, and while
    /// the consumer is mid-frame. Stopping the loop is part of the contract rather than
    /// the caller's job — see ``start(_:)``.
    public func cancel() async {
        let task = consumeTask
        consumeTask = nil
        task?.cancel()
        await task?.value
        await finish(silently: true)
    }
}
