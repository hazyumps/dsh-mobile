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

    private func waterfall(
        eventId: String,
        callId: String? = "call-1",
        event: String = "approval/request"
    ) -> RemoteEvent {
        var request: [String: JSONValue] = [
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
