import Foundation
import Testing

@testable import DSHRemoteKit

// Offline tests for the transport layer. Every one of them runs against
// `StubRelayTransport` / `StubRelaySocket`; nothing here opens a socket, resolves
// a name, or reads the live relay (SPEC §2 "Testing", SPEC §9 "Add focused tests
// around protocol/state boundaries").
//
// The three fixtures that carry the wire shapes are used where they exist:
// `rpc-request.json` for the envelope, `rpc-response-typed-error.json` for the
// business refusal, and `relay-spki-pin.json` for the pin. Everything else is a
// body written by the test, because no capture of it exists — and each such case
// says so.

// MARK: - Helpers

private let hostOrigin = URL(string: "https://192.0.2.10:3443")!

private func json(_ text: String) -> Data { Data(text.utf8) }

/// Thread-safe counter for generated rpcIds, so a test can assert how many calls
/// were made and reproduce the captured envelope exactly.
private final class CountingRpcIds: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let prefix: String

    init(prefix: String = "rpc") {
        self.prefix = prefix
    }

    var next: String {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return "\(prefix)-\(count)"
    }

    var issued: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private func makeRPCClient(
    transport: any RelayTransport,
    sleeper: any RelaySleeper = TaskRelaySleeper(),
    policy: RPCFailureRetryPolicy = .default,
    rpcIds: CountingRpcIds = CountingRpcIds()
) -> DshRpcClient {
    DshRpcClient(
        baseURL: hostOrigin,
        authorization: .bearer("device-token"),
        transport: transport,
        sleeper: sleeper,
        retryPolicy: policy,
        makeRpcId: { rpcIds.next }
    )
}

/// Awaits `condition` for at most `timeout`. Used only where the code under test
/// finishes work in a callback that cannot be awaited directly — the stream
/// termination handler.
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

// MARK: - 1. Envelope construction (SPEC §6.2)

@Test("the client builds the captured client-request envelope")
func rpcEnvelopeMatchesCapture() throws {
    let client = makeRPCClient(
        transport: StubRelayTransport(),
        rpcIds: CountingRpcIds(prefix: "fixture-capture")
    )

    // `Fixtures/rpc-request.json` captured `rpcId: "fixture-capture"`, so a
    // provider returning exactly that lets the whole envelope be compared.
    let envelope = client.makeRequest(
        "session/list",
        args: RPCArguments(request: RPCEmptyRequest())
    )
    let encoded = try #require(
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(envelope)).objectValue
    )

    // SPEC §6.2: {"type":"client-request","rpcId":<uuid>,"method":<method>,"payload":{"args":<args>}}
    #expect(Set(encoded.keys) == ["type", "rpcId", "method", "payload"])
    #expect(encoded["type"] == .string("client-request"))
    #expect(encoded["method"] == .string("session/list"))
    #expect(encoded["payload"]?.objectValue.map { Set($0.keys) } == ["args"])

    let captured = try Fixtures.object(.rpcRequest)
    #expect(encoded["payload"]?["args"] == captured["payload"]?["args"])

    // The method also decides the path, and the two must not disagree.
    #expect(envelope.path == "/api/session/list")
    #expect(envelope.path == "/api/\(captured["method"]?.stringValue ?? "")")
}

@Test("the request posts JSON to /api/<method> with the bearer header")
func rpcHTTPRequestShape() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(status: 200, json(#"{"type":"server-response","rpcId":"r","result":{"ok":true}}"#))
    )
    let client = makeRPCClient(transport: transport)
    try await client.callVoid("commands/list", args: RPCArguments(request: RPCEmptyRequest()))

    let requests = await transport.recordedRequests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.method == "POST")
    #expect(request.url.absoluteString == "https://192.0.2.10:3443/api/commands/list")
    // SPEC §6.2: every relay request carries the device token.
    #expect(request.header("Authorization") == "Bearer device-token")
    #expect(request.header("Content-Type") == "application/json")

    let body = try #require(request.body)
    let envelope = try JSONDecoder().decode(
        RPCRequest<RPCArguments<RPCEmptyRequest>>.self,
        from: body
    )
    #expect(envelope.type == .clientRequest)
    #expect(envelope.method == "commands/list")
    #expect(envelope.payload.args.request == RPCEmptyRequest())
}

@Test("a fresh rpcId is generated per call")
func rpcIdsArePerCall() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(status: 200, json(#"{"type":"server-response","rpcId":"r","result":{"ok":true}}"#))
    )
    let ids = CountingRpcIds()
    let client = makeRPCClient(transport: transport, rpcIds: ids)

    try await client.callVoid("a/one", args: RPCEmptyRequest())
    try await client.callVoid("a/two", args: RPCEmptyRequest())

    // SPEC §6.6: an RPC ID identifies the RPC only, and is never the human
    // submission request ID.
    #expect(ids.issued == 2)
}

// MARK: - 2. Success, void results, and business refusals

@Test("a captured successful response decodes its typed value")
func rpcSuccessDecodesTypedValue() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 200, try Fixtures.data(.rpcSessionList)))
    let client = makeRPCClient(transport: transport)

    let response = try await client.call(
        "session/list",
        args: RPCArguments(request: RPCEmptyRequest()),
        returning: SessionListResult.self
    )

    #expect(response.type == .serverResponse)
    #expect(response.result.ok)
    #expect(response.rpcId == "fixture-capture")
    #expect(try #require(response.result.value).items.isEmpty == false)
    #expect(response.result.error == nil)
}

@Test("an ok result with no value key is a success, not a decode failure")
func voidResultIsSuccess() async throws {
    // SPEC §6.2: "A result may also be {"ok":true} with no `value` key at all,
    // which is what the harness emits for a void result: treat a missing `value`
    // as success, not as a decode failure."
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(status: 200, json(#"{"type":"server-response","rpcId":"r","result":{"ok":true}}"#))
    )
    let client = makeRPCClient(transport: transport)

    let typed = try await client.call(
        "session/interrupt",
        args: RPCEmptyRequest(),
        returning: SessionListResult.self
    )
    #expect(typed.result.ok)
    #expect(typed.result.value == nil)

    let void = try await client.callVoid("session/interrupt", args: RPCEmptyRequest())
    #expect(void.result.ok)
    #expect(void.result.value == nil)
}

@Test("an HTTP 200 with ok:false surfaces the captured typed error")
func businessRefusalKeepsCodeMessageAndEndpoint() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 200, try Fixtures.data(.rpcTypedError)))
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCArguments(request: RPCEmptyRequest()))
    }

    // SPEC §6.2 and §6.9 "Business refusal": code, message and the offending
    // endpoint all survive.
    let rpcError = try #require(error?.rpcError)
    #expect(rpcError.code == "gateway/arguments-invalid")
    #expect(rpcError.message.contains("session/list"))
    #expect(rpcError.details?.endpoint == "session/list")
    #expect(error?.endpoint == "session/list")
    #expect(error?.guidance == .showBusinessRefusal)
    #expect(error?.readableReason == rpcError.message)
    #expect(error?.isRetryable == false)
}

