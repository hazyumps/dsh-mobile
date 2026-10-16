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
        // The forget has finished: a selection begun during it is never current (AC7).
        gate.finishForgetting(b)
        let fresh = gate.begin(b)

        #expect(!gate.isCurrent(old), "the ticket from before the forget came back to life")
        #expect(gate.isCurrent(fresh), "the new selection of B is not current")
    }
}

/// #104, from the security review: `AppModel.forget` ends the selection before it awaits the
/// registry, so a `select(B)` begun during that await would get a fresh ticket nothing ends. Its
/// token read yields nil, and its failure path would publish B. The gate marks B as being
/// forgotten from `forget(_:)` until `finishForgetting(_:)`, and a ticket begun meanwhile is
/// never current.
@Suite("Host selection gate: a host being forgotten")
struct HostSelectionGateForgettingTests {
    private let b = UUID()
    private let c = UUID()

    @Test("AC7: a selection begun while B is being forgotten is not current")
    func selectionDuringForgetIsNotCurrent() {
        var gate = HostSelectionGate()
        gate.forget(b)

        let during = gate.begin(b)

        #expect(!gate.isCurrent(during), "a selection begun mid-forget is current, so it can publish the forgotten host")
    }

    @Test("AC8: once forgetting B finishes, a new selection of B is current (the failed-save case)")
    func selectionAfterForgetFinishesIsCurrent() {
        var gate = HostSelectionGate()
        gate.forget(b)
        // The mark must have taken effect, or the assertion after `finishForgetting` proves nothing.
        let during = gate.begin(b)
        #expect(!gate.isCurrent(during), "precondition: B was not marked as being forgotten")

        gate.finishForgetting(b)
        let after = gate.begin(b)

        #expect(gate.isCurrent(after), "a host whose forget finished (or failed) cannot be selected again")
    }

    @Test("AC9: forgetting B does not affect a selection of C begun meanwhile")
    func markingBDoesNotAffectC() {
        var gate = HostSelectionGate()
        gate.forget(b)
        // B's mark must be in effect, or the assertion about C proves nothing.
        let ofB = gate.begin(b)
        #expect(!gate.isCurrent(ofB), "precondition: B was not marked as being forgotten")

        let ofC = gate.begin(c)

        #expect(gate.isCurrent(ofC), "forgetting B blocked a selection of C")
    }

    @Test("AC10: when two forgets overlap, finishing one keeps the other host marked")
    func overlappingForgetsKeepEachMark() {
        var gate = HostSelectionGate()
        gate.forget(b)
        gate.forget(c)
        gate.finishForgetting(c)

        let whileBIsForgotten = gate.begin(b)
        #expect(!gate.isCurrent(whileBIsForgotten), "finishing C's forget cleared B's mark too")

        gate.finishForgetting(b)
        let afterB = gate.begin(b)
        #expect(gate.isCurrent(afterB), "B cannot be selected after its own forget finished")
    }
}
