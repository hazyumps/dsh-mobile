#if canImport(Security)
import Foundation
import Security
import Testing

@testable import DSHRemoteKit

// The relay trust decision (#68), tested without a handshake. Each test builds a real
// `SecTrust` from certificates in `Fixtures/relay-trust-certificates.json` with
// `SecTrustCreateWithCertificates`, and never evaluates it. Evaluating it is the
// platform's job, and only on the `.deferToPlatform` path.
//
// The certificates are synthetic stand-ins. The leaf carries the live relay's captured
// P-256 key, so its SPKI pin is the relay's published pin, but a throwaway issuer signed
// it. Every expected pin was computed by openssl, outside the code under test; the
// fixture's `source` field has the commands.

/// The stand-in certificates and the pins openssl computed for them.
struct TrustMaterial {
    let leaf: SecCertificate
    let issuer: SecCertificate
    let p384Leaf: SecCertificate
    let rsaLeaf: SecCertificate
    /// SHA-256 over the leaf's DER SPKI: the relay's published pin.
    let expectedPin: String
    /// SHA-256 over the leaf's whole DER certificate, the wrong thing to hash (SPEC §6.3).
    let leafWholeCertificatePin: String
    let issuerOwnPin: String
    let p384OwnPin: String
    let rsaOwnPin: String

    static func load() throws -> TrustMaterial {
        let object = try Fixtures.object(.relayTrustCertificates)
        func string(_ key: String) throws -> String {
            try #require(object[key]?.stringValue, "fixture is missing \(key)")
        }
        func certificate(_ key: String) throws -> SecCertificate {
            let der = try #require(Data(base64Encoded: try string(key)), "\(key) is not base64")
            return try #require(
                SecCertificateCreateWithData(nil, der as CFData),
                "\(key) is not a DER certificate"
            )
        }
        return TrustMaterial(
            leaf: try certificate("leafOverCapturedRelayKey"),
            issuer: try certificate("throwawayIssuer"),
            p384Leaf: try certificate("p384Leaf"),
            rsaLeaf: try certificate("rsaLeaf"),
            expectedPin: try string("expectedPin"),
            leafWholeCertificatePin: try string("leafWholeCertificatePin"),
            issuerOwnPin: try string("issuerOwnPin"),
            p384OwnPin: try string("p384OwnPin"),
            rsaOwnPin: try string("rsaOwnPin")
        )
    }
}

/// An unevaluated server trust for `certificates`, leaf first, under the SSL policy a
/// challenge carries.
func serverTrust(_ certificates: [SecCertificate]) throws -> SecTrust {
    var trust: SecTrust?
    let status = SecTrustCreateWithCertificates(
        certificates as CFArray,
        SecPolicyCreateSSL(true, "dsh-relay" as CFString),
        &trust
    )
    #expect(status == errSecSuccess)
    return try #require(trust)
}

private func der(_ certificate: SecCertificate) -> Data {
    SecCertificateCopyData(certificate) as Data
}

@Suite("TLS trust decision")
struct TLSTrustDecisionTests {
    // MARK: - AC1: the pin decides, and it is read from the leaf's SPKI

    @Test("AC1: the certificate over the captured relay key is accepted with the relay's published pin")
    func capturedKeyAcceptedWithPublishedPin() throws {
        let material = try TrustMaterial.load()
        let trust = try serverTrust([material.leaf])

        let decision = RelayPinningPolicy.pinned(material.expectedPin).decide(serverTrust: trust)

        #expect(decision == .acceptPinned)
    }

    @Test("AC1: the same certificate is rejected under a different pin")
    func capturedKeyRejectedUnderDifferentPin() throws {
        let material = try TrustMaterial.load()
        let trust = try serverTrust([material.leaf])

        // A well-formed SPKI pin, but of another key.
        let decision = RelayPinningPolicy.pinned(material.p384OwnPin).decide(serverTrust: trust)

        #expect(decision == .reject(.pinMismatch))
    }

    @Test("AC1: a pin over the whole certificate is not accepted")
    func wholeCertificatePinRejected() throws {
        let material = try TrustMaterial.load()
        let trust = try serverTrust([material.leaf])

        // SPEC §6.3: the pin is over the SPKI, "not a hash of the whole certificate".
        let decision = RelayPinningPolicy.pinned(material.leafWholeCertificatePin).decide(serverTrust: trust)

        #expect(decision == .reject(.pinMismatch))
    }

