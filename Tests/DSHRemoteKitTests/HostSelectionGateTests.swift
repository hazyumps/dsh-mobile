import DSHRemoteKit
import Foundation
import Testing

/// #104: which host selection is current. `AppModel.select` begins a ticket and checks it after
/// every suspension; `disconnect` ends it; `forget` ends it when it is for the forgotten host.
/// The held-token-read interleaving is in `HostRegistryTests` ("Selection in flight").
@Suite("Host selection gate")
struct HostSelectionGateTests {
    private let b = UUID()
    private let c = UUID()

    @Test("AC1: forgetting B ends a pending selection of B")
    func forgettingTheHostEndsItsSelection() {
        var gate = HostSelectionGate()
        let ticket = gate.begin(b)

        let ended = gate.forget(b)
        #expect(ended, "forget did not report ending B's selection, so nothing tears it down")
        #expect(!gate.isCurrent(ticket), "B's selection is still current after B was forgotten")
    }

    @Test("AC2: forgetting C leaves a pending selection of B current")
    func forgettingAnotherHostKeepsTheSelection() {
        var gate = HostSelectionGate()
        let ticket = gate.begin(b)

        let ended = gate.forget(c)
        #expect(!ended, "forgetting C reported ending B's selection")
        #expect(gate.isCurrent(ticket), "forgetting C ended B's selection")
    }

    @Test("AC2: forgetting a host whose selection was superseded leaves the newer one current")
    func forgettingASupersededHostKeepsTheNewerSelection() {
        var gate = HostSelectionGate()
        _ = gate.begin(b)
        let newer = gate.begin(c)

        let ended = gate.forget(b)
        #expect(!ended, "forgetting B ended C's selection")
        #expect(gate.isCurrent(newer))
    }

    @Test("AC3: a newer selection supersedes an older one")
    func newerSelectionSupersedes() {
        var gate = HostSelectionGate()
        let older = gate.begin(b)
        let newer = gate.begin(c)

        #expect(!gate.isCurrent(older), "the superseded selection of B is still current")
        #expect(gate.isCurrent(newer), "the newest selection is not current")
    }

    @Test("AC3: ending the selection makes its ticket stale")
    func endingMakesTheTicketStale() {
        var gate = HostSelectionGate()
        let ticket = gate.begin(b)
        #expect(gate.isCurrent(ticket), "a just-begun selection is not current")

        gate.end()

        #expect(!gate.isCurrent(ticket), "a selection is still current after disconnect")
    }

    @Test("AC3: selecting a forgotten host again does not revive the old ticket")
    func reselectingDoesNotReviveTheOldTicket() {
        var gate = HostSelectionGate()
        let old = gate.begin(b)
        gate.forget(b)
        let fresh = gate.begin(b)

        #expect(!gate.isCurrent(old), "the ticket from before the forget came back to life")
        #expect(gate.isCurrent(fresh), "the new selection of B is not current")
    }
}
