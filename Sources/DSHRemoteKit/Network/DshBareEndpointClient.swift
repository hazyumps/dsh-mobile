import Foundation

// The two endpoints the app needs that are not Typert and therefore not in
// `Protocol/endpoints.json` at all (SPEC §12: "Two endpoints the app needs are
// *not* Typert and so are absent by nature"). Neither can be driven through the
// generic RPC path: one answers a bare body rather than an envelope, and the
// other is gateway-internal with a hand-validated argument object.

// MARK: - $events/result outcome

/// The `outcome` object of SPEC §6.7's event result.
///
/// The host "validates the body as exactly these three keys and accepts exactly
/// three outcome shapes". The three shapes are modelled as three cases so the
/// encoder cannot produce a fourth:
///
/// | case | wire |
/// |---|---|
/// | ``next`` | `{"kind":"next"}` — no other key |
/// | ``result(_:)`` | `{"kind":"result"}` or `{"kind":"result","value":…}` |
/// | ``rejected(error:)`` | `{"kind":"rejected","error":…}` |
///
/// SPEC §6.7 is explicit that a rejection carrying a reason "must use the
/// `rejected` shape rather than smuggling it through `result`", which is the
/// reason ``rejected(error:)`` takes the error object and ``result(_:)`` does not
/// take a reason.
///
/// unverified: the `error` object's shape is not captured. It is projected to
/// JSON-safe fields by the harness, so it travels here as ``JSONValue`` rather
/// than as a guessed DTO.
public enum EventOutcome: Sendable, Hashable {
    /// "Skip this event and continue with the next one."
    case next
    /// A settled answer. The value is absent for a plain acknowledgement, the
    /// host's `"allowed-once"` / `"rejected"` string for an approval (SPEC §6.7),
    /// or `{"answers":[…]}` for a question.
    case result(JSONValue?)
    /// A refusal, with the host's reason.
    case rejected(error: JSONValue)

    /// The exact wire object.
    public var jsonValue: JSONValue {
        switch self {
        case .next:
            .object(["kind": .string("next")])
        case .result(let value):
            // The key is omitted rather than sent as null when there is no value:
            // SPEC §6.7 says the host accepts `{"kind":"result"}` *carrying* a
            // value or not, and an explicit null is a third shape nobody promised.
            value.map { .object(["kind": .string("result"), "value": $0]) }
                ?? .object(["kind": .string("result")])
        case .rejected(let error):
            .object(["kind": .string("rejected"), "error": error])
        }
    }
}

/// SPEC §6.7's event-result arguments: `clientId`, `eventId`, `outcome`, and
/// nothing else.
public struct EventResultRequest: Sendable, Hashable {
    /// The current readiness frame's server `clientId` (SPEC §6.4).
    public var clientId: String
    /// The event being answered. Opaque (SPEC §5).
    public var eventId: String
    public var outcome: EventOutcome

    public init(clientId: String, eventId: String, outcome: EventOutcome) {
        self.clientId = clientId
        self.eventId = eventId
        self.outcome = outcome
    }

    /// The `payload.args` object, with exactly the three keys the harness
    /// validates.
    public var args: JSONValue {
        .object([
            "clientId": .string(clientId),
            "eventId": .string(eventId),
            "outcome": outcome.jsonValue,
        ])
    }
}

// MARK: - uploadFileBinary

/// A successful `session/uploadFileBinary` body (SPEC §6.8).
///
/// The response is a **bare** `{ok, value}` rather than an RPC envelope, and its
/// HTTP status is 200 even when `ok` is false, so `ok` is the only success signal
/// that exists.
public struct FileUploadResult: Sendable, Hashable {
    /// The `value` object the host returned, verbatim.
    ///
    /// unverified: the shape of a successful upload's `value` is not captured — no
    /// fixture holds an upload response — so nothing here extracts a receipt ID
    /// from it. SPEC §6.8 says prompts cite "file receipt IDs"; which key carries
    /// one has to be read off a real capture or the installed harness before a
    /// typed accessor is added, and guessing a key list would be the guess SPEC §5
    /// forbids.
    public var value: JSONValue?

    public init(value: JSONValue? = nil) {
        self.value = value
    }
}

// MARK: - The client

/// The two endpoints that are not RPC-enveloped (deliverable 3).
public struct DshBareEndpointClient: Sendable {
    public let baseURL: URL
    public let authorization: RelayAuthorization
    public let transport: any RelayTransport

    private let exchange: RelayExchange
    private let makeRpcId: @Sendable () -> String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

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
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    // MARK: session/uploadFileBinary