@Test("a refusal with no error object is still a business refusal")
func refusalWithoutErrorObject() async throws {
    // unverified: no capture shows `ok:false` with no `error`; the client labels it
    // rather than crashing on the missing body.
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(status: 200, json(#"{"type":"server-response","rpcId":"r","result":{"ok":false}}"#))
    )
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }
    #expect(error?.rpcError?.code == "gateway/refused-without-error")
    #expect(error?.guidance == .showBusinessRefusal)
}

@Test("a refusal whose value this build cannot model still surfaces the typed error")
func refusalDoesNotDependOnValueDecoding() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(
            status: 200,
            json(
                #"{"type":"server-response","rpcId":"r","result":{"ok":false,"value":{"future":{"shape":[1,2]}},"error":{"code":"gateway/denied","message":"no"}}}"#
            )
        )
    )
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.call(
            "session/list",
            args: RPCEmptyRequest(),
            returning: SessionListResult.self
        )
    }
    #expect(error?.rpcError?.code == "gateway/denied")
}

// MARK: - 3. Malformed responses (SPEC §6.9 "Malformed response")

@Test("a body that is not JSON is protocol incompatibility, not a crash")
func malformedBodyIsProtocolIncompatible() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 200, json("<html>gateway error</html>")))
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }
    #expect(error?.guidance == .protocolIncompatibility)
    #expect(error?.isRetryable == false)
}

@Test("valid JSON that is not an envelope is protocol incompatibility")
func nonEnvelopeJSONIsProtocolIncompatible() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 200, json(#"{"hello":"world"}"#)))
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }
    #expect(error?.guidance == .protocolIncompatibility)
}

@Test("an empty body on HTTP 200 is protocol incompatibility")
func emptyBodyIsProtocolIncompatible() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 200, Data()))
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }
    #expect(error?.guidance == .protocolIncompatibility)
}

@Test("an echoed client-request envelope is refused")
func echoedClientRequestIsRefused() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(
            status: 200,
            json(#"{"type":"client-request","rpcId":"r","method":"session/list","result":{"ok":true}}"#)
        )
    )
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }
    #expect(error?.guidance == .protocolIncompatibility)
}

@Test("a successful result that does not match the requested type is refused")
func typedValueMismatchIsProtocolIncompatible() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(
            status: 200,
            json(#"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"items":"not an array"}}}"#)
        )
    )
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.call(
            "session/list",
            args: RPCEmptyRequest(),
            returning: SessionListResult.self
        )
    }
    #expect(error?.guidance == .protocolIncompatibility)

    // The same body is fine when the caller does not model the value.
    let untyped = try await client.callVoid("session/list", args: RPCEmptyRequest())
    #expect(untyped.result.ok)
}

// MARK: - 4. Status mapping (SPEC §6.9)

@Test("403 means pair again and is never retried")
func status403MapsToRePair() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(
            status: 403,
            try Fixtures.data(.forbiddenUnpaired),
            headers: ["Content-Type": "application/json"]
        )
    )
    let sleeper = RecordingRelaySleeper()
    let client = makeRPCClient(transport: transport, sleeper: sleeper)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }

    #expect(error == .credentialRejected(
        relayError: RelayErrorResponse(
            error: "forbidden",
            message: "pair this device with the relay first"
        ),
        status: 403
    ))
    #expect(error?.guidance == .pairAgain)
    #expect(error?.isRetryable == false)

    // SPEC §6.9: "no endless retry". One attempt, no sleep.
    let attempts = await transport.recordedRequests.count
    let slept = await sleeper.sleptSeconds
    #expect(attempts == 1)
    #expect(slept.isEmpty)
}

@Test("401 is a relay-to-harness failure, not a re-pair")
func status401MapsToRelayedAuthentication() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(status: 401, json(#"{"error":"unauthorized","message":"harness session is not available"}"#))
    )
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }
    #expect(error?.guidance == .relayToHarnessAuthentication)
    #expect(error?.isRetryable == false)

    guard case .relayedAuthenticationFailure(let relayError, let status) = try #require(error) else {
        Issue.record("expected a relayedAuthenticationFailure")
        return
    }
    #expect(status == 401)
    #expect(relayError?.message == "harness session is not available")
}

@Test("404 means the capability is unavailable and permits the upload fallback")
func status404MapsToCapabilityUnavailable() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 404, Data()))
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/uploadFileBinary", args: RPCEmptyRequest())
    }
    #expect(error == .capabilityUnavailable(endpoint: "session/uploadFileBinary"))
    #expect(error?.guidance == .hideCapability)
    #expect(error?.isRetryable == false)
}

