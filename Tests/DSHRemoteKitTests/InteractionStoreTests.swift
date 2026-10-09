import Foundation
import Testing
@testable import DSHRemoteKit

// SPEC §8's rules for approvals are almost all negative — what must NOT happen — so the
// tests here are mostly about refusal, suppression and races rather than about the happy
// path. Each one names the failure it prevents.

@Suite("Interaction store")
struct InteractionStoreTests {
    private actor Submitter {
        private(set) var sent: [EventResultRequest] = []
        private var gate: CheckedContinuation<Void, Never>?
        private var shouldFail = false
        private var shouldBlock = false

        func failNext() { shouldFail = true }
        func blockNext() { shouldBlock = true }

        func submit(_ request: EventResultRequest) async throws {
            sent.append(request)
            if shouldBlock {
                await withCheckedContinuation { gate = $0 }
            }
            if shouldFail {
                shouldFail = false
                throw DshRPCError.transportInterruption(detail: "dropped")
            }
        }

        var count: Int { sent.count }
        var last: EventResultRequest? { sent.last }

        func release() {
            gate?.resume()
            gate = nil
            shouldBlock = false
        }
    }

    /// A snapshot sink the collector task can append to without sending a closure across
    /// isolation boundaries.
    /// A snapshot sink one test owns. Deliberately not a shared singleton: Swift Testing runs
    /// tests in parallel, and two of them appending to one sink is a race between tests.
    private actor SettleSink {
        private(set) var last: [InteractionRequest]?
        func append(_ value: [InteractionRequest]) { last = value }
        func reset() { last = nil }
    }

    private func waterfall(
        eventId: String,
        callId: String? = "call-1",
        event: String = "approval/request",
        questions: Bool = false
    ) -> RemoteEvent {
        var request: [String: JSONValue] = questions
            ? ["callId": .string("call-1"), "questions": .array([
                .object([
                    "id": .string("q1"),
                    "header": .string("Colour"),
                    "question": .string("Which colour do you prefer?"),
                    "options": .array([.object(["label": .string("Blue")]),
                                       .object(["label": .string("Red")])]),
                ]),
            ])]
            : [
                "toolName": .string("bash"),
                "reason": .string("Run the requested test command"),
            ]
        if let callId { request["callId"] = .string(callId) }
        return .waterfall(RemoteWaterfall(
            event: event,
            eventId: eventId,
            agentId: "session-1",
            request: .object(request)
        ))
    }

    private func store(
        submitter: Submitter,
        generation: UInt64 = 1
    ) -> InteractionStore {
        InteractionStore(
            identity: { RemoteEventRouter.Identity(generation: generation, clientId: "client-1") },
            submit: { request in try await submitter.submit(request) }
        )
    }

    @Test("an arriving waterfall is published, not just recorded")
    func arrivalIsPublished() async throws {
        // Measured against the live host: the store updated on arrival and told nobody, so a
        // subscriber that had already been handed the empty list never learned about the
        // request. The session list kept saying "Running" for a session that was waiting.
        let store = store(submitter: Submitter())
        let sink = SettleSink()
        let stream = await store.snapshots()
        let collector = Task { @Sendable in
            for await value in stream { await sink.append(value) }
        }

        await store.observe(waterfall(eventId: "e1"), generation: 1)

        for _ in 0..<200 where await sink.last?.isEmpty != false {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await sink.last?.count == 1)
        #expect(await sink.last?.first?.id == "e1")
        collector.cancel()
    }

