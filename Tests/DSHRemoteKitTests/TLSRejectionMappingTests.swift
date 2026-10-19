#if canImport(Security)
import Foundation
import Security
import Testing

@testable import DSHRemoteKit

// #89: a pin the transport itself refused must surface as `.tlsPinMismatch` —
// SPEC §6.9 "stop, say the certificate changed, offer re-pair" — rather than as
// `.cancelled`, which the transport documents as "an error to show" nothing.
//
// The 2026-10-19 relay outage made this the live path: the relay re-minted its
// key, the phone's pin refused it, and the phone sat on a generic connection
// failure until re-paired, because the refusal was discarded at the challenge
// handler and the resulting `URLError.cancelled` was classified as a
// cancellation.
//
// The challenge-driven tests reuse `TLSChallengeHandlerTests`' machinery
// (`TrustMaterial`, `serverTrust`), plus the same fake-protection-space trick:
// a `URLProtectionSpace` subclass that carries a trust of the test's choosing,
// handed to the object URLSession actually calls.

/// A protection space that carries a trust of the test's choosing. Outside a
/// real handshake, `serverTrust` is always nil, so this override is what lets
/// a challenge carry a certificate.
///
/// `@unchecked Sendable`: the one stored property is immutable after `init`,
/// and a `SecTrust` is only read here, never evaluated or mutated.
private final class RefusalFakeProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust?

    init(trust: SecTrust?, authenticationMethod: String) {
        self.trust = trust
        super.init(
            host: "relay.invalid",
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: nil,
            authenticationMethod: authenticationMethod
        )
    }

    required init?(coder: NSCoder) { nil }

    override var serverTrust: SecTrust? { trust }
}

/// A challenge must have a sender. The handler answers through its completion
/// handler, so nothing here is called.
private final class RefusalSilentChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private func refusalChallenge(trust: SecTrust?) -> URLAuthenticationChallenge {
    URLAuthenticationChallenge(
        protectionSpace: RefusalFakeProtectionSpace(
            trust: trust,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        ),
        proposedCredential: nil,
        previousFailureCount: 0,
        failureResponse: nil,
        error: nil,
        sender: RefusalSilentChallengeSender()
    )
}

@Suite("Refused-pin classification (#89)")
struct TLSRejectionMappingTests {
    // MARK: AC1 — the -999 the pin caused is a pin mismatch