@Test("429 honours Retry-After and then succeeds")
func status429HonoursRetryAfter() async throws {
    let transport = StubRelayTransport(
        responses: [
            .json(status: 429, Data(), headers: ["Retry-After": "7"]),
            .json(status: 200, json(#"{"type":"server-response","rpcId":"r","result":{"ok":true}}"#)),
        ]
    )
    let sleeper = RecordingRelaySleeper()
    let client = makeRPCClient(transport: transport, sleeper: sleeper)

    let response = try await client.callVoid("session/list", args: RPCEmptyRequest())
    #expect(response.result.ok)

    let slept = await sleeper.sleptSeconds
    let attempts = await transport.recordedRequests.count
    #expect(slept == [7])
    #expect(attempts == 2)
}

@Test("429 with no Retry-After waits the SPEC's 60 seconds")
func status429DefaultsToSixtySeconds() async throws {
    let transport = StubRelayTransport(
        responses: [
            .json(status: 429, Data()),
            .json(status: 200, json(#"{"type":"server-response","rpcId":"r","result":{"ok":true}}"#)),
        ]
    )
    let sleeper = RecordingRelaySleeper()
    let client = makeRPCClient(transport: transport, sleeper: sleeper)

    _ = try await client.callVoid("session/list", args: RPCEmptyRequest())

    // SPEC §6.9: "Honor Retry-After; use 60 seconds if missing".
    let slept = await sleeper.sleptSeconds
    #expect(slept == [60])
}

@Test("429 with an HTTP-date Retry-After is honoured")
func status429HonoursHTTPDateRetryAfter() async throws {
    let transport = StubRelayTransport(
        responses: [
            .json(status: 429, Data(), headers: ["Retry-After": "Wed, 21 Oct 2099 07:28:00 GMT"]),
            .json(status: 200, json(#"{"type":"server-response","rpcId":"r","result":{"ok":true}}"#)),
        ]
    )
    let sleeper = RecordingRelaySleeper()
    // 2001-09-09T01:46:40Z, comfortably before the header's date.
    let clock = FixedEpochClock(millis: 1_000_000_000_000)
    let client = DshRpcClient(
        baseURL: hostOrigin,
        authorization: .bearer("device-token"),
        transport: transport,
        sleeper: sleeper,
        clock: clock
    )

    _ = try await client.callVoid("session/list", args: RPCEmptyRequest())

    let slept = await sleeper.sleptSeconds
    let seconds = try #require(slept.first)
    #expect(slept.count == 1)
    #expect(seconds > 3_000_000_000)
}

@Test("an exhausted 429 becomes a backoff state carrying the delay")
func status429ExhaustsToBackoff() async throws {
    let transport = StubRelayTransport(
        responses: [
            .json(status: 429, Data(), headers: ["Retry-After": "12"]),
            .json(status: 429, Data(), headers: ["Retry-After": "12"]),
            .json(status: 429, Data(), headers: ["Retry-After": "12"]),
        ]
    )
    let sleeper = RecordingRelaySleeper()
    let client = makeRPCClient(transport: transport, sleeper: sleeper)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }
    #expect(error == .rateLimited(retryAfterSeconds: 12, attempts: 3))
    #expect(error?.guidance == .backOff(seconds: 12))

    // Three attempts, two waits.
    let slept = await sleeper.sleptSeconds
    #expect(slept == [12, 12])
}

@Test("502 is harness-unavailable with a bounded retry")
func status502RetriesThenSucceeds() async throws {
    let transport = StubRelayTransport(
        responses: [
            .json(status: 502, json(#"{"error":"bad gateway"}"#)),
            .json(status: 200, json(#"{"type":"server-response","rpcId":"r","result":{"ok":true}}"#)),
        ]
    )
    let sleeper = RecordingRelaySleeper()
    let client = makeRPCClient(transport: transport, sleeper: sleeper)

    _ = try await client.callVoid("session/list", args: RPCEmptyRequest())

    let slept = await sleeper.sleptSeconds
    #expect(slept == [0.5])
}

@Test("an exhausted 502 becomes harness-unavailable")
func status502ExhaustsToHarnessUnavailable() async throws {
    let transport = StubRelayTransport(
        responses: Array(repeating: .json(status: 502, Data()), count: 3)
    )
    let sleeper = RecordingRelaySleeper()
    let client = makeRPCClient(transport: transport, sleeper: sleeper)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }
    #expect(error == .harnessUnavailable(attempts: 3))
    #expect(error?.guidance == .harnessUnavailable)
    #expect(error?.isRetryable == true)
}

@Test("the retry policy can forbid retrying a user submission")
func retryPolicyNoneStopsAfterOneAttempt() async throws {
    // SPEC §3.4 / §6.6: an uncertain prompt is never automatically resent, so
    // prompt submission passes `.none`.
    let transport = StubRelayTransport(
        responses: Array(
            repeating: .json(status: 429, Data(), headers: ["Retry-After": "5"]),
            count: 3
        )
    )
    let sleeper = RecordingRelaySleeper()
    let client = makeRPCClient(transport: transport, sleeper: sleeper)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/prompt", args: RPCEmptyRequest(), retryPolicy: RPCFailureRetryPolicy.none)
    }
    #expect(error == .rateLimited(retryAfterSeconds: 5, attempts: 1))

    let attempts = await transport.recordedRequests.count
    let slept = await sleeper.sleptSeconds
    #expect(attempts == 1)
    #expect(slept.isEmpty)
}

@Test("a write through the mutation helper makes exactly one attempt")
func mutationHelperNeverRetries() async throws {
    // The same guarantee as the test above, but reached without a call site ever
    // naming a policy. The hazard it removes is specific: the policy parameter is
    // `RPCFailureRetryPolicy?` defaulting to nil, so a call site writing `.none`
    // means `Optional.none` and gets the *retrying* default instead — silently,
    // and it compiles cleanly. `mutate` has no policy parameter, so that mistake
    // is not expressible.
    let transport = StubRelayTransport(
        responses: Array(
            repeating: .json(status: 429, Data(), headers: ["Retry-After": "5"]),
            count: 3
        )
    )
    let sleeper = RecordingRelaySleeper()
    let client = makeRPCClient(transport: transport, sleeper: sleeper)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.mutateVoid("session/prompt", args: RPCEmptyRequest())
    }
    #expect(error == .rateLimited(retryAfterSeconds: 5, attempts: 1))

    let attempts = await transport.recordedRequests.count
    let slept = await sleeper.sleptSeconds
    #expect(attempts == 1)
    #expect(slept.isEmpty)
}

@Test("a read still retries, so the helper is not a blanket ban")
func readsStillRetry() async throws {
    // The other half of SPEC §3: safe reads keep the bounded read-retry policy.
    // If the mutation policy had leaked into `call`, this is what would catch it.
    let transport = StubRelayTransport(
        responses: [
            .json(status: 429, Data(), headers: ["Retry-After": "0"]),
            .json(status: 200, json(#"{"type":"server-response","rpcId":"r","result":{"ok":true}}"#)),
        ]
    )
    let sleeper = RecordingRelaySleeper()
    let client = makeRPCClient(transport: transport, sleeper: sleeper)

    try await client.callVoid("session/list", args: RPCEmptyRequest())

    let attempts = await transport.recordedRequests.count
    #expect(attempts == 2)
}

@Test("an unlisted status is carried whole")
func status500MapsToUnexpectedStatus() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 500, Data()))
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }
    #expect(error == .unexpectedStatus(status: 500, endpoint: "session/list"))
}

@Test("a transport interruption preserves the draft")
func transportInterruptionMapsToOffline() async throws {
    let transport = StubRelayTransport(responses: [.failure(.offline("URLError -1009"))])
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }
    #expect(error?.guidance == .preserveDraftAndReconnect)
    #expect(error?.isRetryable == false)
}

@Test("a pin mismatch stops rather than falling back to platform trust")
func pinMismatchIsTerminal() async throws {
    let transport = StubRelayTransport(
        responses: [.failure(.tlsPinMismatch("serverCertificateUntrusted"))]
    )
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }
    // SPEC §3.2: "it never silently falls back to normal CA validation".
    #expect(error?.guidance == .certificateChangedRePair)
    #expect(error?.isRetryable == false)
}

// MARK: - 5. The bare-body endpoints (SPEC §6.7, §6.8)

@Test("uploadFileBinary posts raw bytes with encoded query values")
func uploadFileBinaryRequestShape() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(status: 200, json(#"{"ok":true,"value":{"receiptId":"r-1"}}"#))
    )
    let client = DshBareEndpointClient(
        baseURL: hostOrigin,
        authorization: .bearer("device-token"),
        transport: transport
    )

    let result = try await client.uploadFileBinary(
        sessionId: "session-0001",
        name: "school photo & notes #1.png",
        bytes: Data([0x89, 0x50, 0x4E, 0x47])
    )

    let requests = await transport.recordedRequests
    let request = try #require(requests.first)
    #expect(request.method == "POST")
    // SPEC §6.8: POST /api/session/uploadFileBinary?sessionId=…&name=…
    #expect(request.url.path == "/api/session/uploadFileBinary")
    #expect(request.header("Content-Type") == "application/octet-stream")
    #expect(request.header("Authorization") == "Bearer device-token")
    #expect(request.body == Data([0x89, 0x50, 0x4E, 0x47]))

    // "Encode query values correctly": the space, ampersand and hash must not
    // break the query apart.
    let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)
    #expect(items.contains(URLQueryItem(name: "sessionId", value: "session-0001")))
    #expect(items.contains(URLQueryItem(name: "name", value: "school photo & notes #1.png")))

    // The bare body, not the RPC envelope.
    #expect(result.value?["receiptId"] == .string("r-1"))
}

@Test("a bare ok:false is a business refusal even on HTTP 200")
func uploadFileBinaryBareFailure() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(
            status: 200,
            json(#"{"ok":false,"error":{"code":"session/upload-too-large","message":"file exceeds the host limit"}}"#)
        )
    )
    let client = DshBareEndpointClient(
        baseURL: hostOrigin,
        authorization: .bearer("device-token"),
        transport: transport
    )

    let error = await #expect(throws: DshRPCError.self) {
        try await client.uploadFileBinary(sessionId: "s", name: "big.bin", bytes: Data([0]))
    }
    // SPEC §6.8: "the HTTP status is 200 even on failure", so `ok` is the only
    // success signal.
    #expect(error?.rpcError?.code == "session/upload-too-large")
    #expect(error?.guidance == .showBusinessRefusal)
}

