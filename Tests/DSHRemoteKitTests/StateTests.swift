import Foundation
import Testing

@testable import DSHRemoteKit

// Offline tests for the state layer. Every one runs against `StubRelayTransport` /
// `StubRelaySocket` and the captured fixtures; nothing here opens a socket, resolves a
// name, or reads the live relay (SPEC §2 "Testing", SPEC §4: the whole layer above the
// transport seam is exercised without a network).
//
// The two SPEC §6.4 budgets are the only wall-clock waits in the file, and both are
// tightened to fractions of a second through `ConnectionCoordinator.Budget` so the suite
// stays fast. The production value they stand in for is ten seconds, asserted once in
// `standardBudgetIsTheSpecBudget`.

// MARK: - Helpers

private let hostOrigin = URL(string: "https://192.0.2.10:3443")!

/// A captured-shaped ready frame, from SPEC §6.4:
/// `{"type":"item","streamId":"1","value":{"type":"ready","clientId":"<36 chars>","host":{"home":"<path>"}}}`.
///
/// Written here rather than loaded from `Fixtures/` because no capture contains one —
/// `mux-stream-frames.json` holds twelve frames and none is `ready`. The shape is a SPEC
/// sentence, so the test carries it literally and says so.
private func readyFrameJSON(
    streamId: String,
    clientId: String = "b1f0a3c2-77de-4f4b-9a2e-6c4d5e8f9012"
) -> JSONValue {
    .object([
        "type": .string("item"),
        "streamId": .string(streamId),
        "value": .object([
            "type": .string("ready"),
            "clientId": .string(clientId),
            "host": .object(["home": .string("/Users/redacted")]),
        ]),
    ])
}

private func origin(
    _ authorization: RelayAuthorization = .bearer("device-token")
) -> ConnectionCoordinator.Origin {
    ConnectionCoordinator.Origin(baseURL: hostOrigin, authorization: authorization)
}

/// A coordinator whose transport is scripted, with both budgets tightened so a timeout
/// test measures a fraction of a second. The generous default is deliberate: a test for
/// the *readiness* budget must not become a test for the establishment budget by accident.
private func makeCoordinator(
    transport: StubRelayTransport,
    socket: StubRelaySocket? = nil,
    establishmentSeconds: Double = 5,
    readinessSeconds: Double = 5
) async -> ConnectionCoordinator {
    if let socket {
        await transport.enqueue(socket: socket)
    }
    return ConnectionCoordinator(
        origin: origin(),
        budgets: .init(
            establishmentSeconds: establishmentSeconds,
            readinessSeconds: readinessSeconds
        ),
        makeTransport: { _ in transport }
    )
}

/// Runs `operation` and returns what it threw, or `nil` if it returned. Lets a test check
/// that a path throws an exact value without an `#expect(throws:)` closure.
private func failure<T>(_ operation: () async throws -> T) async -> (any Error)? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error
    }
}

/// Awaits `condition` for at most `timeout`. Used only where the code under test finishes
/// work in a task that cannot be awaited directly — the drain loop.
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

// MARK: - 1. The six states (SPEC §3.1)

@Test("ConnectionStatus is exactly the six states SPEC §3.1 lists, with its words")
func connectionStatusIsTheSpecSix() {
    // SPEC §3.1: "Connecting, Connected, Reconnecting, Offline, Pairing required, or Host
    // unavailable. Status uses text as well as color." Six and no more: a seventh would be
    // a state the UI has no word for.
    #expect(ConnectionStatus.allCases.count == 6)
    #expect(
        Set(ConnectionStatus.allCases.map(\.rawValue))
            == ["connecting", "connected", "reconnecting", "offline", "pairingRequired", "hostUnavailable"]
    )

    // The labels are SPEC §3.1's own phrases. Text is the accessible channel, so no two
    // states may share one and none may be empty.
    let labels = ConnectionStatus.allCases.map(\.label)
    #expect(labels == [
        "Connecting", "Connected", "Reconnecting", "Offline", "Pairing required", "Host unavailable",
    ])
    #expect(Set(labels).count == 6)
    #expect(labels.allSatisfy { !$0.isEmpty })

    // Only `connected` means the host can serve a request.
    #expect(ConnectionStatus.allCases.filter(\.isUsable) == [.connected])

    // The app maps these to symbols itself, so no case here carries or implies one.
    #expect(!labels.contains { $0.contains(".") })
}

