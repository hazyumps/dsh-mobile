import DSHRemoteKit
import Foundation
import Observation
import UIKit

/// Pairing, the selected host, and the state shared by the phone's screens.
///
/// Ownership follows SPEC §2: this is the composition root. It builds one coordinator
/// and one ``HostSessionStore`` per selected host, observes their snapshots on the main
/// actor, and publishes values the screens render. Views send intents and never create
/// sockets or interpret wire payloads.
@MainActor
@Observable
final class AppModel {
    private var idleStatus: ConnectionStatus = .pairingRequired
    var status: ConnectionStatus { recovery?.status ?? idleStatus }
    var connectionID: UUID? { recovery?.connectionID }
    var connectionError: String? { recovery?.error?.description }
    var hosts: [SavedHost] = []

    /// The host whose work is on screen. Nil means there is nothing to show but the
    /// pairing introduction; the shell switches on it.
    private(set) var selectedHost: SavedHost?

    /// What the browse screens render, mapped from the host store's snapshot.
    private(set) var browse: BrowseState = .idle

    /// Every decision this generation has delivered: approvals and questions.
    ///
    /// SPEC §8's routing is the only thing that can answer an approval, and a durable
    /// `tool/call` record in the transcript cannot: the transcript says what happened, this
    /// says what is still waiting.
    private(set) var interactions: [InteractionRequest] = []

    /// Where the user is. Persisted per host, separately from any draft (SPEC §5).
    private(set) var selectedWorkspaceId: String?
    private(set) var selectedSessionId: String?

    /// Result of reading a pasted pairing payload, shown beside the field.
    var pairingOutcome: PairingOutcome?

    /// What the phone calls itself at the relay. Editable, because the default
    /// is whatever the device is named and people pair more than one.
    var deviceName: String = UIDevice.current.name

    var isClaiming = false
    var claimError: String?

    private let clock: any EpochClock = SystemEpochClock()
    private let store = HostStore()
    private let secrets = KeychainSecretStore()
    private let drafts: DraftStore
    /// The origin the current host was connected with, kept so an interaction result can
    /// be posted on the same trust policy and credential as everything else.
    private var origin: ConnectionCoordinator.Origin?
    private var coordinator: ConnectionCoordinator?
    private var recovery: ForegroundConnection?
    private var hostStore: HostSessionStore?
    private var interactionStore: InteractionStore?
    private var statusTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var interactionsTask: Task<Void, Never>?
    private var selectionID = UUID()
    private var isForeground = false

    /// Raised when a chat action is attempted with no live connection. The
    /// coordinator reports *why* through ``status``; this only says the screen
    /// cannot act yet.
    enum ChatUnavailable: Error {
        case notConnected
    }