    @Test("AC1: the pin is taken from the leaf, not the issuer")
    func pinReadFromLeafNotIssuer() throws {
        let material = try TrustMaterial.load()
        let trust = try serverTrust([material.leaf, material.issuer])

        // The platform assumption this test stands on: an unevaluated trust hands its
        // chain back as given, leaf first. If that ever changes, this fails here, not as
        // a confusing pin result.
        let chain = try #require(SecTrustCopyCertificateChain(trust) as? [SecCertificate])
        #expect(chain.map(der) == [der(material.leaf), der(material.issuer)])

        // The issuer is P-256, so a decision that read it would accept.
        let decision = RelayPinningPolicy.pinned(material.issuerOwnPin).decide(serverTrust: trust)

        #expect(decision == .reject(.pinMismatch))
    }

    // MARK: - AC2: a key the pin cannot describe fails closed

    @Test("AC2: a P-384 leaf fails closed even under its own SPKI pin")
    func p384LeafFailsClosed() throws {
        let material = try TrustMaterial.load()
        let trust = try serverTrust([material.p384Leaf])

        let decision = RelayPinningPolicy.pinned(material.p384OwnPin).decide(serverTrust: trust)

        #expect(decision == .reject(.unsupportedKey))
    }

    @Test("AC2: an RSA leaf fails closed even under its own SPKI pin")
    func rsaLeafFailsClosed() throws {
        let material = try TrustMaterial.load()
        let trust = try serverTrust([material.rsaLeaf])

        let decision = RelayPinningPolicy.pinned(material.rsaOwnPin).decide(serverTrust: trust)

        #expect(decision == .reject(.unsupportedKey))
    }

    // MARK: - AC3–AC5: without a pin, and with both switches

    @Test("AC3: no pin with platform trust required defers to the system's check")
    func noPinDefersToPlatform() throws {
        let material = try TrustMaterial.load()
        let trust = try serverTrust([material.leaf, material.issuer])

        let decision = RelayPinningPolicy.platformTrust.decide(serverTrust: trust)

        #expect(decision == .deferToPlatform)
    }

    @Test("AC4: no pin and no platform trust is rejected")
    func noAnchorRejected() throws {
        let material = try TrustMaterial.load()
        let trust = try serverTrust([material.leaf])
        let policy = RelayPinningPolicy(expectedSPKIPin: nil, requiresPlatformTrust: false)

        let decision = policy.decide(serverTrust: trust)

        #expect(decision == .reject(.noTrustAnchor))
    }

    @Test("AC5: a pin with platform trust also required checks only the pin (follow-up #86)")
    func pinWithPlatformTrustChecksOnlyThePin() throws {
        let material = try TrustMaterial.load()
        // The stand-in chains to an issuer no system trusts, so if the platform were also
        // consulted, this could not be accepted.
        let trust = try serverTrust([material.leaf, material.issuer])
        let policy = RelayPinningPolicy(expectedSPKIPin: material.expectedPin, requiresPlatformTrust: true)

        let decision = policy.decide(serverTrust: trust)

        #expect(decision == .acceptPinned)
    }

    // MARK: - AC6: what the delegate hands URLSession

    @Test("AC6: an accepted decision maps to useCredential")
    func acceptedMapsToUseCredential() {
        let disposition = RelayTrustDecision.acceptPinned.disposition

        #expect(disposition == .useCredential)
    }

    @Test("AC6: a deferred decision maps to performDefaultHandling")
    func deferredMapsToDefaultHandling() {
        let disposition = RelayTrustDecision.deferToPlatform.disposition

        #expect(disposition == .performDefaultHandling)
    }

    @Test(
        "AC6: a rejected decision maps to cancelAuthenticationChallenge",
        arguments: [
            RelayTrustRejection.noLeafCertificate, .unsupportedKey, .pinMismatch, .noTrustAnchor,
        ]
    )
    func rejectedMapsToCancel(_ rejection: RelayTrustRejection) {
        let disposition = RelayTrustDecision.reject(rejection).disposition

        #expect(disposition == .cancelAuthenticationChallenge)
    }
}
#endif