@Test("a bare body that is not an object is protocol incompatibility")
func bareBodyMalformed() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 200, json("[]")))
    let client = DshBareEndpointClient(
        baseURL: hostOrigin,
        authorization: .bearer("device-token"),
        transport: transport
    )

    let error = await #expect(throws: DshRPCError.self) {
        try await client.uploadFileBinary(sessionId: "s", name: "f.bin", bytes: Data([1]))
    }
    #expect(error?.guidance == .protocolIncompatibility)
}

@Test("the event result envelope carries exactly clientId, eventId and outcome")
func eventResultEnvelopeShape() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(status: 200, json(#"{"type":"server-response","rpcId":"r","result":{"ok":true}}"#))
    )
    let client = DshBareEndpointClient(
        baseURL: hostOrigin,
        authorization: .bearer("device-token"),
        transport: transport
    )

    let value = try await client.submitEventResult(
        EventResultRequest(
            clientId: "c-1",
            eventId: "e-1",
            outcome: .result(.string("allowed-once"))
        )
    )
    // A void result is not a failure here either.
    #expect(value == nil)

    let requests = await transport.recordedRequests
    let request = try #require(requests.first)
    // SPEC §6.7: the gateway-internal path keeps its `$` unescaped.
    #expect(request.url.absoluteString == "https://192.0.2.10:3443/api/$events/result")
    #expect(DshBareEndpointClient.eventResultPath == "/api/$events/result")

    let body = try #require(request.body)
    let object = try #require(try JSONDecoder().decode(JSONValue.self, from: body).objectValue)
    #expect(object["type"] == .string("client-request"))
    #expect(object["method"] == .string("$events/result"))

    let args = try #require(object["payload"]?["args"]?.objectValue)
    #expect(Set(args.keys) == ["clientId", "eventId", "outcome"])
    #expect(args["clientId"] == .string("c-1"))
    #expect(args["eventId"] == .string("e-1"))
    #expect(args["outcome"] == .object([
        "kind": .string("result"),
        "value": .string("allowed-once"),
    ]))
}

@Test(
    "the three outcome shapes are exactly the three the host validates",
    arguments: [
        (EventOutcome.next, #"{"kind":"next"}"#),
        (EventOutcome.result(nil), #"{"kind":"result"}"#),
        (EventOutcome.result(.string("rejected")), #"{"kind":"result","value":"rejected"}"#),
        (
            EventOutcome.result(.object(["answers": .array([])])),
            #"{"kind":"result","value":{"answers":[]}}"#
        ),
        (
            EventOutcome.rejected(error: .object(["message": .string("changed my mind")])),
            #"{"kind":"rejected","error":{"message":"changed my mind"}}"#
        ),
    ]
)
func outcomeShapesMatchTheContract(outcome: EventOutcome, expected: String) throws {
    // SPEC §6.7: `{"kind":"next"}` carries no other key; `{"kind":"result"}`
    // carries `value` or not; a rejection with a reason uses the `rejected` shape.
    let actual = try #require(
        try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(outcome.jsonValue)
        ) as? [String: Any]
    )
    let wanted = try #require(
        try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? [String: Any]
    )
    #expect(actual.keys.sorted() == wanted.keys.sorted())
    #expect(NSDictionary(dictionary: actual).isEqual(to: wanted))
}

@Test("a next outcome never carries a value key")
func nextOutcomeHasNoValueKey() throws {
    let object = try #require(EventOutcome.next.jsonValue.objectValue)
    #expect(object.keys.sorted() == ["kind"])
}

@Test("the event result refuses a business error like any other RPC")
func eventResultBusinessError() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(
            status: 200,
            json(
                #"{"type":"server-response","rpcId":"r","result":{"ok":false,"error":{"code":"gateway/event-invalid","message":"invalid event result","details":{"endpoint":"$events/result"}}}}"#
            )
        )
    )
    let client = DshBareEndpointClient(
        baseURL: hostOrigin,
        authorization: .bearer("device-token"),
        transport: transport
    )

    let error = await #expect(throws: DshRPCError.self) {
        try await client.submitEventResult(
            EventResultRequest(clientId: "c", eventId: "e", outcome: .next)
        )
    }
    #expect(error?.rpcError?.code == "gateway/event-invalid")
    #expect(error?.endpoint == "$events/result")
}

// MARK: - 6. The multiplexed socket (SPEC §6.4)

private func makeMux(
    transport: StubRelayTransport,
    socket: StubRelaySocket
) async -> MuxClient {
    await transport.enqueue(socket: socket)
    return MuxClient(
        baseURL: hostOrigin,
        authorization: .bearer("device-token"),
        transport: transport
    )
}

private func itemFrame(streamId: String, seq: Int64) -> JSONValue {
    .object([
        "type": .string("item"),
        "streamId": .string(streamId),
        "value": .object([
            "type": .string("event"),
            "event": .object([
                "type": .string("turn/start"),
                "seq": .int(seq),
                "data": .object([:]),
            ]),
        ]),
    ])
}

private func endFrame(streamId: String) -> JSONValue {
    .object(["type": .string("end"), "streamId": .string(streamId)])
}

private func errorFrame(streamId: String) -> JSONValue {
    .object([
        "type": .string("error"),
        "streamId": .string(streamId),
        "message": .string("stream refused"),
    ])
}

@Test("opening a stream upgrades /api/remote.mux and sends the captured open frame")
func muxOpenSendsTheControlFrame() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    _ = try await mux.open(streamId: "1", endpoint: "$events")
    let openStreamIds = await mux.openStreamIds
    #expect(openStreamIds == ["1"])

    let opened = await transport.openedSocketRequests
    let request = try #require(opened.first)
    #expect(request.url.absoluteString == "https://192.0.2.10:3443/api/remote.mux")
    // SPEC §6.2: the upgrade carries the bearer token as well.
    #expect(request.header("Authorization") == "Bearer device-token")

    let sends = await socket.sentTexts
    let sent = try #require(sends.first)
    let object = try #require(
        try JSONDecoder().decode(JSONValue.self, from: Data(sent.utf8)).objectValue
    )
    // SPEC §6.4's example, exactly.
    #expect(object == [
        "type": .string("open"),
        "streamId": .string("1"),
        "endpoint": .string("$events"),
        "payload": .object(["args": .object([:])]),
    ])

    await mux.close()
}

