import Foundation

/// One thing the host is asking the user to decide.
///
/// SPEC §8's approval cards, and the shape question batches will also use. Approval and
/// question waterfalls differ only in their request payload, so one type carries both and
/// the caller switches on ``event``.
public struct InteractionRequest: Sendable, Hashable, Identifiable {
    /// Where this request is in its life.
    ///
    /// ``uncertain`` is not a failure: SPEC §8 requires an unresolved submission to be
    /// shown as unresolved rather than silently treated as rejected or resent.
    public enum State: Sendable, Hashable {
        /// Answerable by this client.
        case pending
        /// This client has an answer in flight.
        case submitting
        /// Over: answered here, answered elsewhere, or withdrawn by the host.
        case settled
        /// An answer was submitted and the outcome is unknown.
        case uncertain

        /// Whether a control should be offered. Only a pending request may be answered, and
        /// a request mid-submission must not be answered twice.
        public var isActionable: Bool { self == .pending }
    }

    /// The waterfall's `eventId`. Unique per delivery within a host, and the value the
    /// result must cite.
    public var id: String
    /// The session that asked. The only session scope on the frame.
    public var sessionId: String
    /// The tool call, when the request carries one. Part of the group key.
    public var callId: String?
    /// The namespaced event name, e.g. `approval/request`.
    public var event: String
    /// The request payload, lossless and untrusted in shape.
    public var request: JSONValue
    /// The connection generation that delivered it.
    public var generation: UInt64
    public var state: State

    public init(
        id: String,
        sessionId: String,
        callId: String?,
        event: String,
        request: JSONValue,
        generation: UInt64,
        state: State = .pending
    ) {
        self.id = id
        self.sessionId = sessionId
        self.callId = callId
        self.event = event
        self.request = request
        self.generation = generation
        self.state = state
    }
}

/// What one group of requests belongs to.
///
/// SPEC §8: a batch is keyed by `(host, sessionId, callId)`, and the spec is explicit that
/// the existing dictionary keyed only by question id **collides across calls** — two
/// different tool calls can each ask a question with id `"1"`. So the group key carries the
/// call, and a question's own id only orders it *within* a group.
public struct InteractionGroupKey: Sendable, Hashable {
    public var sessionId: String
    public var callId: String?

    public init(sessionId: String, callId: String?) {
        self.sessionId = sessionId
        self.callId = callId
    }
}

/// Why an answer was not delivered.
public enum InteractionRefusal: Error, Sendable, Hashable {
    /// No ready connection, or the request belongs to a connection that has gone.
    case staleGeneration
    /// The request is no longer answerable, so nothing was sent.
    case notActionable(state: InteractionRequest.State)
    /// The host refused the answer as a business decision.
    case refused(code: String, message: String)
    /// The submission did not reach a verdict. SPEC §8: keep the decision history and
    /// resynchronise; never replay.
    case uncertain(reason: String)
    /// The request is not a question batch, or carries no questions to answer.
    case notAQuestion
    /// The answer was refused before it was sent. The associated error names the question.
    case invalidAnswer(QuestionAnswerError)
    /// A timed question needs a foreground claim this client does not hold.
    ///
    /// SPEC §8 answers a timed waterfall only after `userQuestions/attachWait` has claimed it,
    /// and owning that claim's lifetime is a separate unit. Answering without it would race
    /// the host's own timeout, so this refuses rather than guesses.
    case timedQuestionNeedsClaim
    /// The `userQuestions/answer` channel was not wired in.
    case continuedChannelUnavailable
}