    @Test("answering publishes the settled state, so the card stops offering controls")
    func settlingIsPublished() async throws {
        // Measured against the live host: without this the store mutated a request to
        // `.settled` but no snapshot carried it, so an answered question card stayed on screen
        // with a live Submit whose every press was refused as not-actionable.
        let submitter = Submitter()
        let store = store(submitter: submitter)
        let sink = SettleSink()
        let stream = await store.snapshots()
        let collector = Task { @Sendable in
            for await value in stream { await sink.append(value) }
        }

        await store.observe(waterfall(eventId: "e1", event: "user-questions/request",
                                     questions: true), generation: 1)
        for _ in 0..<200 where await store.actionable.isEmpty {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await store.actionable.count == 1)

        try await store.answerLiveQuestions("e1", with: [QuestionAnswer(id: "q1", selected: ["Blue"])])

        // The store is settled...
        #expect(await store.actionable.isEmpty)
        #expect(await store.all.first?.state == .settled)
        // ...and a subscriber was told, which is what the screen renders from.
        for _ in 0..<200 where await sink.last?.first?.state != .settled {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await sink.last?.first?.state == .settled)
        collector.cancel()
    }

    // MARK: - The two exact strings

    @Test("allowing sends allowed-once as a result value, not a rejection")
    func allowOnceSendsTheExactValue() async throws {
        let submitter = Submitter()
        let store = store(submitter: submitter)
        await store.observe(waterfall(eventId: "e1"), generation: 1)

        try await store.allowOnce("e1")

        let sent = try #require(await submitter.last)
        #expect(sent.clientId == "client-1")
        #expect(sent.eventId == "e1")
        #expect(sent.outcome == .allowOnce)
        // The shape matters as much as the string: a `rejected` outcome would refuse the
        // remote continuation instead of approving the action.
        #expect(sent.outcome.jsonValue["kind"]?.stringValue == "result")
        #expect(sent.outcome.jsonValue["value"]?.stringValue == "allowed-once")
    }

    @Test("rejecting sends rejected as a result value, not a rejected outcome")
    func denySendsTheExactValue() async throws {
        let submitter = Submitter()
        let store = store(submitter: submitter)
        await store.observe(waterfall(eventId: "e1"), generation: 1)

        try await store.deny("e1")

        let sent = try #require(await submitter.last)
        #expect(sent.outcome == .denyOnce)
        #expect(sent.outcome.jsonValue["kind"]?.stringValue == "result")
        #expect(sent.outcome.jsonValue["value"]?.stringValue == "rejected")
    }

    // MARK: - Suppression

    @Test("a duplicate tap submits once")
    func duplicateTapSubmitsOnce() async throws {
        let submitter = Submitter()
        let store = store(submitter: submitter)
        await store.observe(waterfall(eventId: "e1"), generation: 1)
        await submitter.blockNext()

        // The first tap is in flight when the second arrives.
        async let first: Void = store.allowOnce("e1")
        try? await Task.sleep(for: .milliseconds(20))
        await #expect(throws: InteractionRefusal.self) {
            try await store.deny("e1")
        }
        await submitter.release()
        try await first

