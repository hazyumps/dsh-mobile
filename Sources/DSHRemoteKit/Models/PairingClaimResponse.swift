import Foundation

/// The body of a successful `POST /relay/pair` (SPEC §6.3).
///
/// Proven by `Fixtures/pairing-claim-response.json`. The token is the whole
/// credential and does not expire on use; it is the only value here that must
/// reach the Keychain and never a metadata file or a log.
public struct PairingClaimResponse: Codable, Sendable, Hashable {
    /// Relay device ID. Opaque string (SPEC §5).
    public var deviceId: String
    /// Bearer token sent on every relay request, including the WebSocket upgrade.
    public var token: String
    /// Credential expiry in epoch milliseconds.
    public var expiresAt: Int64
    /// SPKI pin the relay published alongside the credential. When both the pairing
    /// payload and this response carry one, SPEC §3.2 requires agreement.
    public var fingerprint: String?

    enum CodingKeys: String, CodingKey {
        case deviceId
        case token
        case expiresAt
        case fingerprint
    }

    public init(
        deviceId: String,
        token: String,
        expiresAt: Int64,
        fingerprint: String? = nil
    ) {
        self.deviceId = deviceId
        self.token = token
        self.expiresAt = expiresAt
        self.fingerprint = fingerprint
    }

    /// Whether the relay's own credential lifetime has passed for `clock`.
    ///
    /// unverified: SPEC §6.3 says the token "does not expire on use" but the capture
    /// carries an `expiresAt`; how the host treats that date is not established.
    public func isExpired(clock: any EpochClock = SystemEpochClock()) -> Bool {
        expiresAt <= clock.epochMillis()
    }
}

/// A relay-level refusal, which is `HTTP 403` with this body and never `401`
/// (SPEC §3.2 step 4, §6.3).
///
/// Proven by `Fixtures/forbidden-unpaired.json`. This is the transport-layer
/// refusal; it is not the RPC envelope's typed error in ``RPCError``, which rides
/// inside an `HTTP 200`.
public struct RelayErrorResponse: Codable, Sendable, Hashable {
    /// Machine-readable refusal, e.g. `forbidden`.
    public var error: String
    /// Readable reason to show the user.
    public var message: String

    public init(error: String, message: String) {
        self.error = error
        self.message = message
    }
}