// MARK: - 2. Readiness is the ready frame, not an open socket (SPEC §6.4)

@Test("an open socket with no ready frame never reaches connected")
func readinessRequiresTheReadyFrame() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    // The socket is handed out and the `open` frame is accepted — and the host then says
    // nothing at all. SPEC §6.4: "The socket opening alone is not readiness."
    let coordinator = await makeCoordinator(transport: transport, socket: socket, readinessSeconds: 0.2)

    let thrown = await failure { try await coordinator.connect() }
    let error = try #require(thrown as? ConnectionCoordinator.ConnectError)

    #expect(error == .readinessTimedOut(seconds: 0.2))
    // A host that accepts the upgrade and then says nothing is a host that is not
    // answering: `Host unavailable`, and never a hang on `Connecting`.
    #expect(await coordinator.status == .hostUnavailable)
    #expect(await coordinator.connection == nil)
    #expect(await coordinator.lastError == error)

    // The socket really did open and the open frame really did reach the wire, so the
    // failure above is about readiness and not about establishment.
    let sent = await socket.sentTexts
    let openFrame = try #require(sent.first { $0.contains("\"type\":\"open\"") })
    #expect(openFrame.contains("\"endpoint\":\"$events\""))
    #expect(openFrame.contains("\"args\":{}"))
    #expect(openFrame.contains("\"streamId\":\"events-1\""))
    #expect(await transport.openedSocketRequests.count == 1)
}

@Test("a socket that opens but never becomes ready is closed rather than leaked")
func readinessFailureClosesTheSocket() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let coordinator = await makeCoordinator(transport: transport, socket: socket, readinessSeconds: 0.2)

    _ = await failure { try await coordinator.connect() }

    // `MuxClient.close()` is the only thing that closes the socket, so the count is the
    // evidence that the abandoned attempt released it.
    #expect(await socket.closeCount >= 1)
    #expect(await coordinator.activeStream() == nil)
}

@Test("frames before the ready frame are skipped, not mistaken for readiness")
func framesBeforeReadyAreSkipped() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let coordinator = await makeCoordinator(transport: transport, socket: socket)
    let streamId = ConnectionCoordinator.eventsStreamID(for: 1)

    // A value type this build does not model, on the events stream, before ready. It
    // carries no clientId, so it is not readiness.
    try await socket.push(json: .object([
        "type": .string("item"),
        "streamId": .string(streamId),
        "value": .object(["type": .string("something-new"), "payload": .int(7)]),
    ]))
    try await socket.push(json: readyFrameJSON(streamId: streamId, clientId: "the-real-one"))

    let connection = try await coordinator.connect()
    #expect(connection.clientId == "the-real-one")
    #expect(await coordinator.status == .connected)
}

@Test("an error frame before ready fails the attempt with the host's own code")
func streamErrorBeforeReadyFailsTheAttempt() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let coordinator = await makeCoordinator(transport: transport, socket: socket)
    let streamId = ConnectionCoordinator.eventsStreamID(for: 1)

    // SPEC §6.4's error shape, including the empty `details` object it describes.
    try await socket.push(json: .object([
        "type": .string("error"),
        "streamId": .string(streamId),
        "error": .object([
            "code": .string("gateway/internal"),
            "message": .string("the host is not serving streams"),
            "details": .object([:]),
        ]),
    ]))

    let thrown = await failure { try await coordinator.connect() }
    let error = try #require(thrown as? ConnectionCoordinator.ConnectError)
    #expect(error == .streamRejected(
        streamId: streamId,
        detail: "gateway/internal: the host is not serving streams"
    ))
    #expect(await coordinator.status == .hostUnavailable)
}