    @Test("a cancelled task the transport refused for its pin is a tlsPinMismatch")
    func cancelledBecomesPinMismatchWhenRefused() {
        let error = RelayTransportError.classify(
            URLError(.cancelled),
            rejectedRejection: .pinMismatch
        )
        #expect(
            error == .tlsPinMismatch(RelayTrustRejection.pinMismatch.reason),
            "expected the recorded refusal to turn -999 into a pin mismatch, got \(error)"
        )
    }

    @Test("a cancelled task with no recorded refusal stays a cancellation")
    func cancelledWithoutRefusalStaysCancelled() {
        #expect(
            RelayTransportError.classify(URLError(.cancelled), rejectedRejection: nil)
            == .cancelled
        )
    }

    @Test("a caller cancellation is a cancellation even with a recorded refusal")
    func callerCancellationWinsOverRefusal() {
        #expect(
            RelayTransportError.classify(CancellationError(), rejectedRejection: .pinMismatch)
            == .cancelled
        )
    }

    @Test("a recorded refusal does not mask a real transport code")
    func refusalDoesNotMaskOtherCodes() {
        #expect(
            RelayTransportError.classify(URLError(.timedOut), rejectedRejection: .pinMismatch)
            == .offline("-1001")
        )
    }

    // MARK: AC1 — the challenge handler remembers its refusal

    @Test("the challenge handler records a pin refusal for the challenged URL")
    func delegateRecordsPinRefusal() async throws {
        let material = try TrustMaterial.load()
        // Pinned to the P-384 key's own pin: the leaf is P-256, so its pin is
        // computable and simply disagrees.
        let transport = URLSessionRelayTransport(pinning: .pinned(material.p384OwnPin))
        let challenge = refusalChallenge(trust: try serverTrust([material.leaf, material.issuer]))
        // The record is keyed by the authority the protection space names —
        // scheme, host, port — which `send` derives from its request URL
        // through the same helper.
        let challengedAuthority = TrustAuthority.key(of: challenge.protectionSpace)

        guard let delegate = transport.challengeDelegates.request else {
            Issue.record("the request session has no delegate")
            return
        }
        var answered = false
        delegate.urlSession?(URLSession.shared, didReceive: challenge) { _, _ in
            answered = true
        }
        #expect(answered, "the challenge handler answered synchronously")

        #expect(
            transport.trustRejection(for: URL(string: challengedAuthority)!) == .pinMismatch,
            "the handler that refused the trust must remember that it refused it"
        )
    }

    @Test("the challenge handler records nothing for a pin that matches")
    func delegateRecordsNothingOnAccept() async throws {
        let material = try TrustMaterial.load()
        let transport = URLSessionRelayTransport(pinning: .pinned(material.expectedPin))
        let challenge = refusalChallenge(trust: try serverTrust([material.leaf, material.issuer]))
        let challengedAuthority = TrustAuthority.key(of: challenge.protectionSpace)

        guard let delegate = transport.challengeDelegates.request else {
            Issue.record("the request session has no delegate")
            return
        }
        delegate.urlSession?(URLSession.shared, didReceive: challenge) { _, _ in }

        #expect(transport.trustRejection(for: URL(string: challengedAuthority)!) == nil)
    }

    // MARK: AC2 — the socket path keeps the identity too

    @Test("a socket cancelled by a recorded pin refusal is a tlsPinMismatch")
    func socketCancelledBecomesPinMismatchWhenRefused() {
        let error = RelayTransportError.webSocketFailure(
            URLError(.cancelled),
            response: nil,
            rejection: .pinMismatch
        )
        #expect(
            error == .tlsPinMismatch(RelayTrustRejection.pinMismatch.reason),
            "the prefix this detail starts with is the one socketFailure recovers on"
        )
    }

    @Test("a refused upgrade keeps its own status mapping")
    func socketUpgradeRefusalUnchanged() {
        let response = HTTPURLResponse(
            url: URL(string: "https://relay.invalid:3443/remote.mux")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!
        #expect(
            RelayTransportError.webSocketFailure(
                URLError(.cancelled),
                response: response,
                rejection: .pinMismatch
            ) == .webSocketRejected(.credentialRejected(relayError: nil, status: 403))
        )
    }

    @Test("a socket cancellation with no recorded refusal stays a cancellation")
    func socketCancelledWithoutRefusalStaysCancelled() {
        #expect(
            RelayTransportError.webSocketFailure(URLError(.cancelled), response: nil)
            == .cancelled
        )
    }

    // MARK: AC3 — pairing says what happened

    @Test("a refused pairing claim reads as a certificate change, not a debug string")
    func pairingClaimSurfacesCertificateChange() async throws {
        let expiresAt = Int(Date().timeIntervalSince1970 * 1000) + 300_000
        // The fingerprint is never validated for format (only carried, and
        // compared against the claim response), so a stand-in 32-byte digest
        // is enough; the point of this test is the refusal's words.
        let json = """
        {"v":1,"kind":"dsh-relay-pair","url":"https://pairing-relay.invalid:3443","fingerprint":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","code":"12345678","expiresAt":\(expiresAt)}
        """
        // A stub that fails the handshake exactly the way the real transport will
        // once AC1 lands: the transport says tlsPinMismatch, the exchange says
        // certificateChanged, and the claim must say so in words.
        let transport = StubRelayTransport(
            responses: [.failure(.tlsPinMismatch("the key rotated"))]
        )
        let client = PairingClient(transport: transport)
        let payload = try client.decodePayload(Data(json.utf8))

        do {
            _ = try await client.claim(payload, deviceName: "refusal-test")
            Issue.record("the claim was supposed to fail on the refused handshake")
        } catch let error as PairingError {
            #expect(
                error.readableReason?.contains("certificate changed") == true,
                "the pairing sheet shows \(String(describing: error.readableReason)), not a Swift debug string"
            )
        }
    }

    // MARK: AC4 — the notice is exactly the unavailable-plus-refused pair

    @Test("the notice fires only for host-unavailable caused by the certificate change")
    func noticeTable() {
        let refused = ConnectionCoordinator.ConnectError.certificateChanged(detail: "the key rotated")
        #expect(
            ConnectionNotice.certificateChanged(status: .hostUnavailable, lastError: refused)
            == true,
            "host-unavailable + certificate-changed is the one pair that notices"
        )
        #expect(
            ConnectionNotice.certificateChanged(
                status: .hostUnavailable,
                lastError: .transportInterruption(detail: "dropped")
            ) == false
        )
        #expect(ConnectionNotice.certificateChanged(status: .offline, lastError: refused) == false)
        #expect(ConnectionNotice.certificateChanged(status: .connected, lastError: refused) == false)
        #expect(ConnectionNotice.certificateChanged(status: .pairingRequired, lastError: refused) == false)
        #expect(ConnectionNotice.certificateChanged(status: .hostUnavailable, lastError: nil) == false)
    }
}
#endif