        // The second tap produced no second submission.
        #expect(await submitter.count == 1)
    }

    @Test("a settled request offers no further action")
    func settledIsNotActionable() async throws {
        let submitter = Submitter()
        let store = store(submitter: submitter)
        await store.observe(waterfall(eventId: "e1"), generation: 1)
        try await store.allowOnce("e1")

        #expect(await store.request("e1")?.state == .settled)
        #expect(await store.needsInputCount == 0)
        await #expect(throws: InteractionRefusal.self) {
            try await store.deny("e1")
        }
        #expect(await submitter.count == 1)
    }

    // MARK: - Cancel semantics

    @Test("a cancel retires the request without calling it a rejection")
    func cancelSettlesWithoutAVerdict() async throws {
        let submitter = Submitter()
        let store = store(submitter: submitter)
        await store.observe(waterfall(eventId: "e1"), generation: 1)
        await store.observe(.cancel(eventId: "e1"), generation: 1)

        let request = try #require(await store.request("e1"))
        // Settled, not rejected: the same frame arrives when another client answered.
        #expect(request.state == .settled)
        #expect(request.state.isActionable == false)
        #expect(await store.needsInputCount == 0)
        // Nothing was submitted in response to a retirement.
        #expect(await submitter.count == 0)
    }

    @Test("a cancel during a submission wins over the submission's own outcome")
    func cancelWinsTheRace() async throws {
        let submitter = Submitter()
        let store = store(submitter: submitter)
        await store.observe(waterfall(eventId: "e1"), generation: 1)
        await submitter.blockNext()

        async let submission: Void = store.allowOnce("e1")
        try? await Task.sleep(for: .milliseconds(20))
        // The host retires the delivery while our answer is still in flight.
        await store.observe(.cancel(eventId: "e1"), generation: 1)
        await submitter.release()
        try await submission

        // The host is the authority: the request must not be resurrected as pending, and it
        // must not be described as uncertain either — the delivery is simply over.
        #expect(await store.request("e1")?.state == .settled)
        #expect(await store.needsInputCount == 0)
    }

    @Test("a failed submission becomes uncertain rather than rejected")
    func failedSubmissionIsUncertain() async throws {
        let submitter = Submitter()
        let store = store(submitter: submitter)
        await store.observe(waterfall(eventId: "e1"), generation: 1)
        await submitter.failNext()

        await #expect(throws: InteractionRefusal.self) {
            try await store.allowOnce("e1")
        }

        // SPEC §8: an uncertain answer is visibly uncertain, never silently treated as
        // rejected and never resent.
        #expect(await store.request("e1")?.state == .uncertain)
        #expect(await store.request("e1")?.state.isActionable == false)
        #expect(await submitter.count == 1)
    }

    // MARK: - Generation

    @Test("a request from a retired generation is never submitted")
    func staleGenerationIsRefused() async throws {
        let submitter = Submitter()
        // The request arrived on generation 1, but the store now sees generation 2 — which
        // is the reconnect case, and also the replay case where the host reuses an eventId.
        let store = store(submitter: submitter, generation: 2)
        await store.observe(waterfall(eventId: "e1"), generation: 1)

        await #expect(throws: InteractionRefusal.staleGeneration) {
            try await store.allowOnce("e1")
        }
        #expect(await submitter.count == 0)
    }

    @Test("a replayed event id on a new generation is answerable again")
    func replayOnANewGenerationIsAccepted() async throws {
        let submitter = Submitter()
        let store = store(submitter: submitter, generation: 2)
        await store.observe(waterfall(eventId: "e1"), generation: 2)

        try await store.allowOnce("e1")
        #expect(await submitter.count == 1)
    }

    // MARK: - Grouping

    @Test("two tool calls carrying the same question id do not collide")
    func groupsAreKeyedByCall() async throws {
        // SPEC §8: the dictionary keyed only by question id collides across calls, and two
        // calls can each ask a question with id "1". Grouping by call is what fixes it.
        let store = store(submitter: Submitter())
        await store.observe(waterfall(eventId: "e1", callId: "call-1"), generation: 1)
        await store.observe(waterfall(eventId: "e2", callId: "call-2"), generation: 1)

        #expect(await store.group(InteractionGroupKey(sessionId: "session-1", callId: "call-1")).map(\.id) == ["e1"])
        #expect(await store.group(InteractionGroupKey(sessionId: "session-1", callId: "call-2")).map(\.id) == ["e2"])
        #expect(await store.all.count == 2)
    }

    @Test("a request without a call id still groups under its session")
    func groupWithoutACallId() async throws {
        let store = store(submitter: Submitter())
        await store.observe(waterfall(eventId: "e1", callId: nil), generation: 1)

        let group = await store.group(InteractionGroupKey(sessionId: "session-1", callId: nil))
        #expect(group.map(\.id) == ["e1"])
    }

    // MARK: - Badge

    @Test("only live requests count toward the needs-input badge")
    func badgeCountsOnlyLiveRequests() async throws {
        // SPEC §4: a historical ask_user_question tool call does not produce the badge by
        // itself.
        let submitter = Submitter()
        let store = store(submitter: submitter)
        await store.observe(waterfall(eventId: "e1"), generation: 1)
        await store.observe(waterfall(eventId: "e2"), generation: 1)
        #expect(await store.needsInputCount == 2)

        try await store.allowOnce("e1")
        #expect(await store.needsInputCount == 1)

        await store.removeAll()
        #expect(await store.needsInputCount == 0)
    }
}