@Test("a ready frame without a clientId is a failure, not a partial connect")
func readyFrameWithoutClientIdFails() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let coordinator = await makeCoordinator(transport: transport, socket: socket)
    let streamId = ConnectionCoordinator.eventsStreamID(for: 1)

    // SPEC §6.7 needs the clientId to address `$events/result`, so a ready frame with an
    // empty one establishes nothing usable.
    try await socket.push(json: .object([
        "type": .string("item"),
        "streamId": .string(streamId),
        "value": .object(["type": .string("ready"), "clientId": .string("")]),
    ]))

    let thrown = await failure { try await coordinator.connect() }
    #expect(thrown as? ConnectionCoordinator.ConnectError == .readyFrameWithoutClientId)
    #expect(await coordinator.status == .hostUnavailable)
}

// MARK: - 3. The clientId comes from the frame (SPEC §6.4)

@Test("the clientId is taken from the ready frame")
func clientIdComesFromTheReadyFrame() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let coordinator = await makeCoordinator(transport: transport, socket: socket)
    let streamId = ConnectionCoordinator.eventsStreamID(for: 1)

    try await socket.push(json: readyFrameJSON(
        streamId: streamId,
        clientId: "9c1e6b6e-0a3d-4a1c-8f6a-2f9b7c0d1e23"
    ))

    let connection = try await coordinator.connect()

    #expect(connection.clientId == "9c1e6b6e-0a3d-4a1c-8f6a-2f9b7c0d1e23")
    // The ready frame's `host` object is kept whole rather than guessed at.
    #expect(connection.host?["home"]?.stringValue == "/Users/redacted")
    #expect(await coordinator.connection == connection)
    #expect(await coordinator.status == .connected)
    #expect(await coordinator.lastError == nil)
}

@Test("each connect attempt gets a new generation, and the $events stream id follows it")
func eachAttemptBurnsAGeneration() async throws {
    let transport = StubRelayTransport()
    let first = StubRelaySocket()
    let second = StubRelaySocket()
    let coordinator = await makeCoordinator(transport: transport, socket: first)
    await transport.enqueue(socket: second)

    try await first.push(json: readyFrameJSON(
        streamId: ConnectionCoordinator.eventsStreamID(for: 1),
        clientId: "first-client-id"
    ))
    let one = try await coordinator.connect()

    // A second connect tears the first down first — the shape SPEC §6.5 requires, where a
    // reconnect is a new generation rather than a continuation of the old one.
    try await second.push(json: readyFrameJSON(
        streamId: ConnectionCoordinator.eventsStreamID(for: 2),
        clientId: "second-client-id"
    ))
    let two = try await coordinator.connect()

    #expect(one.generation == 1)
    #expect(two.generation == 2)
    #expect(one.clientId != two.clientId)
    #expect(await first.closeCount >= 1)
    #expect(await coordinator.activeStream()?.generation == 2)
}

// MARK: - 4. The two budgets (SPEC §6.4)

@Test("the standard budget is the ten seconds SPEC §6.4 states")
func standardBudgetIsTheSpecBudget() {
    #expect(ConnectionCoordinator.Budget.standard.establishmentSeconds == 10)
    #expect(ConnectionCoordinator.Budget.standard.readinessSeconds == 10)
}

@Test("a stalled establishment fails inside its budget and reports a status, not a hang")
func establishmentBudgetFires() async throws {
    // The socket is never handed out. `StubRelayTransport.openSocket` cannot model that —
    // it either returns a canned socket or throws — so the stall is a small transport of
    // this test's own. Nothing else in the file needs one.
    let transport = StalledServeTransport()

    let coordinator = ConnectionCoordinator(
        origin: origin(),
        budgets: .init(establishmentSeconds: 0.2, readinessSeconds: 5),
        makeTransport: { _ in transport }
    )

    let started = ContinuousClock.now
    let thrown = await failure { try await coordinator.connect() }
    let elapsed = ContinuousClock.now - started

    let error = try #require(thrown as? ConnectionCoordinator.ConnectError)
    #expect(error == .establishmentTimedOut(seconds: 0.2))
    // SPEC §6.4's establishment budget. The bound is generous on purpose: the requirement
    // is that it gave up inside the budget, not a stopwatch reading.
    #expect(elapsed < .seconds(5))
    #expect(await coordinator.status == .hostUnavailable)
    #expect(await coordinator.status != .connecting)
}