@Test("frames are routed to their own stream and no other")
func muxRoutesByStreamId() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    let first = try await mux.open(streamId: "1", endpoint: "$events")
    let second = try await mux.open(streamId: "2", endpoint: "session/follow")

    try await socket.push(json: itemFrame(streamId: "1", seq: 1))
    try await socket.push(json: itemFrame(streamId: "2", seq: 2))
    try await socket.push(json: itemFrame(streamId: "1", seq: 3))

    var firstIterator = first.makeAsyncIterator()
    var secondIterator = second.makeAsyncIterator()

    let firstOne = try #require(try await firstIterator.next())
    #expect(firstOne.streamId == "1")
    #expect(firstOne.frame.streamId == "1")
    #expect(firstOne.frame.value?.event?.seq == 1)

    let secondOne = try #require(try await secondIterator.next())
    #expect(secondOne.streamId == "2")
    #expect(secondOne.frame.value?.event?.seq == 2)

    let firstTwo = try #require(try await firstIterator.next())
    #expect(firstTwo.frame.value?.event?.seq == 3)

    await mux.close()
}

@Test("cancelling one stream leaves the others running")
func muxCancelIsIsolated() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    let first = try await mux.open(streamId: "1", endpoint: "$events")
    let second = try await mux.open(streamId: "2", endpoint: "session/follow")

    var firstIterator = first.makeAsyncIterator()
    var secondIterator = second.makeAsyncIterator()

    await mux.cancel(streamId: "1")
    let stillOpen = await mux.openStreamIds
    #expect(stillOpen == ["2"])

    // SPEC §6.4's cancel frame went out.
    let sends = await socket.sentTexts
    let cancelText = try #require(sends.first { $0.contains("\"cancel\"") })
    let cancel = try #require(
        try JSONDecoder().decode(JSONValue.self, from: Data(cancelText.utf8)).objectValue
    )
    #expect(cancel == ["type": .string("cancel"), "streamId": .string("1")])

    // The cancelled stream is over...
    let cancelledNext = try await firstIterator.next()
    #expect(cancelledNext == nil)

    // ...while the other one keeps delivering.
    try await socket.push(json: itemFrame(streamId: "2", seq: 9))
    let stillAlive = try #require(try await secondIterator.next())
    #expect(stillAlive.frame.value?.event?.seq == 9)

    await mux.close()
}

@Test("a cancelled stream's late frames are never delivered to a new subscriber")
func muxCancelledStreamFramesDoNotLeak() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    let first = try await mux.open(streamId: "1", endpoint: "session/follow")
    var firstIterator = first.makeAsyncIterator()

    await mux.cancel(streamId: "1")
    let firstNext = try await firstIterator.next()
    #expect(firstNext == nil)

    // Frames in flight for the cancelled stream, arriving while nothing is
    // registered for "1". These must be dropped, not buffered.
    try await socket.push(json: itemFrame(streamId: "1", seq: 100))
    try await socket.push(json: itemFrame(streamId: "1", seq: 101))

    // A witness frame on another stream, pushed after them. Awaiting it proves the
    // receive loop has already routed 100 and 101 — the stub delivers in order, so
    // the witness cannot arrive first. Without this barrier the test would race the
    // loop, and would be asserting on whichever order the scheduler picked.
    let witness = try await mux.open(streamId: "witness", endpoint: "$events")
    var witnessIterator = witness.makeAsyncIterator()
    try await socket.push(json: itemFrame(streamId: "witness", seq: 900))
    let seenByWitness = try #require(try await witnessIterator.next())
    #expect(seenByWitness.frame.value?.event?.seq == 900)

    // A new subscriber on the same ID — SPEC §4's "changing conversations cancels
    // the old follow stream and prevents late frames from mutating the new
    // conversation".
    let second = try await mux.open(streamId: "1", endpoint: "session/follow")
    var secondIterator = second.makeAsyncIterator()

    try await socket.push(json: itemFrame(streamId: "1", seq: 200))
    let only = try #require(try await secondIterator.next())
    #expect(only.streamId == "1")
    #expect(only.frame.value?.event?.seq == 200)

    await mux.close()
}

@Test("a cancelled stream's id is not reused, so a later subscriber cannot inherit it")
func muxCancelledStreamIdIsNotReused() async throws {
    // The stronger guarantee the app relies on by default: generated IDs are never
    // handed out twice, so no in-flight frame can reach a subscriber that did not
    // exist when it was sent — not even a frame the socket had already buffered
    // before the new subscription registered, which no client-side rule can tell
    // apart from a frame the host sent after the cancel.
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    let abandoned = try await mux.open(endpoint: "session/follow")
    var abandonedIterator = abandoned.makeAsyncIterator()

    await mux.cancel(streamId: "1")

    // Frames the host sent before it saw the cancel.
    try await socket.push(json: itemFrame(streamId: "1", seq: 100))
    try await socket.push(json: itemFrame(streamId: "1", seq: 101))

    // The next stream takes a fresh id, as SPEC §4's "changing conversations"
    // requires, rather than the cancelled one.
    let replacement = try await mux.open(endpoint: "session/follow")
    var replacementIterator = replacement.makeAsyncIterator()

    try await socket.push(json: itemFrame(streamId: "2", seq: 200))
    let only = try #require(try await replacementIterator.next())
    #expect(only.streamId == "2")
    #expect(only.frame.value?.event?.seq == 200)

    let abandonedNext = try await abandonedIterator.next()
    #expect(abandonedNext == nil)

    let stillOpen = await mux.openStreamIds
    #expect(stillOpen == ["2"])

    await mux.close()
}

@Test("a stream id already in use is refused")
func muxRefusesDuplicateStreamId() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    _ = try await mux.open(streamId: "1", endpoint: "$events")
    await #expect(throws: MuxStreamError.streamIdInUse("1")) {
        _ = try await mux.open(streamId: "1", endpoint: "$events")
    }
    await mux.close()
}

@Test("an end frame terminates its stream only")
func muxEndTerminatesOneStream() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    let first = try await mux.open(streamId: "1", endpoint: "$events")
    let second = try await mux.open(streamId: "2", endpoint: "$events")
    var firstIterator = first.makeAsyncIterator()
    var secondIterator = second.makeAsyncIterator()

    try await socket.push(json: itemFrame(streamId: "1", seq: 1))
    try await socket.push(json: endFrame(streamId: "1"))
    try await socket.push(json: itemFrame(streamId: "2", seq: 2))

    _ = try await firstIterator.next()
    let end = try #require(try await firstIterator.next())
    #expect(end.frame.type == .end)
    #expect(end.streamId == "1")

    let afterEnd = try await firstIterator.next()
    #expect(afterEnd == nil)

    let surviving = try #require(try await secondIterator.next())
    #expect(surviving.frame.value?.event?.seq == 2)

    let stillOpen = await mux.openStreamIds
    #expect(stillOpen == ["2"])

    await mux.close()
}

@Test("an error frame is surfaced to its stream and ends it")
func muxErrorFrameIsSurfaced() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    let stream = try await mux.open(streamId: "1", endpoint: "session/follow")
    var iterator = stream.makeAsyncIterator()

    try await socket.push(json: errorFrame(streamId: "1"))
    let frame = try #require(try await iterator.next())
    #expect(frame.frame.type == .error)
    #expect(frame.streamId == "1")
    // The unmodelled keys of an uncaptured frame kind survive.
    #expect(frame.frame.unknownFields["message"] == .string("stream refused"))

    let afterError = try await iterator.next()
    #expect(afterError == nil)

    await mux.close()
}

