import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Security)
import Security
#endif

// The one seam between this layer and the network. Everything above it — RPC,
// binary upload, the event result, pairing, the multiplexed socket — is written
// against ``RelayTransport`` and ``RelaySocket``, so the whole layer is exercised
// offline by ``StubRelayTransport`` (SPEC §2 "Network: URLSession HTTP and
// URLSessionWebSocketTask", SPEC §9 "Add focused tests around protocol/state
// boundaries").
//
// Deliberately narrow: one HTTP exchange, one WebSocket session, cancellation.
// No URL builder, no credential handling, no retry — those are policy and belong
// above the seam where a stub can script them.

// MARK: - One HTTP exchange

/// A single request/response exchange, independent of what performs it.
///
/// Field names are transport-shaped rather than API-shaped: this layer knows
/// nothing about relay paths, bearer tokens, or RPC envelopes.
public struct RelayHTTPRequest: Sendable, Hashable {
    public var url: URL
    /// Upper-case HTTP verb, e.g. `GET`, `POST`.
    public var method: String
    /// Header names as supplied. Lookup is case-insensitive through
    /// ``header(_:)``, because HTTP header names are.
    public var headers: [String: String]
    /// An in-memory body. Mutually exclusive with ``bodyFile``.
    public var body: Data?
    /// A body to stream from disk, for the one request that can be large.
    ///
    /// SPEC §3.6 / §6.8 asks for a file upload that does not force the file into
    /// memory. A `Data` body cannot do that: the bytes are read once to build the
    /// request and typically copied again by the networking layer, so a large file
    /// costs the app a multiple of its size before a byte leaves the phone.
    ///
    /// Filled through ``init(url:method:headers:bodyFile:)``, which is the only
    /// supported way to set it. A second initializer rather than one field of an
    /// enum, so that every existing in-memory call site keeps compiling untouched.
    /// Exactly one of ``body`` and ``bodyFile`` is set; nothing enforces that at
    /// the type level, which is the price of not rewriting fourteen call sites for
    /// something only uploads need.
    public var bodyFile: URL?

    public init(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.bodyFile = nil
    }

    /// A request whose body is streamed from `bodyFile` rather than held in memory.
    public init(url: URL, method: String, headers: [String: String] = [:], bodyFile: URL) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = nil
        self.bodyFile = bodyFile
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }

    /// Convenience for the one header every relay request carries (SPEC §6.2:
    /// "Every relay request, including WebSocket upgrade and binary upload,
    /// carries `Authorization: Bearer <device token>`").
    public static func authorizationHeader(_ authorization: RelayAuthorization) -> [String: String] {
        guard let value = authorization.headerValue else { return [:] }
        return ["Authorization": value]
    }
}

/// A single response, with the body already fully read.
///
/// The body is `Data` rather than a stream because every response this client
/// reads is a small JSON object — including the bare `{ok,value}` upload body
/// (SPEC §6.8). The asymmetry with requests is deliberate: a request body can be
/// an arbitrary file, and ``RelayHTTPRequest`` carries ``RelayHTTPRequest/bodyFile``
/// for exactly that case.
public struct RelayHTTPResponse: Sendable, Hashable {
    public var status: Int
    /// Header names as received; ``header(_:)`` is case-insensitive so a caller
    /// can ask for `retry-after` without knowing the peer's casing.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

// MARK: - One WebSocket session

/// One inbound WebSocket message.
public enum RelaySocketMessage: Sendable, Hashable {
    case text(String)
    case binary(Data)
}

/// One open WebSocket session.
///
/// Deliberately not `AsyncSequence`: a protocol requirement that is a sequence
/// would force every implementation to hand out a fresh iterator and make
/// cancellation semantics part of the type. `receive()` is a single awaited
/// step, which is all ``MuxClient`` needs.
///
/// `receive()` throws to report a closed or failed socket. It must not return a
/// sentinel message for closure, because the difference between "the peer said
/// end" and "the socket died" decides whether SPEC §6.9 wants a reconnect or a
/// protocol-incompatibility message.
public protocol RelaySocket: Sendable {
    /// Sends a text frame. JSON only reaches the mux socket as text (SPEC §6.4).
    func send(text: String) async throws

    /// Awaits the next inbound message.
    func receive() async throws -> RelaySocketMessage