// MARK: - 5. Session list (SPEC §3.3, SPEC §6.2)

@Test("the session list decodes the captured response through the coordinator")
func sessionListDecodesTheFixture() async throws {
    let transport = StubRelayTransport(responsesByPath: [
        "/api/session/list": .json(status: 200, try Fixtures.data(.rpcSessionList)),
    ])
    let coordinator = ConnectionCoordinator(origin: origin(), makeTransport: { _ in transport })

    let sessions = try await coordinator.sessions()

    // Three rows in the capture (SPEC §3.3).
    #expect(sessions.count == 3)
    let first = try #require(sessions.first)
    #expect(first.sessionId == "session-0001")
    // SPEC §3.3: status "when known", last activity "when supplied". Both are supplied.
    #expect(first.running == true)
    #expect(first.agentAvailable == true)
    #expect(first.title == "redacted")
    #expect(first.projections?.asOfSeq == 995)
    #expect(first.updatedAt == 1791412735279)
    #expect(Set(sessions.map(\.sessionId)).count == 3)

    // The same bytes decode as the descriptor-generated type, which is the cross-check
    // that the hand-written `SessionSummary` has not drifted from `Protocol/schemas`.
    let generated = try Fixtures.decode(RPCResponse<SessionListValue>.self, .rpcSessionList)
    #expect(generated.result.value?.items.map(\.sessionId) == sessions.map(\.sessionId))
}

@Test("session/list is called with the _request field the descriptor names")
func sessionListUsesTheDescriptorArgumentName() async throws {
    let transport = StubRelayTransport(responsesByPath: [
        "/api/session/list": .json(status: 200, try Fixtures.data(.rpcSessionList)),
    ])
    let coordinator = ConnectionCoordinator(origin: origin(), makeTransport: { _ in transport })

    _ = try await coordinator.sessions()

    let requests = await transport.recordedRequests
    #expect(requests.count == 1)
    let request = try #require(requests.first)

    // SPEC §6.2: "the arguments are wrapped in a `_request` field, and omitting it returns
    // gateway/arguments-invalid with the offending details.endpoint". The name is per
    // endpoint, and the descriptor for `session/list` names it `_request`
    // (`Protocol/endpoints.json`, `@deepseek-ai/dsh-api-session-controller#session/list`).
    #expect(request.url.path == "/api/session/list")
    #expect(request.method == "POST")
    #expect(request.header("Authorization") == "Bearer device-token")
    #expect(request.header("Content-Type") == "application/json")

    let body = try #require(request.body)
    let envelopeJSON = try JSONDecoder().decode(JSONValue.self, from: body)
    let args = try #require(envelopeJSON["payload"]?["args"]?.objectValue)
    #expect(Set(args.keys) == ["_request"])
    #expect(args["_request"]?.objectValue != nil)
    // The envelope's `method` must match the path (SPEC §6.2).
    let envelope = try JSONDecoder().decode(RPCRequest<RPCArguments<RPCEmptyRequest>>.self, from: body)
    #expect(envelope.method == "session/list")
    #expect("/api/\(envelope.method)" == request.url.path)
}

@Test("a business refusal from session/list is surfaced with the host's code")
func sessionListBusinessRefusal() async throws {
    let transport = StubRelayTransport(responsesByPath: [
        "/api/session/list": .json(status: 200, try Fixtures.data(.rpcTypedError)),
    ])
    let coordinator = ConnectionCoordinator(origin: origin(), makeTransport: { _ in transport })

    let thrown = await failure { try await coordinator.sessions() }
    let error = try #require(thrown as? ConnectionCoordinator.ConnectError)

    // HTTP 200 with `result.ok == false` is not success (SPEC §6.2), and the host's own
    // code and message travel with it so the app can show its readable reason (§6.9).
    guard case .rpc(.business(let typed)) = error else {
        Issue.record("expected a business refusal, got \(error)")
        return
    }
    #expect(typed.code == "gateway/arguments-invalid")
    #expect(typed.message.isEmpty == false)
}