@Test("an unknown frame kind is yielded rather than dropped")
func muxUnknownFrameKindIsYielded() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    let stream = try await mux.open(streamId: "1", endpoint: "$events")
    var iterator = stream.makeAsyncIterator()

    try await socket.push(json: .object([
        "type": .string("resync"),
        "streamId": .string("1"),
        "reason": .string("watermark regressed"),
    ]))

    let frame = try #require(try await iterator.next())
    #expect(frame.frame.type == .unknown("resync"))
    #expect(frame.frame.unknownFields["reason"] == .string("watermark regressed"))

    await mux.close()
}

@Test("a dead socket fails every open stream")
func muxSocketFailureFailsAllStreams() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    let first = try await mux.open(streamId: "1", endpoint: "$events")
    let second = try await mux.open(streamId: "2", endpoint: "$events")
    var firstIterator = first.makeAsyncIterator()
    var secondIterator = second.makeAsyncIterator()

    await socket.fail(with: .offline("connection lost"))

    let firstError = await #expect(throws: MuxStreamError.self) {
        _ = try await firstIterator.next()
    }
    let secondError = await #expect(throws: MuxStreamError.self) {
        _ = try await secondIterator.next()
    }
    #expect(firstError == .socketFailed(.offline("connection lost")))
    #expect(secondError == firstError)

    let stillOpen = await mux.openStreamIds
    let connected = await mux.isConnected
    #expect(stillOpen.isEmpty)
    #expect(connected == false)
}

@Test("a frame that is not a mux envelope is protocol incompatibility")
func muxMalformedFrameFails() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    let stream = try await mux.open(streamId: "1", endpoint: "$events")
    var iterator = stream.makeAsyncIterator()

    await socket.push(text: "not json at all")

    let error = await #expect(throws: MuxStreamError.self) {
        _ = try await iterator.next()
    }
    guard case .protocolIncompatible = try #require(error) else {
        Issue.record("expected a protocol incompatibility, got \(String(describing: error))")
        return
    }
}

@Test("closing the client ends every stream and closes the socket")
func muxCloseEndsEverything() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    let stream = try await mux.open(streamId: "1", endpoint: "$events")
    var iterator = stream.makeAsyncIterator()

    await mux.close()
    let afterClose = try await iterator.next()
    #expect(afterClose == nil)

    let connected = await mux.isConnected
    let closes = await socket.closeCount
    #expect(connected == false)
    #expect(closes == 1)

    // Not reusable: a reconnect is a new client, which is how SPEC §6.5's
    // "Reconnect creates a new generation" is expressed.
    await #expect(throws: MuxStreamError.clientClosed) {
        _ = try await mux.open(endpoint: "$events")
    }
}

@Test("a consumer that stops consuming releases its stream on the socket")
func muxConsumerCancellationCancelsTheStream() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    let stream = try await mux.open(streamId: "7", endpoint: "session/follow")

    let consumer = Task {
        for try await _ in stream {}
    }
    // Let the loop start, then cancel it: the sequence's termination handler is
    // what has to release the stream on the socket.
    try? await Task.sleep(for: .milliseconds(20))
    consumer.cancel()
    _ = try? await consumer.value

    let cancelled = await waitUntil {
        let texts = await socket.sentTexts
        return texts.contains { $0.contains("\"cancel\"") && $0.contains("\"7\"") }
    }
    #expect(cancelled, "expected a cancel frame for the abandoned stream")

    let stillOpen = await mux.openStreamIds
    #expect(stillOpen.isEmpty)

    await mux.close()
}

@Test("the stream identifier defaults to the next number")
func muxGeneratesStreamIds() async throws {
    let transport = StubRelayTransport()
    let socket = StubRelaySocket()
    let mux = await makeMux(transport: transport, socket: socket)

    _ = try await mux.open(endpoint: "$events")
    _ = try await mux.open(endpoint: "session/follow")

    let stillOpen = await mux.openStreamIds
    #expect(stillOpen == ["1", "2"])

    let sends = await socket.sentTexts
    #expect(sends.count == 2)
    #expect(sends[0].contains("\"streamId\":\"1\""))
    #expect(sends[1].contains("\"streamId\":\"2\""))

    await mux.close()
}

// MARK: - 7. Pairing (SPEC §3.2, §6.3)

/// The captured payload expires at 1755500000000 ms; a frozen clock one
/// millisecond earlier is the only way to validate the capture at all.
private let beforeCaptureExpiry = FixedEpochClock(millis: 1_755_000_000_000 - 1)

private func pairingClient(
    transport: any RelayTransport,
    sleeper: any RelaySleeper = TaskRelaySleeper()
) -> PairingClient {
    PairingClient(transport: transport, sleeper: sleeper)
}

private func unpinnedPayload(_ client: PairingClient) throws -> PairingPayload {
    // The captured claim carries a *different* pin than the captured payload
    // (`3q2+7wAA…` vs `7pcXvn2K…`), so pin agreement has its own tests; the pin is
    // dropped here to isolate the claim's request shape.
    var payload = try client.decodePayload(
        Fixtures.data(.pairingPayload),
        clock: beforeCaptureExpiry
    )
    payload.fingerprint = nil
    return payload
}

@Test("the captured pairing payload decodes and validates")
func pairingPayloadDecodesAndValidates() throws {
    let client = pairingClient(transport: StubRelayTransport())
    let payload = try client.decodePayload(
        Fixtures.data(.pairingPayload),
        clock: beforeCaptureExpiry
    )
    // SPEC §3.2 step 1.
    #expect(payload.kind == "dsh-relay-pair")
    #expect(payload.version == 1)
    #expect(payload.code == "48213977")
    #expect(payload.relayURL?.absoluteString == "https://192.0.2.10:3443")
    #expect(payload.hostname == "192.0.2.10")
}

@Test("a malformed pairing payload is refused before validation")
func pairingPayloadMalformed() {
    let client = pairingClient(transport: StubRelayTransport())
    #expect(throws: PairingError.self) {
        try client.decodePayload(Data("not json".utf8))
    }
}

@Test(
    "pairing refusals keep their own reason",
    arguments: [
        (
            [("kind", JSONValue.string("dsh-relay-other"))],
            PairingPayload.ValidationError.unexpectedKind("dsh-relay-other")
        ),
        ([("v", JSONValue.int(2))], PairingPayload.ValidationError.unsupportedVersion(2)),
        (
            [("url", JSONValue.string("http://192.0.2.10:3444"))],
            PairingPayload.ValidationError.httpsRequired("http://192.0.2.10:3444")
        ),
        ([("code", JSONValue.string(""))], PairingPayload.ValidationError.emptyCode),
        (
            [("expiresAt", JSONValue.int(1_000))],
            PairingPayload.ValidationError.expired(expiresAt: 1_000, now: 2_000)
        ),
    ]
)
func pairingPayloadRefusals(
    mutations: [(String, JSONValue)],
    expected: PairingPayload.ValidationError
) throws {
    // SPEC §3.2 step 1: wrong kind, unsupported v, non-HTTPS URL, empty code,
    // expired — each refused, and each for its own reason.
    var object = try Fixtures.object(.pairingPayload)
    for (key, value) in mutations { object[key] = value }

    let client = pairingClient(transport: StubRelayTransport())
    let error = #expect(throws: PairingError.self) {
        try client.decodePayload(
            try Fixtures.encode(object: object),
            clock: FixedEpochClock(millis: 2_000)
        )
    }
    #expect(error == .invalidPayload(expected))
}

