import Foundation
import Testing
@testable import DSHRemoteKit

// SPEC §10's rule that four states are needed rather than two, and SPEC §12's test-matrix
// row for it: "Unavailable differs from failed". The distinction is not cosmetic — it
// decides whether a feature is hidden from the drawer or shown with a retry, so a
// misclassification either hides a working feature or advertises one that cannot work.

@Suite("Capability state")
struct CapabilityStateTests {
    private func business(_ code: String) -> DshRPCError {
        .business(RPCError(code: code, message: "the host said \(code)"))
    }

    // MARK: - The only two things that prove absence

    @Test("a 404 means the host does not implement the endpoint")
    func transportMissingEndpoint() {
        let state = CapabilityState.classified(from: .capabilityUnavailable(endpoint: "pluginInventory/list"))
        #expect(state?.isAbsent == true)
    }

    @Test("gateway/method-unavailable also means absence, though it is a business error")
    func gatewayMissingMethod() {
        // The trap: this arrives as a business refusal, so a classifier that treats every
        // business error as "the endpoint answered" records a missing endpoint as
        // available and then offers a control that cannot work.
        let state = CapabilityState.classified(from: business(CapabilityState.methodUnavailableCode))
        #expect(state?.isAbsent == true)
    }

    // MARK: - What must never be read as absence

    @Test("an answered refusal means the capability exists")
    func businessRefusalIsAvailable() {
        // The host said no, which is proof it was listening.
        let state = CapabilityState.classified(from: business("session/upload-too-large"))
        #expect(state == .available)
        #expect(state?.isAbsent == false)
    }

    @Test("an authentication failure is not proof of absence", arguments: [
        DshRPCError.credentialRejected(relayError: nil, status: 401),
        DshRPCError.credentialRejected(relayError: nil, status: 403),
        DshRPCError.relayedAuthenticationFailure(relayError: nil, status: 401),
    ])
    func authenticationIsNeverAbsence(_ error: DshRPCError) {
        // SPEC §10 names 401 and 403 explicitly. Treating either as absence would hide a
        // feature that exists simply because the credential had expired.
        let state = CapabilityState.classified(from: error)
        #expect(state?.isAbsent == false)
        guard case .failed = state else {
            Issue.record("expected a failed state, got \(String(describing: state))")
            return
        }
    }

    @Test("transport trouble is not proof of absence", arguments: [
        DshRPCError.transportInterruption(detail: "offline"),
        DshRPCError.harnessUnavailable(attempts: 3),
        DshRPCError.rateLimited(retryAfterSeconds: 5, attempts: 1),
        DshRPCError.certificateChanged(detail: "key rotated"),
        DshRPCError.protocolIncompatible(reason: "bad envelope"),
        DshRPCError.unexpectedStatus(status: 500, endpoint: "session/list"),
    ])
    func transportTroubleIsNeverAbsence(_ error: DshRPCError) {
        let state = CapabilityState.classified(from: error)
        #expect(state?.isAbsent == false)
        guard case .failed = state else {
            Issue.record("expected a failed state, got \(String(describing: state))")
            return
        }
    }

    @Test("a cancellation is no evidence at all")
    func cancellationIsNotEvidence() {
        // Returning a state here would let a user who navigated away mid-request mark a
        // perfectly good feature as broken.
        #expect(CapabilityState.classified(from: .cancelled) == nil)
    }

    // MARK: - The ledger

    @Test("an endpoint is unknown until something is learned about it")
    func unknownUntilLearned() {
        let ledger = CapabilityLedger()
        #expect(ledger.state(of: "schedule/catalog") == .unknown)
        #expect(ledger.state(of: "schedule/catalog").isAbsent == false)
    }

    @Test("a cancellation leaves a known-good capability alone")
    func cancellationPreservesState() {
        var ledger = CapabilityLedger()
        ledger.recordSuccess(of: "schedule/catalog")
        #expect(ledger.state(of: "schedule/catalog") == .available)

        ledger.record(.cancelled, of: "schedule/catalog")
        #expect(ledger.state(of: "schedule/catalog") == .available)

        // Whereas a real failure does downgrade it, because it is evidence.
        ledger.record(.transportInterruption(detail: "dropped"), of: "schedule/catalog")
        #expect(ledger.state(of: "schedule/catalog").isAbsent == false)
        #expect(ledger.state(of: "schedule/catalog") != .available)
    }

    @Test("states are tracked per endpoint, not globally")
    func statesArePerEndpoint() {
        var ledger = CapabilityLedger()
        ledger.record(.capabilityUnavailable(endpoint: "pluginInventory/list"), of: "pluginInventory/list")
        ledger.recordSuccess(of: "schedule/catalog")

        #expect(ledger.state(of: "pluginInventory/list").isAbsent)
        #expect(ledger.state(of: "schedule/catalog") == .available)
        #expect(ledger.recorded.count == 2)
    }

    @Test("a changed host version forgets what the old one taught")
    func versionChangeResets() {
        var ledger = CapabilityLedger(hostVersion: "0.2.0-rc.2")
        ledger.record(.capabilityUnavailable(endpoint: "schedule/catalog"), of: "schedule/catalog")
        #expect(ledger.state(of: "schedule/catalog").isAbsent)

        // An upgrade can add the endpoint. Carrying the old verdict forward would hide a
        // feature that now exists, which is the failure this reset prevents.
        ledger.noteHostVersion("0.3.0")
        #expect(ledger.hostVersion == "0.3.0")
        #expect(ledger.state(of: "schedule/catalog") == .unknown)
    }

    @Test("an unchanged host version keeps what is already known")
    func sameVersionKeepsState() {
        var ledger = CapabilityLedger(hostVersion: "0.2.0-rc.2")
        ledger.recordSuccess(of: "schedule/catalog")

        // Reconnecting must not make a feature flicker between known and unknown.
        ledger.noteHostVersion("0.2.0-rc.2")
        #expect(ledger.state(of: "schedule/catalog") == .available)
    }
}
