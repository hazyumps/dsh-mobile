import DSHRemoteKit
import SwiftUI

/// The host and its connection state, as one compact row (UX spec "Home and
/// starting a session" item 2, "Connection and loading behavior": "Use one
/// compact status row").
///
/// It takes the words rather than the store: the state text is passed in so the
/// caller can carry the spec's fuller phrasing ("Connecting to Patrick's
/// Mac…", "Reconnecting…") while this stays free of transport types. The
/// ``DSHHostState`` helper below gives the six words the kit already names, so
/// a caller does not retype them.
struct HostStatusRow: View {
    let hostName: String
    let state: DSHHostState

    init(hostName: String, state: DSHHostState) {
        self.hostName = hostName
        self.state = state
    }

    /// Convenience for the plain "connected" case the mockups show.
    init(hostName: String, stateText: String, tone: DSHTone, symbol: String? = nil) {
        self.init(hostName: hostName, state: DSHHostState(text: stateText, tone: tone, symbol: symbol))
    }

    var body: some View {
        HStack(spacing: DSHMetrics.space) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(DSHPalette.secondaryText)
                .accessibilityHidden(true)
            Text(hostName)
                .font(.dshSupporting)
                .foregroundStyle(DSHPalette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer(minLength: DSHMetrics.space)
            DSHStatusChip(state.text, tone: state.tone, symbol: state.symbol)
                .fixedSize()
        }
        .padding(.horizontal, DSHMetrics.pageMargin)
        .frame(minHeight: DSHMetrics.minimumHitTarget)
        .background(DSHPalette.navigationSurface)
    }
}

/// One phrase of the connection vocabulary: text, its colour, and an optional
/// symbol for states that read better with motion (reconnecting).
///
/// The spec's connected / reconnecting / needs-input words live here so both
/// the host row and the session list say the same thing about the same state.
struct DSHHostState: Equatable {
    var text: String
    var tone: DSHTone
    var symbol: String?

    init(text: String, tone: DSHTone, symbol: String? = nil) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
    }

    static let connected = DSHHostState(text: "Connected", tone: .success)
    static let connecting = DSHHostState(text: "Connecting", tone: .neutral, symbol: "ellipsis.circle")
    static let reconnecting = DSHHostState(text: "Reconnecting", tone: .attention, symbol: "arrow.clockwise")
    static let needsInput = DSHHostState(text: "Needs your input", tone: .attention)
    static let offline = DSHHostState(text: "Offline", tone: .neutral, symbol: "wifi.slash")
    static let pairingRequired = DSHHostState(text: "Pairing required", tone: .error)
    static let hostUnavailable = DSHHostState(text: "Host unavailable", tone: .error)

    /// The kit's six transport words, mapped to this vocabulary.
    init(_ status: ConnectionStatus) {
        self = switch status {
        case .connected: .connected
        case .connecting: .connecting
        case .reconnecting: .reconnecting
        case .offline: .offline
        case .pairingRequired: .pairingRequired
        case .hostUnavailable: .hostUnavailable
        }
    }
}
