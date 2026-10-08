import DSHRemoteKit
import Foundation
import Observation

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

/// Everything the UI reads. Networking is not wired yet, so the host list is
/// genuinely empty rather than filled with placeholder data.
@MainActor
@Observable
final class AppModel {
    var status: ConnectionStatus = .pairingRequired

    /// Result of reading a pasted pairing payload, shown beside the field.
    var pairingOutcome: PairingOutcome?

    private let clock: any EpochClock = SystemEpochClock()

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
}