    /// Closes the session. Idempotent and non-throwing: it is called from
    /// cancellation paths where there is nobody left to report a failure to.
    func close() async
}

// MARK: - The transport itself

/// One HTTP exchange and one WebSocket session, abstracted (deliverable 1).
///
/// The two methods are exactly what the relay contract needs and nothing more:
/// SPEC §6.2's unary POST, SPEC §6.8's raw-byte POST, SPEC §6.3's pairing claim,
/// and SPEC §6.4's `/api/remote.mux` upgrade all reduce to ``send(_:)``, and the
/// multiplexed socket to ``openSocket(_:)``.
public protocol RelayTransport: Sendable {
    func send(_ request: RelayHTTPRequest) async throws -> RelayHTTPResponse

    /// Performs the WebSocket upgrade and returns the live session.
    ///
    /// The returned socket is owned by the caller: ``RelaySocket/close()`` is the
    /// only way to release it, and nothing here reopens it.
    func openSocket(_ request: RelayHTTPRequest) async throws -> any RelaySocket
}

// MARK: - Transport failures

/// Connection failures, including a refused WebSocket HTTP upgrade.
///
/// Separated from ``DshRPCError`` because these are properties of the connection
/// rather than of an exchange, and because the URLSession implementation is the
/// only thing that can produce them.
public enum RelayTransportError: Error, Sendable, Hashable {
    /// No usable network path, or the connection dropped mid-exchange. SPEC §6.9
    /// "Offline/transport interruption": preserve the draft, reconnect in the
    /// foreground.
    case offline(String)
    /// The peer's certificate did not match the pin. SPEC §6.9 "TLS pin
    /// mismatch": stop, say the certificate changed, offer re-pair. It is a
    /// distinct case because it must never be retried and never fall back to
    /// normal CA validation (SPEC §3.2).
    case tlsPinMismatch(String)
    /// Preserve the upgrade response so authentication failures stop recovery
    /// and rate limits retain Retry-After instead of becoming generic offline.
    case webSocketRejected(DshRPCError)
    /// The exchange was cancelled by the caller's task. Not an error to show.
    case cancelled
    /// Anything else the platform reported.
    case other(String)

    /// Redacted description. `URL` strings can carry a launch token (SPEC §12),
    /// so a transport error is never rendered verbatim into diagnostics without
    /// passing through here first.
    public var safeDescription: String {
        switch self {
        case .offline(let detail): "transport offline: \(detail)"
        case .tlsPinMismatch(let detail): "TLS pin mismatch: \(detail)"
        case .webSocketRejected(let error): "WebSocket upgrade refused: \(error.readableReason ?? String(describing: error))"
        case .cancelled: "transport cancelled"
        case .other(let detail): "transport failure: \(detail)"
        }
    }

    /// Classifies a platform error. `URLError` codes carry the distinction the
    /// SPEC §6.9 table needs; anything else is ``other(_:)``.
    public static func classify(_ error: any Error) -> RelayTransportError {
        if let error = error as? RelayTransportError { return error }
        if error is CancellationError { return .cancelled }
        let urlError = error as? URLError
        if let urlError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .timedOut, .dnsLookupFailed, .dataNotAllowed,
                 .internationalRoamingOff, .secureConnectionFailed:
                return .offline(urlError.code.rawValue.description)
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected, .clientCertificateRequired:
                return .tlsPinMismatch(urlError.code.rawValue.description)
            default:
                return .other("URLError \(urlError.code.rawValue)")
            }
        }
        return .other(String(describing: type(of: error)))
    }

    static func webSocketFailure(_ error: any Error, response: HTTPURLResponse?) -> RelayTransportError {
        guard let response, response.statusCode != 101 else { return classify(error) }
        let failure: DshRPCError
        switch response.statusCode {
        case 401:
            failure = .relayedAuthenticationFailure(relayError: nil, status: 401)
        case 403:
            failure = .credentialRejected(relayError: nil, status: 403)
        case 429:
            let delay = HTTPRetryAfter.seconds(from: response.value(forHTTPHeaderField: "Retry-After"), now: Date())
                ?? RPCFailureRetryPolicy.default.defaultRetryAfterSeconds
            failure = .rateLimited(retryAfterSeconds: delay, attempts: 1)
        case 502:
            failure = .harnessUnavailable(attempts: 1)
        default:
            failure = .unexpectedStatus(status: response.statusCode, endpoint: "remote.mux")
        }
        return .webSocketRejected(failure)
    }
}

// MARK: - Authorization

