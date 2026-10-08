import Foundation

/// The client-to-server control frames on `/api/remote.mux` (SPEC §6.4).
///
/// Serialised from an explicit ``JSONValue`` rather than through `Codable`
/// synthesis, because the wire keys are the contract and a synthesised encoder
/// would happily add a `null` or reorder a union member. SPEC §6.7 makes the same
/// point for the event result: the host validates the body as exactly these keys.
public enum MuxControlFrame: Sendable, Hashable {
    /// ```json
    /// {"type":"open","streamId":"1","endpoint":"$events","payload":{"args":{}}}
    /// ```
    case open(streamId: String, endpoint: String, args: JSONValue)
    /// `{"type":"cancel","streamId":"1"}`
    case cancel(streamId: String)

    public var jsonValue: JSONValue {
        switch self {
        case .open(let streamId, let endpoint, let args):
            .object([
                "type": .string("open"),
                "streamId": .string(streamId),
                "endpoint": .string(endpoint),
                "payload": .object(["args": args]),
            ])
        case .cancel(let streamId):
            .object([
                "type": .string("cancel"),
                "streamId": .string(streamId),
            ])
        }
    }

    /// The frame as it appears on the wire.
    public func text() throws -> String {
        String(decoding: try JSONEncoder().encode(jsonValue), as: UTF8.self)
    }
}

/// One item from a logical mux stream: the frame, plus the stream it belongs to.
///
/// The stream ID is carried beside the frame rather than read out of it, because
/// ``MuxFrame/streamId`` is optional on the wire — an `end` or `error` frame's
/// shape is uncaptured (SPEC §6.4) — and a consumer should never have to
/// re-derive which subscription it is reading from.
public struct MuxStreamItem: Sendable, Hashable {
    public var streamId: String
    public var frame: MuxFrame

    public init(streamId: String, frame: MuxFrame) {
        self.streamId = streamId
        self.frame = frame
    }
}

/// Why a logical stream stopped without a normal end frame.
public enum MuxStreamError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The socket failed. Every open stream fails with this (SPEC §6.9
    /// "Offline/transport interruption"): a multiplexed socket has no per-stream
    /// reconnect, so the caller reconnects and re-establishes baselines.
    ///
    /// Carries the transport error rather than a message: the difference between
    /// a dropped connection and a TLS pin mismatch decides whether the caller may
    /// retry at all (SPEC §6.4), and a string cannot carry that honestly.
    case socketFailed(RelayTransportError)
    /// A frame arrived that is not a `MuxFrame` at all — not JSON, not an object,
    /// or with a non-string `type`. SPEC §6.9 "Malformed response": protocol
    /// incompatibility rather than a crash.
    case protocolIncompatible(reason: String)
    /// ``MuxClient/close()`` was called.
    case clientClosed
    /// The requested stream ID is already registered. Opening it again would make
    /// two consumers race for one stream's frames, which is exactly the
    /// "late frames from a cancelled stream" hazard in the other direction.
    case streamIdInUse(String)

    public var description: String {
        switch self {
        case .socketFailed(let error): "mux socket failed: \(error.safeDescription)"
        case .protocolIncompatible(let reason): "mux protocol incompatibility: \(reason)"
        case .clientClosed: "mux client closed"
        case .streamIdInUse(let streamId): "mux stream \(streamId) is already open"
        }
    }
}

