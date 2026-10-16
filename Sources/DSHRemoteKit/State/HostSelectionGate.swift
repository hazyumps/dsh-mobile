import Foundation

/// Which host selection is current, so work started for an older one can tell it lost (#104).
///
/// A selection suspends (it stops the previous host's streams, then reads the token) before it
/// publishes anything. Whatever happened meanwhile — a newer selection, a disconnect, the host
/// being forgotten — must win, so the selection holds a ``Ticket`` and checks it after every
/// suspension. The gate is a value owned by one isolation domain (the app's main actor): it is
/// checked synchronously, so nothing can happen between the check and the publish. An actor-held
/// ticket would be one `await` stale by the time its answer was acted on.
///
/// STUB for the `Tests:` commit of #104: every method returns a wrong value. The builder
/// implements it.
public struct HostSelectionGate: Sendable {
    /// One selection attempt, for one host.
    public struct Ticket: Sendable, Equatable {
        public let hostId: UUID
        let id: UUID
    }

    public init() {}

    /// Starts a selection of `hostId`, superseding any earlier ticket.
    public mutating func begin(_ hostId: UUID) -> Ticket {
        Ticket(hostId: hostId, id: UUID())
    }

    /// Whether `ticket` is still the current selection.
    public func isCurrent(_ ticket: Ticket) -> Bool {
        false
    }

    /// Ends the current selection (disconnect).
    public mutating func end() {}

    /// Ends the current selection when it is for `hostId`, pending or published. Returns `true`
    /// when it did, which tells the caller to tear that selection down.
    @discardableResult
    public mutating func forget(_ hostId: UUID) -> Bool {
        false
    }
}