@Test("a plain-HTTP payload is refused with an actionable HTTPS message")
func pairingPlainHTTPIsActionable() throws {
    var object = try Fixtures.object(.pairingPayload)
    object["url"] = .string("http://192.0.2.10:3443")
    let client = pairingClient(transport: StubRelayTransport())

    let error = #expect(throws: PairingError.self) {
        try client.decodePayload(try Fixtures.encode(object: object), clock: beforeCaptureExpiry)
    }
    // SPEC §3.2: "reject plain HTTP pairing with an actionable HTTPS-required
    // message", not a generic parse failure.
    #expect(error?.readableReason?.contains("HTTPS") == true)
}

@Test("the claim posts {code,name} to the payload origin with no credential")
func pairingClaimRequestShape() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 200, try Fixtures.data(.pairingClaimResponse)))
    let client = pairingClient(transport: transport)

    let claim = try await client.claim(
        unpinnedPayload(client),
        deviceName: "Patrick's iPhone"
    )
    #expect(claim.deviceId == "9f2c41ab30d7e155")
    #expect(claim.token.hasPrefix("REDACTED-43-CHAR"))

    let requests = await transport.recordedRequests
    let request = try #require(requests.first)
    #expect(request.method == "POST")
    // SPEC §3.2 step 4: the payload URL's /relay/pair, and nowhere else.
    #expect(request.url.absoluteString == "https://192.0.2.10:3443/relay/pair")
    #expect(request.header("Content-Type") == "application/json")
    // The one-time code is the credential for this call; there is no device token
    // yet and none may be invented.
    #expect(request.header("Authorization") == nil)

    let bodyData = try #require(request.body)
    let body = try #require(
        try JSONDecoder().decode(JSONValue.self, from: bodyData).objectValue
    )
    #expect(body.keys.sorted() == ["code", "name"])
    #expect(body["code"] == .string("48213977"))
    #expect(body["name"] == .string("Patrick's iPhone"))
}

@Test("the pairing code is sent once and is absent from everything returned")
func pairingCodeIsNeverPersisted() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 200, try Fixtures.data(.pairingClaimResponse)))
    let client = pairingClient(transport: transport)

    let claim = try await client.claim(unpinnedPayload(client), deviceName: "phone")

    // The return value carries no code: `PairingClaimResponse` has no such field,
    // so this is checked on the encoded bytes rather than by a property lookup.
    let encoded = String(decoding: try JSONEncoder().encode(claim), as: UTF8.self)
    #expect(!encoded.contains("48213977"))

    // And the code appears in exactly one place: the claim body.
    var codeOccurrences = 0
    for request in await transport.recordedRequests {
        let text = String(decoding: request.body ?? Data(), as: UTF8.self)
        codeOccurrences += text.components(separatedBy: "48213977").count - 1
    }
    #expect(codeOccurrences == 1)
}

@Test("a 403 on the claim is a refused pairing offering a fresh code")
func pairingRefusalIsNotALockout() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(status: 403, json(#"{"error":"forbidden","message":"pairing code not recognized"}"#))
    )
    let sleeper = RecordingRelaySleeper()
    let client = pairingClient(transport: transport, sleeper: sleeper)

    let error = await #expect(throws: PairingError.self) {
        try await client.claim(unpinnedPayload(client), deviceName: "phone")
    }
    #expect(error?.guidance == .pairAgain)
    #expect(error?.readableReason == "pairing code not recognized")

    // SPEC §3.2 step 4: not a lockout, so a fresh code is the right action...
    #expect(error?.isLockout == false)
    #expect(error?.shouldOfferFreshCode == true)

    // ...and the credential is not retried into the ground.
    let attempts = await transport.recordedRequests.count
    let slept = await sleeper.sleptSeconds
    #expect(attempts == 1)
    #expect(slept.isEmpty)
}

@Test("a 429 on the claim is a lockout, not a bad code")
func pairingLockoutIsDistinguished() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(
            status: 429,
            json(#"{"error":"rate-limit","message":"too many attempts"}"#),
            headers: ["Retry-After": "120"]
        )
    )
    let sleeper = RecordingRelaySleeper()
    let client = PairingClient(transport: transport, sleeper: sleeper, retryPolicy: .none)

    let error = await #expect(throws: PairingError.self) {
        try await client.claim(unpinnedPayload(client), deviceName: "phone")
    }
    // SPEC §3.2 step 4: a lockout is a rate limit rather than a wrong code, so it
    // must not be presented as a bad code.
    #expect(error?.isLockout == true)
    #expect(error?.shouldOfferFreshCode == false)
    #expect(error?.guidance == .backOff(seconds: 120))
}

@Test("a 403 whose error code names a rate limit is presented as a lockout")
func pairingLockoutCarriedInA403() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(
        .json(status: 403, json(#"{"error":"too-many-requests","message":"address locked out"}"#))
    )
    let client = pairingClient(transport: transport)

    let error = await #expect(throws: PairingError.self) {
        try await client.claim(unpinnedPayload(client), deviceName: "phone")
    }
    #expect(error?.isLockout == true)
    #expect(error?.shouldOfferFreshCode == false)
}

@Test("a claim pin that disagrees with the payload pin is a hard error")
func pairingPinDisagreementIsFatal() async throws {
    // The captured payload and the captured claim carry different pins, which is
    // exactly the disagreement SPEC §3.2 step 6 forbids resolving silently.
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 200, try Fixtures.data(.pairingClaimResponse)))
    let client = pairingClient(transport: transport)

    let payload = try client.decodePayload(
        Fixtures.data(.pairingPayload),
        clock: beforeCaptureExpiry
    )
    #expect(payload.fingerprint != nil)

    let error = await #expect(throws: PairingError.self) {
        try await client.claim(payload, deviceName: "phone")
    }
    guard case .pinMismatch(let payloadPin, let claimPin) = try #require(error) else {
        Issue.record("expected a pin mismatch, got \(String(describing: error))")
        return
    }
    #expect(payloadPin == "3q2+7wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
    #expect(claimPin == "7pcXvn2Kosz4qWgFpUmIao9YQ05bXYTLbfP0IskaeN4=")
    #expect(error?.guidance == .certificateChangedRePair)
}