/// The multiplexed stream client (deliverable 4).
///
/// One socket, many logical streams. SPEC §4: "Use one active host connection, one
/// `$events` stream, one workspace stream, and one session-control stream. Open a
/// `session/follow` stream only for the selected conversation. Changing
/// conversations cancels the old follow stream and prevents late frames from
/// mutating the new conversation."
///
/// The leak rule that sentence implies is enforced here, in one place: a frame is
/// delivered only to the subscription that is registered for its stream ID *at the
/// moment it arrives*. Frames for a cancelled stream are dropped, never buffered
/// for a later subscriber — otherwise reopening `session/follow` on the same ID
/// would replay the previous conversation's tail into the new one.
///
/// `actor` rather than a lock: the socket, the receive loop, and the subscription
/// table are one piece of mutable state, and every entry point that touches them
/// is asynchronous.
public actor MuxClient {
    /// The socket path (SPEC §6.4).
    public static let socketPath = "/api/remote.mux"

    private let baseURL: URL
    private let authorization: RelayAuthorization
    private let transport: any RelayTransport
    private let decoder: JSONDecoder

    private var socket: (any RelaySocket)?
    private var receiveLoop: Task<Void, Never>?
    private var subscriptions: [String: Subscription] = [:]
    private var nextStreamNumber = 0
    private var isClosed = false

    private struct Subscription {
        /// Identifies one registration of a stream ID. A cancelled subscription's
        /// termination handler must not be able to tear down a *newer*
        /// subscription that reuses the same ID, so every removal is guarded by
        /// this token.
        var token: UInt64
        var continuation: AsyncThrowingStream<MuxStreamItem, any Error>.Continuation
    }

    private var nextToken: UInt64 = 0

    public init(
        baseURL: URL,
        authorization: RelayAuthorization,
        transport: any RelayTransport,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.baseURL = baseURL
        self.authorization = authorization
        self.transport = transport
        self.decoder = decoder
    }

    deinit {
        receiveLoop?.cancel()
    }

    // MARK: - Streams

    /// Opens a logical stream and returns its frame sequence.
    ///
    /// The `open` control frame is sent before this returns, so a caller that has
    /// awaited `open` knows the request is on the wire. Frames that arrive before
    /// the caller starts iterating are buffered by the returned sequence.
    ///
    /// - Parameters:
    ///   - streamId: An explicit ID, or `nil` to take the next one. SPEC §6.4's
    ///     example uses `"1"`; the ID is an opaque client-chosen string (SPEC §5).
    ///   - endpoint: The logical endpoint, e.g. `$events` or `session/follow`.
    ///   - args: The endpoint's arguments, sent verbatim as `payload.args`.
    public func open(
        streamId requestedStreamId: String? = nil,
        endpoint: String,
        args: JSONValue = .object([:])
    ) async throws -> AsyncThrowingStream<MuxStreamItem, any Error> {
        guard !isClosed else { throw MuxStreamError.clientClosed }

        let streamId: String
        if let requestedStreamId {
            guard subscriptions[requestedStreamId] == nil else {
                throw MuxStreamError.streamIdInUse(requestedStreamId)
            }
            streamId = requestedStreamId
        } else {
            nextStreamNumber += 1
            streamId = String(nextStreamNumber)
        }

        let liveSocket = try await ensureSocket()

        nextToken += 1
        let token = nextToken
        let (stream, continuation) = AsyncThrowingStream<MuxStreamItem, any Error>.makeStream()
        subscriptions[streamId] = Subscription(token: token, continuation: continuation)

        // A consumer that stops iterating — including because its task was
        // cancelled — must release the stream, and must not be able to release a
        // newer one.
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(streamId: streamId, token: token) }
        }

        do {
            try await liveSocket.send(
                text: try MuxControlFrame.open(streamId: streamId, endpoint: endpoint, args: args).text()
            )
        } catch {
            subscriptions.removeValue(forKey: streamId)
            continuation.finish()
            throw MuxStreamError.socketFailed(RelayTransportError.classify(error))
        }

        return stream
    }

    /// Cancels one logical stream, leaving every other stream untouched.
    ///
    /// Sends SPEC §6.4's `{"type":"cancel","streamId":…}` and finishes that
    /// stream's sequence. Frames already in flight for it are dropped (see the
    /// type's note on the leak rule).
    public func cancel(streamId: String) async {
        guard let subscription = subscriptions.removeValue(forKey: streamId) else { return }
        subscription.continuation.finish()
        await sendCancelFrame(streamId: streamId)
    }

    /// Cancels every stream and closes the socket. The client is not reusable
    /// afterwards; reconnecting is a new ``MuxClient``, which is how SPEC §6.5's
    /// "Reconnect creates a new generation and replaces baselines" is expressed.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        receiveLoop?.cancel()
        receiveLoop = nil

        let openSubscriptions = subscriptions
        subscriptions.removeAll()
        for subscription in openSubscriptions.values {
            subscription.continuation.finish()
        }

        if let socket {
            self.socket = nil
            await socket.close()
        }
    }

    /// The stream IDs currently registered, sorted. Diagnostics and tests.
    public var openStreamIds: [String] {
        subscriptions.keys.sorted()
    }

    /// Whether a socket has been opened and not yet failed or closed.
    public var isConnected: Bool {
        socket != nil
    }

    // MARK: - Socket

    private func ensureSocket() async throws -> any RelaySocket {
        if let socket { return socket }
        let url = try RelayURL.resolve(Self.socketPath, against: baseURL)
        let request = RelayHTTPRequest(
            url: url,
            method: "GET",
            // SPEC §6.2: the WebSocket upgrade carries the bearer token too, and
            // the relay answers 403 without one (SPEC §12).
            headers: RelayHTTPRequest.authorizationHeader(authorization)
        )
        let opened: any RelaySocket
        do {
            opened = try await transport.openSocket(request)
        } catch {
            throw classify(error)
        }
        socket = opened
        startReceiveLoop(on: opened)
        return opened
    }

    private func startReceiveLoop(on socket: any RelaySocket) {
        receiveLoop?.cancel()
        // An unstructured task, deliberately: the socket must keep being drained
        // even when no consumer is currently awaiting its stream, because the
        // frames that arrive in that window belong to *other* streams.
        receiveLoop = Task {
            do {
                while true {
                    let message = try await socket.receive()
                    self.deliver(message)
                }
            } catch {
                self.failAllStreams(self.classify(error))
            }
        }
    }

    private func deliver(_ message: RelaySocketMessage) {
        let data: Data
        switch message {
        case .text(let text): data = Data(text.utf8)
        case .binary(let bytes): data = bytes
        }

        guard let frame = try? decoder.decode(MuxFrame.self, from: data) else {
            // A frame that is not a MuxFrame means the framing contract is gone;
            // guessing past it would silently corrupt every stream.
            failAllStreams(
                .protocolIncompatible(reason: "an inbound frame did not decode as a mux envelope")
            )
            return
        }
        route(frame)
    }

    private func route(_ frame: MuxFrame) {
        switch frame.type {
        case .item:
            // An item without a stream ID belongs to no logical stream and cannot
            // be delivered anywhere.
            guard let streamId = frame.streamId else { return }
            publish(frame, to: streamId)

        case .end, .error:
            // `end` and `error` are scoped by stream ID (SPEC §6.4). A frame that
            // carries none is treated as covering every open stream: leaving them
            // to hang would be worse than an over-broad end, and the alternative
            // reading — drop it — has no way to ever terminate.
            //
            // unverified: neither kind was captured, so whether the host always
            // sends a stream ID with them is unknown.
            let targets = frame.streamId.map { [$0] } ?? subscriptions.keys.sorted()
            for streamId in targets {
                publish(frame, to: streamId)
                finish(streamId)
            }

        case .unknown:
            guard let streamId = frame.streamId else { return }
            publish(frame, to: streamId)
        }
    }

    private func publish(_ frame: MuxFrame, to streamId: String) {
        // The leak guard. An unregistered stream ID is dropped, never buffered.
        guard let subscription = subscriptions[streamId] else { return }
        subscription.continuation.yield(MuxStreamItem(streamId: streamId, frame: frame))
    }

    private func finish(_ streamId: String) {
        guard let subscription = subscriptions.removeValue(forKey: streamId) else { return }
        subscription.continuation.finish()
    }

    private func failAllStreams(_ error: MuxStreamError) {
        receiveLoop = nil
        socket = nil
        let openSubscriptions = subscriptions
        subscriptions.removeAll()
        for subscription in openSubscriptions.values {
            subscription.continuation.finish(throwing: error)
        }
    }

    private func sendCancelFrame(streamId: String) async {
        guard let socket else { return }
        // Best effort: the caller has already been told the stream is over, and a
        // failed cancel only means the host keeps sending frames the leak guard
        // now drops.
        try? await socket.send(text: MuxControlFrame.cancel(streamId: streamId).text())
    }

    /// Removes a subscription when its consumer stops consuming.
    private func unsubscribe(streamId: String, token: UInt64) async {
        // The token guard: a subscription that has been superseded by a newer one
        // on the same stream ID must not tear the newer one down.
        guard let subscription = subscriptions[streamId], subscription.token == token else { return }
        subscriptions.removeValue(forKey: streamId)
        subscription.continuation.finish()
        await sendCancelFrame(streamId: streamId)
    }

    private func classify(_ error: any Error) -> MuxStreamError {
        if let error = error as? MuxStreamError { return error }
        return .socketFailed(RelayTransportError.classify(error))
    }
}
