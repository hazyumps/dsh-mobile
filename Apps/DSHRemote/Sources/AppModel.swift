import DSHRemoteKit
import Foundation
import Observation
import UIKit

/// Pairing, the selected host, and the state shared by the phone's screens.
@MainActor
@Observable
final class AppModel {
    private var idleStatus: ConnectionStatus = .pairingRequired
    var status: ConnectionStatus { recovery?.status ?? idleStatus }
    var connectionID: UUID? { recovery?.connectionID }
    var connectionError: String? { recovery?.error?.description }
    var hosts: [SavedHost] = []
    var sessions: [SessionSummary] = []
    var sessionListError: String?
    private var isRefreshingSessions = false
    var isLoadingSessions: Bool { isRefreshingSessions || status == .connecting }

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
    private var coordinator: ConnectionCoordinator?
    private var recovery: ForegroundConnection?
    private var selectedHostID: UUID?
    private var selectionID = UUID()
    private var refreshID = UUID()
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

    /// The chat session for one conversation, or `nil` when there is no live
    /// connection.
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

    init() {
        hosts = store.load()
        if !hosts.isEmpty { idleStatus = .offline }
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
        } catch let error as PairingError {
            claimError = error.readableReason ?? String(describing: error)
            idleStatus = hosts.isEmpty ? .pairingRequired : .offline
        } catch {
            claimError = String(describing: error)
            idleStatus = hosts.isEmpty ? .pairingRequired : .offline
        }
    }

    func forget(_ host: SavedHost) {
        if selectedHostID == host.id { disconnect() }
        hosts.removeAll { $0.id == host.id }
        Task {
            try? await secrets.deleteRelayDeviceToken(forHostUUID: host.id)
        }
        try? store.save(hosts)
        if hosts.isEmpty { idleStatus = .pairingRequired }
    }

    // MARK: - Sessions

    /// Connect to a saved host and read its sessions. The token comes from the
    /// keychain, so this works after a relaunch without re-pairing.
    func loadSessions(for host: SavedHost) async {
        if selectedHostID == host.id, recovery != nil {
            if status.isUsable { await refreshSessions() }
            return
        }
        await select(host)
    }

    /// The app calls this once for every fresh ready connection, including after
    /// returning from the background. A host data error keeps the cached list.
    func refreshSessions() async {
        refreshID = UUID()
        let refresh = refreshID
        guard let coordinator, let connectionID else {
            isRefreshingSessions = false
            return
        }
        let selection = selectionID
        isRefreshingSessions = true
        sessionListError = nil
        defer {
            if refresh == refreshID {
                isRefreshingSessions = false
            }
        }
        do {
            let latest = try await coordinator.sessions()
            guard refresh == refreshID, selection == selectionID,
                  connectionID == self.connectionID else { return }
            sessions = latest
        } catch {
            guard !Task.isCancelled, refresh == refreshID, selection == selectionID,
                  connectionID == self.connectionID else { return }
            sessionListError = String(describing: error)
        }
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        if !active { isRefreshingSessions = false }
        recovery?.setForeground(active)
    }

    /// SPEC §3.3 groups by the host's workspace registry. The session row carries
    /// `cwd` and the projections carry a title, so that is what this groups on
    /// until the workspace stream is wired.
    var sessionGroups: [(key: String, sessions: [SessionSummary])] {
        let groups = Dictionary(grouping: sessions) { $0.cwd ?? "No directory" }
        return groups
            .map { (key: $0.key, sessions: $0.value.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }) }
            .sorted { $0.key < $1.key }
    }

    func lastActivity(_ session: SessionSummary) -> Date? {
        session.updatedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    private func select(_ host: SavedHost) async {
        let previous = recovery
        previous?.setForeground(false)
        recovery = nil
        coordinator = nil
        selectedHostID = host.id
        selectionID = UUID()
        let selection = selectionID
        sessions = []
        sessionListError = nil
        isRefreshingSessions = false
        idleStatus = .connecting
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
            self.coordinator = coordinator
            let recovery = ForegroundConnection(coordinator: coordinator)
            self.recovery = recovery
            recovery.setForeground(isForeground)
        } catch {
            guard selection == selectionID else { return }
            sessionListError = String(describing: error)
            idleStatus = .pairingRequired
        }
    }

    func disconnect() {
        recovery?.setForeground(false)
        recovery = nil
        coordinator = nil
        selectedHostID = nil
        selectionID = UUID()
        isRefreshingSessions = false
        sessions = []
        sessionListError = nil
        idleStatus = hosts.isEmpty ? .pairingRequired : .offline
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
