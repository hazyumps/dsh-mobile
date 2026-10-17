import Foundation

/// Which host selection is current, so work started for an older one can tell it lost (#104).
///
/// A selection suspends (it stops the previous host's streams, then reads the token) before it
/// publishes anything. Whatever happened meanwhile — a newer selection, a disconnect, the host
/// being forgotten — must win, so the selection holds a ``Ticket`` and checks it after every
/// suspension. The gate is a value owned by one isolation domain (the app's main actor): it is
/// checked synchronously, so nothing can happen between the check and the publish. An actor-held
/// ticket would be one `await` stale by the time its answer was acted on.
public struct HostSelectionGate: Sendable {
    /// One selection attempt, for one host.
    public struct Ticket: Sendable, Equatable {
        public let hostId: UUID
        let id: UUID
    }

    private var current: Ticket?
    private var forgetting: Set<UUID> = []

    public init() {}

    /// Starts a selection of `hostId`, superseding any earlier ticket. While `hostId` is being
    /// forgotten the ticket is never current, though it still supersedes the earlier one.
    public mutating func begin(_ hostId: UUID) -> Ticket {
        let ticket = Ticket(hostId: hostId, id: UUID())
        current = forgetting.contains(hostId) ? nil : ticket
        return ticket
    }

    /// The ticket in force, or `nil` when nothing is selected.
    ///
    /// For work that has to notice later whether the selection it started under has changed,
    /// without starting one of its own — a file import that outlives its pick (#66):
    /// `let selection = gate.ticket` … `gate.isCurrent(selection)`.
    public var ticket: Ticket? { current }

    /// Whether the selection in force is still the one `ticket` names.
    ///
    /// `nil` means "nothing was selected". A `nil` ticket stays current while nothing is
    /// selected: a file picked when no host is connected has no host to protect, and the
    /// caller's "not connected" answer is the honest one (#66).
    public func isCurrent(_ ticket: Ticket?) -> Bool {
        current == ticket
    }

    /// Ends the current selection (disconnect).
    public mutating func end() {
        current = nil
    }

    /// Ends the current selection when it is for `hostId`, pending or published, and marks
    /// `hostId` as being forgotten until ``finishForgetting(_:)``. A selection of it begun while
    /// it is marked is never current. Returns `true` when it ended the current selection, which
    /// tells the caller to tear that selection down.
    @discardableResult
    public mutating func forget(_ hostId: UUID) -> Bool {
        forgetting.insert(hostId)
        guard current?.hostId == hostId else { return false }
        current = nil
        return true
    }

    /// Ends the forget that ``forget(_:)`` started, so `hostId` can be selected again. Call it on
    /// every path out of a forget, a failed list save included.
    public mutating func finishForgetting(_ hostId: UUID) {
        forgetting.remove(hostId)
    }
}