// SPEC §8's channel table: a question is answered through `$events/result` when a live
// waterfall is asking, and through `userQuestions/answer` when the host has parked it in its
// `continued` state. Choosing the wrong channel is silent — the host simply does not take the
// answer — so which channel was used is asserted rather than assumed.

@Suite("Question channels")
struct QuestionChannelTests {
    private actor Recorder {
        private(set) var results: [EventResultRequest] = []
        private(set) var continued: [(agentId: String, callId: String, body: JSONValue)] = []
        var continuedReply = true

        func submit(_ request: EventResultRequest) async throws { results.append(request) }
        func setReply(_ value: Bool) { continuedReply = value }
        func answer(agentId: String, callId: String, body: JSONValue) async throws -> Bool {
            continued.append((agentId, callId, body))
            return continuedReply
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

    /// A snapshot sink the collector task can append to without sending a closure across
    /// isolation boundaries.
    /// A snapshot sink one test owns. Deliberately not a shared singleton: Swift Testing runs
    /// tests in parallel, and two of them appending to one sink is a race between tests.
    private actor SettleSink {
        private(set) var last: [InteractionRequest]?
        func append(_ value: [InteractionRequest]) { last = value }
        func reset() { last = nil }
    }

    private func waterfall(eventId: String = "e1", timed: Bool = false, event: String = "user-questions/request") -> RemoteEvent {
        var request: [String: JSONValue] = ["callId": .string("call-1")]
        // Only a question waterfall carries questions. An approval that happened to carry a
        // `questions` key would be a batch, so the helper must not fabricate one.
        if event == "user-questions/request" {
            request["questions"] = Self.questionsJSON
        } else {
            request["toolName"] = .string("bash")
            request["reason"] = .string("Run the requested test command")
        }
        if timed {
            request["wait"] = .object(["callId": .string("call-1"), "timed": .bool(true)])
        }
        return .waterfall(RemoteWaterfall(
            event: event,
            eventId: eventId,
            agentId: "session-1",
            request: .object(request)
        ))
    }

    private func store(_ recorder: Recorder, generation: UInt64 = 1) -> InteractionStore {
        InteractionStore(
            identity: { RemoteEventRouter.Identity(generation: generation, clientId: "client-1") },
            submit: { try await recorder.submit($0) },
            answerContinued: { agentId, callId, body in
                try await recorder.answer(agentId: agentId, callId: callId, body: body)
            }
        )
    }

    @Test("a live question goes out through the events result channel, as a result value")
    func liveQuestionUsesTheEventsChannel() async throws {
        let recorder = Recorder()
        let store = store(recorder)
        await store.observe(waterfall(), generation: 1)

        try await store.answerLiveQuestions("e1", with: [QuestionAnswer(id: "q1", selected: ["A"])])

        let sent = try #require(await recorder.results.first)
        #expect(sent.eventId == "e1")
        #expect(sent.outcome.jsonValue["kind"]?.stringValue == "result")
        let answers = try #require(sent.outcome.jsonValue["value"]?["answers"]?.arrayValue)
        #expect(answers.first?["id"]?.stringValue == "q1")
        #expect(answers.first?["selected"]?.arrayValue?.first?.stringValue == "A")
        // The continued channel was not touched: choosing the wrong one is silent on the wire.
        #expect(await recorder.continued.isEmpty)
    }

    @Test("an invalid answer is refused locally and nothing is sent")
    func invalidAnswerIsNotSent() async throws {
        let recorder = Recorder()
        let store = store(recorder)
        await store.observe(waterfall(), generation: 1)

        // No entry for q1 at all, which is an omission rather than a skip.
        await #expect(throws: InteractionRefusal.self) {
            try await store.answerLiveQuestions("e1", with: [])
        }
        #expect(await recorder.results.isEmpty)
        // And the request is still answerable, since nothing was submitted.
        #expect(await store.request("e1")?.state == .pending)
    }

    @Test("a timed question is refused until its foreground claim is held")
    func timedQuestionNeedsItsClaim() async throws {
        // SPEC §8 answers a timed waterfall only after userQuestions/attachWait has claimed
        // it. Answering without the claim races the host's own deadline.
        let recorder = Recorder()
        let store = store(recorder)
        await store.observe(waterfall(timed: true), generation: 1)

        await #expect(throws: InteractionRefusal.timedQuestionNeedsClaim) {
            try await store.answerLiveQuestions("e1", with: [QuestionAnswer(id: "q1", selected: ["A"])])
        }
        #expect(await recorder.results.isEmpty)
    }

