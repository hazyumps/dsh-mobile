import Foundation

/// The JSON carried by a `dsh-relay` QR code or pasted into the app.
///
/// Shape is proven by `Fixtures/pairing-payload.json` and SPEC §6.3. Every field is
/// decoded as a plain value — never as an enum with a fixed case list — so a wrong
/// `kind`, a future `v`, or an `http` URL still decodes and is refused by
/// ``PairingPayload/validate(clock:)`` instead of failing as a decode error.
public struct PairingPayload: Codable, Sendable, Hashable {
    /// Payload format version. SPEC §6.3 shows `1`; validation refuses anything else.
    public var version: Int
    /// Must be ``PairingPayload/relayPairKind``.
    public var kind: String
    /// TLS origin of the relay, e.g. `https://192.0.2.10:3443`.
    public var url: String
    /// Plain-HTTP companion origin. Present in the capture; SPEC §3.2 step 1 says to
    /// ignore it, and v1 rejects plain HTTP pairing outright.
    public var plainUrl: String?
    /// Optional base64 SHA-256 of the DER SubjectPublicKeyInfo. SPEC §6.3.
    public var fingerprint: String?
    /// Single-use pairing code.
    public var code: String
    /// Expiry in epoch milliseconds.
    public var expiresAt: Int64

    /// The only `kind` this build accepts (SPEC §3.2 step 1).
    public static let relayPairKind = "dsh-relay-pair"

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind
        case url
        case plainUrl
        case fingerprint
        case code
        case expiresAt
    }

    public init(
        version: Int,
        kind: String,
        url: String,
        plainUrl: String? = nil,
        fingerprint: String? = nil,
        code: String,
        expiresAt: Int64
    ) {
        self.version = version
        self.kind = kind
        self.url = url
        self.plainUrl = plainUrl
        self.fingerprint = fingerprint
        self.code = code
        self.expiresAt = expiresAt
    }

    /// Parsed relay origin, or `nil` when `url` is not a URL this platform can use.
    public var relayURL: URL? { URL(string: url) }

    /// Hostname to show the user before claiming the pairing (SPEC §3.2 step 2).
    public var hostname: String? { URLComponents(string: url)?.host }

    /// Reasons a decoded payload can still be refused. Kept separate from
    /// `DecodingError` so the UI can map each one to its own message (SPEC §6.9).
    public enum ValidationError: Error, Hashable, Sendable, CustomStringConvertible {
        /// `kind` was not `dsh-relay-pair`.
        case unexpectedKind(String)
        /// `v` was not a version this build understands.
        case unsupportedVersion(Int)
        /// `url` did not parse as an absolute URL with a host.
        case invalidURL(String)
        /// `url` was not HTTPS. SPEC §3.2: v1 requires the TLS origin.
        case httpsRequired(String)
        /// `code` was empty. SPEC §3.2 step 1 requires a nonempty code.
        case emptyCode
        /// The code's window had already passed.
        ///
        /// - Parameters:
        ///   - expiresAt: The payload's expiry in epoch milliseconds.
        ///   - now: The clock reading it was compared against.
        case expired(expiresAt: Int64, now: Int64)

        public var description: String {
            switch self {
            case .unexpectedKind(let kind): "pairing payload kind \"\(kind)\" is not supported"
            case .unsupportedVersion(let version): "pairing payload version \(version) is not supported"
            case .invalidURL(let url): "pairing payload url is not usable: \(url)"
            case .httpsRequired(let url): "pairing requires HTTPS, got: \(url)"
            case .emptyCode: "pairing code is empty"
            case .expired(let expiresAt, let now):
                "pairing code expired at \(expiresAt) (clock at \(now))"
            }
        }
    }

    /// Rejects a payload the app must not claim.
    ///
    /// Order follows SPEC §3.2 step 1: kind, then version, then URL scheme, then
    /// code, then expiry. Throws the first refusal found.
    public func validate(clock: any EpochClock = SystemEpochClock()) throws {
        guard kind == Self.relayPairKind else {
            throw ValidationError.unexpectedKind(kind)
        }
        // unverified: the harness never advertises which versions it emits, so 1 is
        // the only accepted value (SPEC §6.3).
        guard version == 1 else {
            throw ValidationError.unsupportedVersion(version)
        }

        guard let components = URLComponents(string: url), components.scheme != nil else {
            throw ValidationError.invalidURL(url)
        }
        guard let host = components.host, !host.isEmpty else {
            throw ValidationError.invalidURL(url)
        }
        guard components.scheme?.lowercased() == "https" else {
            throw ValidationError.httpsRequired(url)
        }

        guard !code.isEmpty else {
            throw ValidationError.emptyCode
        }

        let now = clock.epochMillis()
        guard expiresAt > now else {
            throw ValidationError.expired(expiresAt: expiresAt, now: now)
        }
    }

    /// Whether the code's window has passed for `clock`.
    public func isExpired(clock: any EpochClock = SystemEpochClock()) -> Bool {
        expiresAt <= clock.epochMillis()
    }
}
