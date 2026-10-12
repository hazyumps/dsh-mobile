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

    /// The host's snapshot, kept for the values the browse mapping does not carry — its image
    /// limits being the first of them.
    /// The diagnostics this run has recorded, in memory only (SPEC §11).
    ///
    /// Nothing here writes to disk or to the system log on its own: the records exist until a
    /// person asks for the text, which is the text they are shown.
    private var diagnosticLog = DiagnosticLog()
    /// One UUID per connection attempt, so the records of a single attempt read together.
    private var connectionCorrelation = UUID()
    /// The last value recorded per subject, so a diagnostic line marks a *change* rather than
    /// repeating the same state on every status publish.
    private var lastResourceStates: [String: String] = [:]
    private var lastStatusName: String?
    /// When the current connect attempt began, so its duration can be recorded.
    private var connectStartedAt: Date?

    private var hostSnapshot: HostSessionStore.Snapshot?
    /// Projections read per session through `session/projections`, kept for the values the
    /// control stream does not carry — `imageLimits` being the one that mattered.
    private var sessionProjections: [String: SessionProjectionsValue] = [:]
    /// Images prepared for a session, waiting to ride the next prompt inline.
    private(set) var stagedImages: [String: [PromptImage]] = [:]
    /// What went wrong with the most recent image, in the user's terms.
    private(set) var imageError: String?
    private(set) var isPreparingImage = false

    /// Files uploaded for a session, waiting to be cited by the next prompt.
    ///
    /// Kept per session: SPEC §9 binds every upload to its draft, session, host and attachment
    /// id, and a receipt is scoped to the session runtime that received it.
    private(set) var stagedAttachments: [String: [UploadedAttachment]] = [:]
    /// What went wrong with the most recent attachment, in the user's terms.
    private(set) var attachmentError: String?
    private(set) var isUploading = false

    /// The commands the host advertises, per session (SPEC §9).
    private(set) var commands: [String: [CommandEntry]] = [:]
    /// What the last command said, when it had something to say.
    private(set) var commandMessage: String?

    /// The host's model, mode and permission catalog, once read.
    private(set) var catalog: ModelModeCatalog?
    private(set) var catalogState: ResourceState?
    /// The mode staged for the next new session, as the host's preset id.
    private(set) var stagedMode: String?
    /// The model staged for the next new session.
    private(set) var stagedModel: ModelSelection?

    /// The host's plugin inventory, once read. Nil until a read has happened, which is
    /// distinct from an inventory with no entries.
    private(set) var plugins: PluginInventory?
    private(set) var pluginsReport: SecondaryReport = .unknown
    /// The host's scheduled tasks, once read. Empty means the host has none.
    ///
    /// `scheduledTasks/list`, not `schedule/catalog`: the latter is served only by the
    /// experimental schedule bundle, which this host does not load, so every call 404s
    /// (PUSH-NOTIFICATIONS-SPEC §1).
    private(set) var scheduledTasks: [ScheduledTask] = []
    private(set) var scheduledTasksReport: SecondaryReport = .unknown

    /// Every decision this generation has delivered: approvals and questions.
    ///
    /// SPEC §8's routing is the only thing that can answer an approval, and a durable
    /// `tool/call` record in the transcript cannot: the transcript says what happened, this
    /// says what is still waiting.
    private(set) var interactions: [InteractionRequest] = []

    /// Whether a first prompt is being created and sent right now.
    private(set) var isStartingSession = false
    /// What went wrong with the most recent new-session attempt, in the user's terms.
    private(set) var newSessionError: String?

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
    private var secondaryStore: SecondaryReadStore?
    private var modelModeStore: ModelModeCatalogStore?
    private var commandStore: CommandCatalogStore?
    private var attachmentUploader: AttachmentUploader?
    private var attachmentReader: AttachmentReader?
    /// Decoded images, so a scrolling transcript does not re-decode what it just drew.
    private let imageCache = SessionImageCache()
    private var interactionStore: InteractionStore?
    private var statusTask: Task<Void, Never>?
    /// The phone's own reminders for scheduled tasks. Owned here rather than by the screen so
    /// they survive leaving it, and so a tap can be routed through the same navigation state
    /// as everything else.
    let taskNotifications = TaskNotificationScheduler()
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

    /// Which drawer destination a launch should open: `plugins` or `schedules`.
    ///
    /// The same reason as ``launchSessionId``: `simctl` cannot tap, so a screen reachable
    /// only through the drawer is otherwise unreviewable on this machine. Debug only.
    var launchDestination: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["DSH_DESTINATION"]
        #else
        nil
        #endif
    }

    /// A model a launch should stage for the next new session, as `provider/model` or
    /// `provider/model/effort`.
    ///
    /// Same reason as the other launch affordances: choosing a model needs a tap this machine
    /// cannot make. Debug builds only.
    var launchModel: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["DSH_MODEL"]
        #else
        nil
        #endif
    }

    /// An agent preset a launch should stage for the next new session, by roster id.
    ///
    /// Debug builds only, like the model override.
    var launchMode: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["DSH_MODE"]
        #else
        nil
        #endif
    }

    /// A first prompt for a *new* session, sent once a workspace is known.
    ///
    /// Same reason as the other launch affordances: creating a session needs a tap this
    /// machine cannot make. Point it at a scratch workspace, because it does create a real
    /// session and run one real turn. Debug builds only.
    var launchNewSessionMessage: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["DSH_NEW_SESSION_MESSAGE"]
        #else
        nil
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
        secondaryStore = nil
        plugins = nil
        pluginsReport = .unknown
        scheduledTasks = []
        scheduledTasksReport = .unknown
        modelModeStore = nil
        commandStore = nil
        attachmentUploader = nil
        attachmentReader = nil
        stagedAttachments = [:]
        attachmentError = nil
        stagedImages = [:]
        imageError = nil
        hostSnapshot = nil
        sessionProjections = [:]
        commands = [:]
        commandMessage = nil
        catalog = nil
        catalogState = nil
        stagedMode = nil
        stagedModel = nil
        // A decision belongs to the host that delivered it: switching hosts must not leave
        // another host's approval on screen, where it could be answered.
        interactionStore = nil
        interactions = []
        browse = .idle
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
                // Built here rather than as a shared constant: `URLSessionConfiguration` is not
                // `Sendable`, and the transport is constructed per call anyway.
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = Self.readTimeoutSeconds
                configuration.timeoutIntervalForResource = 60
                return DshRpcClient(
                    baseURL: origin.baseURL,
                    authorization: origin.authorization,
                    transport: URLSessionRelayTransport(
                        configuration: configuration,
                        pinning: origin.pinning
                    )
                )
            }
            let hostStore = HostSessionStore(coordinator: coordinator, makeRPCClient: makeClient)
            // The capability ledger lives with the store, so a 404 learned on one screen
            // suppresses the request on the next (SPEC §10).
            self.secondaryStore = SecondaryReadStore(makeClient: makeClient)
            self.modelModeStore = ModelModeCatalogStore(makeClient: makeClient)
            self.commandStore = CommandCatalogStore(makeClient: makeClient)
            self.attachmentReader = AttachmentReader(makeClient: makeClient)
            self.attachmentUploader = AttachmentUploader(
                makeBareClient: {
                    DshBareEndpointClient(
                        baseURL: origin.baseURL,
                        authorization: origin.authorization,
                        transport: URLSessionRelayTransport(pinning: origin.pinning)
                    )
                },
                makeRPCClient: makeClient
            )
            self.coordinator = coordinator
            self.hostStore = hostStore
            let recovery = ForegroundConnection(coordinator: coordinator)
            self.recovery = recovery

            // Published only now, so a screen's `.task` cannot run against a host whose
            // stores do not exist yet — which is exactly what left the Plugins screen
            // reading a store that was still nil, with nothing to retry it.
            selectedHost = host

            observeStatus(of: coordinator, selection: selection)
            observeSnapshots(of: hostStore, selection: selection)
            try? store.saveSelection(HostSelection(hostId: host.id))
            await restoreNavigation(for: host)
            // After the stored destination, so an explicit launch target wins over it.
            applyLaunchSessionOverride()
            // After both, so a notification tap beats the restored conversation: the user
            // asked for that screen, the restore is a convenience.
            replayDeferredNotification()
            guard selection == selectionID else { return }
            recovery.setForeground(isForeground)
        } catch {
            guard selection == selectionID else { return }
            claimError = nil
            selectedHost = host
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

    /// How long an ordinary read waits, in seconds.
    ///
    /// `URLSession`'s default request timeout is a minute, so a read the host never answers
    /// leaves a screen on its spinner for a minute — indistinguishable from a screen that is
    /// simply broken, and what the Plugins and Usage screens looked like on a phone while the
    /// harness answered the same call instantly over loopback. Twenty seconds is long enough
    /// for a slow LAN and short enough that a failure arrives as a message. Uploads keep the
    /// default: a large file legitimately takes longer than this.
    nonisolated static let readTimeoutSeconds: TimeInterval = 20

    private func apply(status: ConnectionStatus, selection: UUID) async {
        guard selection == selectionID else { return }
        // Recorded before the usability guard: a connection that failed to become usable is
        // exactly the thing a later diagnostic report is about.
        record(status: status, generation: await coordinator?.remoteEvents()?.identity.generation)
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
        guard let router = await coordinator.remoteEvents() else {
            // Nothing to subscribe to means no decisions will ever arrive on this connection.
            // That is worth saying out loud, because the failure looks like a quiet list.
            DSHBeacon.note("subscribeToDecisions: no events router for this generation")
            return
        }
        DSHBeacon.note("subscribed to $events")

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
                },
                // A timed question is answerable only while this phone holds its claim, so the
                // store asks the claim rather than trusting the caller (SPEC §8).
                holdsTimedClaim: { [weak self] eventId in
                    await self?.holdsTimedClaim(eventId) ?? false
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
        DSHBeacon.event(event)
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
                // A live request is a "needs input" signal the projections cannot carry, so the
                // cards are rebuilt from the snapshot already held rather than waiting for the
                // next one — otherwise the badge would lag the request that caused it.
                self.rebuildBrowse()
            }
        }
    }

    // MARK: - Decisions

    /// The approvals and questions waiting on this user, for one session.
    func decisions(for sessionId: String) -> [InteractionRequest] {
        interactions.filter { $0.sessionId == sessionId }
    }

    /// The questions a live waterfall carries, for a caller that has to answer without a card.
    func questionBatch(for id: String) async -> QuestionBatch? {
        await interactionStore?.questionBatch(id)
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

    /// Retires the live deliveries for a session whose turn was stopped.
    ///
    /// Local only, and deliberately so: the host was told nothing about these requests, because
    /// there is nothing to tell it. They are over because the work that asked them is, and the
    /// host's own `cancel` is what ended it.
    func withdrawQuestions(sessionId: String) async {
        await interactionStore?.withdraw(sessionId: sessionId)
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

    // MARK: - Starting a session (SPEC §5)

    /// The draft a new session in this workspace belongs to.
    ///
    /// One per workspace, held for the life of the process: the *draft* is what persists, and
    /// its identity is what makes two new drafts in one workspace unable to overwrite each
    /// other. Re-creating this UUID each time would defeat the storage key that exists to
    /// prevent exactly that.
    private var newSessionDraftIds: [String: UUID] = [:]
    /// Set once a launch-triggered new session has been started, so a later snapshot cannot
    /// start a second one.
    private var didStartLaunchSession = false

    /// Whether the composer can start a new session where the user is.
    var canStartSession: Bool {
        status.isUsable && selectedHost != nil && selectedWorkspaceId != nil
    }

    /// Creates a session in the selected workspace and sends the first prompt.
    ///
    /// The order is SPEC §5's, and each step is there for a failure it prevents:
    ///
    /// 1. the identity is **persisted before the request**, so a lost response still leaves
    ///    the phone able to adopt what the host may have made rather than make a second one;
    /// 2. the create is sent **once**, with that identity, and never re-sent automatically;
    /// 3. a partial success is reconciled — the session exists, so it is opened and the
    ///    attachment problem reported — instead of being retried as a fresh create;
    /// 4. the prompt reuses the submission identity already on disk, which is the value the
    ///    host deduplicates on.
    ///
    /// Nothing here resends anything on a reconnect. An uncertain outcome keeps the draft and
    /// says so.
    @discardableResult
    func startSession(workspaceId: String, text: String) async -> String? {
        guard let coordinator, let host = selectedHost else {
            newSessionError = "This phone is not connected to a harness."
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            newSessionError = "A first prompt needs something to say."
            return nil
        }

        isStartingSession = true
        newSessionError = nil
        defer { isStartingSession = false }

        let draftId = newSessionDraftIds[workspaceId] ?? UUID()
        newSessionDraftIds[workspaceId] = draftId
        let key = DraftKey(hostId: host.id, owner: .newSession(draftId))

        // The identity, chosen here and written before the request goes out.
        let existing = await drafts.draft(for: key)
        let sessionId = existing.proposedSessionId ?? "session-\(UUID().uuidString)"
        _ = await drafts.setWorkspace(workspaceId, for: key)
        _ = await drafts.setText(trimmed, for: key)
        _ = await drafts.setProposedSessionId(sessionId, for: key)
        let draft = await drafts.draft(for: key)
        let submission = await drafts.beginSubmission(requestId: UUID().uuidString, for: key)
        try? await drafts.flush()

        do {
            let outcome = try await coordinator.createSession(
                sessionId: sessionId,
                workspaceId: workspaceId,
                // SPEC §6 stages the mode before creation, so the session starts in it
                // rather than being switched afterwards. `nil` is the host's own default.
                agentPreset: stagedMode
            )
            switch outcome {
            case .created(let created):
                // Bound before anything else: the screen and the draft follow the identity
                // the host confirmed, not the one that was proposed.
                openSession(created.sessionId)

                // The model goes on before the prompt, and a refusal stops the prompt:
                // SPEC §6 is explicit that a failed selection must not be followed by a
                // submission on a different model from the one the user chose.
                if let staged = stagedModel {
                    do {
                        let applied = try await applyModel(staged, to: created.sessionId)
                        stagedModel = applied
                    } catch let refusal as SelectionRefusal {
                        newSessionError = "The session was created, but the model could not be changed: \(Self.describe(refusal)) Nothing was sent."
                        return created.sessionId
                    } catch {
                        newSessionError = "The session was created, but the model could not be changed: \(Self.reason(for: error)) Nothing was sent."
                        return created.sessionId
                    }
                }

                await send(first: trimmed, requestId: submission.requestId, to: created.sessionId, draft: draft, key: key)
                return created.sessionId

            case .attachmentFailed(let reconciled, let reason):
                // SPEC §5: the session may already exist, so it is reconciled and the
                // attachment problem is shown. Creating another one would leave a duplicate.
                let identity = reconciled ?? sessionId
                openSession(identity)
                newSessionError = "The session was created but its workspace could not be attached: \(reason)"
                return identity
            }
        } catch {
            newSessionError = Self.reason(for: error)
            return nil
        }
    }

    /// Applies a model selection and returns the host's **normalized** answer.
    ///
    /// The host's answer is what is kept, not the request echoed back: SPEC §6 notes the host
    /// resolves the request through its own call-config path, so only its response says what
    /// is actually selected.
    private func applyModel(_ selection: ModelSelection, to sessionId: String) async throws -> ModelSelection {
        guard let modelModeStore else { throw SelectionRefusal.transport(reason: "no catalog is loaded") }
        return try await modelModeStore.selectModel(
            sessionId: sessionId,
            provider: selection.provider,
            model: selection.model,
            reasoningEffort: selection.reasoningEffort
        )
    }

    /// Sends the first prompt, clearing only the revision that was submitted.
    private func send(
        first text: String,
        requestId: String,
        to sessionId: String,
        draft: Draft,
        key: DraftKey
    ) async {
        guard let coordinator else { return }
        do {
            try await coordinator.prompt(requestId: requestId, sessionId: sessionId, text: text)
            // Acceptance clears exactly the revision sent; text typed while it was in flight
            // survives, because that is a different revision.
            _ = await drafts.clearSubmitted(revision: draft.revision, for: key)
            try? await drafts.flush()
        } catch {
            // The session exists and is on screen; only the first prompt's fate is unknown.
            // The draft stays so the text can be retried deliberately, and the transaction is
            // never replayed automatically.
            newSessionError = "The session was created, but that message may not have been sent. It will not be resent."
        }
    }

    // MARK: - Secondary reads (SPEC §10)

    /// Reads the host's plugin inventory.
    ///
    /// Read-only on purpose: installing, enabling or removing a plugin is a mutation with
    /// its own consequences, and `managementAvailable` is reported rather than acted on.
    func loadPlugins() async {
        guard let secondaryStore else { return }
        pluginsReport = .loading
        let outcome = await secondaryStore.loadPluginInventory()
        plugins = await secondaryStore.pluginInventory
        pluginsReport = await Self.report(
            outcome,
            endpoint: SecondaryReadStore.pluginInventoryMethod,
            store: secondaryStore
        )
        recordResourceStates()
    }

    /// Turns a read's outcome into what the screen should say.
    ///
    /// A read that failed *because the host has no such endpoint* is not a failure to retry:
    /// the store records that in its ledger, and SPEC §10 keeps "unavailable" and "failed"
    /// apart because only one of them is worth another attempt. The store's own outcome
    /// cannot express both facts at once, so the ledger supplies the second half here.
    private static func report(
        _ outcome: SecondaryReadOutcome,
        endpoint: String,
        store: SecondaryReadStore
    ) async -> SecondaryReport {
        if case .failed = outcome,
           case .unavailable(let reason) = await store.capabilityLedger.state(of: endpoint) {
            return SecondaryReport(kind: .unavailable, detail: reason)
        }
        return SecondaryReport(outcome)
    }

    /// Reads the host's scheduled tasks, then re-plans the phone's own reminders from them.
    ///
    /// A host without `scheduledTasks/*` answers 404, which the store records as
    /// *unavailable* rather than as a failure — and that is what this screen shows.
    ///
    /// The re-plan is here rather than on the screen because the catalog has no stream: it is
    /// read on entry and on pull-to-refresh, and every read is a chance to notice that a task
    /// was edited on the desktop, so it is also the only place a stale reminder can be
    /// corrected.
    func loadScheduledTasks() async {
        guard let secondaryStore else { return }
        scheduledTasksReport = .loading
        let outcome = await secondaryStore.loadScheduledTasks()
        scheduledTasks = await secondaryStore.scheduledTasks
        scheduledTasksReport = await Self.report(
            outcome,
            endpoint: SecondaryReadStore.scheduledTasksListMethod,
            store: secondaryStore
        )
        recordResourceStates()
        let plan = TaskNotificationPlan.build(tasks: scheduledTasks, now: Date())
        #if DEBUG
        // `DSH_TRACE=1` prints this to stdout, which `simctl launch --console-pty` shows. The
        // plan is otherwise invisible: a simulator cannot be granted notification permission,
        // so the pending requests it produces can never be observed there.
        DSHBeacon.note("scheduledTasks tasks=\(scheduledTasks.count) plan=\(plan.count) auth=\(taskNotifications.authorization.rawValue) report=\(scheduledTasksReport.kind)")
        #endif
        await taskNotifications.apply(plan: plan)
    }

    // MARK: - Model and mode (SPEC §6)

    /// Reads the model, mode and permission catalogs.
    ///
    /// The permission catalog is best-effort inside the store: a host without it is a missing
    /// optional section, not a reason to fail the picker the user actually opened.
    func loadModelCatalog() async {
        guard let modelModeStore else { return }
        catalogState = (catalogState ?? .loading).whileLoading
        do {
            catalog = try await modelModeStore.refresh()
            catalogState = .current
            applyLaunchModeOverride()
            applyLaunchModelOverride()
        } catch let refusal as SelectionRefusal {
            catalogState = .failed(reason: Self.describe(refusal))
        } catch {
            catalogState = .failed(reason: Self.reason(for: error))
        }
    }

    /// What a new session would run on if nothing were staged: the host's own default.
    var effectiveMode: ModeOption? {
        catalog?.modes.first { $0.id == stagedMode } ?? catalog?.defaultMode
    }

    var effectiveModel: ModelOption? {
        let selection = stagedModel ?? catalog?.defaultSelection
        guard let selection else { return nil }
        return catalog?.option(for: selection)
    }

    /// Stages an agent preset for the next new session. Local only, like opening a draft.
    func stageMode(_ presetId: String) {
        stagedMode = presetId
        persistStagedSelection()
    }

    /// Stages a model for the next new session.
    func stageModel(_ selection: ModelSelection) {
        stagedModel = selection
        persistStagedSelection()
    }

    /// Writes the staged pair into the workspace's new-session draft.
    ///
    /// SPEC §5 keeps a draft's staged mode and model with the text, so a relaunch restores
    /// what the user had chosen rather than silently reverting to the host default.
    private func persistStagedSelection() {
        guard let host = selectedHost, let workspaceId = selectedWorkspaceId else { return }
        let draftId = newSessionDraftIds[workspaceId] ?? UUID()
        newSessionDraftIds[workspaceId] = draftId
        let key = DraftKey(hostId: host.id, owner: .newSession(draftId))
        let selection = stagedModel ?? catalog?.defaultSelection
        let drafts = self.drafts
        Task {
            _ = await drafts.setSelection(
                agentPreset: stagedMode,
                modelProvider: selection?.provider,
                model: selection?.model,
                reasoningEffort: selection?.reasoningEffort,
                for: key
            )
            try? await drafts.flush()
        }
    }

    /// An effort choice for a staged model, when the host advertises them.
    func stageEffort(_ effort: String?) {
        guard var selection = stagedModel ?? catalog?.defaultSelection else { return }
        selection.reasoningEffort = effort
        stageModel(selection)
    }

    // MARK: - Commands (SPEC §9)

    /// Reads a session's commands. Cached until the session or preset changes.
    func loadCommands(for sessionId: String) async {
        guard let commandStore else { return }
        if commands[sessionId] != nil { return }
        commands[sessionId] = (try? await commandStore.commands(for: sessionId)) ?? []
    }

    /// The command a draft line names, if the host advertises one.
    ///
    /// SPEC §9: unknown slash input uses the ordinary prompt path, so this returning `nil` is
    /// not an error — it is the answer that sends the text as a normal message.
    func registeredCommand(for line: String, in sessionId: String) -> CommandEntry? {
        commands[sessionId]?.first { $0.matches(line: line) }
    }

    /// Runs a registered command.
    ///
    /// A write, so nothing here retries it. A refusal keeps the text — the caller owns the
    /// draft — and refreshes the list, which SPEC §9 names as the command-refused path.
    @discardableResult
    func runCommand(_ line: String, in sessionId: String) async -> CommandOutcome? {
        guard let commandStore else { return nil }
        commandMessage = nil
        do {
            let outcome = try await commandStore.execute(agentId: sessionId, line: line)
            if case .refused = outcome {
                await commandStore.invalidate(sessionId)
                commands[sessionId] = (try? await commandStore.commands(for: sessionId)) ?? commands[sessionId]
            }
            commandMessage = outcome.text
            return outcome
        } catch {
            commandMessage = Self.reason(for: error)
            return nil
        }
    }

    // MARK: - Attachments (SPEC §9)

    /// Uploads one prepared file into a session and stages its receipt.
    ///
    /// Nothing is retried and nothing is discarded on failure: SPEC §9 keeps the prepared bytes
    /// so the user does not have to pick the file again, and an uncertain upload is reconciled
    /// rather than replayed.
    @discardableResult
    func attachFile(at fileURL: URL, name: String? = nil, to sessionId: String) async -> UploadedAttachment? {
        guard let attachmentUploader else {
            attachmentError = "This phone is not connected to a harness."
            return nil
        }
        isUploading = true
        attachmentError = nil
        defer { isUploading = false }

        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        do {
            let uploaded = try await attachmentUploader.upload(
                sessionId: sessionId,
                name: name ?? fileURL.lastPathComponent,
                fileURL: fileURL,
                byteCount: size
            )
            stagedAttachments[sessionId, default: []].append(uploaded)
            return uploaded
        } catch let failure as AttachmentUploadFailure {
            attachmentError = Self.describe(failure)
            return nil
        } catch {
            attachmentError = Self.reason(for: error)
            return nil
        }
    }

    /// What an upload failure means, in the user's terms.
    static func describe(_ failure: AttachmentUploadFailure) -> String {
        switch failure {
        case .tooLargeForFallback(let bytes, let limit):
            "This host has no direct upload route and \(bytes) bytes is over the \(limit)-byte limit for the fallback."
        case .noReceipt:
            "The harness accepted the file but named no receipt, so nothing could cite it."
        case .refused(let code, let message):
            "The harness refused that file (\(code)): \(message)"
        case .transport(let reason):
            "That upload may not have arrived: \(reason)"
        }
    }

    func clearAttachments(for sessionId: String) {
        stagedAttachments[sessionId] = nil
        attachmentError = nil
    }

    // MARK: - Reading attachments back (SPEC §6.8)

    /// An attachment's pixels, decoded for display and cached.
    ///
    /// The host validates that an attachment belongs to the session asking for it, so the
    /// lookup is scoped by both — the cache keys on the pair for the same reason.
    func attachmentImage(sessionId: String, attachmentId: String) async -> DisplayImage? {
        guard let attachmentReader else { return nil }
        return try? await imageCache.image(
            sessionId: sessionId,
            attachmentId: attachmentId,
            fetch: attachmentReader.fetcher
        )
    }

    /// An attachment's bytes, for a caller that wants to inspect or share them.
    func attachmentData(sessionId: String, attachmentId: String) async -> Data? {
        try? await attachmentReader?.attachment(sessionId: sessionId, attachmentId: attachmentId).data
    }

    // MARK: - Inline images (SPEC §9)

    /// The image limits the host advertises for a session.
    ///
    /// Nil when the host has not projected them, and nil means *no image sending* rather than
    /// a guessed limit: the whole point of reading them is that they are the host's numbers.
    func imageLimits(for sessionId: String) -> ImageLimits? {
        if let projected = sessionProjections[sessionId]?.values.imageLimits {
            return ImageLimits(projected)
        }
        // The control stream's copy, when it has one. It is the fallback rather than the
        // source because the installed host's baseline carried `modelSelection` but not
        // `imageLimits` for the sessions seen on 2026-10-09.
        return hostSnapshot?.projections[sessionId]?["imageLimits"].flatMap { ImageLimits(json: $0.value) }
    }

    /// One session's usage, from the projections `session/projections` returns (SPEC §10).
    ///
    /// Read through the same call the image limits use, and nil until it has answered: an empty
    /// screen that says "not reported" is honest, a screen of zeros would not be.
    func usage(for sessionId: String) -> SessionUsage? {
        if let projected = sessionProjections[sessionId] {
            var values = projected.values.additionalProperties
            // The typed subset wins where it overlaps, so one source of truth per key.
            if let inbox = projected.values.inbox { values["inbox"] = .object([:]) ; _ = inbox }
            return SessionUsage(projections: values)
        }
        guard let snapshot = hostSnapshot?.projections[sessionId] else { return nil }
        return SessionUsage(projections: snapshot.mapValues(\.value))
    }

    /// Whether this session's projections have been read yet.
    ///
    /// Distinct from "the usage is empty": a screen that has not read yet and a session the host
    /// reports nothing for are different, and only one of them is worth waiting on.
    func hasProjections(for sessionId: String) -> Bool {
        sessionProjections[sessionId] != nil || hostSnapshot?.projections[sessionId] != nil
    }

    /// Reads a session's projections, which is where its image limits live.
    func loadProjections(for sessionId: String) async {
        guard let coordinator, status.isUsable else { return }
        if let value = try? await coordinator.sessionProjections(sessionId: sessionId) {
            sessionProjections[sessionId] = value
        }
    }

    /// Prepares a picked image against the host's limits and stages it for the next prompt.
    ///
    /// Conversion happens here, before Send, because SPEC §9 asks for conversion errors up
    /// front: an image that cannot be made to fit should say so while the user is still looking
    /// at it, not fail a prompt.
    @discardableResult
    func stageImage(data: Data, name: String?, for sessionId: String) async -> PromptImage? {
        isPreparingImage = true
        imageError = nil
        defer { isPreparingImage = false }

        // The limits arrive with the projections, which are read when the conversation opens.
        // A picture picked in that first moment would otherwise be refused for a limit the host
        // was about to report, so this waits for them rather than guessing or refusing.
        if imageLimits(for: sessionId) == nil {
            await loadProjections(for: sessionId)
        }
        guard let limits = imageLimits(for: sessionId) else {
            imageError = "The harness has not reported what images it accepts, so none can be sent."
            return nil
        }
        do {
            let prepared = try ImagePreparation.prepare(data: data, name: name, limits: limits)
            // Validated against the whole batch, not just the new one: the total is a limit of
            // its own and only the batch can breach it.
            let batch = (stagedImages[sessionId] ?? []) + [prepared]
            try ImageAttachmentValidator.validate(batch, against: limits)
            stagedImages[sessionId] = batch
            return prepared
        } catch let refusal as ImageAttachmentRefusal {
            imageError = ImageAttachmentValidator.describe(refusal)
            return nil
        } catch let failure as ImagePreparationError {
            imageError = Self.describe(failure)
            return nil
        } catch {
            imageError = Self.reason(for: error)
            return nil
        }
    }

    static func describe(_ failure: ImagePreparationError) -> String {
        switch failure {
        case .notAnImage:
            "That file is not an image this phone can read."
        case .encodingFailed:
            "That image could not be re-encoded for the harness."
        case .stillTooLarge(let refusal):
            ImageAttachmentValidator.describe(refusal)
        }
    }

    /// Replaces the staged images for a session — how one of several is removed.
    func replaceImages(_ images: [PromptImage], for sessionId: String) {
        stagedImages[sessionId] = images.isEmpty ? nil : images
        imageError = nil
    }

    func clearImages(for sessionId: String) {
        stagedImages[sessionId] = nil
        imageError = nil
    }

    // MARK: - The timed question's foreground claim

    /// The live claim over one timed question, if this phone holds it.
    ///
    /// SPEC §8 gives the claim's lifetime to the native UI — the screen attaches it, pauses it
    /// while the user is answering, and releases it when it goes away — while the *store* is
    /// what has to consult it before answering. Holding it here is what lets both be true: the
    /// screen drives, the store asks.
    private var timedClaim: TimedQuestionClaim?

    /// Why a claim could not be taken, or `nil` once the host has confirmed one.
    func attachTimedClaim(eventId: String, agentId: String, callId: String) async -> String? {
        guard let interactionStore, let coordinator else {
            return "This phone is not connected to the harness."
        }
        guard let handle = await coordinator.activeStream() else {
            return "The harness is not connected."
        }
        // One claim at a time: a second timed question replaces the first rather than parking
        // two host waits behind one screen.
        await releaseTimedClaim()

        let claim = TimedQuestionClaim(
            eventId: eventId,
            agentId: agentId,
            callId: callId,
            store: interactionStore,
            openStream: { endpoint, args in
                try await handle.client.open(endpoint: endpoint, args: args)
            },
            clock: { try await Task.sleep(for: $0) }
        )
        timedClaim = claim
        do {
            try await claim.attach()
            // The host's own `remainingMs` is what proves the claim; until it arrives there is
            // nothing to answer against, so this waits rather than reporting a false success.
            let held = await claim.waitUntilHeld()
            return held ? nil : "The harness did not confirm the wait."
        } catch {
            timedClaim = nil
            return Self.reason(for: error)
        }
    }

    func releaseTimedClaim() async {
        let claim = timedClaim
        timedClaim = nil
        await claim?.release()
    }

    /// Stops the countdown without giving up the claim, while the user is answering.
    func pauseTimedClaim() async {
        await timedClaim?.pause()
    }

    func resumeTimedClaim() async {
        await timedClaim?.resume()
    }

    /// Whether a claim is held over an event, for the store's timed gate.
    func holdsTimedClaim(_ eventId: String) async -> Bool {
        await timedClaim?.holds(eventId) ?? false
    }

    /// What a refused selection means, in the user's terms (SPEC §6).
    static func describe(_ refusal: SelectionRefusal) -> String {
        switch refusal {
        case .modeLocked: "This session has started, so its mode cannot change."
        case .modelUnavailable(let message): "The harness cannot use that model: \(message)"
        case .refused(let code, let message): "The harness refused that (\(code)): \(message)"
        case .transport(let reason): reason
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

    // MARK: - Diagnostics (SPEC §11)

    /// How many records are held, for the Settings row.
    var diagnosticCount: Int { diagnosticLog.count }

    /// The text a person would send: a preview of exactly what an export produces.
    func diagnosticsText() -> String { diagnosticLog.export() }

    func clearDiagnostics() {
        diagnosticLog.removeAll()
        lastResourceStates.removeAll()
        lastStatusName = nil
    }

    /// Records a connection status change, with the generation that produced it.
    ///
    /// A change, not a heartbeat: a line per status publish would bury the one transition that
    /// matters under a hundred identical ones.
    private func record(status: ConnectionStatus, generation: UInt64?) {
        let name = Self.diagnosticName(status)
        guard name != lastStatusName else { return }
        lastStatusName = name

        // SPEC §11 asks for durations. The one this screen can measure honestly is how long the
        // attempt took: from `connecting` to whatever it became. A state that arrives with no
        // attempt behind it carries none, which is why the field is optional rather than zero.
        var durationMilliseconds: Int?
        if name == "connecting" {
            connectionCorrelation = UUID()
            connectStartedAt = Date()
        } else if let started = connectStartedAt {
            durationMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
            connectStartedAt = nil
        }
        // The status enum carries no failure detail — the reason lives on the error that
        // produced it, which this screen never sees. Recording the state is what is actually
        // known; deriving a code from the enum would be inventing one.
        diagnosticLog.record(DiagnosticRecord(
            correlation: connectionCorrelation,
            subject: .stream("$events"),
            generation: generation,
            resource: "connection",
            stateName: name,
            durationMilliseconds: durationMilliseconds
        ))
    }

    private static func diagnosticName(_ status: ConnectionStatus) -> String {
        status.rawValue
    }

    /// Records each resource's state when it changes.
    ///
    /// The resource names are the endpoints, which is what makes a "the list is stale but the
    /// connection is fine" report readable later.
    private func recordResourceStates() {
        // The two resource states the browse mapping owns are `ResourceState`s; the secondary
        // screens have their own report kind, which is recorded by name for the same reason —
        // a diagnostic line says *which* resource changed and to what, and nothing else.
        var states: [(String, String)] = [
            ("workspace/follow", browse.workspacesState.diagnosticName),
            ("session/list", browse.sessionsState.diagnosticName),
        ]
        states.append(("pluginInventory/list", Self.diagnosticName(pluginsReport.kind)))
        states.append(("scheduledTasks/list", Self.diagnosticName(scheduledTasksReport.kind)))

        for (resource, name) in states {
            guard lastResourceStates[resource] != name else { continue }
            lastResourceStates[resource] = name
            diagnosticLog.record(DiagnosticRecord(
                correlation: connectionCorrelation,
                subject: .endpoint(resource),
                resource: resource,
                stateName: name
            ))
        }
    }

    private static func diagnosticName(_ kind: SecondaryReport.Kind) -> String {
        switch kind {
        case .unknown: "unknown"
        case .loading: "loading"
        case .available: "current"
        case .unavailable: "unavailable"
        case .failed: "failed"
        }
    }

    /// The sessions a live delivery is waiting on, which the projections do not know about.
    private var liveWaiters: Set<String> {
        Set(interactions.filter(\.state.isActionable).map(\.sessionId))
    }

    /// Re-maps the held snapshot into the browse values.
    ///
    /// Cheap enough to do on every interaction change: it is a map over the sessions the
    /// registry already names, with no request of its own.
    private func rebuildBrowse() {
        guard let hostSnapshot else { return }
        let waiters = liveWaiters
        if !waiters.isEmpty { DSHBeacon.note("live waiters: \(waiters.sorted())") }
        browse = BrowseState.from(hostSnapshot, liveWaiters: waiters)
        recordResourceStates()
    }

    private func apply(snapshot: HostSessionStore.Snapshot, selection: UUID) {
        guard selection == selectionID else { return }
        hostSnapshot = snapshot
        let next = BrowseState.from(snapshot, liveWaiters: liveWaiters)
        browse = next
        recordResourceStates()
        // A selected workspace that this host does not have — a host switch, a renamed
        // registry — falls back rather than leaving the screens pointing at nothing.
        if let workspaceId = selectedWorkspaceId, next.workspace(id: workspaceId) == nil {
            selectedWorkspaceId = nil
        }
        if selectedWorkspaceId == nil {
            selectedWorkspaceId = next.workspaces.first?.id
            persistNavigation()
        }
        startLaunchSessionIfAsked()
    }

    /// Debug builds only: start a new session with the prompt a launch named.
    ///
    /// Driven from the snapshot rather than a view's `.task`, because the workspace it needs
    /// only exists once the registry has arrived.
    private func startLaunchSessionIfAsked() {
        guard !didStartLaunchSession, let message = launchNewSessionMessage,
              let workspaceId = selectedWorkspaceId, canStartSession
        else { return }
        didStartLaunchSession = true
        Task { await startSession(workspaceId: workspaceId, text: message) }
    }

    /// Re-reads the session index. The host is not paginated, so one call is the index.
    func refreshSessions() async {
        await hostStore?.refreshSessions()
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        recovery?.setForeground(active)
        guard active, secondaryStore != nil else { return }
        // Coming back is the only moment a reminder can be corrected. An occurrence that
        // fired while the app was away has left the pending set, and the host has already
        // advanced the task's `scheduledAt` — so the next one can only be learned by reading
        // the list again. This is also the re-plan: `loadScheduledTasks` applies the new plan.
        Task { await loadScheduledTasks() }
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

    // MARK: - Notification taps

    /// A tap that arrived before there was a host to route it to.
    ///
    /// A notification launches the app, and the delegate fires before `restoreLastHost` has
    /// run. Routing then would set a session id that `restoreNavigation` immediately
    /// overwrites — the same shape of bug as publishing a host before its stores exist, and
    /// silent for the same reason.
    private var deferredNotification: TaskNotificationPayload?

    /// A drawer destination a tap asked for, until the navigation path consumes it.
    ///
    /// The path is owned by `HomeView`; this is the intent, not the path.
    private(set) var pendingDrawerDestination: String?

    /// Consumes and clears the pending destination.
    func consumeDrawerDestination() -> String? {
        defer { pendingDrawerDestination = nil }
        return pendingDrawerDestination
    }

    /// Routes a notification the user tapped.
    ///
    /// A run that had a session opens it. A reminder for a task that has not run yet — which
    /// is every reminder this build schedules — opens the task list, because there is no
    /// conversation to open and pretending otherwise would land on the wrong one.
    func handleTaskNotification(_ payload: TaskNotificationPayload) {
        guard selectedHost != nil else {
            deferredNotification = payload
            return
        }
        switch payload.destination {
        case .conversation(let sessionId):
            openSession(sessionId)
        case .taskList:
            pendingDrawerDestination = "schedules"
        case nil:
            // A payload this build cannot place does nothing. Opening an arbitrary screen
            // would be worse than the tap being ignored.
            break
        }
    }

    /// Replays a tap held until a host existed.
    private func replayDeferredNotification() {
        guard let payload = deferredNotification else { return }
        deferredNotification = nil
        handleTaskNotification(payload)
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
        // `DSH_DESTINATION=home` means "show Home, not the restored conversation" — a review
        // affordance, since the app otherwise correctly reopens where the user left off.
        if launchDestination == "home" {
            selectedSessionId = nil
            return
        }
        guard shouldOpenFirstSessionOnLaunch, let sessionId = launchSessionId else { return }
        selectedSessionId = sessionId
        #endif
    }

    /// Debug builds only: stage a model for the next new session.
    ///
    /// Written against the *loaded* catalog, so an id the host does not advertise is dropped
    /// rather than sent: the host would refuse it, and this affordance is for verification.
    func applyLaunchModeOverride() {
        guard let wanted = launchMode, let catalog,
              catalog.modes.contains(where: { $0.id == wanted && $0.isSelectable })
        else { return }
        stagedMode = wanted
    }

    func applyLaunchModelOverride() {
        guard let wanted = launchModel, let catalog else { return }
        let parts = wanted.split(separator: "/").map(String.init)
        guard parts.count >= 2,
              let provider = catalog.providers.first(where: { $0.id == parts[0] }),
              let model = provider.models.first(where: { $0.id == parts[1] })
        else { return }
        stagedModel = ModelSelection(
            provider: provider.id,
            model: model.id,
            reasoningEffort: parts.count > 2 ? parts[2] : model.defaultEffort
        )
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
        // The staged receipts ride along, and are cleared only if the host accepts the prompt:
        // an uncertain send keeps them so the same files can be cited again deliberately.
        let receipts = (stagedAttachments[sessionId] ?? []).map(\.receiptId)
        let images = stagedImages[sessionId] ?? []
        try await coordinator.prompt(
            requestId: UUID().uuidString,
            sessionId: sessionId,
            text: text,
            fileReceiptIds: receipts,
            images: images
        )
        if !receipts.isEmpty { clearAttachments(for: sessionId) }
        if !images.isEmpty { clearImages(for: sessionId) }
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
        Task { await releaseTimedClaim() }
        statusTask?.cancel()
        snapshotTask?.cancel()
        eventsTask?.cancel()
        interactionsTask?.cancel()
        recovery?.setForeground(false)
        recovery = nil
        coordinator = nil
        origin = nil
        hostStore = nil
        secondaryStore = nil
        plugins = nil
        pluginsReport = .unknown
        scheduledTasks = []
        scheduledTasksReport = .unknown
        modelModeStore = nil
        catalog = nil
        catalogState = nil
        stagedMode = nil
        stagedModel = nil
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

/// What is known about one capability-gated screen, in SPEC §10's own four states.
///
/// The store answers with a `SecondaryReadOutcome`, which already distinguishes "the host
/// does not implement this" from "the read failed" — and that distinction is lost the moment
/// it is projected onto a `ResourceState`, whose five cases describe freshness rather than
/// existence. Keeping the outcome's meaning is what stops a 404 from rendering as a failure
/// with a Retry button that could never work.
struct SecondaryReport: Equatable {
    enum Kind: Equatable {
        case unknown
        case loading
        case available
        case unavailable
        case failed
    }

    var kind: Kind
    var detail: String?

    static let unknown = SecondaryReport(kind: .unknown)
    static let loading = SecondaryReport(kind: .loading)

    init(kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }

    init(_ outcome: SecondaryReadOutcome) {
        switch outcome {
        case .loaded(let itemCount):
            self.init(kind: .available, detail: "\(itemCount) entries")
        case .gated(let reason):
            self.init(kind: .unavailable, detail: reason)
        case .failed(let reason):
            self.init(kind: .failed, detail: reason)
        }
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
