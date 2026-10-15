#if canImport(Security)
import Foundation
import Security
import Testing

@testable import DSHRemoteKit

// AC8 of #68: the challenge handler URLSession calls answers from the trust decision.
//
// `TLSTrustDecisionTests` proves that `decide` and `disposition` are right. These tests prove that
// the object URLSession asks actually uses them. The verifier found that a handler ignoring the
// decision and always answering `.useCredential` passed every other test. Each test builds a fake
// challenge with no network, hands it to the delegate of each of the transport's two sessions
// (requests, and the mux socket's upgrade), and records the answer.
//
// The fake is a `URLProtectionSpace` subclass that overrides `serverTrust`. Observed on macOS
// (2026-10-15, a scratch program): the subclass survives into
// `URLAuthenticationChallenge.protectionSpace`, `serverTrust` returns the override, and a delegate
// reached through `URLSession.delegate` receives it.

/// Which of the transport's sessions URLSession is asking.
enum ChallengeSession: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case request
    case socket

    var testDescription: String { rawValue }
}

/// What a delegate passed to the completion handler.
struct ChallengeAnswer: Equatable, Sendable, CustomStringConvertible {
    let disposition: URLSession.AuthChallengeDisposition
    let hasCredential: Bool

    var description: String {
        let name = switch disposition {
        case .useCredential: "useCredential"
        case .performDefaultHandling: "performDefaultHandling"
        case .cancelAuthenticationChallenge: "cancelAuthenticationChallenge"
        case .rejectProtectionSpace: "rejectProtectionSpace"
        @unknown default: "rawValue \(disposition.rawValue)"
        }
        return "\(name), credential: \(hasCredential ? "present" : "nil")"
    }
}

/// A protection space that carries a trust of the test's choosing. Outside a real handshake,
/// `serverTrust` is always nil, so this override is what lets a challenge carry a certificate.
///
/// `@unchecked Sendable`: the one stored property is immutable after `init`, and a `SecTrust`
/// is only read here, never evaluated or mutated.
private final class FakeProtectionSpace: URLProtectionSpace, @unchecked Sendable {
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

/// A challenge must have a sender. The handler answers through its completion handler, so
/// nothing here is called.
private final class SilentChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private func makeChallenge(
    trust: SecTrust?,
    method: String = NSURLAuthenticationMethodServerTrust
) -> URLAuthenticationChallenge {
    URLAuthenticationChallenge(
        protectionSpace: FakeProtectionSpace(trust: trust, authenticationMethod: method),
        proposedCredential: nil,
        previousFailureCount: 0,
        failureResponse: nil,
        error: nil,
        sender: SilentChallengeSender()
    )
}

/// Holds the answer the completion handler gave.
private final class AnswerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ChallengeAnswer?

    func record(_ answer: ChallengeAnswer) {
        lock.lock()
        defer { lock.unlock() }
        stored = answer
    }

    var answer: ChallengeAnswer? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// What the transport's delegate for `session` answers to `challenge`. The answer is nil when
/// the session has no delegate, or the delegate has no challenge handler.
///
/// The handler answers synchronously, so the answer is read straight after the call. A handler
/// that answered later would read as nil here, and the test would fail rather than wait.
private func delegateAnswer(
    of transport: URLSessionRelayTransport,
    session: ChallengeSession,
    to challenge: URLAuthenticationChallenge
) -> ChallengeAnswer? {
    let delegates = transport.challengeDelegates
    guard let delegate = session == .request ? delegates.request : delegates.socket else { return nil }
    let box = AnswerBox()
    delegate.urlSession?(URLSession.shared, didReceive: challenge) { disposition, credential in
        box.record(ChallengeAnswer(disposition: disposition, hasCredential: credential != nil))
    }
    return box.answer
}

@Suite("TLS challenge handler")
struct TLSChallengeHandlerTests {
    @Test(
        "AC8: a pinned transport answers the matching certificate with useCredential and a credential",
        arguments: ChallengeSession.allCases
    )
    func matchingPinUsesCredential(_ session: ChallengeSession) throws {
        let material = try TrustMaterial.load()
        let transport = URLSessionRelayTransport(pinning: .pinned(material.expectedPin))
        let challenge = makeChallenge(trust: try serverTrust([material.leaf, material.issuer]))
        // The fake must really carry the trust, or every other case here proves nothing.
        #expect(challenge.protectionSpace.serverTrust != nil)

        let answer = delegateAnswer(of: transport, session: session, to: challenge)

        #expect(answer == ChallengeAnswer(disposition: .useCredential, hasCredential: true))
    }