@Test("a transport failure during session/list is a status, not a silent empty list")
func sessionListTransportFailureIsReported() async throws {
    let transport = StubRelayTransport(responsesByPath: [
        "/api/session/list": .failure(.offline("no route to host")),
    ])
    let coordinator = ConnectionCoordinator(origin: origin(), makeTransport: { _ in transport })

    let thrown = await failure { try await coordinator.sessions() }
    // `RelayExchange` maps a transport failure to the same error domain as everything
    // else, so the app has one type to switch on (SPEC §6.9's table).
    #expect(thrown as? ConnectionCoordinator.ConnectError
        == .transportInterruption(detail: "transport offline: no route to host"))
    // SPEC §6.9 "Offline": the status says so, rather than the UI rendering an empty list
    // that reads as "this host has no sessions".
    #expect(await coordinator.status == .offline)
}

// MARK: - 6. Failures arrive as statuses, never as hangs

@Test("a transport failure during connect surfaces as a status")
func transportFailureSurfacesAsStatus() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    // The WebSocket upgrade itself fails: no socket to read, nothing on the wire.
    // `StubRelayTransport` reports that as a socket that fails on first receive, which is
    // the same throw the coordinator sees from a real transport.
    await socket.fail(with: .offline("network connection was lost"))
    await transport.enqueue(socket: socket)

    let coordinator = ConnectionCoordinator(
        origin: origin(),
        budgets: .init(establishmentSeconds: 5, readinessSeconds: 5),
        makeTransport: { _ in transport }
    )

    let thrown = await failure { try await coordinator.connect() }
    let error = try #require(thrown as? ConnectionCoordinator.ConnectError)

    #expect(error == .transportInterruption(detail: "network connection was lost"))
    #expect(error.isRetryable == true)
    // SPEC §6.9 "Offline/transport interruption". The second assertion is the point: it
    // must not still be claiming to be trying.
    #expect(await coordinator.status == .offline)
    #expect(await coordinator.status != .connecting)
    #expect(await coordinator.connection == nil)
}

@Test("a transport failure before any socket exists is Offline, not a hang")
func upgradeFailureSurfacesAsOffline() async throws {
    let transport = StubRelayTransport()
    // `openSocket` throws: the upgrade never completed. Nothing was opened, so this is a
    // failure of establishment and must be reported as one.
    await transport.enqueue(.failure(.offline("cannot connect to host")))

    let coordinator = ConnectionCoordinator(
        origin: origin(),
        budgets: .init(establishmentSeconds: 5, readinessSeconds: 5),
        makeTransport: { _ in transport }
    )

    let thrown = await failure { try await coordinator.connect() }
    let error = try #require(thrown as? ConnectionCoordinator.ConnectError)

    // `StubRelayTransport` itself produces this detail when its socket script is empty,
    // which is exactly the "the transport refused" shape: no status, no socket. The
    // detail is the transport's own message now, without a redundant category prefix.
    guard case .transportInterruption(let detail) = error else {
        Issue.record("expected a transport interruption, got \(error)")
        return
    }
    #expect(detail.contains("StubRelayTransport has no scripted socket"))
    #expect(await coordinator.status == .offline)
    #expect(await coordinator.connection == nil)
}

@Test("a socket that fails during connect stops the attempt and is reported")
func socketFailureStopsTheAttempt() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    await socket.fail(with: .offline("network connection was lost"))
    await transport.enqueue(socket: socket)

    let coordinator = ConnectionCoordinator(
        origin: origin(),
        budgets: .init(establishmentSeconds: 5, readinessSeconds: 5),
        makeTransport: { _ in transport }
    )

    let thrown = await failure { try await coordinator.connect() }
    let error = try #require(thrown as? ConnectionCoordinator.ConnectError)

    // SPEC §6.9 "Offline/transport interruption": preserve state, reconnect in the
    // foreground. This one *is* retryable, unlike a pin mismatch below.
    #expect(error == .transportInterruption(detail: "network connection was lost"))
    #expect(error.isRetryable == true)
    #expect(await coordinator.status == .offline)
    #expect(await transport.openedSocketRequests.count == 1)
}

