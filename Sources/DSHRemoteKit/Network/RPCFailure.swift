import Foundation

/// What the UI must do about a failed exchange.
///
/// One case per row of SPEC §6.9's table. Kept separate from the error type so
/// the presentation decision is a value a test can assert on, and so a new error
/// code can be added without the UI having to learn a new switch.
public enum RPCFailureGuidance: Sendable, Hashable {
    /// Preserve the draft; reconnect in the foreground. SPEC §6.9 "Offline /
    /// transport interruption". No banner is owed — the connection status already
    /// says Offline.
    case preserveDraftAndReconnect
    /// Explain credential rejection and offer re-pair. SPEC §6.9 "Relay 403".
    /// Never retried: the credential will not become valid by asking again.
    case pairAgain
    /// Explain that the *relay* failed to authenticate to the harness. SPEC §6.9
    /// "Relayed 401": re-pairing the phone is not the fix and must not be
    /// presented as one.
    case relayToHarnessAuthentication
    /// Stop; say the certificate changed; offer an explicit re-pair. SPEC §6.9
    /// "TLS pin mismatch". Never falls back to platform trust (SPEC §3.2).
    case certificateChangedRePair
    /// Hide or disable that one feature with an explanation. SPEC §6.9 "404
    /// optional capability".
    case hideCapability
    /// Wait the given seconds before trying again. SPEC §6.9 "429".
    case backOff(seconds: Double)
    /// Show "harness unavailable behind relay" and keep retrying within the
    /// bounded budget. SPEC §6.9 "502".
    case harnessUnavailable
    /// Show the host's own readable reason and retain the user's input. SPEC §6.9
    /// "Business refusal".
    case showBusinessRefusal
    /// Show protocol incompatibility, retain state and draft, log redacted
    /// diagnostics. SPEC §6.9 "Malformed response".
    case protocolIncompatibility
}

/// Every way an exchange with the relay can fail, after classification.
///
/// One type across the RPC, binary-upload, event-result, and pairing paths, so
/// the UI's error presentation has one thing to switch on. ``guidance`` is the
/// SPEC §6.9 mapping.
public enum DshRPCError: Error, Sendable, Hashable {
    /// HTTP 200 with `result.ok == false`. The typed error inside a successful
    /// HTTP response (SPEC §6.2). `code`, `message`, and `details.endpoint` are
    /// all carried through — the last one is what names the offending endpoint.
    case business(RPCError)

    /// HTTP 403. SPEC §3.2 step 4: the relay mints no session, and the published
    /// distinction is 403-never-401 (SPEC §6.1).
    ///
    /// `relayError` is the decoded `{error, message}` body when the peer sent one.
    /// SPEC §3.2 also warns that repeated pairing failures lock the source address
    /// out, "which is a rate limit rather than a wrong code" — see
    /// ``isPairingLockout``.
    case credentialRejected(relayError: RelayErrorResponse?, status: Int)

    /// HTTP 401: the relay could not authenticate itself to the harness. SPEC §6.9
    /// keeps this distinct from 403 precisely so the app does not tell the user to
    /// re-pair.
    case relayedAuthenticationFailure(relayError: RelayErrorResponse?, status: Int)

    /// HTTP 429. ``retryAfterSeconds`` is the honoured `Retry-After`, or the
    /// 60-second default SPEC §6.9 specifies when the header is absent.
    case rateLimited(retryAfterSeconds: Double, attempts: Int)

    /// HTTP 502 after the bounded retry budget was spent. SPEC §6.9 "Show harness
    /// unavailable behind relay; bounded retry".
    case harnessUnavailable(attempts: Int)

    /// HTTP 404 for an endpoint the host does not implement. SPEC §6.9 "Hide or
    /// disable that feature". For `session/uploadFileBinary` this is also the only
    /// condition that permits the base64 `fileUploads/upload` fallback (SPEC §6.8).
    case capabilityUnavailable(endpoint: String)

    /// The peer's certificate did not match the pin. Distinct from
    /// ``credentialRejected`` because the user action is different.
    case certificateChanged(detail: String)

    /// No network path, or the connection dropped. SPEC §6.9 "Offline".
    case transportInterruption(detail: String)

    /// The exchange was cancelled. Never presented.
    case cancelled

    /// A response that parsed as neither the expected envelope nor a bare
    /// `{ok, …}` body, or one whose typed `value` did not decode. SPEC §6.9
    /// "Malformed response": protocol incompatibility, retain state, do not crash.
    case protocolIncompatible(reason: String)

    /// Any other status. Carried whole rather than folded into one of the cases
    /// above, because SPEC §6.9's table names only five statuses and guessing at
    /// the rest would hide them.
    case unexpectedStatus(status: Int, endpoint: String)

    // MARK: - SPEC §6.9 mapping

    public var guidance: RPCFailureGuidance {
        switch self {
        case .business: .showBusinessRefusal
        case .credentialRejected: .pairAgain
        case .relayedAuthenticationFailure: .relayToHarnessAuthentication
        case .rateLimited(let seconds, _): .backOff(seconds: seconds)
        case .harnessUnavailable: .harnessUnavailable
        case .capabilityUnavailable: .hideCapability
        case .certificateChanged: .certificateChangedRePair
        case .transportInterruption, .cancelled: .preserveDraftAndReconnect
        case .protocolIncompatible: .protocolIncompatibility
        case .unexpectedStatus: .preserveDraftAndReconnect
        }
    }