    @Test("an approval is not a question batch")
    func approvalIsNotAQuestion() async throws {
        let recorder = Recorder()
        let store = store(recorder)
        await store.observe(waterfall(event: "approval/request"), generation: 1)

        await #expect(throws: InteractionRefusal.notAQuestion) {
            try await store.answerLiveQuestions("e1", with: [QuestionAnswer(id: "q1", selected: ["A"])])
        }
        #expect(await recorder.results.isEmpty)
    }

    @Test("a continued question goes out through the answer channel instead")
    func continuedQuestionUsesTheAnswerChannel() async throws {
        let recorder = Recorder()
        let store = store(recorder)

        let accepted = try await store.answerContinuedQuestions(
            agentId: "session-1",
            callId: "call-1",
            with: [QuestionAnswer(id: "q1", selected: ["A"])]
        )

        #expect(accepted)
        let sent = try #require(await recorder.continued.first)
        #expect(sent.agentId == "session-1")
        #expect(sent.callId == "call-1")
        #expect(sent.body["answers"]?.arrayValue?.first?["id"]?.stringValue == "q1")
        // Nothing went through the events channel, which is the distinction under test.
        #expect(await recorder.results.isEmpty)
    }

    @Test("a false from the continued channel is not success")
    func continuedFalseIsNotSuccess() async throws {
        // SPEC §8: "true accepts the reply; false means no longer answerable, not success."
        // The store reports what the host said rather than absorbing it.
        let recorder = Recorder()
        await recorder.setReply(false)
        let store = store(recorder)

        let accepted = try await store.answerContinuedQuestions(
            agentId: "session-1", callId: "call-1", with: [QuestionAnswer(id: "q1", selected: ["A"])]
        )
        #expect(accepted == false)
    }

    @Test("an unwired continued channel refuses rather than silently doing nothing")
    func unwiredContinuedChannelRefuses() async throws {
        let store = InteractionStore(
            identity: { RemoteEventRouter.Identity(generation: 1, clientId: "client-1") },
            submit: { _ in }
        )
        await #expect(throws: InteractionRefusal.continuedChannelUnavailable) {
            try await store.answerContinuedQuestions(
                agentId: "session-1", callId: "call-1", with: [QuestionAnswer(id: "q1", selected: [])]
            )
        }
    }

    @Test("a question is no more re-answerable than an approval")
    func liveQuestionSubmitsOnce() async throws {
        let recorder = Recorder()
        let store = store(recorder)
        await store.observe(waterfall(), generation: 1)

        try await store.answerLiveQuestions("e1", with: [QuestionAnswer(id: "q1", selected: ["A"])])
        await #expect(throws: InteractionRefusal.self) {
            try await store.answerLiveQuestions("e1", with: [QuestionAnswer(id: "q1", selected: ["B"])])
        }
        #expect(await recorder.results.count == 1)
    }
}
