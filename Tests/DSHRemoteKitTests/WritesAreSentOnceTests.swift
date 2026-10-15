import Foundation
import Testing

@testable import DSHRemoteKit

/// Every write the app makes goes to the relay exactly once (#63, AGENTS.md "Writes are never
/// retried", SPEC §3.4 and §8).
///
/// A 502 can arrive *after* the relay has already acted on a write, so a retry is a second
/// approval, a second upload, a second cancel, or a second claim of a single-use pairing code.
/// Each write below is scripted against a 502, a 429 and a dropped connection, and must leave
/// exactly one request on the transport, sleep for nothing, and report `attempts: 1`.
///
/// The clients are built exactly as production builds them, with no retry-policy argument. That
/// is deliberate: in particular `AppModel` sends approvals with `submitEventResult(request,
/// retryPolicy: .none)`, where `.none` is `Optional.none` — the parameter's own `nil` default — so
/// `submitEventResult(request)` here is the call the app makes today, and still compiles once the
/// parameter is gone.
///
/// Every transport answers *every* request with the scripted status (`setDefault`), so a retry
/// meets the same answer again rather than an empty script. The kit clients take a recording
/// sleeper; `ConnectionCoordinator` builds its own client with the real sleeper, so its 429s
/// carry `Retry-After: 0`.
@Suite("Writes are sent once")
struct WritesAreSentOnceTests {

    // MARK: - Helpers

    private static let hostOrigin = URL(string: "https://192.0.2.10:3443")!

    /// The captured pairing payload expires at 1755500000000 ms; a clock just before it is the
    /// only way to validate the capture at all.
    private static let beforeCaptureExpiry = FixedEpochClock(millis: 1_755_000_000_000 - 1)

    private static let badGateway = StubRelayTransport.Stub.json(status: 502, Data())
    private static let rateLimited = StubRelayTransport.Stub.json(
        status: 429, Data(), headers: ["Retry-After": "5"]
    )
    /// For the coordinator, whose sleeper is real: a retry must not cost the suite seconds.
    private static let rateLimitedNoWait = StubRelayTransport.Stub.json(
        status: 429, Data(), headers: ["Retry-After": "0"]
    )
    private static let dropped = StubRelayTransport.Stub.failure(.offline("connection dropped"))

    private func transport(answering stub: StubRelayTransport.Stub) async -> StubRelayTransport {
        let transport = StubRelayTransport()
        await transport.setDefault(stub)
        return transport
    }

    private func bareClient(
        _ transport: StubRelayTransport,
        _ sleeper: RecordingRelaySleeper
    ) -> DshBareEndpointClient {
        DshBareEndpointClient(
            baseURL: Self.hostOrigin,
            authorization: .bearer("device-token"),
            transport: transport,
            sleeper: sleeper
        )
    }

    private func coordinator(_ transport: StubRelayTransport) -> ConnectionCoordinator {
        ConnectionCoordinator(
            origin: ConnectionCoordinator.Origin(
                baseURL: Self.hostOrigin,
                authorization: .bearer("device-token")
            ),
            budgets: .init(establishmentSeconds: 5, readinessSeconds: 5),
            makeTransport: { _ in transport }
        )
    }

    /// The approval the app sends when the user taps Allow.
    private static let approval = EventResultRequest(
        clientId: "b1f0a3c2-77de-4f4b-9a2e-6c4d5e8f9012",
        eventId: "event-1",
        outcome: .allowOnce
    )

    private func claimPayload(_ client: PairingClient) throws -> PairingPayload {
        var payload = try client.decodePayload(
            Fixtures.data(.pairingPayload),
            clock: Self.beforeCaptureExpiry
        )
        // Pin agreement has its own tests; this file is about how often the claim is sent.
        payload.fingerprint = nil
        return payload
    }