    /// Whether retrying the identical request could succeed. SPEC §6.9 makes 403
    /// and a pin mismatch terminal; 429 and 502 are the two it names as retryable.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .harnessUnavailable: true
        default: false
        }
    }

    /// The typed business error, when there is one.
    public var rpcError: RPCError? {
        if case .business(let error) = self { error } else { nil }
    }

    /// The endpoint the failure is attributed to, when the failure knows one.
    public var endpoint: String? {
        switch self {
        case .business(let error): error.details?.endpoint
        case .capabilityUnavailable(let endpoint), .unexpectedStatus(_, let endpoint): endpoint
        case .credentialRejected, .relayedAuthenticationFailure, .rateLimited,
             .harnessUnavailable, .certificateChanged, .transportInterruption,
             .cancelled, .protocolIncompatible:
            nil
        }
    }

    /// SPEC §3.2 step 4: "Repeated failures lock the source address out, which is
    /// a rate limit rather than a wrong code, so do not present a lockout as a
    /// bad code."
    ///
    /// unverified: the relay's lockout response was never captured, so the app
    /// cannot be certain which 403 means "wrong code" and which means "locked
    /// out". This is true only when the relay *says* so in its `error` field —
    /// `rate-limit`, `rate_limited` or `too-many-requests` — and is false for the
    /// one body that is captured (`forbidden`). Message prose is deliberately not
    /// inspected, because matching on prose is how a wrong-code refusal gets
    /// relabelled as a lockout.
    public var isPairingLockout: Bool {
        guard case .credentialRejected(let relayError, _) = self,
              let code = relayError?.error.lowercased()
        else { return false }
        return ["rate-limit", "rate_limited", "ratelimit", "too-many-requests", "locked"]
            .contains(code)
    }

    /// The readable reason SPEC §6.9 asks to show, when the peer supplied one.
    public var readableReason: String? {
        switch self {
        case .business(let error): error.message
        case .credentialRejected(let error, _), .relayedAuthenticationFailure(let error, _): error?.message
        case .rateLimited(let seconds, _): "rate limited; retry after \(Int(seconds))s"
        case .harnessUnavailable: "harness is unavailable behind the relay"
        case .capabilityUnavailable(let endpoint): "the host does not implement \(endpoint)"
        case .certificateChanged(let detail): "the relay's certificate changed: \(detail)"
        case .transportInterruption(let detail): detail
        case .cancelled: nil
        case .protocolIncompatible(let reason): reason
        case .unexpectedStatus(let status, let endpoint): "HTTP \(status) from \(endpoint)"
        }
    }
}

// MARK: - Retry policy

/// How many times, and after how long, an exchange may be repeated.
///
/// SPEC §6.9 names bounded retry for 502 and `Retry-After` for 429, and no other
/// retry at all. SPEC §3.4 forbids the app from automatically resending an
/// *uncertain prompt*, and a retried `session/prompt` is exactly that — a 502 may
/// have reached the harness. So the policy is a per-call value: prompt submission
/// passes ``none`` and reconciles by request ID instead, while read-only calls
/// take the default.
public struct RPCFailureRetryPolicy: Sendable, Hashable {
    /// Total attempts, including the first. `1` disables retry.
    public var maxAttempts: Int
    /// Used when a 429 arrives without a usable `Retry-After`. SPEC §6.9: "use 60
    /// seconds if missing".
    public var defaultRetryAfterSeconds: Double
    /// Used between 502 attempts, where the peer supplied no delay of its own.
    /// Jittered exponential backoff "starting at 0.5 seconds and capped at 10
    /// seconds" is the reconnect schedule SPEC §6.4 states for the socket; a
    /// unary retry has no stated schedule, so this reuses that shape with a small
    /// cap.
    public var backoffBaseSeconds: Double
    public var backoffCapSeconds: Double

    public init(
        maxAttempts: Int = 3,
        defaultRetryAfterSeconds: Double = 60,
        backoffBaseSeconds: Double = 0.5,
        backoffCapSeconds: Double = 10
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.defaultRetryAfterSeconds = defaultRetryAfterSeconds
        self.backoffBaseSeconds = backoffBaseSeconds
        self.backoffCapSeconds = backoffCapSeconds
    }

    /// Exactly one attempt. For anything whose retry could duplicate a user
    /// action (SPEC §3.4, SPEC §6.6).
    public static let none = RPCFailureRetryPolicy(maxAttempts: 1)

    public static let `default` = RPCFailureRetryPolicy()

    /// Delay before attempt number `attempt` (1-based) of a retryable failure
    /// whose own delay is unknown.
    public func backoff(attempt: Int) -> Double {
        let exponent = Double(max(0, attempt - 1))
        return min(backoffCapSeconds, backoffBaseSeconds * pow(2, exponent))
    }
}

// MARK: - Retry-After

/// Parses the `Retry-After` header, which is specified as either delta-seconds or
/// an HTTP-date.
///
/// unverified: the relay's own header format was never captured. Both forms are
/// RFC 9110-legal for a 429, so both are read; delta-seconds is tried first
/// because it is what a service typically emits and because a delta-seconds value
/// can look like nothing else.
enum HTTPRetryAfter {
    static func seconds(from headerValue: String?, now: Date) -> Double? {
        guard let raw = headerValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if let seconds = Double(raw), seconds >= 0, seconds.isFinite {
            return seconds
        }
        guard let date = httpDate(raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// `IMF-fixdate` only. The two obsolete RFC 850 / asctime forms are legal to
    /// *send* but not required to be read, and building a formatter per call keeps
    /// this free of shared mutable state under strict concurrency.
    private static func httpDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: raw)
    }
}