@Test("agreeing pins are accepted")
func pairingPinAgreementIsAccepted() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 200, try Fixtures.data(.pairingClaimResponse)))
    let client = pairingClient(transport: transport)

    var payload = try client.decodePayload(
        Fixtures.data(.pairingPayload),
        clock: beforeCaptureExpiry
    )
    // The same pin the relay publishes.
    payload.fingerprint = "7pcXvn2Kosz4qWgFpUmIao9YQ05bXYTLbfP0IskaeN4="

    let claim = try await client.claim(payload, deviceName: "phone")
    #expect(claim.fingerprint == "7pcXvn2Kosz4qWgFpUmIao9YQ05bXYTLbfP0IskaeN4=")
}

@Test("a claim body that is not the documented shape is refused")
func pairingClaimMalformed() async throws {
    let transport = StubRelayTransport()
    await transport.setDefault(.json(status: 200, json(#"{"deviceId":"x"}"#)))
    let client = pairingClient(transport: transport)

    let error = await #expect(throws: PairingError.self) {
        try await client.claim(unpinnedPayload(client), deviceName: "phone")
    }
    guard case .malformedPayload = try #require(error) else {
        Issue.record("expected a malformed claim refusal, got \(String(describing: error))")
        return
    }
}

// MARK: - 8. SPKI pinning (SPEC §6.3)

private struct SPKIVector {
    var spkiDer: Data
    var rawPublicKey: Data
    var expectedPin: String
    var wholeCertificatePin: String
}

private func loadSPKIVector() throws -> SPKIVector {
    let object = try Fixtures.object(.relaySPKIPin)
    func base64(_ key: String) throws -> Data {
        let text = try #require(object[key]?.stringValue, "fixture is missing \(key)")
        return try #require(Data(base64Encoded: text), "\(key) is not base64")
    }
    return SPKIVector(
        spkiDer: try base64("spkiDerBase64"),
        rawPublicKey: try base64("rawPublicKeyBase64"),
        expectedPin: try #require(object["expectedPin"]?.stringValue),
        wholeCertificatePin: try #require(object["competingPinOverWholeCertificate"]?.stringValue)
    )
}

@Test("the live relay's published pin is reproduced from its SPKI")
func spkiMatchesTheLiveRelayVector() throws {
    let vector = try loadSPKIVector()

    #expect(vector.spkiDer.count == SPKIPin.derP256SPKIByteCount)
    #expect(vector.rawPublicKey.count == SPKIPin.rawP256PublicKeyByteCount)

    // The pin the relay itself publishes, over the DER SubjectPublicKeyInfo.
    #expect(SPKIPin.pin(derSPKI: vector.spkiDer) == vector.expectedPin)
    #expect(vector.expectedPin == "7pcXvn2Kosz4qWgFpUmIao9YQ05bXYTLbfP0IskaeN4=")

    // The same pin, from the raw key the platform hands over.
    #expect(try SPKIPin.pin(rawP256PublicKey: vector.rawPublicKey) == vector.expectedPin)
    #expect(try SPKIPin.derSPKI(fromRawP256PublicKey: vector.rawPublicKey) == vector.spkiDer)

    #expect(SPKIPin.matches(pin: vector.expectedPin, derSPKI: vector.spkiDer))
    #expect(SPKIPin.matches(pin: vector.expectedPin, rawP256PublicKey: vector.rawPublicKey))
}

@Test("the pin is not a hash of the whole certificate")
func spkiIsNotAWholeCertificateHash() throws {
    // SPEC §6.3: "not a hash of the whole certificate". The fixture carries the
    // competing value so this is a real negative rather than a narrowed search.
    let vector = try loadSPKIVector()
    #expect(vector.wholeCertificatePin != vector.expectedPin)
    #expect(!SPKIPin.matches(pin: vector.expectedPin, pin: vector.wholeCertificatePin))
}

@Test("the wrapping prefix is exactly the P-256 SubjectPublicKeyInfo header")
func spkiDerWrapping() throws {
    let vector = try loadSPKIVector()

    // Fixed-length outer SEQUENCE of 89 bytes, AlgorithmIdentifier of 19, and a
    // 66-byte BIT STRING whose payload is the uncompressed point.
    #expect(Array(vector.spkiDer.prefix(2)) == [0x30, 0x59])
    #expect(Array(vector.spkiDer.prefix(26).suffix(3)) == [0x03, 0x42, 0x00])
    #expect(vector.spkiDer.suffix(65) == vector.rawPublicKey)
    #expect(vector.rawPublicKey.first == 0x04)

    let wrapped = try SPKIPin.derSPKI(fromRawP256PublicKey: vector.rawPublicKey)
    #expect(wrapped == vector.spkiDer)
}

@Test("a key that is not a P-256 uncompressed point is refused, not hashed")
func spkiRejectsNonP256Keys() throws {
    let vector = try loadSPKIVector()

    let tooShort = Data(vector.rawPublicKey.dropLast())
    #expect(throws: SPKIPin.WrappingError.unsupportedRawKeyLength(tooShort.count)) {
        _ = try SPKIPin.derSPKI(fromRawP256PublicKey: tooShort)
    }

    var compressed = vector.rawPublicKey
    compressed[0] = 0x02
    #expect(throws: SPKIPin.WrappingError.unsupportedPointFormat(0x02)) {
        _ = try SPKIPin.derSPKI(fromRawP256PublicKey: compressed)
    }

    // A key that cannot be wrapped answers "no" at the comparison site rather than
    // throwing: the question there is "does this still match", and it does not.
    #expect(!SPKIPin.matches(pin: vector.expectedPin, rawP256PublicKey: tooShort))
}

@Test("a wrong pin does not match")
func spkiMismatch() throws {
    let vector = try loadSPKIVector()
    let other = Data(repeating: 0x11, count: 32).base64EncodedString()
    #expect(!SPKIPin.matches(pin: other, derSPKI: vector.spkiDer))
    #expect(!SPKIPin.matches(pin: "not base64 at all", pin: vector.expectedPin))
    #expect(SPKIPin.matches(pin: vector.expectedPin, pin: vector.expectedPin))
}

// MARK: - 9. The doubles themselves

@Test("the stub transport refuses an unscripted request rather than reaching the network")
func stubHasNoDefaultNetwork() async throws {
    let transport = StubRelayTransport()
    let client = makeRPCClient(transport: transport)

    let error = await #expect(throws: DshRPCError.self) {
        try await client.callVoid("session/list", args: RPCEmptyRequest())
    }
    // An unscripted stub is a test bug, and it must surface as a failure rather
    // than as a real request.
    #expect(error?.guidance == .preserveDraftAndReconnect)

    let attempts = await transport.recordedRequests.count
    #expect(attempts == 1)
}

@Test("the stub records control frames in order")
func stubRecordsSends() async throws {
    let socket = StubRelaySocket()
    try await socket.send(text: "one")
    try await socket.send(text: "two")

    let sends = await socket.sentTexts
    #expect(sends == ["one", "two"])

    await socket.close()
    let closes = await socket.closeCount
    #expect(closes == 1)
}

@Test("the recording sleeper accumulates what it was asked to wait")
func sleeperRecords() async throws {
    let sleeper = RecordingRelaySleeper()
    try await sleeper.sleep(seconds: 1)
    try await sleeper.sleep(seconds: 2.5)

    let slept = await sleeper.sleptSeconds
    let total = await sleeper.totalSleptSeconds
    #expect(slept == [1, 2.5])
    #expect(total == 3.5)
}