    /// A file on disk for the streamed upload, at a path no other test uses.
    private func temporaryUploadFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("writes-sent-once-\(UUID().uuidString).bin")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        return url
    }

    /// Runs `operation` and returns what it threw, or `nil` if it returned.
    private func thrown<T>(_ operation: () async throws -> T) async -> (any Error)? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    private func isInterruption(_ error: (any Error)?) -> Bool {
        if case .transportInterruption? = error as? DshRPCError { return true }
        if case .exchange(.transportInterruption)? = error as? PairingError { return true }
        if case .transportInterruption? = error as? ConnectionCoordinator.ConnectError { return true }
        return false
    }

    // MARK: - AC1: $events/result (approvals and answers)

    @Test("AC1: an approval is sent once when the relay answers 502")
    func approvalOn502() async throws {
        let transport = await transport(answering: Self.badGateway)
        let sleeper = RecordingRelaySleeper()
        let client = bareClient(transport, sleeper)

        let error = await thrown { try await client.submitEventResult(Self.approval) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        let slept = await sleeper.sleptSeconds
        #expect(slept == [])
        #expect(error as? DshRPCError == .harnessUnavailable(attempts: 1))
    }

    @Test("AC1: an approval is sent once when the relay answers 429")
    func approvalOn429() async throws {
        let transport = await transport(answering: Self.rateLimited)
        let sleeper = RecordingRelaySleeper()
        let client = bareClient(transport, sleeper)

        let error = await thrown { try await client.submitEventResult(Self.approval) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        let slept = await sleeper.sleptSeconds
        #expect(slept == [])
        #expect(error as? DshRPCError == .rateLimited(retryAfterSeconds: 5, attempts: 1))
    }

    @Test("AC1: an approval is sent once when the connection drops")
    func approvalOnDroppedConnection() async throws {
        let transport = await transport(answering: Self.dropped)
        let sleeper = RecordingRelaySleeper()
        let client = bareClient(transport, sleeper)

        let error = await thrown { try await client.submitEventResult(Self.approval) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        let slept = await sleeper.sleptSeconds
        #expect(slept == [])
        #expect(isInterruption(error))
    }

    // MARK: - AC2: uploadFileBinary, in memory

    private func uploadBytes(_ client: DshBareEndpointClient) async throws -> FileUploadResult {
        try await client.uploadFileBinary(
            sessionId: "session-1", name: "notes.png", bytes: Data([0x89, 0x50, 0x4E, 0x47])
        )
    }

    @Test("AC2: an in-memory upload is sent once on 502")
    func bytesUploadOn502() async throws {
        let transport = await transport(answering: Self.badGateway)
        let sleeper = RecordingRelaySleeper()
        let client = bareClient(transport, sleeper)

        let error = await thrown { try await uploadBytes(client) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        let slept = await sleeper.sleptSeconds
        #expect(slept == [])
        #expect(error as? DshRPCError == .harnessUnavailable(attempts: 1))
    }

    @Test("AC2: an in-memory upload is sent once on 429")
    func bytesUploadOn429() async throws {
        let transport = await transport(answering: Self.rateLimited)
        let sleeper = RecordingRelaySleeper()
        let client = bareClient(transport, sleeper)

        let error = await thrown { try await uploadBytes(client) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        let slept = await sleeper.sleptSeconds
        #expect(slept == [])
        #expect(error as? DshRPCError == .rateLimited(retryAfterSeconds: 5, attempts: 1))
    }

    @Test("AC2: an in-memory upload is sent once when the connection drops")
    func bytesUploadOnDroppedConnection() async throws {
        let transport = await transport(answering: Self.dropped)
        let sleeper = RecordingRelaySleeper()
        let client = bareClient(transport, sleeper)

        let error = await thrown { try await uploadBytes(client) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        let slept = await sleeper.sleptSeconds
        #expect(slept == [])
        #expect(isInterruption(error))
    }

    // MARK: - AC3: uploadFileBinary, streamed from disk

    private func uploadFile(_ client: DshBareEndpointClient, _ file: URL) async throws -> FileUploadResult {
        try await client.uploadFileBinary(sessionId: "session-1", name: "notes.png", fileURL: file)
    }

    @Test("AC3: a file upload is sent once on 502")
    func fileUploadOn502() async throws {
        let file = try temporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = await transport(answering: Self.badGateway)
        let sleeper = RecordingRelaySleeper()
        let client = bareClient(transport, sleeper)

        let error = await thrown { try await uploadFile(client, file) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        let slept = await sleeper.sleptSeconds
        #expect(slept == [])
        #expect(error as? DshRPCError == .harnessUnavailable(attempts: 1))
    }

    @Test("AC3: a file upload is sent once on 429")
    func fileUploadOn429() async throws {
        let file = try temporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = await transport(answering: Self.rateLimited)
        let sleeper = RecordingRelaySleeper()
        let client = bareClient(transport, sleeper)

        let error = await thrown { try await uploadFile(client, file) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        let slept = await sleeper.sleptSeconds
        #expect(slept == [])
        #expect(error as? DshRPCError == .rateLimited(retryAfterSeconds: 5, attempts: 1))
    }

    @Test("AC3: a file upload is sent once when the connection drops")
    func fileUploadOnDroppedConnection() async throws {
        let file = try temporaryUploadFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = await transport(answering: Self.dropped)
        let sleeper = RecordingRelaySleeper()
        let client = bareClient(transport, sleeper)

        let error = await thrown { try await uploadFile(client, file) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        let slept = await sleeper.sleptSeconds
        #expect(slept == [])
        #expect(isInterruption(error))
    }

    // MARK: - AC4: the pairing claim (single-use code, 5-minute lifetime)

    @Test("AC4: a pairing claim is sent once on 502")
    func claimOn502() async throws {
        let transport = await transport(answering: Self.badGateway)
        let sleeper = RecordingRelaySleeper()
        let client = PairingClient(transport: transport, sleeper: sleeper)
        let payload = try claimPayload(client)

        let error = await thrown { try await client.claim(payload, deviceName: "phone") }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        let slept = await sleeper.sleptSeconds
        #expect(slept == [])
        #expect(error as? PairingError == .exchange(.harnessUnavailable(attempts: 1)))
    }

    @Test("AC4: a pairing claim rate-limited without Retry-After reports the lockout at once")
    func claimOn429WithoutRetryAfter() async throws {
        // SPEC §6.9's 60-second default per retry is what spent most of the code's five-minute
        // lifetime asleep before the user was told anything.
        let transport = await transport(answering: .json(status: 429, Data()))
        let sleeper = RecordingRelaySleeper()
        let client = PairingClient(transport: transport, sleeper: sleeper)
        let payload = try claimPayload(client)

        let error = await thrown { try await client.claim(payload, deviceName: "phone") }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        let slept = await sleeper.sleptSeconds
        #expect(slept == [])
        let pairingError = error as? PairingError
        #expect(pairingError == .exchange(.rateLimited(retryAfterSeconds: 60, attempts: 1)))
        #expect(pairingError?.isLockout == true)
    }

    @Test("AC4: a pairing claim is sent once when the connection drops")
    func claimOnDroppedConnection() async throws {
        let transport = await transport(answering: Self.dropped)
        let sleeper = RecordingRelaySleeper()
        let client = PairingClient(transport: transport, sleeper: sleeper)
        let payload = try claimPayload(client)

        let error = await thrown { try await client.claim(payload, deviceName: "phone") }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        let slept = await sleeper.sleptSeconds
        #expect(slept == [])
        #expect(isInterruption(error))
    }

    // MARK: - AC5: session/cancel

    @Test("AC5: a cancel is sent once on 502")
    func cancelOn502() async throws {
        let transport = await transport(answering: Self.badGateway)
        let coordinator = coordinator(transport)

        let error = await thrown { try await coordinator.cancelSession("session-1") }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(error as? ConnectionCoordinator.ConnectError == .rpc(.harnessUnavailable(attempts: 1)))
    }

    @Test("AC5: a cancel is sent once on 429")
    func cancelOn429() async throws {
        let transport = await transport(answering: Self.rateLimitedNoWait)
        let coordinator = coordinator(transport)

        let error = await thrown { try await coordinator.cancelSession("session-1") }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(
            error as? ConnectionCoordinator.ConnectError
                == .rpc(.rateLimited(retryAfterSeconds: 0, attempts: 1))
        )
    }

    @Test("AC5: a cancel is sent once when the connection drops")
    func cancelOnDroppedConnection() async throws {
        let transport = await transport(answering: Self.dropped)
        let coordinator = coordinator(transport)

        let error = await thrown { try await coordinator.cancelSession("session-1") }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(isInterruption(error))
    }

    // MARK: - AC6: session/create (refactor guard: correct today)

    private func create(_ coordinator: ConnectionCoordinator) async throws -> ConnectionCoordinator.SessionCreateOutcome {
        try await coordinator.createSession(sessionId: "session-new", workspaceId: "workspace-1")
    }

    @Test("AC6: a session create is sent once on 502")
    func createOn502() async throws {
        let transport = await transport(answering: Self.badGateway)
        let coordinator = coordinator(transport)

        let error = await thrown { try await create(coordinator) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(error as? ConnectionCoordinator.ConnectError == .rpc(.harnessUnavailable(attempts: 1)))
    }

    @Test("AC6: a session create is sent once on 429")
    func createOn429() async throws {
        let transport = await transport(answering: Self.rateLimitedNoWait)
        let coordinator = coordinator(transport)

        let error = await thrown { try await create(coordinator) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(
            error as? ConnectionCoordinator.ConnectError
                == .rpc(.rateLimited(retryAfterSeconds: 0, attempts: 1))
        )
    }

    @Test("AC6: a session create is sent once when the connection drops")
    func createOnDroppedConnection() async throws {
        let transport = await transport(answering: Self.dropped)
        let coordinator = coordinator(transport)

        let error = await thrown { try await create(coordinator) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(isInterruption(error))
    }

    // MARK: - AC7: session/prompt (refactor guard)

    private func prompt(_ coordinator: ConnectionCoordinator) async throws {
        try await coordinator.prompt(requestId: "submission-1", sessionId: "session-1", text: "hello")
    }

    @Test("AC7: a prompt is sent once on 502")
    func promptOn502() async throws {
        let transport = await transport(answering: Self.badGateway)
        let coordinator = coordinator(transport)

        let error = await thrown { try await prompt(coordinator) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(error as? ConnectionCoordinator.ConnectError == .rpc(.harnessUnavailable(attempts: 1)))
    }

    @Test("AC7: a prompt is sent once on 429")
    func promptOn429() async throws {
        let transport = await transport(answering: Self.rateLimitedNoWait)
        let coordinator = coordinator(transport)

        let error = await thrown { try await prompt(coordinator) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(
            error as? ConnectionCoordinator.ConnectError
                == .rpc(.rateLimited(retryAfterSeconds: 0, attempts: 1))
        )
    }

    @Test("AC7: a prompt is sent once when the connection drops")
    func promptOnDroppedConnection() async throws {
        let transport = await transport(answering: Self.dropped)
        let coordinator = coordinator(transport)

        let error = await thrown { try await prompt(coordinator) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(isInterruption(error))
    }

    // MARK: - AC8: userQuestions/answer (refactor guard)

    private func answer(_ coordinator: ConnectionCoordinator) async throws -> Bool {
        try await coordinator.answer(
            agentId: "session-1", callId: "call-1", questionId: "question-1", selected: ["Yes"]
        )
    }

    @Test("AC8: an answer is sent once on 502")
    func answerOn502() async throws {
        let transport = await transport(answering: Self.badGateway)
        let coordinator = coordinator(transport)

        let error = await thrown { try await answer(coordinator) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(error as? ConnectionCoordinator.ConnectError == .rpc(.harnessUnavailable(attempts: 1)))
    }

    @Test("AC8: an answer is sent once on 429")
    func answerOn429() async throws {
        let transport = await transport(answering: Self.rateLimitedNoWait)
        let coordinator = coordinator(transport)

        let error = await thrown { try await answer(coordinator) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(
            error as? ConnectionCoordinator.ConnectError
                == .rpc(.rateLimited(retryAfterSeconds: 0, attempts: 1))
        )
    }

    @Test("AC8: an answer is sent once when the connection drops")
    func answerOnDroppedConnection() async throws {
        let transport = await transport(answering: Self.dropped)
        let coordinator = coordinator(transport)

        let error = await thrown { try await answer(coordinator) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(isInterruption(error))
    }

    // MARK: - AC9: userQuestions/answer for a continued question (refactor guard)

    private func answerContinued(_ coordinator: ConnectionCoordinator) async throws -> Bool {
        try await coordinator.answerContinued(
            agentId: "session-1",
            callId: "call-1",
            body: .object(["answers": .array([
                .object(["id": .string("question-1"), "selected": .array([.string("Yes")])]),
            ])])
        )
    }

    @Test("AC9: a continued answer is sent once on 502")
    func continuedAnswerOn502() async throws {
        let transport = await transport(answering: Self.badGateway)
        let coordinator = coordinator(transport)

        let error = await thrown { try await answerContinued(coordinator) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(error as? ConnectionCoordinator.ConnectError == .rpc(.harnessUnavailable(attempts: 1)))
    }

    @Test("AC9: a continued answer is sent once on 429")
    func continuedAnswerOn429() async throws {
        let transport = await transport(answering: Self.rateLimitedNoWait)
        let coordinator = coordinator(transport)

        let error = await thrown { try await answerContinued(coordinator) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(
            error as? ConnectionCoordinator.ConnectError
                == .rpc(.rateLimited(retryAfterSeconds: 0, attempts: 1))
        )
    }

    @Test("AC9: a continued answer is sent once when the connection drops")
    func continuedAnswerOnDroppedConnection() async throws {
        let transport = await transport(answering: Self.dropped)
        let coordinator = coordinator(transport)

        let error = await thrown { try await answerContinued(coordinator) }

        let requestsSent = await transport.recordedRequests.count
        #expect(requestsSent == 1)
        #expect(isInterruption(error))
    }
}
