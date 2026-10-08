import Foundation

/// The unary RPC client (deliverable 2): SPEC §6.2's `POST /api/<method>`.
///
/// Two things this type deliberately does not do. It does not decide *what* to
/// send — argument shapes are per endpoint and live in the descriptor, and the
/// `_request` versus `request` distinction is the caller's to make (SPEC §6.2).
/// And it does not own a connection generation: SPEC §6.5 makes generations a
/// property of the socket, and a unary call is stateless enough that a
/// ``RPCFailureRetryPolicy`` is the only state policy it needs.
public struct DshRpcClient: Sendable {
    /// Relay origin, e.g. `https://192.0.2.10:3443`.
    public let baseURL: URL
    /// The device credential (SPEC §6.3).
    public let authorization: RelayAuthorization
    public let transport: any RelayTransport

    private let exchange: RelayExchange
    private let makeRpcId: @Sendable () -> String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter makeRpcId: The `rpcId` for each envelope. Injected so a test
    ///   can pin it, and so the app has one place to record what it sent without
    ///   reading it back out of a log. SPEC §6.6: an RPC ID is never the human
    ///   submission request ID.
    public init(
        baseURL: URL,
        authorization: RelayAuthorization,
        transport: any RelayTransport,
        sleeper: any RelaySleeper = TaskRelaySleeper(),
        clock: any EpochClock = SystemEpochClock(),
        retryPolicy: RPCFailureRetryPolicy = .default,
        makeRpcId: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.baseURL = baseURL
        self.authorization = authorization
        self.transport = transport
        self.exchange = RelayExchange(
            transport: transport,
            sleeper: sleeper,
            clock: clock,
            retryPolicy: retryPolicy
        )
        self.makeRpcId = makeRpcId
        let encoder = JSONEncoder()
        // Deterministic bytes: the harness does not care about key order, but a
        // fixture comparison and a redacted diagnostic both do.
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    // MARK: - Building the request

    /// The envelope SPEC §6.2 defines:
    /// ```json
    /// {"type":"client-request","rpcId":"<uuid>","method":"<method>","payload":{"args":{…}}}
    /// ```
    public func makeRequest<Args: Codable & Sendable>(_ method: String, args: Args) -> RPCRequest<Args> {
        RPCRequest(rpcId: makeRpcId(), method: method, args: args)
    }

    /// The HTTP exchange for an envelope: `POST /api/<method>`, JSON body, bearer
    /// header.
    public func makeHTTPRequest<Args: Codable & Sendable>(
        _ request: RPCRequest<Args>
    ) throws -> RelayHTTPRequest {
        let url = try RelayURL.resolve(request.path, against: baseURL)
        let body = try encoder.encode(request)
        var headers = RelayHTTPRequest.authorizationHeader(authorization)
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        return RelayHTTPRequest(url: url, method: "POST", headers: headers, body: body)
    }

    // MARK: - Calling

    /// Sends one unary RPC and returns the decoded response.
    ///
    /// Success is `result.ok == true`. A result with **no `value` key** is a
    /// success and decodes with `value == nil` — SPEC §6.2: "A result may also be
    /// `{"ok":true}` with no `value` key at all, which is what the harness emits
    /// for a void result: treat a missing `value` as success, not as a decode
    /// failure." ``callVoid(_:args:retryPolicy:)`` is the convenience for it.
    ///
    /// - Throws: ``DshRPCError`` for everything else, with ``DshRPCError/guidance``
    ///   carrying the SPEC §6.9 behaviour.
    @discardableResult
    public func call<Args: Codable & Sendable, Value: Codable & Sendable>(
        _ method: String,
        args: Args,
        returning _: Value.Type = Value.self,
        retryPolicy: RPCFailureRetryPolicy? = nil
    ) async throws -> RPCResponse<Value> {
        let response = try await perform(method: method, args: args, retryPolicy: retryPolicy)
        return try Self.decodeResponse(Value.self, from: response.body, decoder: decoder)
    }

    /// A call whose result the caller does not model.
    ///
    /// Modelled as `Value == JSONValue` rather than as a separate path, because
    /// the interesting case — `{"ok":true}` with no `value` — is exactly what a
    /// missing optional decodes to, and one code path is one place for that rule
    /// to be right.
    @discardableResult
    public func callVoid<Args: Codable & Sendable>(
        _ method: String,
        args: Args,
        retryPolicy: RPCFailureRetryPolicy? = nil
    ) async throws -> RPCResponse<JSONValue> {
        try await call(method, args: args, returning: JSONValue.self, retryPolicy: retryPolicy)
    }

    // MARK: - Internals

    private func perform<Args: Codable & Sendable>(
        method: String,
        args: Args,
        retryPolicy: RPCFailureRetryPolicy?
    ) async throws -> RelayHTTPResponse {
        let envelope = makeRequest(method, args: args)
        let request = try makeHTTPRequest(envelope)
        var usingExchange = exchange
        if let retryPolicy {
            usingExchange.retryPolicy = retryPolicy
        }
        return try await usingExchange.perform(request, endpoint: method)
    }

    /// Decodes an `HTTP 200` body into ``RPCResponse``, or refuses it as a
    /// protocol incompatibility (SPEC §6.9 "Malformed response").
    ///
    /// Two passes on purpose. The first reads the envelope with `value` as
    /// ``JSONValue``, which cannot fail on *any* JSON value, so a refusal whose
    /// `value` this build does not model still surfaces as the host's typed
    /// business error instead of as a decode failure. Only once `ok` is known to
    /// be true is the typed `Value` decoded.
    static func decodeResponse<Value: Codable & Sendable>(
        _ type: Value.Type,
        from body: Data,
        decoder: JSONDecoder
    ) throws -> RPCResponse<Value> {        guard !body.isEmpty else {
            throw DshRPCError.protocolIncompatible(reason: "empty response body on HTTP 200")
        }

        let probe: RPCResponse<JSONValue>
        do {
            probe = try decoder.decode(RPCResponse<JSONValue>.self, from: body)
        } catch {
            throw DshRPCError.protocolIncompatible(
                reason: "HTTP 200 body did not decode as an RPC response envelope"
            )
        }

        // A `client-request` coming back means the peer echoed our own request;
        // nothing useful can be read out of it. A `type` this build has no case
        // for is *not* rejected — RPCMessageType decodes unknown values on purpose
        // (SPEC §5), and the `result` object is the real discriminator.
        guard probe.type != .clientRequest else {
            throw DshRPCError.protocolIncompatible(
                reason: "response envelope carried type \"client-request\""
            )
        }

        guard probe.result.ok else {
            throw DshRPCError.business(
                probe.result.error ?? RPCError(
                    // unverified: no capture shows `ok: false` without an `error`
                    // object, so this code is this client's own label for a shape
                    // the host has never been observed to send.
                    code: "gateway/refused-without-error",
                    message: "the host refused the request without an error body"
                )
            )
        }

        do {
            return try decoder.decode(RPCResponse<Value>.self, from: body)
        } catch {
            throw DshRPCError.protocolIncompatible(
                reason: "the operation succeeded but its value did not match \(Value.self)"
            )
        }
    }
}
