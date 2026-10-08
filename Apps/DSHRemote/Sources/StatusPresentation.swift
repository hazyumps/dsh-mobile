import DSHRemoteKit
import SwiftUI

/// SF Symbols are a UI concern, so they live here rather than in the kit. The
/// kit supplies the human-readable label, and both are shown: SPEC §3.1 wants
/// status readable without relying on colour.
extension ConnectionStatus {
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

/// Whether a coordinator can be reused for a new request. `connected` is the
/// only state that is actually usable; the others need a real connect first.
extension ConnectionStatus {
    var isUsable: Bool { self == .connected }
}

struct StatusBadge: View {
    let status: ConnectionStatus

    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }
}
