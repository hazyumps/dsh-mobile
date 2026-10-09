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

/// The transport state, in the same chip the host row and the cards use.
///
/// It used to be a bare `Label`, which a navigation bar squeezes into a single
/// letter — "Offline" became a clipped circle. The chip carries the same words, its
/// state colour, and a symbol, and `fixedSize` stops the bar from compressing it.
struct StatusBadge: View {
    let status: ConnectionStatus

    var body: some View {
        let state = DSHHostState(status)
        DSHStatusChip(state.text, tone: state.tone, symbol: state.symbol)
            .fixedSize()
    }
}