    /// Whether a launch should open the first host without a tap.
    ///
    /// Xcode 27 ships no Simulator GUI and `simctl` cannot inject touches, so
    /// there is no other way to reach the session list or the chat screen on a
    /// simulator. Debug builds only, and it changes nothing unless the variable
    /// is set. Read here rather than in the view because this file already
    /// imports Foundation.
    var shouldOpenFirstHostOnLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["DSH_OPEN_HOST"] != nil
        #else
        false
        #endif
    }

    /// Whether a launch should also open the first session, for the same reason:
    /// the chat screen is unreachable on a simulator without a tap.
    var shouldOpenFirstSessionOnLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["DSH_OPEN_SESSION"] != nil
        #else
        false
        #endif
    }

    /// A specific session to open instead of the first, for verifying one
    /// conversation rather than whatever happens to be newest.
    var launchSessionId: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["DSH_SESSION_ID"]
        #else
        nil
        #endif
    }

    /// Whether a launch should show the design-system gallery instead of the
    /// landing screen.
    ///
    /// The visual work has to be *looked at* to be reviewed, and this machine
    /// has no Simulator GUI — the same reason ``shouldOpenFirstHostOnLaunch``
    /// exists. Debug builds only, and it changes nothing unless the variable is
    /// set, so the shipping app's normal flow is untouched.
    var shouldShowDesignGalleryOnLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["DSH_DESIGN_GALLERY"] != nil
        #else
        false
        #endif
    }

    /// Whether a launch should render the browse screens from fixture data instead of
    /// a host.
    ///
    /// Same reason as the gallery, one level up: Home and the drawer only exist once a
    /// host has been paired and has answered, and a screenshot is the only way to review
    /// them on a machine with no Simulator GUI. Debug builds only.
    var shouldShowScreenGalleryOnLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["DSH_SCREEN_GALLERY"] != nil
        #else
        false
        #endif
    }

    /// A message to send once the conversation opens. Only ever set for
    /// verification, and only ever pointed at a scratch session: a duplicate or
    /// stray prompt costs real work, so this must not be aimed at a conversation
    /// somebody cares about.
    var launchMessage: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["DSH_SEND_MESSAGE"]
        #else
        nil
        #endif
    }

    init(draftsDirectory: URL? = nil) {
        hosts = store.load()
        drafts = DraftStore(directory: draftsDirectory ?? Self.defaultDraftsDirectory)
        if !hosts.isEmpty { idleStatus = .offline }
        // A host the user forgot must not stay selected on disk.
        store.reconcileSelection(with: hosts)
    }

    private static var defaultDraftsDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DSHRemote/Drafts", directoryHint: .isDirectory)
    }

    // MARK: - Host selection

    /// Opens the host the app was last using, so a cold launch lands on work rather
    /// than on the host list (UX spec, "Navigation and returning to work").
    ///
    /// Does nothing when a host is already selected: returning from the background is
    /// ``setForeground(_:)``'s job, not a second selection.
    func restoreLastHost() async {
        guard selectedHost == nil else { return }
        if shouldOpenFirstHostOnLaunch, let first = hosts.first {
            await select(first)
            return
        }
        guard let selection = store.loadSelection(),
              let host = hosts.first(where: { $0.id == selection.hostId })
        else { return }
        await select(host)
    }

    /// Makes a saved host current: one coordinator, one host store, one set of streams.
    func select(_ host: SavedHost) async {
        // Re-selecting the current host is a refresh, not a new connection: tearing a
        // live socket down to reconnect to the same host would drop the follow stream
        // and the streams the store has already opened, for nothing.
        if host.id == selectedHost?.id, coordinator != nil {
            await refreshSessions()
            return
        }

        let previous = recovery
        statusTask?.cancel()
        snapshotTask?.cancel()
        eventsTask?.cancel()
        interactionsTask?.cancel()
        recovery = nil
        coordinator = nil
        hostStore = nil
        // A decision belongs to the host that delivered it: switching hosts must not leave
        // another host's approval on screen, where it could be answered.
        interactionStore = nil
        interactions = []
        browse = .idle
        selectedHost = host
        selectionID = UUID()
        let selection = selectionID
        idleStatus = .connecting
        // Take the previous host's streams down before building the next one's, so the
        // two hosts never share a generation (SPEC §2, "one connection owner per host").
        await previous?.stop()
        guard selection == selectionID else { return }

        do {
            let token = try await secrets.secret(for: RelayDeviceCredential.account(hostUUID: host.id))
            guard selection == selectionID else { return }
            guard let token else { throw HostConnectionError.missingCredential }

            let origin = ConnectionCoordinator.Origin(
                baseURL: host.origin,
                authorization: .bearer(token),
                pinning: RelayPinningPolicy(
                    expectedSPKIPin: host.pinnedFingerprint,
                    requiresPlatformTrust: host.pinnedFingerprint == nil
                )
            )
            let coordinator = ConnectionCoordinator(origin: origin)
            self.origin = origin
            // The session index is read through a client this store owns rather than
            // through the coordinator's own `sessions()`, which owns a status policy: a
            // list failure must not demote a healthy connection (SPEC §3).
            let makeClient: @Sendable () -> DshRpcClient = {
                DshRpcClient(
                    baseURL: origin.baseURL,
                    authorization: origin.authorization,
                    transport: URLSessionRelayTransport(pinning: origin.pinning)
                )
            }
            let hostStore = HostSessionStore(coordinator: coordinator, makeRPCClient: makeClient)
            self.coordinator = coordinator
            self.hostStore = hostStore
            let recovery = ForegroundConnection(coordinator: coordinator)
            self.recovery = recovery

            observeStatus(of: coordinator, selection: selection)
            observeSnapshots(of: hostStore, selection: selection)
            try? store.saveSelection(HostSelection(hostId: host.id))
            await restoreNavigation(for: host)
            // After the stored destination, so an explicit launch target wins over it.
            applyLaunchSessionOverride()
            guard selection == selectionID else { return }
            recovery.setForeground(isForeground)
        } catch {
            guard selection == selectionID else { return }
            claimError = nil
            let reason = Self.reason(for: error)
            browse = BrowseState(
                workspaces: [],
                workspacesState: .failed(reason: reason),
                sessionsState: .failed(reason: reason)
            )
            idleStatus = .pairingRequired
        }
    }

    /// What to show the user for a failed selection.
    ///
    /// `String(describing:)` on a `LocalizedError` prints the case name — a missing
    /// credential read as "missingCredential" on screen. The readable form is the point
    /// of conformance, so use it when it exists.
    static func reason(for error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    /// The host store opens its streams the moment the connection is ready, and drops
    /// them when it is not. Reading `statusUpdates()` rather than polling `status` is
    /// what makes "an event arriving immediately after ready is not lost" true: the
    /// subscription is live before the first refresh runs.
    private func observeStatus(of coordinator: ConnectionCoordinator, selection: UUID) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await status in await coordinator.statusUpdates() {
                guard !Task.isCancelled else { return }
                await self?.apply(status: status, selection: selection)
            }
        }
    }

    private func apply(status: ConnectionStatus, selection: UUID) async {
        guard selection == selectionID else { return }
        guard status.isUsable, let hostStore, let coordinator else { return }
        // Both calls are idempotent for a generation that is already open, so a status
        // stream that repeats `connected` cannot open a second pair of streams.
        _ = await hostStore.start()
        await hostStore.refreshSessions()
        await subscribeToDecisions(of: coordinator, selection: selection)
    }

    /// Mounts the one `$events` consumer, and the store that turns its waterfalls into
    /// decisions this phone can answer (SPEC §8).
    ///
    /// The store is built once per selected host and survives a reconnect: an event replayed
    /// to a new generation overwrites the old request by `eventId`, and a submission from an
    /// abandoned generation is refused by the store's own generation check. What must be
    /// re-established on every ready connection is the *subscription*, because the router is
    /// per generation and the old one is retired with its socket.
    private func subscribeToDecisions(of coordinator: ConnectionCoordinator, selection: UUID) async {
        guard let router = await coordinator.remoteEvents() else { return }

        if interactionStore == nil {
            let origin = self.origin
            let submit: @Sendable (EventResultRequest) async throws -> Void = { request in
                guard let origin else { throw ChatUnavailable.notConnected }
                let client = DshBareEndpointClient(
                    baseURL: origin.baseURL,
                    authorization: origin.authorization,
                    transport: URLSessionRelayTransport(pinning: origin.pinning)
                )
                // Never retried: two identical results for one event cost a second turn of
                // the agent's work in the worst case (SPEC §8).
                try await client.submitEventResult(request, retryPolicy: .none)
            }
            let store = InteractionStore(
                identity: { await coordinator.remoteEvents()?.identity },
                submit: submit,
                answerContinued: { agentId, callId, body in
                    try await coordinator.answerContinued(agentId: agentId, callId: callId, body: body)
                }
            )
            interactionStore = store
            observeDecisions(of: store, selection: selection)
        }

        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in await router.events() {
                guard !Task.isCancelled else { return }
                await self?.deliver(event)
            }
        }
    }

    private func deliver(_ event: RemoteEvent) async {
        guard let interactionStore, let coordinator else { return }
        // Read from the router rather than from the coordinator's status: the router *is*
        // the generation, which is what makes a stale submission detectable at all.
        guard let generation = await coordinator.remoteEvents()?.identity.generation else { return }
        await interactionStore.observe(event, generation: generation)
    }

    private func observeDecisions(of store: InteractionStore, selection: UUID) {
        interactionsTask?.cancel()
        interactionsTask = Task { [weak self] in
            for await requests in await store.snapshots() {
                guard !Task.isCancelled else { return }
                guard let self, selection == self.selectionID else { return }
                self.interactions = requests
            }
        }
    }

    // MARK: - Decisions

    /// The approvals and questions waiting on this user, for one session.
    func decisions(for sessionId: String) -> [InteractionRequest] {
        interactions.filter { $0.sessionId == sessionId }
    }

    /// The live question waterfall for a tool call, when one is still open.
    ///
    /// SPEC §8's channel table turns on this: a question with a current delivery is answered
    /// through `$events/result`, and only one with no live channel uses
    /// `userQuestions/answer`. The transcript cannot tell the two apart.
    func liveQuestion(callId: String) -> InteractionRequest? {
        interactions.first { $0.callId == callId && $0.state.isActionable }
    }

    /// Allows an approval once. Returns a message to show when it could not be sent.
    func allowOnce(_ id: String) async -> String? {
        await submit { try await $0.allowOnce(id) }
    }

    /// Rejects an approval. Returns a message to show when it could not be sent.
    func deny(_ id: String) async -> String? {
        await submit { try await $0.deny(id) }
    }

    /// Answers a live question delivery through `$events/result`.
    func answerLive(_ id: String, with answers: [QuestionAnswer]) async -> String? {
        await submit { try await $0.answerLiveQuestions(id, with: answers) }
    }

    private func submit(_ work: (InteractionStore) async throws -> Void) async -> String? {
        guard let interactionStore else { return "This phone is not connected to the harness." }
        do {
            try await work(interactionStore)
            return nil
        } catch let refusal as InteractionRefusal {
            return Self.describe(refusal)
        } catch {
            return Self.reason(for: error)
        }
    }

    /// What an unanswered submission means, in the user's terms.
    ///
    /// A refusal is not a failure to report and forget: the request may have been settled by
    /// another client, in which case the card is history rather than something to retry.
    static func describe(_ refusal: InteractionRefusal) -> String {
        switch refusal {
        case .notActionable: "This request is no longer open."
        case .staleGeneration: "The connection changed before that was sent. It was not sent."
        case .timedQuestionNeedsClaim: "That question needs its wait claimed first."
        case .notAQuestion: "That request is not a question."
        case .invalidAnswer(let error): "That answer was refused before sending: \(error)"
        case .continuedChannelUnavailable: "This build cannot answer that question yet."
        case .refused(let code, let message): "The harness refused that (\(code)): \(message)"
        case .uncertain: "That may not have been sent. It will not be retried."
        }
    }

    private func observeSnapshots(of store: HostSessionStore, selection: UUID) {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            for await snapshot in await store.snapshots() {
                guard !Task.isCancelled else { return }
                self?.apply(snapshot: snapshot, selection: selection)
            }
        }
    }

    private func apply(snapshot: HostSessionStore.Snapshot, selection: UUID) {
        guard selection == selectionID else { return }
        let next = BrowseState.from(snapshot)
        browse = next
        // A selected workspace that this host does not have — a host switch, a renamed
        // registry — falls back rather than leaving the screens pointing at nothing.
        if let workspaceId = selectedWorkspaceId, next.workspace(id: workspaceId) == nil {
            selectedWorkspaceId = nil
        }
        if selectedWorkspaceId == nil {
            selectedWorkspaceId = next.workspaces.first?.id
            persistNavigation()
        }
    }

    /// Re-reads the session index. The host is not paginated, so one call is the index.
    func refreshSessions() async {
        await hostStore?.refreshSessions()
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        recovery?.setForeground(active)
    }

    // MARK: - Navigation

    func selectWorkspace(_ workspaceId: String) {
        guard selectedWorkspaceId != workspaceId else { return }
        selectedWorkspaceId = workspaceId
        persistNavigation()
    }

    func openSession(_ sessionId: String) {
        selectedSessionId = sessionId
        persistNavigation()
    }

    func closeSession() {
        guard selectedSessionId != nil else { return }
        selectedSessionId = nil
        persistNavigation()
    }

    private func restoreNavigation(for host: SavedHost) async {
        let saved = await drafts.navigation(for: host.id)
        selectedWorkspaceId = saved.workspaceId
        selectedSessionId = saved.sessionId
    }

    /// Debug builds only: open the session a launch names.
    ///
    /// This belongs here rather than in a view. It used to be a `.task` on Home that
    /// appended to the navigation path, and it silently did nothing — a launch target set
    /// during the first render races the `.task(id:)` that owns the path, and the screen
    /// stayed on Home with no error anywhere. Setting the selection once the host is
    /// chosose means the path has a single owner and the target is just state.
    private func applyLaunchSessionOverride() {
        #if DEBUG
        guard shouldOpenFirstSessionOnLaunch, let sessionId = launchSessionId else { return }
        selectedSessionId = sessionId
        #endif
    }

    private func persistNavigation() {
        guard let host = selectedHost else { return }
        let value = DraftNavigation(
            workspaceId: selectedWorkspaceId,
            sessionId: selectedSessionId,
            scrollAnchor: nil
        )
        let drafts = self.drafts
        Task { try? await drafts.setNavigation(value, for: host.id) }
    }

    // MARK: - Chat plumbing (until the conversation store owns it)

    /// The chat session for one conversation, or `nil` when there is no live connection.
    ///
    /// The screen cannot reach the coordinator itself: reading a conversation and
    /// writing to one are different capabilities (SPEC §4), and this is the seam
    /// that keeps them out of the view.
    func chatSession(for sessionId: String) async -> ChatSession? {
        guard status.isUsable, let coordinator else { return nil }
        return await ChatSession.connected(to: coordinator, sessionId: sessionId)
    }

    /// Sends a prompt. Never retried — an uncertain send is reported, not
    /// repeated, because a duplicate turn costs real work (SPEC §3.4).
    ///
    /// The submission identity is minted here, once, because this is the only place
    /// that knows a send is a *new* message rather than a retry of an uncertain one.
    /// When the draft store's send transaction lands (SPEC §5) it will capture this
    /// ID and hand it back unchanged on a retry, which is what lets the host
    /// deduplicate instead of admitting a second turn.
    func sendPrompt(_ text: String, to sessionId: String) async throws {
        guard status.isUsable, let coordinator else { throw ChatUnavailable.notConnected }
        try await coordinator.prompt(
            requestId: UUID().uuidString,
            sessionId: sessionId,
            text: text
        )
    }

    /// Answers a question the harness asked, so a session that needs a decision
    /// does not stall until somebody reaches a computer.
    ///
    /// Never retried, for the same reason a prompt is not: an answer delivered
    /// twice is worse than one reported as uncertain, because the agent may act
    /// on both (SPEC §3.4).
    func answerQuestion(
        sessionId: String,
        callId: String,
        questionId: String,
        selected: [String],
        custom: String? = nil
    ) async throws -> Bool {
        guard status.isUsable, let coordinator else { throw ChatUnavailable.notConnected }
        return try await coordinator.answer(
            agentId: sessionId,
            callId: callId,
            questionId: questionId,
            selected: selected,
            custom: custom
        )
    }

    // MARK: - Pairing

    /// What the user pasted, decoded and checked. The payload is untrusted
    /// input, so nothing here authorises anything — it only says what the
    /// payload claims, and whether it is well formed and unexpired.
    enum PairingOutcome: Equatable {
        case accepted(Summary)
        case refused(String)

        struct Summary: Equatable {
            var host: String
            var fingerprint: String?
            var code: String
            var expiresAt: Date
        }

        var summary: Summary? {
            if case .accepted(let summary) = self { return summary }
            return nil
        }
    }

    func inspect(pasted: String) {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pairingOutcome = nil
            return
        }
        guard let data = trimmed.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PairingPayload.self, from: data)
        else {
            pairingOutcome = .refused("That is not a pairing payload. Paste the JSON from the relay's pairing page.")
            return
        }
        do {
            try payload.validate(clock: clock)
        } catch {
            pairingOutcome = .refused(String(describing: error))
            return
        }
        let host = URL(string: payload.url)?.host() ?? payload.url
        pairingOutcome = .accepted(
            .init(
                host: host,
                fingerprint: payload.fingerprint,
                code: payload.code,
                expiresAt: Date(timeIntervalSince1970: Double(payload.expiresAt) / 1000)
            )
        )
    }

    /// Claim the one-time code, keep the token in the keychain, and remember the
    /// host. The code is never stored (SPEC §3.2 step 5).
    func claim(pasted: String) async {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PairingPayload.self, from: data),
              let origin = URL(string: payload.url)
        else {
            claimError = "That is not a pairing payload."
            return
        }
        claimError = nil
        isClaiming = true
        idleStatus = .connecting
        defer { isClaiming = false }

        // A pin from the payload is the trust anchor; without one the platform
        // must validate normally (SPEC §3.2 steps 3 and 4).
        let pinning = RelayPinningPolicy(
            expectedSPKIPin: payload.fingerprint,
            requiresPlatformTrust: payload.fingerprint == nil
        )
        let transport = URLSessionRelayTransport(pinning: pinning)
        let client = PairingClient(transport: transport)

        do {
            let claim = try await client.claim(payload, deviceName: deviceName)
            let host = SavedHost(
                displayName: URL(string: payload.url)?.host() ?? deviceName,
                origin: origin,
                pinnedFingerprint: payload.fingerprint ?? claim.fingerprint,
                relayDeviceId: claim.deviceId
            )
            try await secrets.setRelayDeviceToken(claim.token, forHostUUID: host.id)
            hosts.append(host)
            try store.save(hosts)
            pairingOutcome = nil
            idleStatus = .offline
            // Pairing is a deliberate act: land on the host that was just paired.
            await select(host)
        } catch let error as PairingError {
            claimError = error.readableReason ?? String(describing: error)
            idleStatus = hosts.isEmpty ? .pairingRequired : .offline
        } catch {
            claimError = String(describing: error)
            idleStatus = hosts.isEmpty ? .pairingRequired : .offline
        }
    }

    func forget(_ host: SavedHost) {
        let wasSelected = selectedHost?.id == host.id
        hosts.removeAll { $0.id == host.id }
        Task {
            try? await secrets.deleteRelayDeviceToken(forHostUUID: host.id)
        }
        Task {
            await drafts.remove(hostId: host.id)
        }
        try? store.reconcileSelection(with: hosts)
        if wasSelected { disconnect() }
        if hosts.isEmpty { idleStatus = .pairingRequired }
    }

    func disconnect() {
        statusTask?.cancel()
        snapshotTask?.cancel()
        eventsTask?.cancel()
        interactionsTask?.cancel()
        recovery?.setForeground(false)
        recovery = nil
        coordinator = nil
        origin = nil
        hostStore = nil
        interactionStore = nil
        interactions = []
        selectedHost = nil
        selectedWorkspaceId = nil
        selectedSessionId = nil
        browse = .idle
        selectionID = UUID()
        idleStatus = hosts.isEmpty ? .pairingRequired : .offline
    }

    // MARK: - Fixture seeding

    /// Sets the published state directly, for the screens gallery only.
    ///
    /// The setters of these properties are private to this file, which is what keeps a
    /// host store the only thing that can move them in the running app. The gallery
    /// exists because this machine has no Simulator GUI and Home is unreachable without a
    /// paired host, so it needs one narrow door — an explicit method, not loosened access.
    ///
    /// The only caller is `ScreensGalleryView`, and it is reached only through
    /// ``shouldShowScreenGalleryOnLaunch``.
    func seedForGallery(
        host: SavedHost,
        status: ConnectionStatus,
        browse: BrowseState,
        workspaceId: String?
    ) {
        selectedHost = host
        idleStatus = status
        self.browse = browse
        selectedWorkspaceId = workspaceId
    }
}

/// A saved host whose keychain entry is gone — the metadata survived a restore
/// but the credential did not. Re-pairing is the only fix, so say so.
enum HostConnectionError: LocalizedError {
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .missingCredential: "This host has no stored credential. Pair it again."
        }
    }
}
