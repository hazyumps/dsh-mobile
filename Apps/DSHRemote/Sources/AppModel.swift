import DSHRemoteKit
import Foundation
import Observation
import UIKit

/// The connection states SPEC §3.1 requires the UI to show. Every case carries
/// text as well as a symbol, because colour alone is not a status.
enum ConnectionStatus: String, Sendable, CaseIterable {
    case connecting
    case connected
    case reconnecting
    case offline
    case pairingRequired
    case hostUnavailable

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .offline: "Offline"
        case .pairingRequired: "Pairing required"
        case .hostUnavailable: "Host unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .connecting: "ellipsis.circle"
        case .connected: "checkmark.circle.fill"
        case .reconnecting: "arrow.clockwise.circle"
        case .offline: "wifi.slash"
        case .pairingRequired: "qrcode"
        case .hostUnavailable: "exclamationmark.triangle"
        }
    }
}

/// Everything the UI reads. Pairing is wired; connecting to a host and reading
/// its sessions is the next slice, so the host list is real but inert.
@MainActor
@Observable
final class AppModel {
    var status: ConnectionStatus = .pairingRequired
    var hosts: [SavedHost] = []

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

    init() {
        hosts = store.load()
        if !hosts.isEmpty { status = .offline }
    }

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
        status = .connecting
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
            status = .offline
        } catch let error as PairingError {
            claimError = error.readableReason ?? String(describing: error)
            status = hosts.isEmpty ? .pairingRequired : .offline
        } catch {
            claimError = String(describing: error)
            status = hosts.isEmpty ? .pairingRequired : .offline
        }
    }

    func forget(_ host: SavedHost) {
        hosts.removeAll { $0.id == host.id }
        Task {
            try? await secrets.deleteRelayDeviceToken(forHostUUID: host.id)
        }
        try? store.save(hosts)
        if hosts.isEmpty { status = .pairingRequired }
    }
}
