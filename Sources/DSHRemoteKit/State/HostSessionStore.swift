import Foundation

// The host's workspace registry, session index, and live projection versions for one
// connection (SPEC §3.3, §4).
//
// `ConnectionCoordinator` owns *when* a host is usable and deliberately opens no
// application stream: its `activeStream()` doc says opening a stream for something it does
// not track "would be the 'late frames mutating the new conversation' hazard in the other
// direction". So the two streams SPEC §4 budgets one of each — `workspace/follow` and
// `session/control` — are opened and reduced here, alongside the unary `session/list`
// that fills the index between them.
//
// An actor, not a `@MainActor` class: SPEC §4 requires that "Network and reducer work must
// not block the main actor", and nothing this type holds is view state. What it publishes
// is a ``Snapshot``, which is `Sendable` by construction, so a screen can take one value
// and render it without holding the store.
public actor HostSessionStore {
    // MARK: - Endpoints

    /// `workspace/follow`, opened with empty args (`{}`).
    public static let workspaceEndpoint = "workspace/follow"
    /// `session/control`, opened with empty args (`{}`).
    public static let controlEndpoint = "session/control"
    /// The unary endpoint the session index comes from.
    ///
    /// Its arguments are `{"_request": {}}` — a leading underscore that is **per
    /// endpoint, not a convention** (SPEC §6.2) — so the envelope is built through
    /// ``RPCArguments`` rather than by hand. There is no cursor and no total in the reply,
    /// so one call is the whole index and there is nothing to page.
    public static let sessionListMethod = "session/list"
    /// The section title held by sessions no workspace claims.
    public static let ungroupedSectionTitle = "Ungrouped"

    /// A connection generation (SPEC §5, SPEC §6.5).
    public typealias Generation = ConnectionCoordinator.Generation

    /// The `workspace/follow` stream ID for one generation.
    ///
    /// Per generation, like `eventsStreamID(for:)`: `MuxClient` refuses an ID that is
    /// still registered, and making the ID generation-specific means a frame left over
    /// from an abandoned socket can never be read as the replacement's.
    public static func workspaceStreamID(for generation: Generation) -> String {
        "workspace-\(generation)"
    }

    /// The `session/control` stream ID for one generation.
    public static func controlStreamID(for generation: Generation) -> String {
        "control-\(generation)"
    }

    // MARK: - Workspaces

    /// One entry of the `workspace/follow` registry.
    ///
    /// The baseline carries `{"workspaceId","path","title","sessionIds"}`, and `upsert`
    /// carries the same object under `workspace`, so both decode through ``init(json:)``:
    /// one item shape, one decoder.
    ///
    /// IDs and paths are opaque. A workspace id is never derived from a title — the two
    /// are independent fields on the wire, a title is user-editable, and the id is what
    /// ``Section/workspaceId`` and every delta address.
    public struct Workspace: Sendable, Hashable, Identifiable {
        public var workspaceId: String
        public var path: String?
        public var title: String?
        /// The sessions the host says belong here. Membership is exactly this list, never
        /// a `cwd` match and never a title match.
        public var sessionIds: [String]

        public var id: String { workspaceId }

        /// The label a section can show: the host's title, else its path, else its id.
        public var displayTitle: String { title ?? path ?? workspaceId }

        public init(
            workspaceId: String,
            path: String? = nil,
            title: String? = nil,
            sessionIds: [String] = []
        ) {
            self.workspaceId = workspaceId
            self.path = path
            self.title = title
            self.sessionIds = sessionIds
        }

        /// Decodes one registry object. `workspaceId` is the only required field: it is
        /// the key every delta addresses, so an entry without one cannot be registered.
        init?(json: JSONValue) {
            guard let workspaceId = json["workspaceId"]?.stringValue, !workspaceId.isEmpty else {
                return nil
            }
            self.init(
                workspaceId: workspaceId,
                path: json["path"]?.stringValue,
                title: json["title"]?.stringValue,
                sessionIds: json["sessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
        }
    }

    // MARK: - Projections

    /// One `session/control` projection update, `{sessionId, key, value, seq}`.
    ///
    /// `seq` is kept beside the value because the two are one unit for the ordering rule:
    /// a strictly older value for the **same key** is ignored, and `seq` is what decides
    /// that. Nothing derives a version from arrival order.
    public struct Projection: Sendable, Hashable {
        public var key: String
        public var value: JSONValue
        public var seq: Int64

        public init(key: String, value: JSONValue, seq: Int64) {
            self.key = key
            self.value = value
            self.seq = seq
        }
    }

    // MARK: - Sessions

    /// One `session/list` row.
    ///
    /// The field list is the descriptor's own
    /// (`Protocol/schemas/dsh-api-session-controller.types.SessionListValue.json`):
    /// `sessionId`, `updatedAt`, `running`, `blank`, `agentAvailable`, and optional
    /// `parentSessionId`, `origin`, `cwd`, `projections`. It is deliberately wider than
    /// ``SessionSummary``, which models neither `parentSessionId` nor `origin`; this file
    /// may not change `Models/`, and silently dropping two keys the contract names would
    /// make the index lossy for a subagent child.
    ///
    /// Only `sessionId` is required. SPEC §5 lets a host omit metadata, and a missing
    /// `updatedAt` must not cost the client the whole list.
    public struct SessionRecord: Codable, Sendable, Hashable {
        public var sessionId: String
        /// Last activity, epoch milliseconds.
        public var updatedAt: Int64?
        public var running: Bool?
        /// A session with no user prompt yet.
        public var blank: Bool?
        public var agentAvailable: Bool?
        public var cwd: String?
        /// Set on a subagent child, naming its parent.
        public var parentSessionId: String?
        /// `"subagent"` on the wire, when the host sends it. Opaque: the descriptor fixes
        /// one literal, not a closed set.
        public var origin: String?
        /// The row's own `{kind, asOfSeq, values}` wrapper, as `session/list` sends it.
        ///
        /// Distinct from ``Snapshot/projections``, which are the per-key
        /// `session/control` updates: this one arrives with the list, that one with the
        /// control stream, and the two are never merged because a value's version belongs
        /// to whichever shape delivered it.
        public var projections: SessionProjections?

        /// The projected title `session/list` supplies, when it supplies one.
        public var title: String? { projections?.values?.title }

        public init(
            sessionId: String,
            updatedAt: Int64? = nil,
            running: Bool? = nil,
            blank: Bool? = nil,
            agentAvailable: Bool? = nil,
            cwd: String? = nil,
            parentSessionId: String? = nil,
            origin: String? = nil,
            projections: SessionProjections? = nil
        ) {
            self.sessionId = sessionId
            self.updatedAt = updatedAt
            self.running = running
            self.blank = blank
            self.agentAvailable = agentAvailable
            self.cwd = cwd
            self.parentSessionId = parentSessionId
            self.origin = origin
            self.projections = projections
        }
    }

    /// The `result.value` of `session/list`: `{"items": […]}`.
    ///
    /// No cursor and no total, so there is nothing to page: one call returns everything
    /// (the descriptor's object has exactly `items`).
    public struct SessionListValue: Codable, Sendable, Hashable {
        public var items: [SessionRecord]

        public init(items: [SessionRecord] = []) {
            self.items = items
        }
    }

    // MARK: - Snapshot

    /// One group of the session list: a workspace, or the ungrouped section.
    ///
    /// The members are ids rather than whole records so a section is cheap to compare and
    /// a record is looked up once, in ``Snapshot/sessions``.
    public struct Section: Sendable, Hashable, Identifiable {
        /// The workspace this group is, or `nil` for the ungrouped section.
        public var workspaceId: String?
        public var title: String
        public var sessionIds: [String]

        public var id: String { workspaceId ?? HostSessionStore.ungroupedSectionTitle }

        public init(workspaceId: String?, title: String, sessionIds: [String]) {
            self.workspaceId = workspaceId
            self.title = title
            self.sessionIds = sessionIds
        }
    }

    /// Everything this store knows, as one `Sendable` value.
    ///
    /// The three ``ResourceState``s are separate on purpose (SPEC §3: "A ready socket is
    /// not proof that the workspace list, transcript, or pending controls are current"),
    /// so a failed `session/list` cannot relabel the workspace registry and a control
    /// stream that has said nothing yet is not an empty one.
    public struct Snapshot: Sendable, Hashable {
        /// The generation the current streams belong to, once ``start()`` has one.
        public var generation: Generation?
        /// The registry, in the order the host set.
        public var workspaces: [Workspace]
        public var archivedSessionIds: [String]
        public var pinnedSessionIds: [String]
        /// The `session/list` index, keyed by session id.
        public var sessions: [String: SessionRecord]
        /// `session/control` updates, keyed by session id and then by projection key.
        public var projections: [String: [String: Projection]]
        /// The workspaces in registry order, then the ungrouped section when it has members.
        public var sections: [Section]
        public var workspacesState: ResourceState
        public var sessionsState: ResourceState
        public var controlState: ResourceState
    }

    // MARK: - State

    /// Which stream a frame was read from. The two endpoints deliver different unions, and
    /// neither is modelled in `Models/` (see ``applyWorkspace(_:generation:)``).
    private enum Stream {
        case workspaces
        case control

        var endpoint: String {
            switch self {
            case .workspaces: HostSessionStore.workspaceEndpoint
            case .control: HostSessionStore.controlEndpoint
            }
        }
    }

    private let coordinator: ConnectionCoordinator
    private let makeRPCClient: @Sendable () -> DshRpcClient

    private var generation: Generation?
    private var workspaces: [Workspace] = []
    private var archivedSessionIds: [String] = []
    private var pinnedSessionIds: [String] = []
    private var sessions: [String: SessionRecord] = [:]
    /// The order `session/list` reported, kept so the ungrouped section is stable rather
    /// than dictionary-ordered.
    private var sessionOrder: [String] = []
    /// `session/control` state, keyed by session id and projection key. The stored
    /// ``Projection/seq`` *is* the version for that key, so no second high-water table
    /// exists to drift out of step with the value it describes.
    private var projections: [String: [String: Projection]] = [:]

    /// Nothing has arrived yet: a load in flight with no data, which is the state the
    /// contract requires to be distinguishable from an empty success.
    private var workspacesState: ResourceState = .loading
    private var sessionsState: ResourceState = .loading
    private var controlState: ResourceState = .loading

    private var consumers: [Task<Void, Never>] = []
    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    /// - Parameters:
    ///   - coordinator: the connection whose mux the two streams are opened on, and whose
    ///     ``ConnectionStatus`` this store deliberately never writes.
    ///   - makeRPCClient: builds the unary client `session/list` is called with. Injected
    ///     rather than built here because the origin and transport are the composition
    ///     root's to choose, and injected rather than reached through
    ///     `ConnectionCoordinator.sessions()` because that path owns a status policy: it
    ///     may demote the connection for an offline or credential failure. A session-list
    ///     failure here must not change connection status, so this store must make its own
    ///     call — and a transport that is genuinely gone is reported by `$events`, not by
    ///     this endpoint.
    public init(
        coordinator: ConnectionCoordinator,
        makeRPCClient: @escaping @Sendable () -> DshRpcClient
    ) {
        self.coordinator = coordinator
        self.makeRPCClient = makeRPCClient
    }

    // MARK: - Reading

    /// The current state, as one value.
    public func snapshot() -> Snapshot {
        Snapshot(
            generation: generation,
            workspaces: workspaces,
            archivedSessionIds: archivedSessionIds,
            pinnedSessionIds: pinnedSessionIds,
            sessions: sessions,
            projections: projections,
            sections: Self.sections(
                workspaces: workspaces,
                sessions: sessions,
                projections: projections,
                listOrder: sessionOrder
            ),
            workspacesState: workspacesState,
            sessionsState: sessionsState,
            controlState: controlState
        )
    }

    /// Every snapshot from now on, starting with the current one.
    ///
    /// Cancelling the consumer removes its subscription. The current snapshot is yielded
    /// first so a screen that mounts after the workspace baseline still sees it.
    public func snapshots() -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream()
        subscribers[id] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func publish() {
        guard !subscribers.isEmpty else { return }
        let snapshot = snapshot()
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    // MARK: - Streams

    /// Opens `workspace/follow` and `session/control` for the coordinator's current
    /// generation, replacing both when the generation has moved on.
    ///
    /// Returns the generation the streams belong to, or `nil` while there is no ready
    /// connection — opening a stream for a generation that does not exist is the one thing
    /// the coordinator's `activeStream()` exists to prevent.
    ///
    /// A stream that opens after data has already arrived leaves that data on screen and
    /// marks it ``ResourceState/stale(reason:)`` rather than blanking it, which is the
    /// same rule a failed refresh follows.
    @discardableResult
    public func start() async -> Generation? {
        guard let handle = await coordinator.activeStream() else { return nil }
        if generation == handle.generation, !consumers.isEmpty { return handle.generation }

        await stopConsumers()
        generation = handle.generation

        do {
            let workspaceStream = try await handle.client.open(
                streamId: Self.workspaceStreamID(for: handle.generation),
                endpoint: Self.workspaceEndpoint
            )
            workspacesState = workspacesState.whileLoading
            consumers.append(Task { [weak self] in
                await self?.consume(workspaceStream, stream: .workspaces, generation: handle.generation)
            })

            let controlStream = try await handle.client.open(
                streamId: Self.controlStreamID(for: handle.generation),
                endpoint: Self.controlEndpoint
            )
            controlState = controlState.whileLoading
            consumers.append(Task { [weak self] in
                await self?.consume(controlStream, stream: .control, generation: handle.generation)
            })
        } catch {
            // One refusal is not evidence about the other stream, but neither can be
            // claimed to be current, and the generation is already recorded so the guard
            // still applies to anything a half-open pair delivers.
            let reason = Self.reason(for: error)
            workspacesState = workspacesState.afterFailure(reason: reason)
            controlState = controlState.afterFailure(reason: reason)
        }

        publish()
        return handle.generation
    }

    /// Cancels the consumers of a previous generation. Awaiting a cancelled consumer is
    /// safe here because the suspension releases the actor for it to finish.
    private func stopConsumers() async {
        let tasks = consumers
        consumers.removeAll()
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private func consume(
        _ stream: AsyncThrowingStream<MuxStreamItem, any Error>,
        stream kind: Stream,
        generation: Generation
    ) async {
        do {
            for try await item in stream {
                if Task.isCancelled { return }
                receive(item, stream: kind, generation: generation)
            }
            // A cancelled iteration can end without throwing, so cancellation is checked
            // again: a deliberate replacement must not be reported as a lost stream.
            if Task.isCancelled { return }
            streamEnded(kind, reason: "the host ended the \(kind.endpoint) stream", generation: generation)
        } catch {
            if Task.isCancelled { return }
            streamEnded(kind, reason: Self.reason(for: error), generation: generation)
        }
    }

    private func receive(_ item: MuxStreamItem, stream kind: Stream, generation: Generation) {
        switch item.frame.type {
        case .item:
            // `workspace/follow` and `session/control` values are outside the modelled
            // union on purpose — `MuxFrameValue` covers `session/follow` only — so the
            // whole value object, `type` included, arrives as `unknown`. Reading it back
            // through `unknownValue` is what keeps this file from adding cases to a model
            // whose fields no capture proves.
            guard let payload = item.frame.value?.unknownValue else { return }
            switch kind {
            case .workspaces: applyWorkspace(payload, generation: generation)
            case .control: applyControl(payload, generation: generation)
            }

        case .error:
            streamEnded(kind, reason: ConnectionCoordinator.describe(item.frame), generation: generation)

        case .end:
            streamEnded(kind, reason: "the host ended the \(kind.endpoint) stream", generation: generation)

        case .unknown:
            // A frame type this build does not classify. The socket is still the socket
            // (SPEC §5), so one unknown frame does not end the stream.
            return
        }
    }

    private func streamEnded(_ kind: Stream, reason: String, generation: Generation) {
        // The generation guard, copied from `RemoteEventRouter`'s contract: a late report
        // from an abandoned stream cannot mark the generation that replaced it.
        guard generation == self.generation else { return }
        switch kind {
        case .workspaces: workspacesState = workspacesState.afterFailure(reason: reason)
        case .control: controlState = controlState.afterFailure(reason: reason)
        }
        publish()
    }

    // MARK: - Workspaces

    /// Applies one `workspace/follow` item value.
    ///
    /// The wire shapes, from the contract and the descriptor:
    /// ```json
    /// {"type":"baseline","value":{"items":[{"workspaceId","path","title","sessionIds"}],
    ///                              "archivedSessionIds":[],"pinnedSessionIds":[]}}
    /// {"type":"upsert","workspace":{…}}   {"type":"remove","workspaceId":"…"}
    /// {"type":"order","workspaceIds":[…]} {"type":"archived","archivedSessionIds":[…]}
    /// {"type":"pinned","pinnedSessionIds":[…]}
    /// ```
    ///
    /// Internal rather than private so a test can drive the registry without a socket, and
    /// so the generation guard is exercised directly.
    ///
    /// - Returns: whether the frame was applied. `false` means the generation is stale or
    ///   the value is a shape this build does not act on, and the registry was not touched.
    @discardableResult
    func applyWorkspace(_ payload: JSONValue, generation: Generation) -> Bool {
        guard generation == self.generation, let type = payload["type"]?.stringValue else { return false }

        switch type {
        case "baseline":
            let value = payload["value"]
            workspaces = (value?["items"]?.arrayValue ?? []).compactMap(Workspace.init(json:))
            archivedSessionIds = value?["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            pinnedSessionIds = value?["pinnedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []

        case "upsert":
            // Replace in place, append when new. An update is not a reorder, so `order`
            // remains the only frame that moves a workspace.
            guard let workspace = payload["workspace"].flatMap(Workspace.init(json:)) else { return false }
            if let index = workspaces.firstIndex(where: { $0.workspaceId == workspace.workspaceId }) {
                workspaces[index] = workspace
            } else {
                workspaces.append(workspace)
            }

        case "remove":
            guard let workspaceId = payload["workspaceId"]?.stringValue else { return false }
            workspaces.removeAll { $0.workspaceId == workspaceId }

        case "order":
            guard let ids = payload["workspaceIds"]?.arrayValue?.compactMap(\.stringValue) else { return false }
            applyOrder(ids)

        case "archived":
            guard let ids = payload["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) else { return false }
            archivedSessionIds = ids

        case "pinned":
            guard let ids = payload["pinnedSessionIds"]?.arrayValue?.compactMap(\.stringValue) else { return false }
            pinnedSessionIds = ids

        default:
            return false
        }

        workspacesState = .afterSuccess(itemCount: workspaces.count)
        publish()
        return true
    }

    /// Reorders the registry to the host's sequence.
    ///
    /// An id the registry does not know is skipped, and a workspace the frame does not name
    /// keeps its relative position at the end rather than being dropped: `order` states a
    /// sequence, and a workspace missing from one frame is not a workspace removed.
    private func applyOrder(_ ids: [String]) {
        var remaining = Dictionary(workspaces.map { ($0.workspaceId, $0) }, uniquingKeysWith: { _, last in last })
        var ordered: [Workspace] = []
        for id in ids {
            if let workspace = remaining.removeValue(forKey: id) { ordered.append(workspace) }
        }
        ordered.append(contentsOf: workspaces.filter { remaining[$0.workspaceId] != nil })
        workspaces = ordered
    }

    // MARK: - Sessions

    /// Loads the host's session index with one unary `session/list` call.
    ///
    /// One call, no cursor: the reply is the whole index, so a success replaces it rather
    /// than merging into it. A failure keeps whatever was already loaded and only moves
    /// ``Snapshot/sessionsState`` — never the connection's status.
    public func refreshSessions() async {
        sessionsState = sessionsState.whileLoading
        publish()

        do {
            let client = makeRPCClient()
            let response = try await client.call(
                Self.sessionListMethod,
                args: RPCArguments(request: RPCEmptyRequest()),
                returning: SessionListValue.self
            )
            // A missing `value` is a success with no payload (SPEC §6.2), which for this
            // endpoint reads as "no sessions" rather than as a decode failure.
            let items = response.result.value?.items ?? []
            apply(items)
            sessionsState = .afterSuccess(itemCount: items.count)
        } catch {
            // The reason is user-facing text and never reaches diagnostics
            // (`ResourceState.failed(reason:)`). Nothing here touches the coordinator.
            sessionsState = sessionsState.afterFailure(reason: Self.reason(for: error))
        }

        publish()
    }

    /// Replaces the index with one `session/list` reply.
    private func apply(_ items: [SessionRecord]) {
        sessions = Dictionary(items.map { ($0.sessionId, $0) }, uniquingKeysWith: { _, last in last })
        sessionOrder = items.map(\.sessionId)
    }

    // MARK: - Control

    /// Applies one `session/control` item value.
    ///
    /// A `baseline` carries `value.projections` keyed by session id; each value is a
    /// `{kind, asOfSeq, values}` wrapper, and its `asOfSeq` orders **only the keys that
    /// wrapper supplies**. A delta is flat: `{"type":"projection","sessionId","key",
    /// "value","seq"}`.
    ///
    /// Internal rather than private for the same reason as
    /// ``applyWorkspace(_:generation:)``.
    ///
    /// - Returns: whether the frame was applied. `false` means a stale generation, an
    ///   unusable shape, or a value no newer than the one already held for that key.
    @discardableResult
    func applyControl(_ payload: JSONValue, generation: Generation) -> Bool {
        guard generation == self.generation, let type = payload["type"]?.stringValue else { return false }

        switch type {
        case "baseline":
            guard let supplied = payload["value"]?["projections"]?.objectValue else { return false }
            for (sessionId, wrapper) in supplied {
                // A wrapper that states no `asOfSeq` is applied at no version at all, so
                // any delta that carries one wins. That is the honest reading of a
                // baseline with nothing to order it by: it is older than every versioned
                // value, not newer than the first one.
                let asOfSeq = wrapper["asOfSeq"]?.intValue ?? .min
                for (key, value) in wrapper["values"]?.objectValue ?? [:] {
                    _ = applyProjection(sessionId: sessionId, key: key, value: value, seq: asOfSeq)
                }
            }

        case "projection":
            guard let sessionId = payload["sessionId"]?.stringValue,
                  let key = payload["key"]?.stringValue,
                  let seq = payload["seq"]?.intValue,
                  let value = payload["value"]
            else { return false }
            guard applyProjection(sessionId: sessionId, key: key, value: value, seq: seq) else {
                return false
            }

        default:
            return false
        }

        controlState = .afterSuccess(itemCount: projectionCount)
        publish()
        return true
    }

    /// Stores one projection value unless a newer one for *that key* is already held.
    ///
    /// The rule, and the reason it is per key rather than per session: several projection
    /// keys are republished at one `seq`, so a single high-water mark per session would
    /// discard every key after the first. A strictly older value is ignored; an equal one
    /// is accepted, because "ignore strictly older" is not "require strictly newer".
    private func applyProjection(sessionId: String, key: String, value: JSONValue, seq: Int64) -> Bool {
        if let known = projections[sessionId]?[key]?.seq, seq < known { return false }
        projections[sessionId, default: [:]][key] = Projection(key: key, value: value, seq: seq)
        return true
    }

    private var projectionCount: Int {
        projections.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Sections

    /// Groups the index by workspace membership.
    ///
    /// Membership is `workspace.sessionIds` and nothing else — not `cwd`, not a title. A
    /// workspace-member id the index has not heard of is still listed, because the
    /// registry is the authority on membership and a record may simply not have arrived
    /// yet. Every id the index or the control stream knows that no workspace claims goes
    /// in the named ungrouped section, which is present only when it has members.
    static func sections(
        workspaces: [Workspace],
        sessions: [String: SessionRecord],
        projections: [String: [String: Projection]],
        listOrder: [String]
    ) -> [Section] {
        var claimed = Set<String>()
        var sections: [Section] = []

        for workspace in workspaces {
            claimed.formUnion(workspace.sessionIds)
            sections.append(Section(
                workspaceId: workspace.workspaceId,
                title: workspace.displayTitle,
                sessionIds: workspace.sessionIds
            ))
        }

        let known = Set(sessions.keys).union(projections.keys)
        var ungrouped = listOrder.filter { known.contains($0) && !claimed.contains($0) }
        let listed = Set(ungrouped)
        ungrouped.append(contentsOf: known.subtracting(claimed).subtracting(listed).sorted())

        if !ungrouped.isEmpty {
            sections.append(Section(
                workspaceId: nil,
                title: ungroupedSectionTitle,
                sessionIds: ungrouped
            ))
        }
        return sections
    }

    // MARK: - Failures

    /// The user-facing reason for a failure, taken from the error's own readable text.
    ///
    /// Kept in one place so every state transition reports the same words, and so the one
    /// string that leaves this type through ``ResourceState`` has one author.
    static func reason(for error: any Error) -> String {
        if let failure = error as? ConnectionCoordinator.ConnectError { return failure.description }
        if let failure = error as? DshRPCError {
            return failure.readableReason ?? "the host refused the request"
        }
        return String(describing: error)
    }
}
