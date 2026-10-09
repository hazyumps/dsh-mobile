import Foundation

/// What the phone knows about one host capability.
///
/// SPEC §10 asks for exactly four states and is specific about why they are four
/// rather than two: a capability that is genuinely absent must not be confused with
/// one that merely failed on this attempt. The drawer's honesty depends on the
/// difference — an endpoint the host does not implement should not be shown as a
/// broken feature, and a feature that failed because the credential expired must not
/// be hidden as if it did not exist.
///
/// | state | means | what the UI does |
/// |---|---|---|
/// | ``unknown`` | never tried, or nothing learned | show it, attempt on use |
/// | ``available`` | the host answered | show it normally |
/// | ``unavailable(reason:)`` | the host does not implement it | omit it, or explain the host requirement |
/// | ``failed(reason:)`` | the attempt failed for some other reason | show the failure, offer a retry |
public enum CapabilityState: Sendable, Hashable {
    case unknown
    case available
    /// The host does not have this endpoint. The only state that justifies hiding a
    /// feature, and the only one that must never be reached through an authentication
    /// failure.
    case unavailable(reason: String)
    /// The call failed in a way that says nothing about whether the capability exists.
    case failed(reason: String)

    public var isAvailable: Bool { self == .available }

    /// Whether the feature should be treated as not existing.
    public var isAbsent: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

extension CapabilityState {
    /// The state implied by a failed call, or `nil` when the failure is no evidence.
    ///
    /// The asymmetry is the whole point of the type, and each branch below is a
    /// sentence from SPEC §10:
    ///
    /// - A transport 404 is the host saying it has no such endpoint.
    /// - `gateway/method-unavailable` is the other way it says the same thing. Both are
    ///   `unavailable`.
    /// - **Any other business refusal means the endpoint answered**, so the capability
    ///   exists. A refusal is not an absence, and treating it as one would hide working
    ///   features whenever the host felt like saying no.
    /// - An authentication failure is explicitly *not* proof of absence: the spec names
    ///   401 and 403 as "not proof that a capability is absent". The endpoint may be
    ///   perfectly present and the credential stale.
    /// - A timeout, a 502, a protocol mismatch, a changed certificate and every other
    ///   transport failure say nothing about the endpoint either.
    /// - A cancellation says nothing at all, so it returns `nil` and leaves whatever was
    ///   already known in place.
    public static func classified(from error: DshRPCError) -> CapabilityState? {
        switch error {
        case .capabilityUnavailable(let endpoint):
            return .unavailable(reason: "the host does not implement \(endpoint)")

        case .business(let error):
            // The gateway's own name for "there is no such method". It arrives as a
            // business error rather than a 404, so it has to be recognised here or a
            // missing endpoint would be recorded as available.
            if error.code == Self.methodUnavailableCode {
                return .unavailable(reason: error.message)
            }
            // It answered. It exists.
            return .available

        case .credentialRejected:
            return .failed(reason: "the device credential was refused")
        case .relayedAuthenticationFailure:
            return .failed(reason: "the relay could not authenticate to the harness")

        case .rateLimited:
            return .failed(reason: "the host is rate limiting")
        case .harnessUnavailable:
            return .failed(reason: "the harness is unavailable behind the relay")
        case .certificateChanged:
            return .failed(reason: "the host certificate changed")
        case .transportInterruption:
            return .failed(reason: "the connection was interrupted")
        case .protocolIncompatible:
            return .failed(reason: "the response did not match the protocol")
        case .unexpectedStatus(let status, _):
            return .failed(reason: "the host returned an unexpected status \(status)")

        case .cancelled:
            // Not evidence of anything. Reporting `failed` here would let a user
            // navigating away mark a working feature broken.
            return nil
        }
    }

    /// The gateway's code for a method the host does not expose, read from the
    /// installed gateway's own error-code set.
    public static let methodUnavailableCode = "gateway/method-unavailable"
}

/// What one connection to one host knows about a set of capabilities.
///
/// SPEC §10: "Maintain a small capability state per host/version." A ledger belongs to
/// a host, and the version matters because a capability can appear or disappear when
/// the harness is upgraded — so learning a new version forgets everything the previous
/// one taught, rather than carrying a stale "unavailable" into a build that has the
/// endpoint.
///
/// Deliberately not a `@MainActor` observable and not a store: it is the small piece of
/// bookkeeping the stores share, and making it observable would invite it to become a
/// second source of truth about connection state.
public struct CapabilityLedger: Sendable {
    /// The host version these states were learned against, when known.
    public private(set) var hostVersion: String?

    private var states: [String: CapabilityState] = [:]

    public init(hostVersion: String? = nil) {
        self.hostVersion = hostVersion
    }

    /// The state for `endpoint`, which is ``CapabilityState/unknown`` until something
    /// is learned about it.
    public func state(of endpoint: String) -> CapabilityState {
        states[endpoint] ?? .unknown
    }

    /// Every endpoint with a recorded state, for a diagnostic export or a test.
    public var recorded: [String: CapabilityState] { states }

    public mutating func set(_ state: CapabilityState, for endpoint: String) {
        states[endpoint] = state
    }

    /// Records that a call to `endpoint` succeeded.
    public mutating func recordSuccess(of endpoint: String) {
        states[endpoint] = .available
    }

    /// Records what a failed call implies, if it implies anything.
    ///
    /// A failure that is no evidence — a cancellation — leaves the previous state
    /// alone rather than downgrading a known-good capability.
    public mutating func record(_ error: DshRPCError, of endpoint: String) {
        guard let state = CapabilityState.classified(from: error) else { return }
        states[endpoint] = state
    }

    /// Notes the host version, forgetting everything learned against a different one.
    ///
    /// Called on connect. An unchanged version keeps the ledger, because re-learning
    /// on every reconnect would make a feature flicker between known and unknown while
    /// the app is in the background.
    public mutating func noteHostVersion(_ version: String?) {
        guard version != hostVersion else { return }
        hostVersion = version
        states.removeAll()
    }
}
