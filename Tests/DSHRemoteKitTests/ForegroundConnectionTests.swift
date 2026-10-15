import Foundation
import Testing
@testable import DSHRemoteKit

@Suite("Foreground recovery")
@MainActor
struct ForegroundConnectionTests {
    private func coordinator(_ transport: StubRelayTransport) -> ConnectionCoordinator {
        ConnectionCoordinator(
            origin: .init(baseURL: URL(string: "https://relay.test")!, authorization: .bearer("saved-token")),
            makeTransport: { _ in transport }
        )
    }

    private func ready(_ socket: StubRelaySocket, generation: UInt64) async throws {
        try await socket.push(json: .object([
            "type": .string("item"),
            "streamId": .string(ConnectionCoordinator.eventsStreamID(for: generation)),
            "value": .object(["type": .string("ready"), "clientId": .string("client-\(generation)")]),
        ]))
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    /// The transport error a refused WebSocket upgrade produces, as the message
    /// shape a real relay answer takes (SPEC §6.9). Status 403 is what the relay
    /// answers for *both* a bad credential and a Host-fence refusal, which is why
    /// #26 is reachable at all — see issue #79.
    private func upgradeRefused(_ status: Int) throws -> RelayTransportError {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://relay.test/api/remote.mux")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]
        ))
        return RelayTransportError.webSocketFailure(URLError(.badServerResponse), response: response)
    }

    @Test("returning opens a new ready connection using the saved credential, without pairing or writes")
    func returnToApp() async throws {
        let first = StubRelaySocket(), second = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [first, second])
        try await ready(first, generation: 1)
        try await ready(second, generation: 2)
        let recovery = ForegroundConnection(coordinator: coordinator(transport))
        recovery.setForeground(true)
        #expect(await eventually { recovery.connectionID != nil })
        let previousID = recovery.connectionID
        await recovery.stop()
        #expect(recovery.status == .offline)
        #expect(recovery.connectionID == nil)
        #expect(await first.closeCount == 1)
        #expect(await transport.openedSocketRequests.count == 1)

        recovery.setForeground(true)
        #expect(await eventually { recovery.connectionID != nil && recovery.connectionID != previousID })
        #expect(recovery.status == .connected)
        let requests = await transport.openedSocketRequests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.header("Authorization") == "Bearer saved-token" })
        #expect(await transport.recordedRequests.isEmpty)
        await recovery.stop()
    }

    @Test("a logical events-stream end reconnects and closes the abandoned socket")
    func logicalEndRecovers() async throws {
        let first = StubRelaySocket(), second = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [first, second])
        try await ready(first, generation: 1)
        try await ready(second, generation: 2)
        let sleeper = RecordingRelaySleeper()
        let recovery = ForegroundConnection(coordinator: coordinator(transport), sleeper: sleeper, jitter: { 1 })
        recovery.setForeground(true)
        #expect(await eventually { recovery.connectionID != nil })
        let previousID = recovery.connectionID
        try await first.push(json: .object([
            "type": .string("end"),
            "streamId": .string(ConnectionCoordinator.eventsStreamID(for: 1)),
        ]))
        #expect(await eventually { recovery.connectionID != nil && recovery.connectionID != previousID })
        #expect(await sleeper.sleptSeconds == [0.5])
        #expect(await first.closeCount == 1)
        await recovery.stop()
    }

    @Test("an unavailable network retries automatically while foregrounded")
    func temporaryFailureRecovers() async throws {
        let first = StubRelaySocket(), second = StubRelaySocket()
        await first.fail(with: .offline("no network"))
        try await ready(second, generation: 2)
        let transport = StubRelayTransport(sockets: [first, second])
        let sleeper = RecordingRelaySleeper()
        let recovery = ForegroundConnection(coordinator: coordinator(transport), sleeper: sleeper, jitter: { 1 })
        recovery.setForeground(true)
        #expect(await eventually { recovery.status == .connected })
        #expect(await sleeper.sleptSeconds == [0.5])
        #expect(await transport.openedSocketRequests.count == 2)
        await recovery.stop()
    }

    @Test("an end buffered immediately after ready cannot leave a dead connection marked usable")
    func immediateEndRecovers() async throws {
        let first = StubRelaySocket(), second = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [first, second])
        try await ready(first, generation: 1)
        try await first.push(json: .object([
            "type": .string("end"),
            "streamId": .string(ConnectionCoordinator.eventsStreamID(for: 1)),
        ]))
        try await ready(second, generation: 2)
        let coordinator = coordinator(transport)
        let recovery = ForegroundConnection(coordinator: coordinator, sleeper: RecordingRelaySleeper())
        recovery.setForeground(true)
        #expect(await eventually { await coordinator.connection?.generation == 2 })
        #expect(await eventually { recovery.status == .connected })
        #expect(await first.closeCount == 1)
        await recovery.stop()
    }

    @Test("backgrounding cancels a stalled handshake promptly and never starts a background retry")
    func cancelStalledHandshake() async throws {
        let socket = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [socket])
        let recovery = ForegroundConnection(coordinator: coordinator(transport))
        recovery.setForeground(true)
        #expect(await eventually { await !socket.sentTexts.isEmpty })
        let started = ContinuousClock.now
        await recovery.stop()
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(await socket.closeCount == 1)
        #expect(await transport.openedSocketRequests.count == 1)
        #expect(recovery.status == .offline)
    }

    @Test("rapid app switching cannot let an old shutdown close the current socket")
    func rapidTransitions() async throws {
        let first = StubRelaySocket(), second = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [first, second])
        try await ready(first, generation: 1)
        try await ready(second, generation: 2)
        let recovery = ForegroundConnection(coordinator: coordinator(transport))
        recovery.setForeground(true)
        #expect(await eventually { recovery.status == .connected })
        recovery.setForeground(false)
        recovery.setForeground(true)
        recovery.setForeground(false)
        recovery.setForeground(true)
        #expect(await eventually { recovery.status == .connected })
        #expect(await transport.openedSocketRequests.count == 2)
        #expect(await first.closeCount == 1)
        #expect(await second.closeCount == 0)
        await recovery.stop()
    }

    @Test("backgrounding cancels backoff without another connection attempt")
    func cancelBackoff() async throws {
        let socket = StubRelaySocket()
        await socket.fail(with: .offline("no route"))
        let transport = StubRelayTransport(sockets: [socket])
        let sleeper = PausedRecoverySleeper()
        let recovery = ForegroundConnection(coordinator: coordinator(transport), sleeper: sleeper)
        recovery.setForeground(true)
        #expect(await eventually { await sleeper.started })
        await recovery.stop()
        #expect(recovery.status == .offline)
        #expect(await transport.openedSocketRequests.count == 1)
        #expect(await socket.closeCount == 1)
    }

    @Test("an upgrade completing after background cancellation is closed")
    func lateUpgradeCannotReviveConnection() async throws {
        let transport = DeferredRecoveryTransport()
        let coordinator = ConnectionCoordinator(
            origin: .init(baseURL: URL(string: "https://relay.test")!, authorization: .bearer("saved-token")),
            makeTransport: { _ in transport }
        )
        let recovery = ForegroundConnection(coordinator: coordinator)
        recovery.setForeground(true)
        #expect(await eventually { await transport.isWaiting })
        await recovery.stop()
        let lateSocket = StubRelaySocket()
        await transport.finish(with: lateSocket)
        #expect(await eventually { await lateSocket.closeCount == 1 })
        #expect(await lateSocket.sentTexts.isEmpty)
        #expect(recovery.connectionID == nil)
        #expect(recovery.status == .offline)
    }

    @Test("a changed certificate parks, and a wake earns exactly one fresh attempt")
    func changedIdentityParksAndRevives() async throws {
        // Rewritten from `changedIdentityStops`, which asserted `count == 1` after a wake and so
        // encoded the dead end as the contract. The part that is still true is kept below: there is
        // no *automatic* retry, and one wake buys one attempt, not a loop.
        let first = StubRelaySocket(), second = StubRelaySocket()
        await first.fail(with: .tlsPinMismatch("changed key"))
        await second.fail(with: .tlsPinMismatch("changed key"))
        let transport = StubRelayTransport(sockets: [first, second])
        let recovery = ForegroundConnection(coordinator: coordinator(transport))
        recovery.setForeground(true)
        #expect(await eventually { recovery.error == .certificateChanged(detail: "changed key") })
        #expect(recovery.status == .hostUnavailable)
        #expect(await transport.openedSocketRequests.count == 1)

        await recovery.stop()
        recovery.setForeground(true)
        #expect(await eventually { await transport.openedSocketRequests.count == 2 })
        #expect(await eventually { recovery.status == .hostUnavailable })
        #expect(await transport.openedSocketRequests.count == 2)
        await recovery.stop()
    }

    @Test("a credential rejected mid-connection parks, and a wake earns exactly one fresh attempt")
    func revokedCredentialParksAndRevives() async throws {
        // Rewritten from `revokedCredentialStops` for the same reason as the certificate case: it
        // asserted `count == 1` after a wake. The backoff claim it was really making — a 403 never
        // sleeps — is kept and asserted directly.
        let live = StubRelaySocket(), refused = StubRelaySocket()
        try await ready(live, generation: 1)
        await refused.fail(with: try upgradeRefused(403))
        let transport = StubRelayTransport(
            responses: [.json(status: 403, Data("{}".utf8))], sockets: [live, refused]
        )
        let coordinator = coordinator(transport)
        let sleeper = RecordingRelaySleeper()
        let recovery = ForegroundConnection(coordinator: coordinator, sleeper: sleeper)
        recovery.setForeground(true)
        #expect(await eventually { recovery.status == .connected })
        _ = try? await coordinator.sessions()
        #expect(await eventually { recovery.status == .pairingRequired })
        #expect(await transport.openedSocketRequests.count == 1)
        #expect(await sleeper.sleptSeconds.isEmpty)

        await recovery.stop()
        recovery.setForeground(true)
        #expect(await eventually { await transport.openedSocketRequests.count == 2 })
        #expect(await eventually { recovery.status == .pairingRequired })
        #expect(await sleeper.sleptSeconds.isEmpty)
        await recovery.stop()
    }

    @Test("a wake earns one fresh attempt after a parked credential rejection")
    func wakeRevivesParkedCredential() async throws {
        // The defect: `setForeground` returned early whenever the last failure was non-retryable,
        // and the stored error is only cleared by a success — so one refused upgrade meant the app
        // never dialled again, and only a relaunch cured it.
        let refused = StubRelaySocket()
        await refused.fail(with: try upgradeRefused(403))
        let recovered = StubRelaySocket()
        try await ready(recovered, generation: 2)
        let transport = StubRelayTransport(sockets: [refused, recovered])
        let recovery = ForegroundConnection(coordinator: coordinator(transport))
        recovery.setForeground(true)
        #expect(await eventually { recovery.status == .pairingRequired })
        #expect(await transport.openedSocketRequests.count == 1)

        recovery.setForeground(false)
        recovery.setForeground(true)
        #expect(await eventually { recovery.status == .connected })
        #expect(recovery.error == nil)
        #expect(await transport.openedSocketRequests.count == 2)
        await recovery.stop()
    }

    @Test("a parked failure never sleeps and never loops")
    func parkedFailureDoesNotLoop() async throws {
        let socket = StubRelaySocket()
        await socket.fail(with: try upgradeRefused(403))
        let transport = StubRelayTransport(sockets: [socket])
        let sleeper = RecordingRelaySleeper()
        let recovery = ForegroundConnection(coordinator: coordinator(transport), sleeper: sleeper)
        recovery.setForeground(true)
        #expect(await eventually { recovery.status == .pairingRequired })
        // No backoff was scheduled, and no second attempt happened without a wake. "Stop retrying"
        // (SPEC §6.9) is a statement about the loop, not about the app's ability to try again.
        #expect(await sleeper.sleptSeconds.isEmpty)
        #expect(await transport.openedSocketRequests.count == 1)
        await recovery.stop()
    }

    @Test("an unpaired host never dials, across wakes")
    func unpairedNeverDials() async throws {
        let transport = StubRelayTransport()
        let coordinator = ConnectionCoordinator(
            origin: .init(baseURL: URL(string: "https://relay.test")!, authorization: .none),
            makeTransport: { _ in transport }
        )
        let recovery = ForegroundConnection(coordinator: coordinator)
        recovery.setForeground(true)
        #expect(await eventually { recovery.status == .pairingRequired })
        await recovery.stop()
        // Reviving a park must not turn a local refusal into a network attempt.
        recovery.setForeground(true)
        #expect(await eventually { recovery.status == .pairingRequired })
        #expect(await transport.openedSocketRequests.isEmpty)
        await recovery.stop()
    }

    @Test("authentication refused during WebSocket upgrade stops without a retry", arguments: [401, 403])
    func rejectedUpgradeStops(status: Int) async throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://relay.test/api/remote.mux")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]
        ))
        let socket = StubRelaySocket()
        await socket.fail(with: RelayTransportError.webSocketFailure(URLError(.badServerResponse), response: response))
        let transport = StubRelayTransport(sockets: [socket])
        let recovery = ForegroundConnection(coordinator: coordinator(transport))
        recovery.setForeground(true)
        #expect(await eventually { recovery.error != nil })
        #expect(recovery.status == (status == 403 ? .pairingRequired : .hostUnavailable))
        #expect(recovery.error?.isRetryable == false)
        #expect(await transport.openedSocketRequests.count == 1)
        await recovery.stop()
    }

    @Test("WebSocket rate limiting reaches the recovery delay with Retry-After intact")
    func upgradeRateLimit() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://relay.test/api/remote.mux")!,
            statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "45"]
        ))
        let error = RelayTransportError.webSocketFailure(URLError(.badServerResponse), response: response)
        let failure = ConnectionCoordinator.failure(from: MuxStreamError.socketFailed(error))
        #expect(failure.isRetryable)
        #expect(ForegroundConnection.retryDelay(for: failure, attempt: 0, jitter: 1) == 45)
    }

    @Test("retry timing backs off, caps at ten seconds, and honors Retry-After")
    func backoffPolicy() {
        let failure = ConnectionCoordinator.ConnectError.transportInterruption(detail: "offline")
        #expect((0...7).map { ForegroundConnection.retryDelay(for: failure, attempt: $0, jitter: 1) }
                == [0.5, 1, 2, 4, 8, 10, 10, 10])
        #expect(ForegroundConnection.retryDelay(
            for: .rpc(.rateLimited(retryAfterSeconds: 45, attempts: 1)), attempt: 0, jitter: 1
        ) == 45)
    }
}

private actor PausedRecoverySleeper: RelaySleeper {
    private(set) var started = false
    func sleep(seconds: Double) async throws {
        started = true
        try await Task.sleep(for: .seconds(60))
    }
}

private actor DeferredRecoveryTransport: RelayTransport {
    private var waiter: CheckedContinuation<any RelaySocket, Never>?
    var isWaiting: Bool { waiter != nil }
    func openSocket(_ request: RelayHTTPRequest) async throws -> any RelaySocket {
        await withCheckedContinuation { waiter = $0 }
    }
    func send(_ request: RelayHTTPRequest) async throws -> RelayHTTPResponse {
        throw RelayTransportError.offline("not used")
    }
    func finish(with socket: any RelaySocket) {
        waiter?.resume(returning: socket)
        waiter = nil
    }
}