/// The relay credential as it appears on the wire (SPEC §6.3).
///
/// An enum rather than a bare `String?` so an unpaired client cannot be
/// accidentally represented as `"Bearer "` with an empty token.
public enum RelayAuthorization: Sendable, Hashable {
    case bearer(String)
    /// No credential. Only a loopback operator connection is served without one.
    case none

    public var headerValue: String? {
        switch self {
        case .bearer(let token): "Bearer \(token)"
        case .none: nil
        }
    }
}

// MARK: - Sleeping

/// Where a backoff waits. SPEC §6.9 requires honouring `Retry-After`; tests
/// cannot wait 60 seconds, so the wait is a dependency like any other.
public protocol RelaySleeper: Sendable {
    func sleep(seconds: Double) async throws
}

/// The real one.
public struct TaskRelaySleeper: RelaySleeper {
    public init() {}

    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - URLSession

/// Header carrying the pin of the certificate the caller already trusts.
///
/// `URLSession` has no public API for "trust exactly this key", so pinning is
/// enforced at the `URLSessionDelegate` challenge instead. The URLSession
/// transport is therefore not the thing that *decides* the pin — that decision
/// belongs with the saved host — but it must not silently succeed when a caller
/// has asked for a pin. ``URLSessionRelayTransport`` treats a mismatch as
/// ``RelayTransportError/tlsPinMismatch(_:)`` and never falls back to the system
/// trust store when a pin is configured (SPEC §3.2: "A supplied pin mismatch is
/// a hard error … it never silently falls back to normal CA validation").
public struct RelayPinningPolicy: Sendable, Hashable {
    /// Base64 SHA-256 of the DER SubjectPublicKeyInfo, as the relay publishes it
    /// (SPEC §6.3).
    public var expectedSPKIPin: String?
    /// Whether the platform must also validate the chain and hostname. SPEC §3.2:
    /// a payload without a fingerprint "must pass normal platform TLS and
    /// hostname validation". A self-signed relay with a pin cannot, so pinning
    /// and platform validation are separate switches.
    public var requiresPlatformTrust: Bool

    public init(expectedSPKIPin: String? = nil, requiresPlatformTrust: Bool = true) {
        self.expectedSPKIPin = expectedSPKIPin
        self.requiresPlatformTrust = requiresPlatformTrust
    }

    /// The policy for a relay that published a pin: the pin is the whole
    /// authority and the chain is not required.
    public static func pinned(_ pin: String) -> RelayPinningPolicy {
        RelayPinningPolicy(expectedSPKIPin: pin, requiresPlatformTrust: false)
    }

    public static let platformTrust = RelayPinningPolicy()

    var isPinned: Bool { expectedSPKIPin != nil }
}

#if canImport(Security)
/// What the challenge handler does with a server's trust (#68).
enum RelayTrustDecision: Equatable, Sendable {
    /// The pin matched, and it stands in for the chain.
    case acceptPinned
    /// The system checks the chain and the hostname (SPEC §3.2).
    case deferToPlatform
    case reject(RelayTrustRejection)
}

/// Why a server's trust was refused.
enum RelayTrustRejection: Equatable, Sendable {
    /// The trust carried no certificate.
    case noLeafCertificate
    /// The leaf key is not P-256, so no pin can be computed. This fails closed (SPEC §6.3).
    case unsupportedKey
    case pinMismatch
    /// There is no pin and no platform validation, so nothing vouches for the server.
    case noTrustAnchor
}

extension RelayPinningPolicy {
    /// Whether to trust the server behind `serverTrust`, without evaluating it.
    ///
    /// The order is the rule. A pin, when there is one, is the whole authority:
    /// it is checked, and a mismatch is a hard error that never falls back to
    /// the system trust store (SPEC §3.2: "A supplied pin mismatch is a hard
    /// error … it never silently falls back to normal CA validation"). Without a
    /// pin, the system checks the chain and the hostname (SPEC §3.2: a payload
    /// without a fingerprint "must pass normal platform TLS and hostname
    /// validation"). With neither, nothing vouches for the server, and it is
    /// refused (#68; it used to be accepted).
    ///
    /// A pin together with `requiresPlatformTrust` checks only the pin; whether
    /// that should mean both is #86.
    ///
    /// The pin is computed from the leaf's key, not from the certificate, and
    /// not from anything in the response (SPEC §3.2 step 3: "Never learn a pin
    /// from an unverified network response").
    func decide(serverTrust: SecTrust) -> RelayTrustDecision {
        guard let expected = expectedSPKIPin else {
            return requiresPlatformTrust ? .deferToPlatform : .reject(.noTrustAnchor)
        }
        guard let leaf = RelayServerKey.leafCertificate(of: serverTrust) else {
            return .reject(.noLeafCertificate)
        }
        guard let actual = RelayServerKey.spkiPin(of: leaf) else {
            return .reject(.unsupportedKey)
        }
        // A pinned self-signed relay cannot satisfy the platform chain; the pin
        // stands in for it.
        return SPKIPin.matches(pin: expected, pin: actual) ? .acceptPinned : .reject(.pinMismatch)
    }
}

extension RelayTrustDecision {
    /// What the challenge handler tells `URLSession`. Only ``acceptPinned``
    /// comes with a credential (`URLCredential(trust:)`); the delegate supplies it.
    var disposition: URLSession.AuthChallengeDisposition {
        switch self {
        case .acceptPinned: .useCredential
        case .deferToPlatform: .performDefaultHandling
        case .reject: .cancelAuthenticationChallenge
        }
    }
}

/// The leaf → key → pin steps the decision rests on (SPEC §6.3).
enum RelayServerKey {
    /// The server's own certificate: the first in the chain, never an issuer.
    static func leafCertificate(of trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }

    /// The certificate's public key as `SecKeyCopyExternalRepresentation` gives
    /// it. For P-256 that is the 65-byte uncompressed X9.63 point `04 || X || Y`
    /// that ``SPKIPin/derSPKI(fromRawP256PublicKey:)`` wraps. Observed through a
    /// real `SecTrust` in `TLSTrustDecisionTests` (#68): the stand-in over the
    /// relay's captured key gives 65 bytes that hash to the published pin, while
    /// a P-384 key gives 97 bytes and an RSA key 270 (PKCS#1).
    static func externalRepresentation(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        return SecKeyCopyExternalRepresentation(key, nil) as Data?
    }

    /// The certificate's SPKI pin, or `nil` when its key is not P-256. A key the
    /// pin cannot describe fails closed rather than being hashed in some other
    /// shape (SPEC §6.3).
    static func spkiPin(of certificate: SecCertificate) -> String? {
        guard let raw = externalRepresentation(of: certificate) else { return nil }
        return try? SPKIPin.pin(rawP256PublicKey: raw)
    }
}
#endif

/// The real transport (deliverable 1): `URLSession` for HTTP,
/// `URLSessionWebSocketTask` for the mux socket.
///
/// Redirects are refused outright. SPEC §6.2: "Do not forward credentials to
/// redirects or another origin. Do not follow API redirects in v1." A refusal
/// surfaces as the redirect response itself, which is then classified by status
/// like any other — never as a followed request.
public final class URLSessionRelayTransport: NSObject, RelayTransport, @unchecked Sendable {
    private let session: URLSession
    /// Sockets get their own session: see ``socketConfiguration(from:)``.
    private let socketSession: URLSession
    private let pinning: RelayPinningPolicy
    private let delegate: TransportDelegate

    /// - Parameters:
    ///   - configuration: Defaults to `.ephemeral` so nothing about a host is
    ///     cached on disk. SPEC §2 stores host metadata deliberately; a URL cache
    ///     is not part of that decision.
    ///   - pinning: Pin policy for challenges. See ``RelayPinningPolicy``.
    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        pinning: RelayPinningPolicy = .platformTrust
    ) {
        self.pinning = pinning
        self.delegate = TransportDelegate(pinning: pinning)
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        // A socket is not a request. `timeoutIntervalForRequest` bounds how long a task may go
        // without receiving anything, and for a `URLSessionWebSocketTask` that means silence —
        // so a client that sets a sensible read budget for unary calls (20 s, as this app does)
        // would tear down its own idle mux connection on that budget, and the coordinator would
        // reconnect forever while the connection looked healthy. A browser holds a WebSocket
        // open indefinitely, which is why the relay's own web interface does not show this.
        self.socketSession = URLSession(
            configuration: Self.socketConfiguration(from: configuration),
            delegate: delegate,
            delegateQueue: nil
        )
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
        socketSession.invalidateAndCancel()
    }