    @Test(
        "AC8: a pinned transport cancels a certificate under a different pin",
        arguments: ChallengeSession.allCases
    )
    func wrongPinCancels(_ session: ChallengeSession) throws {
        let material = try TrustMaterial.load()
        let transport = URLSessionRelayTransport(pinning: .pinned(material.p384OwnPin))
        let challenge = makeChallenge(trust: try serverTrust([material.leaf, material.issuer]))

        let answer = delegateAnswer(of: transport, session: session, to: challenge)

        #expect(answer == ChallengeAnswer(disposition: .cancelAuthenticationChallenge, hasCredential: false))
    }

    @Test(
        "AC8: a platform-trust transport leaves the server-trust challenge to the system",
        arguments: ChallengeSession.allCases
    )
    func platformTrustDefers(_ session: ChallengeSession) throws {
        let material = try TrustMaterial.load()
        let transport = URLSessionRelayTransport(pinning: .platformTrust)
        let challenge = makeChallenge(trust: try serverTrust([material.leaf, material.issuer]))

        let answer = delegateAnswer(of: transport, session: session, to: challenge)

        #expect(answer == ChallengeAnswer(disposition: .performDefaultHandling, hasCredential: false))
    }

    @Test(
        "AC8: a transport with no pin and no platform trust cancels the challenge",
        arguments: ChallengeSession.allCases
    )
    func noAnchorCancels(_ session: ChallengeSession) throws {
        let material = try TrustMaterial.load()
        let transport = URLSessionRelayTransport(
            pinning: RelayPinningPolicy(expectedSPKIPin: nil, requiresPlatformTrust: false)
        )
        let challenge = makeChallenge(trust: try serverTrust([material.leaf, material.issuer]))

        let answer = delegateAnswer(of: transport, session: session, to: challenge)

        #expect(answer == ChallengeAnswer(disposition: .cancelAuthenticationChallenge, hasCredential: false))
    }

    @Test(
        "AC8: a pinned transport leaves an HTTP Basic challenge to the system",
        arguments: ChallengeSession.allCases
    )
    func nonServerTrustDefers(_ session: ChallengeSession) throws {
        let material = try TrustMaterial.load()
        let transport = URLSessionRelayTransport(pinning: .pinned(material.expectedPin))
        // It carries the matching trust, so only the method can explain a non-credential answer.
        let challenge = makeChallenge(
            trust: try serverTrust([material.leaf, material.issuer]),
            method: NSURLAuthenticationMethodHTTPBasic
        )

        let answer = delegateAnswer(of: transport, session: session, to: challenge)

        #expect(answer == ChallengeAnswer(disposition: .performDefaultHandling, hasCredential: false))
    }

    /// Today's behaviour, kept on purpose and recorded here. The security reviewer noted that
    /// cancelling would be stricter. URLSession does not send a server-trust challenge without a
    /// trust, and if it did, the system's default handling would still evaluate the chain.
    @Test(
        "AC8: a server-trust challenge without a trust is left to the system (today's behaviour)",
        arguments: ChallengeSession.allCases
    )
    func missingTrustDefers(_ session: ChallengeSession) throws {
        let material = try TrustMaterial.load()
        let transport = URLSessionRelayTransport(pinning: .pinned(material.expectedPin))
        let challenge = makeChallenge(trust: nil)

        let answer = delegateAnswer(of: transport, session: session, to: challenge)

        #expect(answer == ChallengeAnswer(disposition: .performDefaultHandling, hasCredential: false))
    }
}
#endif
