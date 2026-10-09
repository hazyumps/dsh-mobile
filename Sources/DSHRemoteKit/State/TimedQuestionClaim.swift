import Foundation

/// One foreground claim over one timed question.
///
/// SPEC §8's timed wait is a two-part bargain: the host will not accept an answer to a
/// `request.wait:{callId, timed:true}` question until `userQuestions/attachWait` has claimed
/// it, because opening that stream is what *pauses the host's own countdown* while a human
/// looks at the screen. This type owns exactly that stream and exactly that deadline for one
/// question. It deliberately does **not** own the answer: submitting answers stays on
/// ``InteractionStore/answerLiveQuestions(_:with:)``, which asks
/// ``holds(_:)`` before it will answer a timed question.
///
/// The mistakes each rule here prevents:
///
/// - **Answering before attachment.** A claim is not held until the host has said how much
///   time is left, so a sheet cannot appear answerable while the host's timer is still running.
/// - **Guessing the deadline locally.** The remaining time is the host's, verbatim. A local
///   countdown would drift against the timer that actually decides, and SPEC §8 makes the host
///   the authority. The road not taken is a monotonic `now` seam plus local arithmetic.
/// - **Losing the claim silently.** Background, cancellation, host switch, stream end and
///   completion all end in ``release()``: a claim held with nothing on screen would keep a
///   human's question parked forever.
/// - **Replay after a timeout.** The local refusal is sent once. If it is not delivered, the
///   store's own state is the reconciliation; SPEC §8 forbids resending.
public actor TimedQuestionClaim {
    /// Where this claim is in its life.
    public enum State: Sendable, Hashable {
        /// No stream open: before ``attach()``, or after an attach that failed.
        case idle
        /// The stream is open but no `remainingMs` has arrived, so the question is **not**
        /// answerable yet — attachment is only proven by the host's own answer to it.
        case attaching
        /// Held, counting down the last `remainingMs` the host sent.
        case held
        /// Held, but not counting: ``pause()`` cancelled the deadline until ``resume()``.
        case paused
        /// Over. The stream is cancelled and nothing may be answered.
        case released

        /// Whether this client currently owns the foreground claim.
        ///
        /// Paused counts as held: the host's timer is still paused on this client's behalf,
        /// which is the whole reason a timed question is answerable at all. A claim can only be
        /// paused after a `remainingMs` has been seen, so "paused" never means "held before the
        /// host confirmed it".
        public var isHeld: Bool { self == .held || self == .paused }
    }

    /// Opens a logical mux stream — `MuxClient.open(endpoint:args:)`'s shape, injected so a
    /// test can attach without a socket.
    public typealias OpenStream = @Sendable (
        _ endpoint: String,
        _ args: JSONValue
    ) async throws -> AsyncThrowingStream<MuxStreamItem, any Error>

    /// Waits for a duration. Injected so tests need no real time, and so the one place the
    /// countdown touches a clock is replaceable.
    ///
    /// Throwing is how cancellation arrives: a `Task.sleep` behind this closure throws
    /// ``CancellationError`` when the claim is paused or released, which is what stops the
    /// countdown. The fake clock in the tests is deliberately *not* cancellation-aware, so
    /// the token check in ``timeoutFired(token:)`` is exercised rather than assumed.
    public typealias Clock = @Sendable (_ duration: Duration) async throws -> Void

    /// The stream SPEC §8 claims a timed question on.
    public static let endpoint = "userQuestions/attachWait"

    /// The lookup pair `attachWait` takes: `agentId` and `callId`.
    ///
    /// These are the wire names, not local ones: the endpoint rejects anything else, and the
    /// pair is the same one `userQuestions/answer` takes.
    public static func attachArgs(agentId: String, callId: String) -> JSONValue {
        .object([
            "agentId": .string(agentId),
            "callId": .string(callId),
        ])
    }

    /// The refusal sent when the deadline passes with nobody at the screen.
    ///
    /// SPEC §8 names the code, the error name, and the message; a near-miss here is silently
    /// not a timeout on the host, which is why the strings live in one place — and why the
    /// tests assert them literally rather than against this constant.
    public static let timeoutError: JSONValue = .object([
        "name": .string("UserQuestionError"),
        "message": .string("ask_user_question timed out before the user answered"),
        "code": .string("ASK_TIMED_OUT"),
    ])

    /// The waterfall event this claim is over. ``InteractionStore`` keys the claim check on it.
    public let eventId: String
    /// The session the question belongs to — `agentId` on the wire, `sessionId` elsewhere.
    public let agentId: String
    /// The tool call the question belongs to. Together with ``agentId`` this is the claim's
    /// host-side identity.
    public let callId: String

    private let store: InteractionStore
    private let openStream: OpenStream
    private let clock: Clock

    private var state: State = .idle
    /// The last `remainingMs` the host sent, verbatim. Never decremented locally.
    public private(set) var remaining: Duration?
    /// Whether the deadline passed unattended and the refusal was sent.
    public private(set) var timedOut = false

    /// Guards every deadline against a late resume: a firing can only act if it is still the
    /// current arm. Bumped by every fresh frame, pause, resume and release.
    private var epoch: UInt64 = 0
    private var timeoutTask: Task<Void, Never>?
    private var consumeTask: Task<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - eventId: the waterfall's `eventId`, for the refusal that goes back through
    ///     `$events/result`.
    ///   - agentId: the session id the wire calls `agentId`.
    ///   - callId: the tool call the question belongs to.
    ///   - store: the store the refusal is submitted through. The claim does not submit
    ///     `$events/result` itself: the generation check and the submit-once guard are the
    ///     store's, and a second copy of them here would be a second thing to get wrong.
    ///   - openStream: opens the `attachWait` stream.
    ///   - clock: waits out the host's remaining time.
    public init(
        eventId: String,
        agentId: String,
        callId: String,
        store: InteractionStore,
        openStream: @escaping OpenStream,
        clock: @escaping Clock
    ) {
        self.eventId = eventId
        self.agentId = agentId
        self.callId = callId
        self.store = store
        self.openStream = openStream
        self.clock = clock
    }

    // MARK: - Reading

    /// Whether this claim covers `eventId` and is currently held.
    ///
    /// This is what ``InteractionStore`` asks before it answers a timed question, so it is
    /// the one question a caller may ask of a claim without owning it.
    public func holds(_ eventId: String) -> Bool {
        eventId == self.eventId && state.isHeld
    }

    /// The current state, for a screen that has to say why it is not offering controls.
    public func currentState() -> State { state }

    /// Suspends until the claim is held, released, or failed to attach.
    ///
    /// - Returns: whether the claim is held. The gate exists because
    ///   ``InteractionStore/answerLiveQuestions(_:with:)`` refuses a timed question until
    ///   ``holds(_:)`` is true, and a screen that offers the answer path a frame early would
    ///   show a refusal the user cannot act on.
    @discardableResult
    public func waitUntilHeld() async -> Bool {
        while state == .attaching {
            await withCheckedContinuation { holdWaiters.append($0) }
        }
        return state.isHeld
    }

    // MARK: - Attaching

    /// Opens the foreground claim, unless one is already open.
    ///
    /// Returns as soon as the stream is open; the claim is **not** held yet. It becomes held
    /// when the first `remainingMs` arrives, because that frame is the host's confirmation
    /// that the wait is claimed — until then there is nothing to answer against.
    ///
    /// Idempotent on purpose. Reopening the sheet calls this again, and a second attach would
    /// come back with a *fresh* remaining time, restarting a countdown that was already
    /// running; SPEC §8's deadline only moves on a fresh frame from the stream that is already
    /// open. Releasing is terminal, so a released claim never reopens — a reopened sheet wants
    /// a new claim, not a resurrected one.
    public func attach() async throws {
        guard state == .idle else { return }
        state = .attaching

        let stream: AsyncThrowingStream<MuxStreamItem, any Error>
        do {
            stream = try await openStream(Self.endpoint, Self.attachArgs(agentId: agentId, callId: callId))
        } catch {
            // No stream, no claim. Back to idle rather than "held": a claim that cannot be
            // released is worse than one that was never taken, and a caller may try again. A
            // release that landed mid-open keeps its verdict — releasing is terminal.
            if state == .attaching { state = .idle }
            resumeHoldWaiters()
            throw error
        }

        consumeTask = Task { [weak self] in
            do {
                for try await item in stream {
                    guard let value = item.frame.value?.unknownValue else { continue }
                    // Leaving the loop finishes the stream, which is what sends the mux cancel;
                    // there is nothing to hold open for a claim that has been deallocated.
                    guard let self else { return }
                    await self.ingest(value)
                }
            } catch {
                // The socket failed or the host refused the stream. Both mean the wait is
                // over; the claim is dropped below rather than left held with nothing behind it.
            }
            await self?.streamEnded()
        }

        // A release or a host switch may have landed while the open was in flight. The consumer
        // is started and then cancelled rather than skipped, because that is what terminates the
        // stream: an unread `AsyncThrowingStream` buffers everything the host sends, and
        // `MuxClient` only tears the logical stream down when its consumer stops.
        if state != .attaching { cancelStream() }
    }

    /// Applies one `attachWait` item.
    ///
    /// Internal rather than public: the only field that matters is `remainingMs`, and a caller
    /// able to feed arbitrary values could hold a claim the host never granted.
    func ingest(_ value: JSONValue) {
        guard state != .released else { return }
        // A frame without a usable number says nothing about the deadline. Leaving the claim
        // attaching is the honest reading; guessing a deadline is not.
        guard let milliseconds = value["remainingMs"]?.intValue else { return }

        // The host is the authority, paused or not: a fresh frame is the one thing allowed to
        // move the deadline. While paused it moves the stored value but arms nothing, because
        // the whole point of pausing is that no countdown runs.
        remaining = .milliseconds(max(0, milliseconds))
        guard state != .paused else { return }

        state = .held
        resumeHoldWaiters()
        armTimeout()
    }

    private func armTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
        epoch &+= 1
        let token = epoch
        guard let remaining else { return }
        let clock = self.clock
        timeoutTask = Task { [weak self] in
            do {
                try await clock(remaining)
            } catch {
                // Cancelled: paused or released. Not a timeout.
                return
            }
            await self?.timeoutFired(token: token)
        }
    }

    // MARK: - Pause and resume

    /// Stops the countdown without giving up the claim.
    ///
    /// SPEC §8's pause is about the host's timer, and this is the local half of it: the armed
    /// wait is cancelled, so no timeout can fire while the sheet is elsewhere. The claim stays
    /// held, because releasing it would let the host's timer run again.
    ///
    /// Pausing while still ``State/attaching`` does nothing, and that is a choice: there is no
    /// countdown to stop yet, and a paused-but-unattached state would have to report the claim
    /// as held before the host confirmed it — which is exactly the answer-before-attachment
    /// mistake this type exists to prevent. A screen that wants the countdown stopped pauses
    /// once the claim is held.
    public func pause() {
        guard state == .held else { return }
        state = .paused
        dropDeadline()
    }

    /// Resumes the countdown from where the host last said it was.
    ///
    /// Not from a locally remembered elapsed time: the remaining duration is the host's last
    /// `remainingMs`, which is the only figure that cannot disagree with the host's own timer.
    public func resume() {
        guard state == .paused else { return }
        // `.paused` is only reachable from `.held`, and `.held` is only entered with the host's
        // deadline in hand, so there is always something to re-arm.
        state = .held
        armTimeout()
    }

    // MARK: - Releasing

    /// Drops the claim and cancels the stream, whatever state it is in.
    ///
    /// Idempotent, and safe before ``attach()`` has ever run: a screen going to the background
    /// on first appearance must not leave a claim behind, and a second release must not send a
    /// second stream cancel. Releasing is terminal — see ``attach()``.
    public func release() {
        guard state != .released else { return }
        dropDeadline()
        cancelStream()
        state = .released
        resumeHoldWaiters()
    }

    /// The host's wait ended — the stream finished, failed, or was cancelled.
    ///
    /// A claim with no stream behind it is not a claim: the host is no longer pausing anything,
    /// so keeping ``State/held`` would park the question with nothing showing it.
    private func streamEnded() {
        guard state != .released else { return }
        dropDeadline()
        state = .released
        resumeHoldWaiters()
    }

    /// The local deadline passed with nobody at the screen.
    ///
    /// The refusal goes out through the store's normal `$events/result` path, so the
    /// generation check and the submit-once guard apply to a timeout exactly as they do to a
    /// tap. Failures are swallowed and never retried: SPEC §8 reconciles an undelivered answer
    /// rather than replaying it, and the store has already recorded that state.
    private func timeoutFired(token: UInt64) async {
        guard token == epoch, state == .held else { return }
        timedOut = true
        dropDeadline() // bumps the epoch, so a second firing cannot send anything
        cancelStream()
        state = .released
        resumeHoldWaiters()
        // The claim is already released when this lands, which is deliberate: the local
        // deadline is spent, so the claim must not be held while a network round trip runs.
        try? await store.answer(eventId, with: .rejected(error: Self.timeoutError))
    }

    /// Cancels the armed wait and invalidates anything already in flight for it.
    private func dropDeadline() {
        epoch &+= 1
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    /// Cancels the consuming task. `AsyncThrowingStream` finishes on task cancellation, which
    /// fires `MuxClient`'s termination handler and sends the mux `cancel` frame for this stream
    /// only.
    private func cancelStream() {
        consumeTask?.cancel()
        consumeTask = nil
    }

    private func resumeHoldWaiters() {
        let waiters = holdWaiters
        holdWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