    /// The configuration a long-lived socket needs, given the one the caller uses for requests.
    ///
    /// Built field by field rather than by copying: `URLSessionConfiguration.copy()` returns an
    /// object that shares the caller's settings, so adjusting the timeouts on it changed the
    /// *request* session's budget too — a test caught that, which is the only reason it is not
    /// in production.
    ///
    /// Internal so the property can be asserted directly: a socket must not inherit a request
    /// timeout, however sensible that timeout is for a unary call.
    static func socketConfiguration(from configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let socket = URLSessionConfiguration.ephemeral
        socket.httpAdditionalHeaders = configuration.httpAdditionalHeaders
        socket.allowsCellularAccess = configuration.allowsCellularAccess
        socket.allowsExpensiveNetworkAccess = configuration.allowsExpensiveNetworkAccess
        socket.allowsConstrainedNetworkAccess = configuration.allowsConstrainedNetworkAccess
        socket.httpMaximumConnectionsPerHost = configuration.httpMaximumConnectionsPerHost
        socket.requestCachePolicy = configuration.requestCachePolicy
        // A day, and a week for the resource: long enough that neither can be what closed an
        // idle socket, which is the whole point of having a separate configuration.
        socket.timeoutIntervalForRequest = 24 * 60 * 60
        socket.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return socket
    }

    public func send(_ request: RelayHTTPRequest) async throws -> RelayHTTPResponse {
        let urlRequest = Self.urlRequest(from: request)
        do {
            // A file body is handed to URLSession as a file rather than read into
            // memory first. This is the whole point of `bodyFile`: the upload's cost
            // stops scaling with the file's size. Everything else takes the ordinary
            // in-memory path.
            let (data, response): (Data, URLResponse)
            if let bodyFile = request.bodyFile {
                (data, response) = try await session.upload(for: urlRequest, fromFile: bodyFile)
            } else {
                (data, response) = try await session.data(for: urlRequest)
            }
            guard let http = response as? HTTPURLResponse else {
                throw RelayTransportError.other("response was not HTTP")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key] = value
                }
            }
            return RelayHTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch {
            throw RelayTransportError.classify(error)
        }
    }

    public func openSocket(_ request: RelayHTTPRequest) async throws -> any RelaySocket {
        let task = socketSession.webSocketTask(with: Self.urlRequest(from: request))
        task.resume()
        return URLSessionRelaySocket(task: task)
    }

    /// Internal rather than private so the streaming contract below can be asserted:
    /// `httpBody` must stay nil when the body comes from a file.
    static func urlRequest(from request: RelayHTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        // Deliberately not `request.body` unconditionally: a file body is supplied to
        // the upload call itself, and setting `httpBody` here as well would send
        // nothing extra but would defeat the streaming.
        urlRequest.httpBody = request.bodyFile == nil ? request.body : nil
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        // `timeoutInterval` is left at the session default: SPEC §6.4's 10-second
        // budgets are connection budgets owned by the caller, not per-request
        // timeouts, and a unary RPC has no stated budget at all.
        return urlRequest
    }

    /// Shared challenge handling for HTTP and the WebSocket upgrade.
    ///
    /// A thin adapter: whether to trust the server is
    /// ``RelayPinningPolicy/decide(serverTrust:)``, which reads the pin from the
    /// server's key and never from the response (SPEC §3.2 step 3).
    private final class TransportDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let pinning: RelayPinningPolicy

        init(pinning: RelayPinningPolicy) {
            self.pinning = pinning
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // SPEC §6.2: no redirects, and never a credential to another origin.
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust
            else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            // The decision is ``RelayPinningPolicy/decide(serverTrust:)``, tested
            // offline (#68); this adapter only hands it to URLSession. The trust
            // is a credential only when the pin vouched for it.
            let decision = pinning.decide(serverTrust: trust)
            let credential = decision == .acceptPinned ? URLCredential(trust: trust) : nil
            completionHandler(decision.disposition, credential)
        }
    }
}

/// One `URLSessionWebSocketTask` behind ``RelaySocket``.
private final class URLSessionRelaySocket: RelaySocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw RelayTransportError.webSocketFailure(error, response: task.response as? HTTPURLResponse)
        }
    }

    func receive() async throws -> RelaySocketMessage {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default:
                throw RelayTransportError.other("unknown WebSocket message kind")
            }
        } catch {
            throw RelayTransportError.webSocketFailure(error, response: task.response as? HTTPURLResponse)
        }
    }

    func close() async {
        // `.goingAway` rather than `.normalClosure`: this side is leaving but the
        // host keeps running (SPEC §7: "Do not imply the harness stopped merely
        // because the phone is offline").
        task.cancel(with: .goingAway, reason: nil)
    }
}
