import Foundation

/// The connection status SPEC §3.1 requires to stay visible on Sessions and Chat.
///
/// > Connection status remains visible on Sessions and Chat: Connecting, Connected,
/// > Reconnecting, Offline, Pairing required, or Host unavailable. Status uses text as
/// > well as color.
///
/// Exactly those six states and no others. A seventh would be a state the UI has no
/// word for, and SPEC §3.1 is a closed list — so anything this layer cannot express as
/// one of the six is a defect here rather than a case to add later.
///
/// No SF Symbol names, no colours, no SwiftUI types: choosing a glyph is the app's
/// business (the app target already maps each case to its own symbol), and a library
/// that names a symbol drags a UI framework into a package that must build and test
/// without one.
///
/// ``rawValue`` mirrors the case name, so the app can persist or log a status by name
/// without a second mapping table. ``label`` is the human-readable phrase SPEC §3.1
/// lists, and it is the only text this type offers: the app shows text *as well as*
/// colour, so the phrase has to come from somewhere shared rather than being retyped
/// per view.
public enum ConnectionStatus: String, Sendable, CaseIterable, Hashable, Codable {
    /// A connection is being attempted and readiness has not been reached. This is the
    /// initial state of a connect attempt, and it is deliberately not a state anything
    /// may remain in: SPEC §6.4 gives socket establishment and readiness ten seconds
    /// each, and either budget expiring moves to ``hostUnavailable``.
    case connecting

    /// The `$events` ready frame arrived (SPEC §6.4). **Not** the same as "the socket
    /// opened": the socket opening alone is explicitly not readiness, and the server
    /// `clientId` that every host request is addressed with only exists once that
    /// frame has been read.
    case connected

    /// A previous connection dropped and is being re-established. SPEC §3.1 names it
    /// as a distinct word from ``connecting`` because a user who *was* connected is
    /// owed a different sentence than a user who never was.
    ///
    /// Reachable in this slice only through ``ConnectionCoordinator/reportReconnecting()``;
    /// SPEC §6.4's jittered exponential backoff that actually produces it is the next
    /// slice (see the "Reconnect" MARK in `ConnectionCoordinator.swift`).
    case reconnecting

    /// No usable network path, or the connection dropped. SPEC §6.9 "Offline /
    /// transport interruption": preserve the draft and reconnect in the foreground.
    case offline

    /// The relay refused the credential, or there is no credential yet. SPEC §6.9
    /// "Relay 403": explain the rejection, offer re-pair, and never retry endlessly.
    case pairingRequired

    /// The relay is up but the harness behind it is not, the exchange timed out, or the
    /// protocol did not match this build. SPEC §6.9 "502" (harness unavailable behind
    /// relay) and "Malformed response" (protocol incompatibility) both land here,
    /// because the user-facing meaning is the same: the host cannot serve this app
    /// right now, and waiting is the only action.
    ///
    /// This is also where a connection **budget** expiry lands (SPEC §6.4: ten seconds
    /// for establishment, ten for readiness), which is what keeps a stalled connect
    /// from sitting on ``connecting`` forever.
    case hostUnavailable

    /// The phrase SPEC §3.1 lists for this state. Shown beside the colour, never
    /// instead of it.
    public var label: String {
        switch self {
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .offline: "Offline"
        case .pairingRequired: "Pairing required"
        case .hostUnavailable: "Host unavailable"
        }
    }

    /// Whether this status means the host can currently serve a request.
    ///
    /// One place for the question every caller asks — "may I send, may I load
    /// sessions, may I offer Send" — so a view never re-derives it from a list of cases
    /// and drifts from the coordinator's own rule.
    public var isUsable: Bool { self == .connected }

    /// Whether this status is one the app may recover from on its own, with no user
    /// action. SPEC §6.9 makes a pin mismatch and a 403 terminal (stop, re-pair) while
    /// offline and host-unavailable are the two it describes as retryable.
    ///
    /// unverified: SPEC §6.4 also says to stop retries for credential *and pin*
    /// failures, and a pin mismatch never arrives here as a status — the coordinator
    /// reports it as ``hostUnavailable``, which this returns `true` for. The app must
    /// therefore decide from the carried error, not from the status alone, before
    /// scheduling a retry. Reconnect is the next slice and owns that decision.
    public var isRecoverableWithoutUserAction: Bool {
        switch self {
        case .connecting, .reconnecting, .offline, .hostUnavailable: true
        case .connected, .pairingRequired: false
        }
    }
}
