import Foundation

// In-memory doubles for the transport seam (deliverable 1: "a `URLSession`
// implementation and an in-memory stub used by tests"). They live in the library
// rather than the test target on purpose: the layer above them is the thing under
// test, and a double that only the tests can see invites a second, divergent
// double the moment a caller wants one.

/// A transport that answers from a script, records what it was asked, and hands
/// out scripted sockets.
///
/// Reached off the network in every test, so the whole Network layer is exercised
/// offline (SPEC §2, §9). Nothing here opens a socket or creates a `URLSession`.
public actor StubRelayTransport: RelayTransport {
    /// One scripted HTTP answer.
    public enum Stub: Sendable {
        case response(RelayHTTPResponse)
        case failure(RelayTransportError)

        public static func json(
            status: Int,
            _ body: Data,
            headers: [String: String] = [:]
        ) -> Stub {
            .response(RelayHTTPResponse(status: status, headers: headers, body: body))
        }
    }

    private var queuedResponses: [Stub]
    private var responsesByPath: [String: Stub]
    private var defaultStub: Stub?
    private var cannedSockets: [StubRelaySocket]

    /// Every request this transport was asked to perform, in order.
    public private(set) var recordedRequests: [RelayHTTPRequest] = []
    /// Every socket this transport handed out, in order.
    public private(set) var openedSocketRequests: [RelayHTTPRequest] = []

    /// - Parameters:
    ///   - responses: Answers returned in order, one per `send(_:)`, regardless of
    ///     the request. The escape hatch for a retry test.
    ///   - responsesByPath: Answers keyed by `URL.path`, for a script that spans
    ///     several endpoints.
    ///   - sockets: Sockets handed out in order by `openSocket(_:)`.
    public init(
        responses: [Stub] = [],
        responsesByPath: [String: Stub] = [:],
        sockets: [StubRelaySocket] = []
    ) {
        self.queuedResponses = responses
        self.responsesByPath = responsesByPath
        self.cannedSockets = sockets
    }

    public func send(_ request: RelayHTTPRequest) async throws -> RelayHTTPResponse {
        recordedRequests.append(request)

        let stub: Stub?
        if !queuedResponses.isEmpty {
            stub = queuedResponses.removeFirst()
        } else if let path = responsesByPath[request.url.path] {
            stub = path
        } else {
            stub = defaultStub
        }

        guard let stub else {
            throw RelayTransportError.other("StubRelayTransport has no scripted answer for \(request.url.path)")
        }

        switch stub {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }

    public func openSocket(_ request: RelayHTTPRequest) async throws -> any RelaySocket {
        openedSocketRequests.append(request)
        guard !cannedSockets.isEmpty else {
            throw RelayTransportError.other("StubRelayTransport has no scripted socket")
        }
        return cannedSockets.removeFirst()
    }

    /// Answers any request that has no queued or path-specific script. Set this
    /// instead of enumerating paths when the test does not care which URL is hit.
    public func setDefault(_ stub: Stub) {
        defaultStub = stub
    }

    /// Appends another scripted answer, for a test that extends its script after
    /// the systems under test have already started.
    public func enqueue(_ stub: Stub) {
        queuedResponses.append(stub)
    }

    /// Appends another scripted socket.
    public func enqueue(socket: StubRelaySocket) {
        cannedSockets.append(socket)
    }

    /// The `Authorization` header of the n-th recorded request (0-based).
    public func authorizationHeader(at index: Int) -> String? {
        recordedRequests.indices.contains(index)
            ? recordedRequests[index].header("Authorization")
            : nil
    }
}

/// A socket whose inbound frames the test writes and whose outbound text the test
/// reads back.
///
/// Inbound messages are buffered until the reader asks for them, so a test can
/// push frames before the receive loop that will consume them has started — which
/// is the common case, since ``MuxClient`` opens the socket and starts reading
/// only once its actor gets a turn.
public actor StubRelaySocket: RelaySocket {
    private var pending: [RelaySocketMessage] = []
    private var waiter: CheckedContinuation<RelaySocketMessage, any Error>?
    private var terminalError: (any Error)?
    private var isClosed = false

    /// Every text frame this socket was asked to send, in order.
    public private(set) var sentTexts: [String] = []
    /// How many times ``close()`` was called.
    public private(set) var closeCount = 0

    public init() {}

    // MARK: RelaySocket

    public func send(text: String) async throws {
        if isClosed {
            throw RelayTransportError.offline("socket is closed")
        }
        sentTexts.append(text)
    }

    public func receive() async throws -> RelaySocketMessage {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        if let terminalError {
            throw terminalError
        }
        return try await withCheckedThrowingContinuation { continuation in
            // One reader at a time, like a real socket. A second concurrent
            // `receive()` would be a bug in the caller, not something to paper
            // over.
            precondition(waiter == nil, "StubRelaySocket.receive() called re-entrantly")
            waiter = continuation
        }
    }

    public func close() async {
        closeCount += 1
        isClosed = true
        resumeWaiter(throwing: RelayTransportError.offline("socket closed"))
    }

    // MARK: Test control

    /// Delivers one inbound message to the reader.
    public func push(_ message: RelaySocketMessage) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            pending.append(message)
        }
    }

    /// Delivers one inbound text frame.
    public func push(text: String) {
        push(.text(text))
    }

    /// Delivers a JSON object as a text frame.
    public func push(json: JSONValue) throws {
        push(.text(String(decoding: try JSONEncoder().encode(json), as: UTF8.self)))
    }

    /// Ends the session: the next `receive()` throws, as a real dropped socket
    /// does. Distinct from ``finish()``, which is a clean end of stream and still
    /// throws on the wire — there is no in-band "closed" message in the mux
    /// protocol, so both look like a throw to ``MuxClient``.
    public func fail(with error: RelayTransportError = .offline("socket closed by peer")) {
        terminalError = error
        resumeWaiter(throwing: error)
    }

    /// Ends the session cleanly, as far as the transport is concerned.
    public func finish() {
        fail(with: .offline("socket closed by peer"))
    }

    private func resumeWaiter(throwing error: any Error) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(throwing: error)
    }
}

/// A sleeper that returns immediately and records what it was asked to wait.
///
/// SPEC §6.9 requires honouring `Retry-After`; a test cannot wait 60 seconds, and
/// asserting *that the app waited 60* is the actual requirement.
public actor RecordingRelaySleeper: RelaySleeper {
    /// Every requested delay, in seconds, in order.
    public private(set) var sleptSeconds: [Double] = []
    /// When true, the next sleep throws, to prove an interrupted backoff does not
    /// swallow the failure.
    private var shouldThrow = false

    public init() {}

    public func sleep(seconds: Double) async throws {
        sleptSeconds.append(seconds)
        if shouldThrow {
            shouldThrow = false
            throw CancellationError()
        }
    }

    public func failNextSleep() {
        shouldThrow = true
    }

    public var totalSleptSeconds: Double {
        sleptSeconds.reduce(0, +)
    }
}