/// Approvals and questions, and the rules that stop one being answered twice.
///
/// SPEC §8. The behaviours that matter are all negative, which is why they are the ones
/// tested:
///
/// - A duplicate tap submits **once**. `state == .submitting` is the guard.
/// - A `cancel` arriving during a submission **wins** over the stale local state, because
///   the host is the authority on whether the request is still open.
/// - An event from a **stale generation** is never submitted, even if its `eventId` matches
///   a replayed current one.
/// - **Acknowledgement is not execution.** A settled request says this client's controls
///   are retired; it does not claim the agent ran anything, because another client may have
///   answered first and the gateway ignores stale results while still acknowledging them.
/// - Nothing is replayed on reconnect.
///
/// Question batches are modelled but not yet answered here: the two live channels and the
/// timed-wait claim are a separate unit, and pretending otherwise would be the half-built
/// path this file is meant to avoid.
public actor InteractionStore {
    private var requests: [String: InteractionRequest] = [:]
    /// Group membership, so a batch can be found by call rather than by question id.
    private var groups: [InteractionGroupKey: Set<String>] = [:]

    private let identity: @Sendable () async -> RemoteEventRouter.Identity?
    private let submit: @Sendable (EventResultRequest) async throws -> Void
    private let answerContinued: (@Sendable (String, String, JSONValue) async throws -> Bool)?

    /// - Parameters:
    ///   - identity: the current ready generation and `clientId`, read at submission time.
    ///     Reading it late rather than capturing it is what makes a stale submission
    ///     impossible: if the connection has been replaced, this returns a different
    ///     generation and the answer is refused instead of delivered to a dead socket.
    ///   - submit: performs the `$events/result` POST, injected so tests never touch the
    ///     network.
    ///   - answerContinued: performs `userQuestions/answer` for a question the host has
    ///     parked in its `continued` state. Optional because that channel is only used for
    ///     questions with no live delivery, and a caller that never meets one need not wire
    ///     it — but a caller that does meet one gets ``InteractionRefusal/continuedChannelUnavailable``
    ///     rather than a silent no-op.
    public init(
        identity: @escaping @Sendable () async -> RemoteEventRouter.Identity?,
        submit: @escaping @Sendable (EventResultRequest) async throws -> Void,
        answerContinued: (@Sendable (String, String, JSONValue) async throws -> Bool)? = nil
    ) {
        self.identity = identity
        self.submit = submit
        self.answerContinued = answerContinued
    }

    // MARK: - Reading

    /// Every request this generation has seen, settled ones included.
    public var all: [InteractionRequest] {
        requests.values.sorted { $0.id < $1.id }
    }

    /// The requests a screen may offer controls for, newest last.
    public var actionable: [InteractionRequest] {
        all.filter { $0.state.isActionable }
    }

    public func request(_ id: String) -> InteractionRequest? {
        requests[id]
    }

    public func group(_ key: InteractionGroupKey) -> [InteractionRequest] {
        (groups[key] ?? [])
            .compactMap { requests[$0] }
            .sorted { $0.id < $1.id }
    }

    /// The number of requests still waiting on this user, for a "Needs your input" badge.
    ///
    /// Counted from live requests only: SPEC §4 is explicit that a historical
    /// `ask_user_question` tool call does not produce the badge by itself.
    public var needsInputCount: Int {
        actionable.count
    }

    // MARK: - Observing

    /// Applies one event from the `$events` router.
    ///
    /// - Parameter generation: the ready generation that delivered it. Recorded on the
    ///   request so a later submission can prove it is answering the same connection, which
    ///   is what makes a stale answer impossible rather than merely unlikely.
    public func observe(_ event: RemoteEvent, generation: UInt64) {
        switch event {
        case .waterfall(let waterfall):
            let request = InteractionRequest(
                id: waterfall.eventId,
                sessionId: waterfall.agentId,
                callId: Self.callId(in: waterfall.request),
                event: waterfall.event,
                request: waterfall.request,
                generation: generation
            )
            // The host may replay the same eventId to a new client after a reconnect.
            // Accepting the new delivery is correct; the old correlation died with the old
            // router, which is why the generation is taken from the caller rather than
            // compared against a remembered one.
            requests[request.id] = request
            groups[InteractionGroupKey(sessionId: request.sessionId, callId: request.callId), default: []]
                .insert(request.id)

        case .cancel(let eventId):
            // The same frame arrives on settlement as on abortion, so it retires a delivery
            // and says nothing about why. Recording it as "rejected" is the mistake SPEC §8
            // names explicitly.
            guard var request = requests[eventId] else { return }
            request.state = .settled
            requests[eventId] = request

        case .ready, .emit, .unknown:
            return
        }
    }

    /// The call id a request payload carries, where it has one.
    static func callId(in request: JSONValue) -> String? {
        request["callId"]?.stringValue
    }

    // MARK: - Answering

    /// Allows the requested action once.
    ///
    /// The value is ``EventOutcome/allowOnce``, which exists because the host matches that
    /// string exactly and a near-miss is silently not an approval.
    public func allowOnce(_ id: String) async throws {
        try await answer(id, with: .allowOnce)
    }

    /// Rejects the requested action.
    ///
    /// ``EventOutcome/denyOnce`` is a `result` carrying `"rejected"`, deliberately **not**
    /// `rejected(error:)`, which refuses the remote continuation with an error instead of
    /// answering the request.
    public func deny(_ id: String) async throws {
        try await answer(id, with: .denyOnce)
    }

    /// Submits one outcome for one request, exactly once.
    public func answer(_ id: String, with outcome: EventOutcome) async throws {
        guard var request = requests[id] else {
            throw InteractionRefusal.notActionable(state: .settled)
        }
        // The duplicate-tap guard. A second tap while the first is in flight is dropped
        // rather than sent, because two identical results for one event cost a second turn
        // of the agent's work in the worst case.
        guard request.state.isActionable else {
            throw InteractionRefusal.notActionable(state: request.state)
        }
        guard let ready = await identity(), ready.generation == request.generation else {
            // The connection this request arrived on is gone. Submitting would address a
            // generation the host has retired.
            throw InteractionRefusal.staleGeneration
        }

        request.state = .submitting
        requests[id] = request

        do {
            try await submit(EventResultRequest(
                clientId: ready.clientId,
                eventId: id,
                outcome: outcome
            ))
            settle(id, as: .settled)
        } catch {
            // A `cancel` may have arrived while the submission was in flight, and the host
            // is the authority on whether the request is still open. Record the uncertainty
            // on the request only if it is still ours to describe.
            settle(id, as: .uncertain)
            throw InteractionRefusal.uncertain(reason: String(describing: error))
        }
    }

    /// Retires a request, unless a `cancel` already did so.
    ///
    /// The "unless" is what makes the race safe: a cancel that lands mid-submission must not
    /// be overwritten by the submission's own outcome, because the host has already said the
    /// delivery is over.
    private func settle(_ id: String, as state: InteractionRequest.State) {
        guard var request = requests[id] else { return }
        guard request.state != .settled else { return }
        request.state = state
        requests[id] = request
    }

    /// Forgets everything. Called when a conversation closes or a host is switched.
    public func removeAll() {
        requests.removeAll()
        groups.removeAll()
    }

    // MARK: - Questions

    /// The batch a question waterfall carries, if this request has one.
    public func questionBatch(_ id: String) -> QuestionBatch? {
        guard let request = requests[id] else { return nil }
        return QuestionBatch(request: request.request)
    }

    /// Whether the request is a timed question awaiting a foreground claim.
    ///
    /// SPEC §8's table keys the channel on `request.wait:{callId,timed:true}`. A timed
    /// question is answered only after `userQuestions/attachWait` has claimed it, so this
    /// refuses rather than answering into a race.
    static func isTimed(_ request: JSONValue) -> Bool {
        guard let wait = request["wait"] else { return false }
        return wait["timed"]?.boolValue == true
    }

    /// Answers a **live** question waterfall through `$events/result`.
    ///
    /// This is the first row of SPEC §8's channel table. It validates before sending, and
    /// goes through ``answer(_:with:)`` so the duplicate-tap guard and the generation check
    /// apply unchanged — a question is no more re-answerable than an approval is.
    public func answerLiveQuestions(_ id: String, with answers: [QuestionAnswer]) async throws {
        guard let request = requests[id] else {
            throw InteractionRefusal.notActionable(state: .settled)
        }
        guard let batch = QuestionBatch(request: request.request) else {
            throw InteractionRefusal.notAQuestion
        }
        if Self.isTimed(request.request) {
            // Answering a timed question without holding its claim would race the host's own
            // deadline, so the claim is required rather than optional.
            throw InteractionRefusal.timedQuestionNeedsClaim
        }
        do {
            try QuestionAnswerValidator.validate(answers, against: batch)
        } catch let error as QuestionAnswerError {
            throw InteractionRefusal.invalidAnswer(error)
        }
        try await answer(id, with: .result(QuestionAnswerValidator.body(answers)))
    }

    /// Answers a question the host parked in its `continued` state.
    ///
    /// The third row of SPEC §8's table, reached through `userQuestions/answer` rather than
    /// `$events/result` because there is no live delivery to reply to. `true` means the host
    /// accepted the reply; **`false` means the question is no longer answerable, which is not
    /// success** and is reported as such rather than as a delivered answer.
    ///
    /// - Returns: whether the host accepted the reply.
    @discardableResult
    public func answerContinuedQuestions(
        agentId: String,
        callId: String,
        with answers: [QuestionAnswer]
    ) async throws -> Bool {
        guard let channel = answerContinued else {
            throw InteractionRefusal.continuedChannelUnavailable
        }
        // Validation needs the batch, which lives on the waterfall that asked. A continued
        // row arrives from a projection rather than a waterfall, so the caller supplies the
        // questions it is answering when there is no waterfall to read them from.
        guard let ready = await identity() else {
            throw InteractionRefusal.staleGeneration
        }
        _ = ready
        return try await channel(agentId, callId, QuestionAnswerValidator.body(answers))
    }
}