@Test("a pin mismatch survives the mux layer's string detail and stops retries")
func pinMismatchStops() {
    // This is the shape a *real* transport produces: `URLSessionRelayTransport` answers the
    // TLS challenge inside `openSocket`, so a pin mismatch is thrown during the WebSocket
    // upgrade. It now arrives as the transport error itself rather than a string, so the
    // recovery is asserted on the kind rather than on its wording.
    let recovered = ConnectionCoordinator.failure(
        from: MuxStreamError.socketFailed(.tlsPinMismatch("cert 1"))
    )

    // SPEC §6.9 "TLS pin mismatch": stop, say the certificate changed, offer re-pair. It
    // must never fall back to normal CA validation (SPEC §3.2), and SPEC §6.4 says to stop
    // retrying pin failures.
    #expect(recovered == .certificateChanged(detail: "cert 1"))
    #expect(recovered.isRetryable == false)
    #expect(recovered.status == .hostUnavailable)
    #expect(ConnectionCoordinator.ConnectError.status(for: .certificateChanged(detail: "x")) == .hostUnavailable)
    #expect(ConnectionCoordinator.ConnectError.status(for: .cancelled) == .offline)
}

@Test("the SPEC §3.1 word for a refusal is decided in one place")
func failureToStatusMapping() {
    // SPEC §6.9 "Relay 403": explain the rejection and offer re-pair.
    #expect(ConnectionCoordinator.ConnectError.rpc(
        .credentialRejected(relayError: nil, status: 403)
    ).status == .pairingRequired)

    // SPEC §6.9 "Relayed 401": the relay could not authenticate to the harness. Re-pairing
    // the phone is not the fix, so it must not read as `Pairing required`.
    #expect(ConnectionCoordinator.ConnectError.rpc(
        .relayedAuthenticationFailure(relayError: nil, status: 401)
    ).status == .hostUnavailable)

    // SPEC §6.9 "502": the harness is unavailable behind the relay.
    #expect(ConnectionCoordinator.ConnectError.rpc(.harnessUnavailable(attempts: 3)).status
        == .hostUnavailable)

    // SPEC §6.9 "429": honour Retry-After and back off — the connection is not the problem.
    #expect(ConnectionCoordinator.ConnectError.rpc(
        .rateLimited(retryAfterSeconds: 60, attempts: 1)
    ).status == .hostUnavailable)

    // SPEC §6.9 "Business refusal" and "404 optional capability".
    #expect(ConnectionCoordinator.ConnectError.rpc(
        .business(RPCError(code: "gateway/refused", message: "no"))
    ).status == .hostUnavailable)
    #expect(ConnectionCoordinator.ConnectError.rpc(
        .capabilityUnavailable(endpoint: "session/uploadFileBinary")
    ).status == .hostUnavailable)

    // The two that mean the connection itself is gone.
    #expect(ConnectionCoordinator.ConnectError.rpc(
        .transportInterruption(detail: "gone")
    ).status == .offline)
    #expect(ConnectionCoordinator.ConnectError.transportInterruption(detail: "gone").status
        == .offline)
}

@Test("an unpaired coordinator refuses locally instead of hitting the relay")
func unpairedCoordinatorRefusesLocally() async throws {
    let transport = StubRelayTransport()
    let coordinator = ConnectionCoordinator(origin: origin(.none), makeTransport: { _ in transport })

    #expect(await coordinator.status == .pairingRequired)

    let thrown = await failure { try await coordinator.connect() }
    let error = try #require(thrown as? ConnectionCoordinator.ConnectError)
    #expect(error.status == .pairingRequired)
    #expect(await coordinator.status == .pairingRequired)
    #expect(await coordinator.lastError == error)
    // SPEC §6.2 makes the bearer header mandatory on every relay request, so there is
    // nothing to try: no socket was asked for, and no generation was burned.
    #expect(await transport.openedSocketRequests.isEmpty)
    #expect(await coordinator.generationCount == 0)
}

// MARK: - 7. Clean shutdown

