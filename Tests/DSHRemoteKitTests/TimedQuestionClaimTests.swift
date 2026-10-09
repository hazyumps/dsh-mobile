import Foundation
import Testing
@testable import DSHRemoteKit

// SPEC §8's timed wait is entirely about *order* and *ownership*: attaching is what pauses the
// host's timer, so a claim that is taken late, lost early, or refreshed by a reopened sheet
// answers a question the host is no longer holding open. The tests below name the failure each
// one prevents, and none of them sleeps — the clock and the stream are both injected.

@Suite("Timed question claim")
struct TimedQuestionClaimTests {
    /// Records `$events/result` submissions and lets a test await one without sleeping.
    private actor Submitter {
        private(set) var sent: [EventResultRequest] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func submit(_ request: EventResultRequest) async throws {
            sent.append(request)
            let waiting = waiters
            waiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }

        var count: Int { sent.count }

        /// Suspends until at least one submission has arrived.
        func waitForSubmission() async {
            if !sent.isEmpty { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// A clock the test fires by hand.
    ///
    /// Deliberately *not* cancellation-aware: a real `Task.sleep` throws when its task is
    /// cancelled, and a fake that did the same would hide the token check that protects a
    /// deadline firing after a pause. This one stays suspended and then returns, which is the
    /// race the claim has to survive.
    private actor StubClock {
        private(set) var slept: [Duration] = []
        private var pending: [CheckedContinuation<Void, Never>] = []
        private var sleepWaiters: [CheckedContinuation<Void, Never>] = []

        func sleep(_ duration: Duration) async throws {
            slept.append(duration)
            await withCheckedContinuation { continuation in
                // Register before waking the test's waiter, so a test that sees this sleep can
                // fire it without racing the registration.
                pending.append(continuation)
                let waiting = sleepWaiters
                sleepWaiters.removeAll()
                for waiter in waiting { waiter.resume() }
            }
        }

        /// Suspends until at least `count` waits have been requested.
        func waitForSleeps(_ count: Int) async {
            while slept.count < count {
                await withCheckedContinuation { sleepWaiters.append($0) }
            }
        }

        /// Lets every outstanding deadline pass, as a real clock eventually does.
        func elapse() {
            let waiting = pending
            pending.removeAll()
            for waiter in waiting { waiter.resume() }
        }
    }

    /// The `attachWait` stream: the arguments it was opened with, the frames the test pushes,
    /// and the termination the claim causes when it cancels.
    private actor StreamSource {
        private(set) var opens: [(endpoint: String, args: JSONValue)] = []
        private(set) var terminations = 0
        private var continuation: AsyncThrowingStream<MuxStreamItem, any Error>.Continuation?
        private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
        private var openGate: CheckedContinuation<Void, Never>?
        private var openWaiters: [CheckedContinuation<Void, Never>] = []
        private var isGated = false

        func open(
            endpoint: String,
            args: JSONValue
        ) async throws -> AsyncThrowingStream<MuxStreamItem, any Error> {
            opens.append((endpoint: endpoint, args: args))
            if isGated {
                isGated = false
                await withCheckedContinuation { continuation in
                    openGate = continuation
                    let waiting = openWaiters
                    openWaiters.removeAll()
                    for waiter in waiting { waiter.resume() }
                }
            }
            let (stream, continuation) = AsyncThrowingStream<MuxStreamItem, any Error>.makeStream()
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.markTerminated() }
            }
            return stream
        }

        /// Makes the next `open` wait for ``releaseOpen()``, so a test can act while the attach
        /// is still in flight.
        func gateNextOpen() { isGated = true }

        /// Suspends until a gated `open` is waiting.
        func waitUntilOpenIsWaiting() async {
            if openGate != nil { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }

        func releaseOpen() {
            let gate = openGate
            openGate = nil
            gate?.resume()
        }

        func push(remainingMs: Int64) {
            continuation?.yield(MuxStreamItem(
                streamId: "1",
                frame: MuxFrame(
                    type: .item,
                    streamId: "1",
                    value: .unknown(
                        type: "attach-wait",
                        value: .object(["remainingMs": .int(remainingMs)])
                    )
                )
            ))
        }

        /// The host ends the wait, as a finished `attachWait` stream does.
        func finish() { continuation?.finish() }

        private func markTerminated() {
            terminations += 1
            let waiting = terminationWaiters
            terminationWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
        }

        func waitForTermination() async {
            if terminations > 0 { return }
            await withCheckedContinuation { terminationWaiters.append($0) }
        }
    }

    /// Holds the claim so the store's predicate can be wired before the claim exists — the same
    /// circularity the app has, where the store is created first.
    private actor ClaimHolder {
        private var claim: TimedQuestionClaim?
        func set(_ claim: TimedQuestionClaim) { self.claim = claim }
        func holds(_ eventId: String) async -> Bool {
            guard let claim else { return false }
            return await claim.holds(eventId)
        }
    }

    private static let questionsJSON = JSONValue.array([
        .object([
            "id": .string("q1"),
            "question": .string("Which one?"),
            "options": .array([
                .object(["label": .string("A")]),
                .object(["label": .string("B")]),
            ]),
        ])
    ])

    private func timedWaterfall(
        eventId: String = "e1",
        agentId: String = "session-1",
        callId: String = "call-1"
    ) -> RemoteEvent {
        .waterfall(RemoteWaterfall(
            event: "user-questions/request",
            eventId: eventId,
            agentId: agentId,
            request: .object([
                "callId": .string(callId),
                "questions": Self.questionsJSON,
                "wait": .object(["callId": .string(callId), "timed": .bool(true)]),
            ])
        ))
    }

    private func store(_ submitter: Submitter) -> InteractionStore {
        InteractionStore(
            identity: { RemoteEventRouter.Identity(generation: 1, clientId: "client-1") },
            submit: { try await submitter.submit($0) }
        )
    }

    private func makeClaim(
        store: InteractionStore,
        source: StreamSource,
        clock: StubClock,
        eventId: String = "e1",
        agentId: String = "session-1",
        callId: String = "call-1"
    ) -> TimedQuestionClaim {
        TimedQuestionClaim(
            eventId: eventId,
            agentId: agentId,
            callId: callId,
            store: store,
            openStream: { endpoint, args in
                try await source.open(endpoint: endpoint, args: args)
            },
            clock: { duration in try await clock.sleep(duration) }
        )
    }

    /// Yields until `condition` holds. Yielding is not sleeping: every state change under test
    /// is an actor hop, and this only gives the consumer task those hops.
    private func eventually(_ condition: @Sendable () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            await Task.yield()
        }
    }

    // MARK: - Attach

    @Test("attach opens attachWait with the session and call id, and holds nothing until a frame")
    func attachOpensTheStreamAndWaitsForAFrame() async throws {
        let submitter = Submitter()
        let clock = StubClock()
        let source = StreamSource()
        let claim = makeClaim(store: store(submitter), source: source, clock: clock)

        try await claim.attach()

        // The lookup pair is the wire's: `agentId` carries the session id, and `callId` the tool
        // call — the same pair `userQuestions/answer` takes.
        let opened = try #require(await source.opens.first)
        #expect(opened.endpoint == "userQuestions/attachWait")
        #expect(opened.args["agentId"]?.stringValue == "session-1")
        #expect(opened.args["callId"]?.stringValue == "call-1")

        // Attaching is not claiming. Until the host answers with `remainingMs` there is no proof
        // its timer is paused, and answering now would be answering into a running deadline.
        #expect(await claim.currentState() == .attaching)
        #expect(await claim.holds("e1") == false)
        #expect(await claim.remaining == nil)

        await source.push(remainingMs: 4000)
        #expect(await claim.waitUntilHeld())
        #expect(await claim.holds("e1"))
        #expect(await claim.remaining == .seconds(4))

        await claim.release()
    }

    @Test("attaching twice opens one stream, because a reopened sheet must not restart the wait")
    func attachIsIdempotent() async throws {
        let clock = StubClock()
        let source = StreamSource()
        let claim = makeClaim(store: store(Submitter()), source: source, clock: clock)

        try await claim.attach()
        await source.push(remainingMs: 5000)
        await clock.waitForSleeps(1)

        // The sheet closes and reopens; the host's countdown is already paused by the first
        // attach, and a second one would come back with a fresh, longer window.
        try await claim.attach()

        #expect(await source.opens.count == 1)
        #expect(await claim.remaining == .seconds(5))
        #expect(await clock.slept == [.seconds(5)])
    }

    // MARK: - The deadline

    @Test("the deadline is the host's remainingMs, and a later frame moves it")
    func aLaterFrameMovesTheDeadline() async throws {
        let clock = StubClock()
        let source = StreamSource()
        let claim = makeClaim(store: store(Submitter()), source: source, clock: clock)
        try await claim.attach()

        await source.push(remainingMs: 5000)
        await clock.waitForSleeps(1)
        #expect(await claim.remaining == .seconds(5))

        await source.push(remainingMs: 3000)
        await clock.waitForSleeps(2)
        #expect(await claim.remaining == .seconds(3))
        // Both waits are the host's own figures. Nothing was decremented locally, and the new
        // one replaced the old rather than being added to it.
        #expect(await clock.slept == [.seconds(5), .seconds(3)])
    }

    @Test("a remainingMs of zero arms a deadline that has already passed")
    func zeroRemainingStillArmsADeadline() async throws {
        let clock = StubClock()
        let source = StreamSource()
        let claim = makeClaim(store: store(Submitter()), source: source, clock: clock)
        try await claim.attach()

        await source.push(remainingMs: 0)
        await clock.waitForSleeps(1)

        // The host said there is no time left, so the claim is held and the wait is zero — not
        // unheld, which would leave the question answerable with the host's timer running.
        #expect(await claim.holds("e1"))
        #expect(await clock.slept == [.zero])
    }

    // MARK: - Pause and resume

    @Test("pausing stops the countdown and resuming continues from the host's last figure")
    func pauseAndResume() async throws {
        let clock = StubClock()
        let source = StreamSource()
        let claim = makeClaim(store: store(Submitter()), source: source, clock: clock)
        try await claim.attach()
        await source.push(remainingMs: 5000)
        await clock.waitForSleeps(1)

        await claim.pause()
        #expect(await claim.currentState() == .paused)
        #expect(await claim.remaining == .seconds(5))
        // Still held: the host's timer is paused on this client's behalf, which is the whole
        // reason the question may be answered at all.
        #expect(await claim.holds("e1"))

        // A fresh frame is the one thing allowed to move the deadline, paused or not.
        await source.push(remainingMs: 4000)
        await eventually { await claim.remaining == .seconds(4) }
        #expect(await claim.remaining == .seconds(4))
        #expect(await clock.slept == [.seconds(5)])

        await claim.resume()
        await clock.waitForSleeps(2)
        // Resumed from the host's figure, not from a locally remembered elapsed time.
        #expect(await clock.slept == [.seconds(5), .seconds(4)])
        #expect(await claim.currentState() == .held)
    }

    // MARK: - The unattended timeout

    @Test("an unattended deadline sends the exact ASK_TIMED_OUT refusal")
    func unattendedDeadlineSendsTheRefusal() async throws {
        let submitter = Submitter()
        let store = store(submitter)
        await store.observe(timedWaterfall(), generation: 1)
        let clock = StubClock()
        let source = StreamSource()
        let claim = makeClaim(store: store, source: source, clock: clock)
        try await claim.attach()
        await source.push(remainingMs: 5000)
        await clock.waitForSleeps(1)

        await clock.elapse()
        await submitter.waitForSubmission()

        let sent = try #require(await submitter.sent.first)
        #expect(sent.eventId == "e1")
        #expect(sent.clientId == "client-1")
        // The exact wire shape, asserted literally: the host matches these strings, and a
        // near-miss is silently not a timeout.
        #expect(sent.outcome.jsonValue["kind"]?.stringValue == "rejected")
        let error = try #require(sent.outcome.jsonValue["error"])
        #expect(error["name"]?.stringValue == "UserQuestionError")
        #expect(error["message"]?.stringValue == "ask_user_question timed out before the user answered")
        #expect(error["code"]?.stringValue == "ASK_TIMED_OUT")

        // One submission, never a retry: SPEC §8 reconciles to what the host said, and the
        // store's own state is that reconciliation.
        #expect(await submitter.count == 1)
        #expect(await store.request("e1")?.state == .settled)
        #expect(await claim.timedOut)
        #expect(await claim.currentState() == .released)
        #expect(await claim.holds("e1") == false)
    }

    @Test("a deadline that fires while the sheet is paused is not an unattended timeout")
    func aPausedClaimDoesNotTimeOut() async throws {
        let submitter = Submitter()
        let store = store(submitter)
        await store.observe(timedWaterfall(), generation: 1)
        let clock = StubClock()
        let source = StreamSource()
        let claim = makeClaim(store: store, source: source, clock: clock)
        try await claim.attach()
        await source.push(remainingMs: 5000)
        await clock.waitForSleeps(1)

        await claim.pause()
        // The host's timer fires at the same instant as the pause tap. Someone is looking at
        // the screen, so this must not be read as an unattended timeout.
        await clock.elapse()
        await claim.resume()
        await clock.waitForSleeps(2)
        #expect(await claim.timedOut == false)

        // And the resumed deadline is a real one: unattended, it still refuses.
        await clock.elapse()
        await submitter.waitForSubmission()
        #expect(await submitter.count == 1)
        #expect(await submitter.sent.first?.outcome.jsonValue["error"]?["code"]?.stringValue == "ASK_TIMED_OUT")
    }

    // MARK: - Release

    @Test("release cancels the stream, and releasing twice is harmless")
    func releaseCancelsTheStreamOnce() async throws {
        let source = StreamSource()
        let claim = makeClaim(store: store(Submitter()), source: source, clock: StubClock())
        try await claim.attach()
        await source.push(remainingMs: 5000)
        #expect(await claim.waitUntilHeld())

        await claim.release()
        // Cancelling the consumer finishes the stream, which is what sends the mux cancel for
        // this stream and nothing else.
        await source.waitForTermination()
        #expect(await source.terminations == 1)
        #expect(await claim.currentState() == .released)
        #expect(await claim.holds("e1") == false)

        await claim.release()
        #expect(await source.terminations == 1)
        #expect(await source.opens.count == 1)
    }

    @Test("release before attach is harmless and opens nothing")
    func releaseBeforeAttachIsHarmless() async throws {
        let source = StreamSource()
        let claim = makeClaim(store: store(Submitter()), source: source, clock: StubClock())

        // The screen went to the background on first appearance, before the stream was opened.
        await claim.release()
        #expect(await claim.currentState() == .released)
        #expect(await claim.holds("e1") == false)
        #expect(await claim.timedOut == false)
        #expect(await source.opens.isEmpty)

        // Releasing is terminal: a released claim does not quietly reattach and hold a timer
        // with nothing on screen.
        try await claim.attach()
        #expect(await source.opens.isEmpty)
    }

    @Test("a release while the attach is still in flight cancels the stream")
    func releaseDuringAttachCancelsTheStream() async throws {
        let source = StreamSource()
        let claim = makeClaim(store: store(Submitter()), source: source, clock: StubClock())
        await source.gateNextOpen()

        let attaching = Task { try await claim.attach() }
        await source.waitUntilOpenIsWaiting()
        // The host switch arrives while the open is on the wire. Skipping the stream here would
        // leave the host streaming into a subscription nothing reads.
        await claim.release()
        await source.releaseOpen()
        try await attaching.value

        await source.waitForTermination()
        #expect(await source.terminations == 1)
        #expect(await claim.currentState() == .released)
        #expect(await source.opens.count == 1)
    }

    @Test("the host ending the wait drops the claim")
    func streamEndingDropsTheClaim() async throws {
        let source = StreamSource()
        let claim = makeClaim(store: store(Submitter()), source: source, clock: StubClock())
        try await claim.attach()
        await source.push(remainingMs: 5000)
        #expect(await claim.waitUntilHeld())

        // The host ends `attachWait`: its timer is running again, so a claim held here would
        // be a claim with nothing behind it.
        await source.finish()
        await eventually { await claim.currentState() == .released }
        #expect(await claim.currentState() == .released)
        #expect(await claim.holds("e1") == false)
    }

    // MARK: - The store's gate

    @Test("a held claim is what lets the store answer a timed question")
    func aHeldClaimUnlocksTheTimedQuestion() async throws {
        let submitter = Submitter()
        let holder = ClaimHolder()
        let store = InteractionStore(
            identity: { RemoteEventRouter.Identity(generation: 1, clientId: "client-1") },
            submit: { try await submitter.submit($0) },
            holdsTimedClaim: { await holder.holds($0) }
        )
        await store.observe(timedWaterfall(), generation: 1)

        // The refusal stands until a claim is held. This is the gap the claim closes.
        await #expect(throws: InteractionRefusal.timedQuestionNeedsClaim) {
            try await store.answerLiveQuestions("e1", with: [QuestionAnswer(id: "q1", selected: ["A"])])
        }

        let clock = StubClock()
        let source = StreamSource()
        let claim = makeClaim(store: store, source: source, clock: clock)
        await holder.set(claim)
        try await claim.attach()
        await source.push(remainingMs: 4000)
        #expect(await claim.waitUntilHeld())

        try await store.answerLiveQuestions("e1", with: [QuestionAnswer(id: "q1", selected: ["A"])])
        await submitter.waitForSubmission()
        let sent = try #require(await submitter.sent.first)
        #expect(sent.outcome.jsonValue["kind"]?.stringValue == "result")
        #expect(sent.outcome.jsonValue["value"]?["answers"]?.arrayValue?.first?["id"]?.stringValue == "q1")
    }
}