    /// `POST /api/session/uploadFileBinary?sessionId=…&name=…` with
    /// `application/octet-stream` (SPEC §6.8).
    ///
    /// - Parameters:
    ///   - sessionId: The session the file belongs to. SPEC §3.6/A13 make receipts
    ///     session-scoped, so this is not optional.
    ///   - name: The file name the host should record. Encoded as a query value.
    ///   - bytes: The file's bytes. SPEC §3.6 caps this at 20 MiB as an *app*
    ///     limit; that is enforced by the caller, not here, so this method never
    ///     silently refuses a file the user chose.
    /// - Throws: ``DshRPCError``. A 404 surfaces as
    ///   ``DshRPCError/capabilityUnavailable(endpoint:)`` — the one status SPEC §6.8
    ///   permits to trigger the base64 `fileUploads/upload` fallback — and never as
    ///   a business refusal.
    public func uploadFileBinary(
        sessionId: String,
        name: String,
        bytes: Data
    ) async throws -> FileUploadResult {
        let path = "/api/session/uploadFileBinary"
        let url = try RelayURL.resolve(
            path,
            against: baseURL,
            queryItems: [
                URLQueryItem(name: "sessionId", value: sessionId),
                URLQueryItem(name: "name", value: name),
            ]
        )
        var headers = RelayHTTPRequest.authorizationHeader(authorization)
        headers["Content-Type"] = "application/octet-stream"
        let request = RelayHTTPRequest(url: url, method: "POST", headers: headers, body: bytes)

        let response = try await exchange.perform(request, endpoint: "session/uploadFileBinary")
        return try decodeBareBody(response.body, endpoint: "session/uploadFileBinary")
    }

    // MARK: $events/result

    /// The envelope for SPEC §6.7's event result, with `payload.args` exactly
    /// `{clientId, eventId, outcome}`.
    public func makeEventResultRequest(_ request: EventResultRequest) -> RPCRequest<JSONValue> {
        RPCRequest(rpcId: makeRpcId(), method: Self.eventResultMethod, args: request.args)
    }

    /// `POST /api/$events/result` (SPEC §6.7).
    ///
    /// Answers an approval or question. The endpoint is gateway-internal and
    /// therefore absent from `Protocol/endpoints.json`; the argument object is
    /// built by ``EventResultRequest/args`` rather than by a generated DTO.
    @discardableResult
    public func submitEventResult(
        _ request: EventResultRequest,
        retryPolicy: RPCFailureRetryPolicy? = nil
    ) async throws -> JSONValue? {
        let envelope = makeEventResultRequest(request)
        let url = try RelayURL.resolve(envelope.path, against: baseURL)
        var headers = RelayHTTPRequest.authorizationHeader(authorization)
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        let httpRequest = RelayHTTPRequest(
            url: url,
            method: "POST",
            headers: headers,
            body: try encoder.encode(envelope)
        )

        var usingExchange = exchange
        if let retryPolicy {
            usingExchange.retryPolicy = retryPolicy
        }
        let response = try await usingExchange.perform(httpRequest, endpoint: Self.eventResultMethod)

        // Same envelope and same typed-error rule as any other RPC; it only lacks
        // a modelled result type, and a result this endpoint returns has no
        // stated shape.
        return try DshRpcClient.decodeResponse(
            JSONValue.self,
            from: response.body,
            decoder: decoder
        ).result.value
    }

    /// The endpoint name on the wire. `$events/result`, not `events/result`.
    public static let eventResultMethod = "$events/result"

    /// The path on the wire. `$` is an RFC 3986 sub-delim and must not be escaped
    /// (SPEC §6.7).
    public static let eventResultPath = "/api/$events/result"

    // MARK: - Bare body decoding

    /// Decodes SPEC §6.8's bare `{ok, value}` / `{ok, error}` body.
    ///
    /// Failure is a *business* refusal, because the HTTP status was already 200 —
    /// SPEC §6.8: "the HTTP status is 200 even on failure". The `error` object is
    /// the same typed error the envelope carries (``RPCError``), since
    /// `Fixtures/forbidden-unpaired.json` shows the relay's own refusal body is a
    /// different shape and this one is described as the RPC error.
    func decodeBareBody(_ body: Data, endpoint: String) throws -> FileUploadResult {
        struct BareBody: Decodable {
            var ok: Bool
            var value: JSONValue?
            var error: RPCError?
        }

        guard !body.isEmpty else {
            throw DshRPCError.protocolIncompatible(reason: "empty body from \(endpoint)")
        }
        let decoded: BareBody
        do {
            decoded = try decoder.decode(BareBody.self, from: body)
        } catch {
            throw DshRPCError.protocolIncompatible(
                reason: "HTTP 200 body from \(endpoint) was not a bare {ok,…} object"
            )
        }
        guard decoded.ok else {
            throw DshRPCError.business(
                decoded.error ?? RPCError(
                    // unverified: no upload capture exists, so an `ok: false` with
                    // no `error` object has never been observed; this code is the
                    // client's own label for it.
                    code: "gateway/refused-without-error",
                    message: "the host refused \(endpoint) without an error body"
                )
            )
        }
        return FileUploadResult(value: decoded.value)
    }
}