@Test("shutdown cancels the stream, closes the socket, and leaves no task running")
func shutdownLeavesNothingRunning() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let coordinator = await makeCoordinator(transport: transport, socket: socket)
    let streamId = ConnectionCoordinator.eventsStreamID(for: 1)

    try await socket.push(json: readyFrameJSON(streamId: streamId))
    _ = try await coordinator.connect()
    #expect(await coordinator.status == .connected)

    await coordinator.shutdown()

    #expect(await coordinator.status == .offline)
    #expect(await coordinator.connection == nil)
    #expect(await coordinator.activeStream() == nil)
    // `MuxClient.close()` closes the socket exactly once, and a second shutdown is guarded.
    #expect(await socket.closeCount == 1)

    // The open frame is the only frame this side sent: only `$events` was ever open, so
    // there is no per-stream cancel to send (SPEC §6.4's cancel is scoped to a stream).
    let sent = await socket.sentTexts
    #expect(sent.count == 1)

    // Nothing is left reading the socket, so a later frame changes nothing and cannot
    // resurrect the connection.
    await socket.push(text: "{}")
    #expect(await coordinator.status == .offline)
    #expect(await coordinator.connection == nil)
}

@Test("shutdown is idempotent and safe before anything was ever connected")
func shutdownIsIdempotent() async throws {
    let coordinator = ConnectionCoordinator(
        origin: origin(),
        makeTransport: { _ in StubRelayTransport() }
    )

    await coordinator.shutdown()
    await coordinator.shutdown()

    #expect(await coordinator.status == .offline)
    #expect(await coordinator.activeStream() == nil)
}

@Test("a socket that dies mid-connection stops the status claiming connected")
func socketLossAfterReadyDemotesTheStatus() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let coordinator = await makeCoordinator(transport: transport, socket: socket)
    let streamId = ConnectionCoordinator.eventsStreamID(for: 1)

    try await socket.push(json: readyFrameJSON(streamId: streamId))
    _ = try await coordinator.connect()

    await socket.fail(with: .offline("network connection was lost"))

    // The drain loop is the only place a mid-connection failure can be seen, and it must
    // move the status rather than leave a dead socket reading as connected (SPEC §6.9).
    #expect(await waitUntil { await coordinator.status != .connected })
    #expect(await coordinator.status == .offline)
    #expect(await coordinator.connection == nil)
    #expect(await coordinator.lastError
        == .transportInterruption(detail: "network connection was lost"))
}

// MARK: - 8. The reconnect seam (SPEC §6.4)

@Test("Reconnecting is reachable by the next slice rather than an unreachable state")
func reconnectingIsSettable() async throws {
    let coordinator = ConnectionCoordinator(
        origin: origin(),
        makeTransport: { _ in StubRelayTransport() }
    )

    // SPEC §3.1 lists Reconnecting, so the state must exist and the backoff loop that will
    // produce it must have somewhere to report it. This is that seam, and nothing else in
    // this slice sets it.
    await coordinator.reportReconnecting()
    #expect(await coordinator.status == .reconnecting)
    #expect(await coordinator.status != .connected)
}

// MARK: - A transport that never establishes

/// A transport whose socket upgrade never returns.
///
/// `StubRelayTransport` cannot express this: ``StubRelayTransport/openSocket(_:)`` either
/// returns a canned socket or throws, so it models "the host is silent after the upgrade"
/// (which `StubRelaySocket` does) but not "the upgrade itself hangs". SPEC §6.4 budgets
/// establishment and readiness separately, so both halves need a test, and this is the
/// smallest thing that stalls the first one.
private struct StalledServeTransport: RelayTransport {
    func send(_ request: RelayHTTPRequest) async throws -> RelayHTTPResponse {
        throw RelayTransportError.other("StalledServeTransport has no HTTP script")
    }

    func openSocket(_ request: RelayHTTPRequest) async throws -> any RelaySocket {
        // Suspends. `ConnectionCoordinator.withBudget` cancels this task when the budget
        // expires, and the cancellation surfaces here as a throw — so the attempt ends
        // rather than leaving a task behind.
        try await Task.sleep(for: .seconds(3600))
        throw RelayTransportError.offline("unreachable")
    }
}
