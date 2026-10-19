import Foundation

// The state layer's first piece: "connected to a host, here are its sessions".
//
// It sits exactly where SPEC §4's diagram puts it — above `DshRpcClient` and
// `MuxClient`, below the stores — and it owns the one thing neither of those owns:
// *when* a host counts as usable. Neither primitive may claim that on its own.
// `MuxClient` knows a socket is open, and SPEC §6.4 is explicit that "The socket
// opening alone is not readiness"; `DshRpcClient` has no connection at all. So the
// readiness handshake, the two §6.4 budgets, and the mapping from a failure to the
// word the user sees all live here.

/// One host's connection, from `Connecting` to a usable `clientId`.
///
/// Owns exactly one ``MuxClient`` and one ``DshRpcClient`` for one origin (SPEC §4:
/// "Use one active host connection, one `$events` stream…"). An `actor` rather than a
/// `@MainActor` class, because nothing here is UI: SPEC §4 requires that "Network and
/// reducer work must not block the main actor", and an actor that hops to the main
/// actor for every frame would do exactly that.
///
/// ## What this type does not do
///
/// ``ForegroundConnection`` schedules automatic retries and foreground recovery.
/// This type does not reduce
/// conversation state (SPEC §6.5), page history, or store sessions — ``sessions()``
/// returns what the host just said, and the store that puts it on screen is not this.
public actor ConnectionCoordinator {
    // MARK: - Budgets

    /// SPEC §6.4's two connection budgets, in one value so they are visible together
    /// and can be tightened in a test without pretending to be a policy engine.
    ///
    /// > Connection time budgets: 10 seconds for initial socket establishment, then 10
    /// > seconds for ready.
    ///
    /// Note SPEC §6.4's own caveat: the installed harness's *observed* budget had not
    /// been recorded when this was written, and the line is to be corrected to match
    /// observation. Until it is, ten seconds is what the client enforces. These are
    /// deadlines on the connection, not per-request `URLRequest` timeouts — which is
    /// why `URLSessionRelayTransport` deliberately leaves `timeoutInterval` at the
    /// session default.
    public struct Budget: Sendable, Hashable {
        /// Time allowed for the socket to be established and the `$events` open frame
        /// to reach the wire.
        public var establishmentSeconds: Double
        /// Time allowed for the ready frame, measured from the moment the street is
        /// open — i.e. from the return of the open call, not from the start of the
        /// attempt.
        public var readinessSeconds: Double

        public init(establishmentSeconds: Double = 10, readinessSeconds: Double = 10) {
            self.establishmentSeconds = establishmentSeconds
            self.readinessSeconds = readinessSeconds
        }

        /// SPEC §6.4's stated budget.
        public static let standard = Budget()
    }

    /// The origin, credential, and pin policy one connection is made with.
    ///
    /// Bundled rather than passed as three arguments because the three are never
    /// chosen independently: SPEC §3.2 step 3 makes the payload's SPKI fingerprint
    /// "the trust anchor for the pairing connection *and subsequent requests*", so the
    /// credential and the pin arrive together from the pairing claim and travel
    /// together from then on.
    public struct Origin: Sendable, Hashable {
        /// Relay origin, e.g. `https://192.0.2.10:3443`. SPEC §3.2 requires the TLS
        /// origin in v1; `plainUrl` is ignored.
        public var baseURL: URL
        /// The device token from the pairing claim (SPEC §6.3). The token *is* the
        /// whole credential — there is nothing else to present.
        public var authorization: RelayAuthorization
        /// Pin policy (SPEC §3.2 step 3, SPEC §6.3). Defaults to platform trust, which
        /// is correct for a payload that carried no fingerprint.
        public var pinning: RelayPinningPolicy

        public init(
            baseURL: URL,
            authorization: RelayAuthorization,
            pinning: RelayPinningPolicy = .platformTrust
        ) {
            self.baseURL = baseURL
            self.authorization = authorization
            self.pinning = pinning
        }
    }

    /// Builds the transport each attempt runs on.
    ///
    /// A closure rather than one transport instance, so each reconnect gets a
    /// pristine connection instead of reusing one that just failed — and so a test can
    /// hand out a scripted transport per attempt, which is what makes
    /// "attempt 1 fails, attempt 2 succeeds" expressible at all.
    ///
    /// The coordinator's default is ``URLSessionRelayTransport``, which is the only
    /// place a real socket can come from; every test replaces it with
    /// ``StubRelayTransport`` and touches no network (SPEC §2 "Testing").
    public typealias TransportFactory = @Sendable (Origin) -> any RelayTransport

    /// A connection generation (SPEC §5 `ConnectionGeneration`, SPEC §6.5 "Reconnect
    /// creates a new generation and replaces baselines").
    ///
    /// Fresh local, never the host's. Frames, tasks, and errors carry the generation
    /// they belong to, so a late failure from an abandoned attempt cannot demote the
    /// status of the attempt that replaced it. `UInt64` rather than a UUID because the
    /// value is only ever compared and logged, and because SPEC §5 keeps host IDs
    /// opaque but says nothing that would make a local counter unsafe.
    public typealias Generation = UInt64

    // MARK: - Errors

    /// Why a connect attempt did not produce a usable connection, or why a call made
    /// through one failed.
    ///
    /// Every case is something the app must say differently, which is why they are not
    /// one `Error`. The mapping to ``ConnectionStatus`` is ``status``.
    public enum ConnectError: Error, Sendable, Hashable, CustomStringConvertible {
        /// The socket was not established within the establishment budget (SPEC §6.4).
        /// The underlying attempt may still be in flight; the coordinator has already
        /// abandoned and closed it.
        case establishmentTimedOut(seconds: Double)
        /// The socket opened but the ready frame did not arrive within the readiness
        /// budget (SPEC §6.4). This is the case that exists precisely because "The
        /// socket opening alone is not readiness": a relay that accepts the upgrade and
        /// then says nothing is a host that is not there.
        case readinessTimedOut(seconds: Double)
        /// The transport failed before any status existed — no network path, or the
        /// connection dropped.
        case transportInterruption(detail: String)
        /// SPEC §6.9 "TLS pin mismatch": stop, say the certificate changed, offer
        /// re-pair. Never retried, never silently downgraded to CA validation.
        case certificateChanged(detail: String)
        /// A well-formed failure from an RPC exchange: a relay refusal, a rate limit, a
        /// 404, or the host's own typed business error. Carried whole so the app can use
        /// ``DshRPCError/guidance`` rather than a re-derived guess.
        case rpc(DshRPCError)
        /// An `error` frame arrived on the stream before readiness. SPEC §6.4 records
        /// the shape (`{"type":"error","streamId":…,"error":{code,message,details}}`).
        case streamRejected(streamId: String, detail: String)
        /// A frame this build could not classify. SPEC §6.9 "Malformed response":
        /// protocol incompatibility, retain state, do not crash.
        case protocolIncompatible(reason: String)
        /// The attempt was cancelled — by ``shutdown()`` or by the caller's task. Not an
        /// error to show.
        case cancelled
        /// The ready frame arrived without a usable `clientId`, so no host request could
        /// be addressed. SPEC §6.4 shows the field; a client that invents one would
        /// silently address the wrong connection.
        case readyFrameWithoutClientId

        /// The word SPEC §3.1 puts on screen for this failure.
        ///
        /// The rule behind the mapping, in one place: a failure that means "this phone
        /// cannot reach the host" is ``ConnectionStatus/offline``; a failure that means
        /// "the host or the relay answered, and the answer was no" is
        /// ``ConnectionStatus/hostUnavailable``; a refusal that only re-pairing can fix
        /// is ``ConnectionStatus/pairingRequired``.
        public var status: ConnectionStatus {
            switch self {
            case .establishmentTimedOut, .readinessTimedOut, .streamRejected,
                 .protocolIncompatible, .readyFrameWithoutClientId:
                .hostUnavailable

            case .transportInterruption:
                .offline

            case .certificateChanged:
                // A pin mismatch is not retryable and needs an explicit re-pair
                // (SPEC §3.2, §6.9). SPEC §3.1 has no "Re-pair required" state, and
                // `refreshStatus` keeps a hard `.pairingRequired` once it has been set;
                // until then the honest word for "this host will not serve you" is
                // Host unavailable.
                .hostUnavailable

            case .rpc(let error):
                Self.status(for: error)

            case .cancelled:
                // Never presented. `refreshStatus` swallows it rather than letting a
                // cancelled attempt paint a status.
                .offline
            }
        }

        /// The SPEC §3.1 status for a ``DshRPCError``. One mapping, shared by the
        /// connect path and every call made through a live connection, so the two can
        /// never disagree about what a 403 means.
        public static func status(for error: DshRPCError) -> ConnectionStatus {
            switch error {
            case .credentialRejected:
                .pairingRequired
            case .transportInterruption:
                .offline
            case .cancelled:
                .offline
            case .relayedAuthenticationFailure, .rateLimited, .harnessUnavailable,
                 .capabilityUnavailable, .certificateChanged, .protocolIncompatible,
                 .unexpectedStatus, .business:
                .hostUnavailable
            }
        }

        /// Whether retrying could succeed with no user action. SPEC §6.4 stops retries
        /// for credential and pin failures; SPEC §6.9 makes 429 and 502 the two
        /// retryable statuses.
        public var isRetryable: Bool {
            switch self {
            case .establishmentTimedOut, .readinessTimedOut, .transportInterruption,
                 .readyFrameWithoutClientId:
                true
            case .certificateChanged, .streamRejected, .protocolIncompatible, .cancelled:
                false
            case .rpc(let error):
                error.isRetryable
            }
        }

        /// Redacted, for diagnostics (SPEC §3.7: error codes, never credential-bearing
        /// URLs). Every detail here has already been through
        /// ``RelayTransportError/safeDescription`` or is the host's own message.
        public var description: String {
            switch self {
            case .establishmentTimedOut(let seconds):
                "socket was not established within \(seconds)s"
            case .readinessTimedOut(let seconds):
                "the $events ready frame did not arrive within \(seconds)s"
            case .transportInterruption(let detail):
                "transport interruption: \(detail)"
            case .certificateChanged(let detail):
                "TLS pin mismatch: \(detail)"
            case .rpc(let error):
                error.readableReason ?? "\(error)"
            case .streamRejected(let streamId, let detail):
                "stream \(streamId) was rejected before readiness: \(detail)"
            case .protocolIncompatible(let reason):
                "protocol incompatibility: \(reason)"
            case .cancelled:
                "cancelled"
            case .readyFrameWithoutClientId:
                "the ready frame carried no clientId"
            }
        }
    }

    /// One usable connection: the generation, and the server `clientId` from the ready
    /// frame.
    public struct Connection: Sendable, Hashable {
        public var generation: Generation
        /// The server-side client id (SPEC §6.4). SPEC §6.7's `$events/result` body
        /// requires it, so it is the single most important thing the ready frame
        /// supplies — and it is why "socket open" cannot be treated as connected.
        public var clientId: String
        /// The ready frame's `host` object, kept whole.
        ///
        /// unverified: SPEC §6.4 shows only `{"home": "<path>"}` and nothing here needs
        /// the value, so it stays a ``JSONValue`` rather than a guessed shape.
        public var host: JSONValue?

        public init(generation: Generation, clientId: String, host: JSONValue? = nil) {
            self.generation = generation
            self.clientId = clientId
            self.host = host
        }
    }

    /// A live ``MuxClient`` plus the generation it belongtd to.
    ///
    /// Handing the client out rather than proxying every endpoint keeps this type from
    /// growing a method per stream, while making it impossible to open a stream without
    /// knowing which generation it is on (SPEC §6.5: baselines are per generation).
    public struct StreamHandle: Sendable {
        public let client: MuxClient
        public let generation: Generation
        /// The `$events` stream's ID, as this coordinator opened it.
        public let eventsStreamId: String

        fileprivate init(client: MuxClient, generation: Generation, eventsStreamId: String) {
            self.client = client
            self.generation = generation
            self.eventsStreamId = eventsStreamId
        }
    }

    // MARK: - State

    /// The current status. Read it from an actor-isolated context.
    public private(set) var status: ConnectionStatus = .pairingRequired {
        didSet {
            for observer in statusObservers.values { observer.yield(status) }
        }
    }
    private var statusObservers: [UUID: AsyncStream<ConnectionStatus>.Continuation] = [:]

    /// Includes the current state so a loss between connect and subscription is
    /// observed as well. Cancelling the consumer removes its subscription.
    public func statusUpdates() -> AsyncStream<ConnectionStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ConnectionStatus>.makeStream()
        statusObservers[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStatusObserver(id) }
        }
        return stream
    }

    private func removeStatusObserver(_ id: UUID) {
        statusObservers.removeValue(forKey: id)
    }
    /// The live connection, when there is one. Non-nil exactly when ``status`` is
    /// ``ConnectionStatus/connected``.
    public private(set) var connection: Connection?
    /// The most recent failure, kept so the UI can show *why* rather than only *what*.
    /// Cleared when a connect attempt starts.
    public private(set) var lastError: ConnectError?

    private let origin: Origin
    private let budgets: Budget
    private let makeTransport: TransportFactory

    /// How many attempts this coordinator has started **and** finished. Also the next
    /// generation's value, so every attempt has a distinct one.
    public private(set) var generationCount: Generation = 0

    private var activeGeneration: Generation?
    private var mux: MuxClient?
    private var eventRouter: RemoteEventRouter?

    /// Public for tests and for an explicit logout; production wiring passes the
    /// origin once and leaves it alone (SPEC §3.2: selecting another host disconnects
    /// the previous one, which is a *new* coordinator).
    /// - Parameter makeTransport: Defaults to the real `URLSession` transport. Every
    ///   test supplies ``StubRelayTransport`` instead.
    public init(
        origin: Origin,
        budgets: Budget = .standard,
        makeTransport: @escaping TransportFactory = { origin in
            URLSessionRelayTransport(pinning: origin.pinning)
        }
    ) {
        self.origin = origin
        self.budgets = budgets
        self.makeTransport = makeTransport
        // No credential, no connection: SPEC §3.1's initial state for an unpaired
        // device. A paired device's app moves it to `connecting` by calling `connect()`.
        if case .none = origin.authorization {
            self.status = .pairingRequired
        }
    }

    // MARK: - Connecting

    /// Establishes the socket, opens `$events`, and waits for the ready frame.
    ///
    /// Only when the ready frame has been read does this return and set
    /// ``ConnectionStatus/connected`` (SPEC §3.2 step 6: "Only mark the host connected
    /// after the stream readiness handshake completes").
    ///
    /// Calling it again tears the previous connection down first and burns a new
    /// generation, which is the shape SPEC §6.5 requires of a reconnect.
    /// ``ForegroundConnection`` schedules automatic attempts.
    ///
    /// - Throws: ``ConnectError``. On *any* throw the status has already been moved off
    ///   ``ConnectionStatus/connecting`` — a failure never leaves the app claiming to
    ///   be trying.
    @discardableResult
    public func connect() async throws -> Connection {
        await teardown()
        lastError = nil

        guard case .bearer = origin.authorization else {
            // SPEC §6.2: every relay request carries the bearer token, so an unpaired
            // device has nothing to connect with. Refusing locally beats a guaranteed 403
            // and beats a connect that hangs on a socket the relay will drop.
            throw await abandon(.rpc(.credentialRejected(relayError: nil, status: 403)))
        }

        generationCount += 1
        let generation = generationCount
        activeGeneration = generation
        status = .connecting

        do {
            return try await performConnect(generation: generation)
        } catch {
            throw await abandon(Self.failure(from: error))
        }
    }

    /// Discards a failed attempt and moves the status off `connecting`.
    ///
    /// Every throw path in ``connect()`` goes through here, which is what makes "a failure
    /// never leaves the app claiming to be trying" a property of the type rather than of
    /// each call site.
    private func abandon(_ failure: ConnectError) async -> ConnectError {
        await teardown()
        activeGeneration = nil
        lastError = failure
        refreshStatus(from: failure)
        return failure
    }

    /// One attempt: establish, open `$events`, wait for ready.
    private func performConnect(generation: Generation) async throws -> Connection {
        let transport = makeTransport(origin)
        let client = MuxClient(
            baseURL: origin.baseURL,
            authorization: origin.authorization,
            transport: transport
        )
        // Published before the open call so a budget expiry can close a mux whose
        // establishment has not returned yet. A stalled connect must not leak a socket.
        mux = client

        let eventsStreamId = Self.eventsStreamID(for: generation)
        let opened = try await Self.withBudget(
            seconds: budgets.establishmentSeconds,
            onExpiry: { .establishmentTimedOut(seconds: $0) }
        ) {
            try await client.open(streamId: eventsStreamId, endpoint: Self.eventsEndpoint)
        }

        // The socket is up; the budget that applies from here is readiness (SPEC §6.4:
        // "10 seconds for initial socket establishment, then 10 seconds for ready").
        let ready = try await Self.withBudget(
            seconds: budgets.readinessSeconds,
            onExpiry: { .readinessTimedOut(seconds: $0) }
        ) {
            try await Self.firstReadyFrame(in: opened, streamId: eventsStreamId)
        }

        guard generation == activeGeneration, !Task.isCancelled else { throw ConnectError.cancelled }
        let connection = Connection(generation: generation, clientId: ready.clientId, host: ready.host)
        self.connection = connection

        // Frames that arrive after the ready frame are still the socket's business — they
        // must be read or the connection stalls. They are no longer *discarded*: one
        // router consumes `$events` for this generation and fans the decoded events out.
        // SPEC §2 replaced the drain on exactly this reasoning, and §8 needs the events.
        // The router owns its own loop, so teardown only has to cancel the router.
        let router = RemoteEventRouter(
            identity: .init(generation: generation, clientId: ready.clientId),
            onEnded: { [weak self] error in
                await self?.streamEnded(generation: generation, error: error)
            }
        )
        // Assigned **before** the status is published, and that order is the whole point: a
        // subscriber that reacts to `connected` asks for ``remoteEvents()`` immediately, and
        // publishing first left a window where it got nil and gave up — producing a client
        // that was connected, held no `$events` subscription, and never retried. Measured
        // against the installed host, that is what kept a session's question from reaching the
        // session list. The router buffers what arrives before its first subscriber, so
        // starting it here loses nothing.
        eventRouter = router
        status = .connected
        await router.start(opened)

        return connection
    }

    /// The `$events` router for the current ready generation, when one is connected.
    ///
    /// The only supported way to receive host events. It returns nil while there is no
    /// ready connection, so a caller cannot subscribe to a generation that has gone.
    public func remoteEvents() -> RemoteEventRouter? {
        guard connection != nil, let eventRouter else { return nil }
        return eventRouter
    }

    // MARK: - Creating a session (SPEC §5)

    /// What a create attempt left behind.
    ///
    /// Two outcomes rather than one, because SPEC §5 gives the second its own rule: a
    /// `session/workspace-attach-failed` means the session **may already exist**, so the
    /// caller must reconcile the identity it gets back rather than create another one.
    public enum SessionCreateOutcome: Sendable, Hashable {
        case created(CreatedSession)
        case attachmentFailed(sessionId: String?, reason: String)
    }

    /// The identity a create returned.
    public struct CreatedSession: Sendable, Hashable {
        public var sessionId: String
        public var agentPreset: String?

        public init(sessionId: String, agentPreset: String? = nil) {
            self.sessionId = sessionId
            self.agentPreset = agentPreset
        }
    }

    /// Creates — or adopts — a session with an identity the caller chose.
    ///
    /// **The identity is the caller's, never minted here.** SPEC §5: omitting `sessionId`
    /// makes the host invent one *and* disables its persisted-identity checks, so supplying
    /// it is what makes adopting an unknown outcome safe. A method that generated one would
    /// silently remove the only thing that makes a retry after a timeout safe.
    ///
    /// `workspaceId` and `cwd` are mutually exclusive on the host, which refuses both with
    /// `gateway/bad-request`. This takes the workspace only: the phone uses a workspace the
    /// host already knows, never a path it invented.
    ///
    /// Retries are off, like every other write (SPEC §3.4).
    public func createSession(
        sessionId: String,
        workspaceId: String? = nil,
        agentPreset: String? = nil
    ) async throws -> SessionCreateOutcome {
        let client = DshRpcClient(
            baseURL: origin.baseURL,
            authorization: origin.authorization,
            transport: makeTransport(origin)
        )
        let request = SessionCreateRequest(
            workspaceId: workspaceId,
            sessionId: sessionId,
            agentPreset: agentPreset
        )
        do {
            let response = try await client.mutate(
                Self.sessionCreateMethod,
                args: SessionCreateArguments(request: request),
                returning: SessionCreateValue.self
            )
            // A missing value after `ok: true` would leave a session whose identity this
            // client cannot name, which is worse than reporting the anomaly.
            guard let value = response.result.value else {
                throw Self.failure(from: DshRPCError.protocolIncompatible(
                    reason: "session/create returned no session identity"
                ))
            }
            return .created(CreatedSession(sessionId: value.sessionId, agentPreset: value.agentPreset))
        } catch {
            // `failure(from:)` lifts the transport error into the coordinator's own type;
            // the business refusal underneath is what carries SPEC §5's partial success.
            let failure = Self.failure(from: error)
            if case .rpc(.business(let business)) = failure, business.code == Self.attachFailedCode {
                return .attachmentFailed(
                    sessionId: business.details?.unknownFields["sessionId"]?.stringValue,
                    reason: business.message
                )
            }
            lastError = failure
            applyCallFailure(failure)
            throw failure
        }
    }

    /// The host's code for "the session was made, but its workspace was not attached".
    public static let attachFailedCode = "session/workspace-attach-failed"

    // MARK: - Sessions (SPEC §3.3)

    /// A session's current projections, decoded from `session/projections`.
    ///
    /// Read through the unary endpoint rather than taken from the `session/control` stream,
    /// because the two are not the same picture: against the installed host on 2026-10-09 the
    /// control baseline for a live session carried its `modelSelection` but **not** its
    /// `imageLimits`, while this endpoint carried both. A picker that trusted the stream would
    /// refuse images the host actually accepts.
    public func sessionProjections(sessionId: String) async throws -> SessionProjectionsValue? {
        let client = DshRpcClient(
            baseURL: origin.baseURL,
            authorization: origin.authorization,
            transport: makeTransport(origin)
        )
        do {
            let response = try await client.call(
                Self.sessionProjectionsMethod,
                args: SessionProjectionsArguments(request: SessionProjectionsRequest(sessionId: sessionId)),
                returning: SessionProjectionsValue.self
            )
            return response.result.value
        } catch {
            let failure = Self.failure(from: error)
            lastError = failure
            throw failure
        }
    }

    /// Stops the turn a session is running.
    ///
    /// Nothing in `userQuestions` can decline a question — `answer` and `attachWait` are the whole
    /// namespace — so this is how a question gets released without an answer.
    ///
    /// A write, so it goes once (SPEC §3, "Retry rule"): a 502 after the host has already
    /// cancelled would otherwise send the cancel again (#63).
    public func cancelSession(_ sessionId: String) async throws {
        let client = DshRpcClient(
            baseURL: origin.baseURL,
            authorization: origin.authorization,
            transport: makeTransport(origin)
        )
        do {
            _ = try await client.mutate(
                Self.sessionCancelMethod,
                args: SessionCancelArguments(request: SessionCancelRequest(sessionId: sessionId)),
                returning: SessionCancelResponse.self
            )
        } catch {
            let failure = Self.failure(from: error)
            lastError = failure
            applyCallFailure(failure)
            throw failure
        }
    }

    /// One page of older history, decoded from `session/page`.
    ///
    /// A read, so it uses the ordinary read-retry policy rather than the mutation
    /// policy — but note what SPEC §7 fixes about its arguments: `throughSeq` is the
    /// *opening follow snapshot's* cursor for the generation the caller is showing, not
    /// a delivery event's watermark, and `beforeSeq` is exclusive. Both come from the
    /// conversation window, which is why the request carries them rather than this
    /// method deriving them.
    @discardableResult
    public func page(_ request: ConversationPageRequest) async throws -> ConversationPage {
        let client = DshRpcClient(
            baseURL: origin.baseURL,
            authorization: origin.authorization,
            transport: makeTransport(origin)
        )
        // The window's own address, not one rebuilt from `sessionId`: a subagent's session form is
        // refused by the host (`session/agent-busy`), so the parent address has to survive the trip
        // from the screen that opened the conversation.
        let argument = SessionPageRequest(
            address: request.address.pageAddress,
            throughSeq: request.throughSeq,
            beforeSeq: request.beforeSeq,
            maxMessages: Int64(request.maxMessages)
        )
        do {
            let response = try await client.call(
                Self.sessionPageMethod,
                args: SessionPageArguments(request: argument),
                returning: SessionPage.self
            )
            let value = response.result.value
            let events = (value?.records ?? []).map(Self.envelope(from:))
            // `hasMore` is the host's own answer about older history, and SPEC §7 makes
            // it the authority rather than an inference from the page's size.
            return ConversationPage(events: events, hasMore: value?.hasMore ?? false)
        } catch {
            let failure = Self.failure(from: error)
            lastError = failure
            applyCallFailure(failure)
            throw failure
        }
    }

    /// Maps one `session/page` record onto the durable envelope the rest of the app
    /// already folds. The generated record type does the decoding; this is a rename.
    ///
    /// `surfaceOp` is passed through **whole**. It used to be narrowed with `.stringValue`,
    /// which silently dropped the object form the host sends on `tool/result` (#99) — the same
    /// narrowing that failed the frame on the mux path.
    private static func envelope(from record: SessionPageRecordsItem) -> DurableEventEnvelope {
        DurableEventEnvelope(
            type: record.event.type,
            seq: record.event.seq,
            time: record.event.time,
            data: record.event.data,
            surfaceOp: record.event.surfaceOp
        )
    }

    /// The host's session list, decoded from `session/list`.
    ///
    /// `session/list` takes its arguments in a field named **`_request`**, and the
    /// parameter name is per endpoint rather than a convention — `session/create`,
    /// `session/follow` and `session/prompt` take `request` instead (SPEC §6.2). The
    /// name is read from the installed harness's own descriptor
    /// (`Protocol/endpoints.json`, `@deepseek-ai/dsh-api-session-controller#session/list`
    /// → `parameters[0].name == "_request"`), which is why ``RPCArguments`` exists.
    ///
    /// - Throws: ``ConnectError``. A failure here is *not* necessarily a lost
    ///   connection: a business refusal leaves the connection up and only the call
    ///   failed, so the status is left alone unless the failure is one that means the
    ///   connection is gone.
    @discardableResult
    public func sessions() async throws -> [SessionSummary] {
        let client = DshRpcClient(
            baseURL: origin.baseURL,
            authorization: origin.authorization,
            transport: makeTransport(origin)
        )
        do {
            let response = try await client.call(
                Self.sessionListMethod,
                args: RPCArguments(request: RPCEmptyRequest()),
                returning: SessionListResult.self
            )
            // SPEC §6.2: `result.ok` is the success signal, and a missing `value` is a
            // success with no payload, not a decode failure. `session/list` always has
            // a value, but a host that answered `{"ok":true}` must read as "no sessions"
            // rather than as an error.
            return response.result.value?.items ?? []
        } catch {
            let failure = Self.failure(from: error)
            lastError = failure
            applyCallFailure(failure)
            throw failure
        }
    }

    // MARK: - Prompts

    /// Sends a prompt to a session and returns once the host has accepted it.
    ///
    /// Sent with retries **disabled**, deliberately: SPEC §3.4 forbids resending a
    /// prompt whose outcome is unknown, because a duplicate turn costs real work
    /// and the user cannot tell it happened. An uncertain send is reported, never
    /// repeated — the user decides.
    ///
    /// Acceptance is not completion: the turn itself arrives over the session's
    /// follow stream, which is ``ChatSession``'s job to fold.
    /// Sends a prompt as one human submission.
    ///
    /// - Parameter requestId: The persisted identity of *this* submission, which the
    ///   caller owns. It is a required argument rather than minted here on purpose.
    ///
    ///   SPEC §5 requires a retry of an uncertain send to reuse the original request ID
    ///   with the same content, and the host deduplicates on exactly that value:
    ///   `hasPromptRequest(agent, request.requestId)` returns the earlier acceptance
    ///   rather than admitting a second turn. A method that generated the ID itself would
    ///   make that impossible to satisfy — every retry would look like a new submission,
    ///   the deduplication would never match, and the duplicate turn SPEC §3.4 forbids
    ///   would be created silently. So the identity comes from the caller, which is the
    ///   only place that can tell a retry from a new message.
    public func prompt(
        requestId: String,
        sessionId: String,
        text: String,
        fileReceiptIds: [String] = [],
        images: [PromptImage] = []
    ) async throws {
        let client = DshRpcClient(
            baseURL: origin.baseURL,
            authorization: origin.authorization,
            transport: makeTransport(origin)
        )
        // SPEC §9: a staged file is cited by its **receipt**, not by an `attachmentId`, and
        // an `attachmentId` is explicitly not a substitute. The parts go in as `file` content
        // items beside the text, in the order the caller staged them.
        var content: [SessionPromptRequestContentItem] = [
            .text(SessionPromptRequestContentItemText(type: "text", text: text))
        ]
        content.append(contentsOf: fileReceiptIds.map {
            .file(SessionPromptRequestContentItemFile(type: "file", receiptId: $0))
        })
        // Images travel inline, base64, with the host's own media type — SPEC §9 keeps the
        // upload route for generic files and puts pictures in the prompt itself. Whether these
        // are within the host's `imageLimits` is checked before this call, not here.
        content.append(contentsOf: images.map { image in
            .image(SessionPromptRequestContentItemImage(
                type: "image",
                mediaType: SessionPromptRequestContentItemImageMediaType(rawValue: image.mediaType),
                data: image.data.base64EncodedString(),
                name: image.name
            ))
        })
        let request = SessionPromptRequest(
            requestId: requestId,
            sessionId: sessionId,
            mode: .queue,
            content: content,
            clientTimeZone: TimeZone.current.identifier
        )
        do {
            _ = try await client.mutate(
                Self.sessionPromptMethod,
                args: SessionPromptArguments(request: request),
                returning: SessionPromptValue.self
            )
        } catch {
            let failure = Self.failure(from: error)
            lastError = failure
            applyCallFailure(failure)
            throw failure
        }
    }

    // MARK: - Questions

    /// Answers a question the harness asked a session.
    ///
    /// Retries are off for the same reason prompts have them off (SPEC §3.4): an
    /// answer delivered twice is worse than one reported as uncertain, because the
    /// agent may act on both.
    ///
    /// - Parameters:
    ///   - agentId: the session that asked.
    ///   - callId: the tool call carrying the question.
    ///   - questionId: which question this answers, from the question's own `id`.
    ///   - selected: option ids chosen.
    ///   - custom: free text, when the question allows it.
    public func answer(
        agentId: SessionId,
        callId: ToolCallId,
        questionId: String,
        selected: [String],
        custom: String? = nil
    ) async throws -> Bool {
        let client = DshRpcClient(
            baseURL: origin.baseURL,
            authorization: origin.authorization,
            transport: makeTransport(origin)
        )
        let arguments = UserQuestionsAnswerArguments(
            agentId: agentId,
            callId: callId,
            answer: AskUserQuestionAnswer(answers: [
                AskUserQuestionAnswerAnswersItem(
                    id: questionId,
                    selected: selected,
                    custom: custom
                )
            ])
        )
        do {
            let response = try await client.mutate(
                Self.userQuestionsAnswerMethod,
                args: arguments,
                returning: UserQuestionsAnswerResult.self
            )
            // `ok: true` means the call was accepted; this value says whether the
            // host actually applied it. A question that had already been abandoned
            // answers `false`, which is not a transport failure and must not be
            // reported as one — the caller decides what to tell the user.
            return response.result.value ?? false
        } catch {
            let failure = Self.failure(from: error)
            lastError = failure
            applyCallFailure(failure)
            throw failure
        }
    }

    // MARK: - Streams

    /// Answers a question the host parked in its `continued` state.
    ///
    /// The same endpoint as ``answer(agentId:callId:questionId:selected:custom:)``, but the
    /// body is a whole batch that the caller has already validated — SPEC §8's third channel
    /// row, where the questions came from a projection rather than from a live delivery, so
    /// the caller holds the batch and this method only carries it.
    ///
    /// Retries are off for the same reason every other write's are.
    ///
    /// - Returns: whether the host accepted the reply. `false` means the question is no
    ///   longer answerable, which is not success.
    @discardableResult
    public func answerContinued(
        agentId: String,
        callId: String,
        body: JSONValue
    ) async throws -> Bool {
        let client = DshRpcClient(
            baseURL: origin.baseURL,
            authorization: origin.authorization,
            transport: makeTransport(origin)
        )
        // A local shape rather than the generated `UserQuestionsAnswerArguments`, whose
        // `answer` field is the generated DTO: this body is built and validated by
        // `QuestionAnswerValidator`, and re-modelling it here would be a second opinion
        // about the same wire object.
        struct ContinuedAnswerArguments: Codable, Sendable {
            var agentId: String
            var callId: String
            var answer: JSONValue
        }
        do {
            let response = try await client.mutate(
                Self.userQuestionsAnswerMethod,
                args: ContinuedAnswerArguments(agentId: agentId, callId: callId, answer: body),
                returning: UserQuestionsAnswerResult.self
            )
            return response.result.value ?? false
        } catch {
            let failure = Self.failure(from: error)
            lastError = failure
            applyCallFailure(failure)
            throw failure
        }
    }

    /// The live mux and its generation, for the next slices (`session/follow`,
    /// `$events/result`, the workspace and control streams).
    ///
    /// Opening the streams themselves belongs to whoever reduces them: SPEC §4 gives
    /// each one an owner, and a coordinator that opened a follow stream for a session
    /// it does not track would be the "late frames mutating the new conversation"
    /// hazard in the other direction.
    public func activeStream() -> StreamHandle? {
        guard let mux, let generation = activeGeneration, connection != nil else { return nil }
        return StreamHandle(
            client: mux,
            generation: generation,
            eventsStreamId: Self.eventsStreamID(for: generation)
        )
    }

    /// Called by the router when the `$events` stream ends. Guards on the generation so a
    /// late failure from an abandoned attempt cannot demote the attempt that replaced
    /// it (SPEC §6.5: a reconnect replaces baselines rather than merging them).
    private func streamEnded(generation: Generation, error: any Error) {
        guard generation == activeGeneration, connection != nil else { return }
        let failure = Self.failure(from: error)
        // A socket that fails while connected is not a cancelled attempt: report it
        // even though it is a `.cancelled`-shaped error being suppressed elsewhere.
        var reported = failure
        if case .cancelled = failure {
            reported = .transportInterruption(detail: "the multiplexed socket closed")
        }
        lastError = reported
        connection = nil
        // Keep ownership until teardown closes the entire socket, including any
        // conversation stream left behind by a logical events-stream end.
        activeGeneration = nil
        status = reported.status
    }

    // MARK: - Shutdown

    /// Cancels every stream, closes the socket, and leaves no task running.
    ///
    /// Idempotent, and safe to call before anything was ever connected. After it, the
    /// status is ``ConnectionStatus/offline`` — a deliberate shutdown is not a
    /// pairing problem and not a host problem (SPEC §3.2: selecting another host
    /// disconnects the previous one; SPEC §7: being offline on the phone does not mean
    /// the harness stopped).
    public func shutdown() async {
        await teardown()
        activeGeneration = nil
        connection = nil
        lastError = nil
        status = .offline
    }

    /// The shared teardown: cancel the router, close the mux, forget the connection.
    ///
    /// ``MuxClient/close()`` is what cancels the receive loop and closes the socket —
    /// and it finishes every open stream, which is what lets a consumer's `for await`
    /// end instead of hanging on a socket nobody will feed again.
    private func teardown() async {
        // Drop the connection's claim *first*. The router is about to observe its stream
        // end, and that end belongs to this deliberate teardown — `streamEnded` guards on
        // `connection != nil`, so nothing here can be reported as a lost connection and
        // schedule a pointless reconnect.
        connection = nil

        // The socket goes before the router, not after. `MuxClient.close()` removes every
        // subscription before finishing it, so the router's iterator ends without its
        // termination handler reaching the per-stream cancel path — a cancel frame for a
        // stream we are already abandoning is a write on a socket that is closing.
        if let mux {
            self.mux = nil
            await mux.close()
        }

        // Belt and braces: stops the consumer if the stream end has not already, retires
        // this generation's pending deliveries, and closes its subscribers. Idempotent.
        let router = eventRouter
        eventRouter = nil
        await router?.cancel()
    }

    // MARK: - Status

    /// Records that a connection was lost and is being re-established.
    ///
    /// Available to manual callers. ``ForegroundConnection`` owns the app's
    /// reconnecting presentation while it schedules retries.
    public func reportReconnecting() {
        status = .reconnecting
    }

    /// Moves the status for a failure, unless a terminal one is already showing.
    ///
    /// The rule that keeps the status honest: a hard credential failure is **sticky**.
    /// The simplest plausible reconnect loop — backoff, `connect()`, fail, backoff —
    /// would otherwise flip a clear "Pairing required" back to `Connecting` and then
    /// `Host unavailable` on every attempt, and SPEC §6.9 requires the app to *stop*
    /// retrying a 403 and clear it with a re-pair, not to churn.
    ///
    /// It is deliberately one-directional and tiny; when the real backoff loop lands it
    /// may want to own this policy instead.
    private func refreshStatus(from failure: ConnectError) {
        if case .rpc(.credentialRejected) = failure, status == .pairingRequired {
            return
        }
        status = failure.status
    }

    /// The status rule for a failure thrown by a call *through* a live connection
    /// rather than by a connect attempt.
    ///
    /// The distinction SPEC §3.1's six words make necessary: every one of these
    /// failures arrived over a connection that demonstrably still works, so a 404 for an
    /// endpoint the host does not implement, a rate limit, or the host refusing one
    /// request on business grounds (SPEC §6.9's "hide that feature", "429", "business
    /// refusal" rows) is not evidence about the socket. Demoting a live connection to
    /// `Host unavailable` because one endpoint 404'd would make the status lie.
    ///
    /// The one case that *is* evidence about the connection is ``pairingRequired``: a 403 is the
    /// host's own verdict about this credential, so the UI has to say so. ``offline`` is
    /// deliberately **not** applied — a call failure is evidence about the call. A request that
    /// timed out is classified `.offline` (`URLError.timedOut`, ``RelayTransportError/classify(_:)``),
    /// so promoting it made one slow reply tear down and rebuild a healthy socket (#82), while
    /// `HomeView` refreshes `session/list` every 15 seconds — often enough to see it.
    ///
    /// Nothing is lost by that: a socket that really died ends `$events`, and
    /// ``streamEnded(generation:error:)`` repaints the connection status itself.
    private func applyCallFailure(_ failure: ConnectError) {
        switch failure.status {
        case .pairingRequired:
            refreshStatus(from: failure)
        case .connecting, .connected, .reconnecting, .offline, .hostUnavailable:
            // Leave the connection's own status alone. Only the connect path, the drain loop,
            // and the socket's own end may move a live connection's status.
            break
        }
    }

    /// Maps anything thrown anywhere in this file onto the one error type the app
    /// switches on. Kept exhaustive so a new throw site cannot introduce a third error
    /// domain by accident.
    ///
    /// ``DshRPCError`` has **two** shapes and they map differently, which is the one
    /// non-obvious rule here. The cases that carry a well-formed answer from the relay or
    /// the host — a refusal body, a status, a typed business error — stay wrapped in
    /// ``ConnectError/rpc(_:)`` so the app keeps access to
    /// ``DshRPCError/guidance``/``DshRPCError/isPairingLockout``/``DshRPCError/rpcError``.
    /// The two that are really connection facts — the transport going away, and a pin
    /// mismatch — are lifted out into ``ConnectError/transportInterruption(detail:)`` and
    /// ``ConnectError/certificateChanged(detail:)``.
    ///
    /// That lift is not cosmetic. Without it, "the socket dropped during a unary call"
    /// would be `.rpc(.transportInterruption)` on the call path and
    /// `.transportInterruption` on the connect path — two spellings of one condition, which
    /// is exactly how an app ends up with a retry rule that holds in one place and not the
    /// other.
    static func failure(from error: any Error) -> ConnectError {
        if let error = error as? ConnectError { return error }
        if let error = error as? DshRPCError {
            switch error {
            case .transportInterruption(let detail):
                return .transportInterruption(detail: detail)
            case .certificateChanged(let detail):
                return .certificateChanged(detail: detail)
            case .cancelled:
                return .cancelled
            case .credentialRejected, .relayedAuthenticationFailure, .rateLimited,
                 .harnessUnavailable, .capabilityUnavailable, .protocolIncompatible,
                 .unexpectedStatus, .business:
                return .rpc(error)
            }
        }
        if let error = error as? MuxStreamError {
            switch error {
            case .socketFailed(let transportError):
                return socketFailure(transportError)
            case .protocolIncompatible(let reason):
                return .protocolIncompatible(reason: reason)
            case .clientClosed:
                return .cancelled
            case .streamIdInUse(let streamId):
                // A client-side ID collision, not a host failure: it would mean two
                // consumers raced for one stream, which is this side's bug.
                return .protocolIncompatible(reason: "stream id \(streamId) was already in use")
            }
        }
        switch RelayTransportError.classify(error) {
        case .offline(let detail), .other(let detail):
            return .transportInterruption(detail: detail)
        case .tlsPinMismatch(let detail):
            return .certificateChanged(detail: detail)
        case .webSocketRejected(let error):
            return .rpc(error)
        case .cancelled:
            return .cancelled
        }
    }

    /// Classifies ``MuxStreamError/socketFailed(detail:)``, which reaches this layer as a
    /// string and nothing more.
    ///
    /// This exists because of a real hazard, not for tidiness: `MuxClient` establishes its
    /// socket with `transport.openSocket`, which is where a **pin mismatch** actually
    /// happens — the TLS challenge is answered during the WebSocket upgrade. A real
    /// `URLSessionRelayTransport` turns that into ``RelayTransportError/tlsPinMismatch(_:)``
    /// *inside* `openSocket`, `MuxClient.classify` then reports it as
    /// `.socketFailed(detail: "TLS pin mismatch: …")`, and the distinction between "the
    /// certificate changed, stop and re-pair" and "the network dropped, retry" is gone
    /// unless it is recovered here. Since #89 the transport's premise is real: the
    /// challenge handler records its refusal, and the socket's failure seam maps the
    /// refusal's own `-999` to that error, which is where this prefix comes from.
    ///
    /// So the kind is recovered from the one thing that survives — the prefix of
    /// ``RelayTransportError/safeDescription``, which is stable and is the *only* prefix
    /// construction in the codebase. Losing it would mean a pin mismatch counted as
    /// retryable, which SPEC §6.4 and SPEC §6.9 both forbid.
    ///
    /// The honest limitation: a genuinely unknown `transport failure:` detail is reported
    /// as ``ConnectError/transportInterruption(detail:)``, and a `cancelled` detail as
    /// ``ConnectError/cancelled``. ``ConnectError/certificateChanged(detail:)`` is claimed
    /// only on a `TLS pin mismatch: ` prefix. Matching one prefix in isolation is a long
    /// way from matching on prose, but the durable fix is to carry the case through
    /// `MuxStreamError` instead of a string; see this slice's report.
    static func socketFailure(_ error: RelayTransportError) -> ConnectError {
        switch error {
        case .tlsPinMismatch(let detail):
            // SPEC §6.4: stop, say the certificate changed, offer re-pairing. The
            // kind is read from the error itself, not recovered from its wording.
            return .certificateChanged(detail: detail)
        case .webSocketRejected(let error):
            return .rpc(error)
        case .cancelled:
            return .cancelled
        case .offline(let detail), .other(let detail):
            return .transportInterruption(detail: detail)
        }
    }

    /// The prefix ``RelayTransportError/safeDescription`` puts on a pin mismatch.
    static let pinMismatchPrefix = "TLS pin mismatch"

    // MARK: - The ready frame (SPEC §6.4)

    /// The `$events` endpoint name as SPEC §6.4 writes it, `$` included.
    public static let eventsEndpoint = "$events"
    /// The unary endpoint SPEC §3.3's session list comes from.
    public static let sessionListMethod = "session/list"
    public static let sessionPageMethod = "session/page"
    public static let sessionCancelMethod = "session/cancel"
    public static let sessionCreateMethod = "session/create"
    public static let sessionProjectionsMethod = "session/projections"
    public static let sessionPromptMethod = "session/prompt"
    public static let userQuestionsAnswerMethod = "userQuestions/answer"

    /// A stream ID for `$events`, unique per generation.
    ///
    /// SPEC §6.4's example uses `"1"` and SPEC §5 calls the ID an opaque client-chosen
    /// string, so the value is free. Making it per-generation keeps a re-used ID from
    /// colliding with a cancelled stream's leftovers in one process — `MuxClient`
    /// refuses to open a stream ID that is still registered.
    static func eventsStreamID(for generation: Generation) -> String { "events-\(generation)" }

    /// The decoded ready frame, SPEC §6.4's one item on `$events` that means the host is
    /// there.
    public struct ReadyFrame: Sendable, Hashable {
        public var clientId: String
        public var host: JSONValue?
    }

    /// Reads `$events` until the ready frame arrives, and **not** until the socket
    /// opens.
    ///
    /// SPEC §6.4, captured from the running relay rather than inferred:
    /// ```json
    /// {"type":"item","streamId":"1","value":{"type":"ready","clientId":"<36 chars>","host":{"home":"<path>"}}}
    /// ```
    /// The ready frame is an ordinary `item` whose `value.type` this build models only as
    /// ``MuxFrameValue/unknown(type:value:)`` — SPEC §5 keeps an unrecognised value
    /// whole rather than failing, so nothing has to be added to `Models/` to read it.
    ///
    /// Two behaviours worth stating because they are choices:
    /// - An `error` frame for this stream fails the attempt with what the host said
    ///   instead of being skipped. Waiting out the ready budget for a stream the host has
    ///   already refused would only delay the same answer.
    /// - Any other frame before ready — an `end`, or an item of another kind — is
    ///   skipped, not treated as readiness. A `clientId` is the *only* proof.
    ///
    /// - Throws: ``ConnectError/streamRejected(streamId:detail:)``,
    ///   ``ConnectError/readyFrameWithoutClientId``, or whatever the stream threw.
    static func firstReadyFrame(
        in stream: AsyncThrowingStream<MuxStreamItem, any Error>,
        streamId: String
    ) async throws -> ReadyFrame {
        for try await item in stream {
            switch item.frame.type {
            case .error:
                throw ConnectError.streamRejected(
                    streamId: streamId,
                    detail: describe(item.frame)
                )
            case .item:
                let value = item.frame.value
                guard value?.typeName == MuxFrameValue.readyRawValue,
                      let payload = value?.unknownValue
                else { continue }
                guard let clientId = payload["clientId"]?.stringValue, !clientId.isEmpty else {
                    // SPEC §6.4 captured `clientId` as a 36-character string and SPEC §6.7
                    // needs it for `$events/result`. A ready frame without one cannot
                    // address any host request, so it is a failure rather than a partial
                    // success.
                    throw ConnectError.readyFrameWithoutClientId
                }
                return ReadyFrame(clientId: clientId, host: payload["host"])
            case .end:
                // SPEC §6.4: no `end` frame has ever been observed; treat it as defined
                // but unproven and as a refusal to serve this stream.
                throw ConnectError.streamRejected(
                    streamId: streamId,
                    detail: "the host ended $events before it was ready"
                )
            case .unknown(let raw):
                throw ConnectError.protocolIncompatible(
                    reason: "unrecognised mux frame type \"\(raw)\" on $events"
                )
            }
        }
        // The sequence ended without a ready frame: the socket is gone.
        throw ConnectError.transportInterruption(
            detail: "the $events stream ended before the ready frame"
        )
    }

    /// A one-line, redacted rendering of a frame this build cannot classify.
    ///
    /// Deliberately shallow: the interesting content of an `error` frame is
    /// `error.code` / `error.message`, both of which stay in ``MuxFrame/unknownFields``
    /// because neither shape was captured (SPEC §6.4 shows `code`, `message`, and
    /// `details`, but no fixture contains one). Only names and codes are surfaced, never
    /// the whole payload, because a diagnostics line must not carry host content.
    static func describe(_ frame: MuxFrame) -> String {
        guard let reported = frame.unknownFields["error"] else {
            return "the host reported an error on this stream"
        }
        let code = reported["code"]?.stringValue
        let message = reported["message"]?.stringValue
        switch (code, message) {
        case (let code?, let message?): return "\(code): \(message)"
        case (let code?, nil): return code
        case (nil, let message?): return message
        case (nil, nil): return "the host reported an error on this stream"
        }
    }

    // MARK: - Budgets

    /// Race the deadline and operation without waiting on an unresponsive socket.
    /// AsyncStream also wakes immediately on caller cancellation, so backgrounding
    /// can tear down a stalled handshake instead of waiting for its timeout.
    static func withBudget<T: Sendable>(
        seconds: Double,
        onExpiry: @escaping @Sendable (Double) -> ConnectError,
        sleeper: any RelaySleeper = TaskRelaySleeper(),
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let (stream, continuation) = AsyncThrowingStream<T, any Error>.makeStream()
        let work = Task {
            do {
                try Task.checkCancellation()
                continuation.yield(try await operation())
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let timer = Task {
            do {
                try await sleeper.sleep(seconds: seconds)
                continuation.finish(throwing: onExpiry(seconds))
            } catch {}
        }
        defer {
            work.cancel()
            timer.cancel()
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next(), !Task.isCancelled else {
            throw ConnectError.cancelled
        }
        return value
    }
}

// MARK: - MuxFrameValue, read as the unknown case it is

extension MuxFrameValue {
    /// The wire value of SPEC §6.4's `$events` ready frame.
    ///
    /// It lives here rather than in `Models/StreamFrames.swift` on purpose: a `ready`
    /// frame's own shape is stated by SPEC from the running relay but is **not** in
    /// `Fixtures/mux-stream-frames.json`, and that file's design rule is that a value
    /// type becomes a modelled case only when a capture proves its fields. Adding a
    /// case there would be inventing a shape on the strength of a spec sentence, in
    /// files this slice may not touch. The obvious follow-up is to capture one — then
    /// `ready` earns a modelled case and this extension goes away.
    public static let readyRawValue = "ready"

    /// The payload of an ``MuxFrameValue/unknown(type:value:)`` value, or `nil` for a
    /// value this build models.
    public var unknownValue: JSONValue? {
        if case .unknown(_, let value) = self { value } else { nil }
    }
}

// Automatic foreground recovery is owned by ForegroundConnection. This actor
// owns the handshake, socket, and per-connection generation.
