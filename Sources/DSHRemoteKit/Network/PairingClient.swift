import Foundation

/// Pairing (deliverable 5): decode and validate SPEC §3.2's payload, claim it at
/// `POST /relay/pair`, return the credential.
///
/// Three rules this type exists to hold in one place:
///
/// - The payload is refused for the reasons SPEC §3.2 step 1 lists — wrong `kind`,
///   unsupported `v`, non-HTTPS, empty code, expired — and each refusal is its own
///   case so the UI can say something actionable. A plain-HTTP payload gets the
///   HTTPS-required message, not a generic parse failure.
/// - A supplied pin is never overridden by a pin learned from a response. SPEC §3.2
///   step 3: "Never learn a pin from an unverified network response." When both
///   sides carry one they must agree, and a disagreement is a hard error.
/// - The one-time code is never persisted. It exists as a field on the decoded
///   payload, is sent once in the claim body, and is absent from everything this
///   type returns. There is no disk, Keychain, or log write in this file.
public struct PairingClient: Sendable {
    public let transport: any RelayTransport

    private let exchange: RelayExchange
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        transport: any RelayTransport,
        sleeper: any RelaySleeper = TaskRelaySleeper(),
        clock: any EpochClock = SystemEpochClock(),
        retryPolicy: RPCFailureRetryPolicy = .default
    ) {
        self.transport = transport
        self.exchange = RelayExchange(
            transport: transport,
            sleeper: sleeper,
            clock: clock,
            retryPolicy: retryPolicy
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// The claim endpoint, relative to the payload's HTTPS origin.
    ///
    /// A path, not a URL: SPEC §3.2 step 4 says the claim goes to "the payload
    /// URL's `/relay/pair`", which is what stops a payload from pointing the
    /// credential somewhere else.
    public static let claimPath = "/relay/pair"

    // MARK: - Decoding and validating the payload

    /// Decodes a QR or pasted payload and checks it is one this app may claim.
    ///
    /// Decoding and validation are separate steps, matching the split already in
    /// ``PairingPayload``: a wrong `kind` must still *decode*, so the app can say
    /// which kind it rejected rather than "not valid JSON".
    ///
    /// - Throws: ``PairingError/malformedPayload(reason:)`` when the bytes are not
    ///   the payload object, ``PairingError/invalidPayload(_:)`` when they are but
    ///   the payload must be refused.
    public func decodePayload(_ data: Data, clock: (any EpochClock)? = nil) throws -> PairingPayload {
        let payload: PairingPayload
        do {
            payload = try decoder.decode(PairingPayload.self, from: data)
        } catch {
            throw PairingError.malformedPayload(
                reason: "the pairing data is not a relay pairing payload"
            )
        }
        do {
            try payload.validate(clock: clock ?? SystemEpochClock())
        } catch let error as PairingPayload.ValidationError {
            throw PairingError.invalidPayload(error)
        }
        return payload
    }

    // MARK: - Claiming

    /// Claims a validated payload and returns the relay credential.
    ///
    /// SPEC §3.2 step 4: `POST <payload url>/relay/pair`,
    /// `Content-Type: application/json`, body `{"code":…,"name":…}`, without
    /// following redirects. The no-redirect rule is enforced by the transport
    /// (``URLSessionRelayTransport`` refuses every redirect), because "do not
    /// follow" is a property of the connection rather than of the request.
    ///
    /// The returned ``PairingClaimResponse`` is the whole credential. Nothing else
    /// survives this call — in particular the pairing code does not, and no
    /// persistence of any kind happens here.
    @discardableResult
    public func claim(
        _ payload: PairingPayload,
        deviceName: String,
        retryPolicy: RPCFailureRetryPolicy? = nil
    ) async throws -> PairingClaimResponse {
        guard let origin = payload.relayURL else {
            throw PairingError.invalidPayload(.invalidURL(payload.url))
        }

        // No `Authorization` header: the one-time code is the credential for this
        // one call, and there is no device token yet.
        let url = try RelayURL.resolve(Self.claimPath, against: origin)
        var headers: [String: String] = [:]
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        let body = try encoder.encode(
            ClaimBody(code: payload.code, name: deviceName)
        )
        let request = RelayHTTPRequest(url: url, method: "POST", headers: headers, body: body)

        var usingExchange = exchange
        if let retryPolicy {
            usingExchange.retryPolicy = retryPolicy
        }

        let response: RelayHTTPResponse
        do {
            response = try await usingExchange.perform(request, endpoint: "relay/pair")
        } catch let error as DshRPCError {
            throw PairingError.exchange(error)
        }

        let claim: PairingClaimResponse
        do {
            claim = try decoder.decode(PairingClaimResponse.self, from: response.body)
        } catch {
            throw PairingError.malformedPayload(
                reason: "the relay's claim response did not carry deviceId, token and expiresAt"
            )
        }

        // SPEC §3.2 step 3/6: a pin the user already has is the trust anchor, and
        // "when both payload and response contain pins, require agreement".
        if let payloadPin = payload.fingerprint,
           let claimPin = claim.fingerprint,
           !SPKIPin.matches(pin: payloadPin, pin: claimPin) {
            throw PairingError.pinMismatch(payloadPin: payloadPin, claimPin: claimPin)
        }

        return claim
    }

    /// The claim body. A private type so the one place the pairing code is
    /// serialised is also the only place that can see it.
    private struct ClaimBody: Encodable {
        var code: String
        var name: String
    }
}

/// Everything that can refuse a pairing.
public enum PairingError: Error, Sendable, Hashable {
    /// The bytes were not a pairing payload object at all.
    case malformedPayload(reason: String)
    /// The payload decoded but must not be claimed. Carries the model's own
    /// refusal so the UI can map each one to its own message (SPEC §6.9).
    case invalidPayload(PairingPayload.ValidationError)
    /// The relay answered with a pin that disagrees with the payload's. SPEC §3.2:
    /// a hard error with an explicit re-pair, never a silent fallback.
    case pinMismatch(payloadPin: String, claimPin: String)
    /// A transport or HTTP-status failure, classified by the same SPEC §6.9 rules
    /// as every other exchange. The interesting members here are
    /// ``DshRPCError/credentialRejected(relayError:status:)`` (HTTP 403, the
    /// wrong-code or refused case) and ``DshRPCError/rateLimited(retryAfterSeconds:attempts:)``
    /// (the lockout SPEC §3.2 warns is a rate limit rather than a bad code).
    case exchange(DshRPCError)

    /// The SPEC §6.9 guidance, for the failures that have one.
    public var guidance: RPCFailureGuidance? {
        switch self {
        case .exchange(let error): error.guidance
        // A refused payload is not a transport state: the app stays on the pairing
        // screen and explains. §6.9's table has no row for it, so it gets none.
        case .malformedPayload, .invalidPayload: nil
        case .pinMismatch: .certificateChangedRePair
        }
    }

    /// SPEC §3.2 step 4: repeated failures lock the source address out, and a
    /// lockout must not be presented as a bad code. A 429 is unambiguous; a 403
    /// only when the relay names itself a rate limit (see
    /// ``DshRPCError/isPairingLockout``).
    public var isLockout: Bool {
        switch self {
        case .exchange(.rateLimited): true
        case .exchange(let error): error.isPairingLockout
        default: false
        }
    }

    /// Whether the user should be offered a fresh code, as opposed to a wait.
    public var shouldOfferFreshCode: Bool {
        switch self {
        case .exchange(.credentialRejected): !isLockout
        case .invalidPayload(.expired): true
        default: false
        }
    }

    public var readableReason: String? {
        switch self {
        case .malformedPayload(let reason): reason
        case .invalidPayload(let error): error.description
        case .pinMismatch(let payloadPin, let claimPin):
            "the relay published a different pin (\(claimPin)) than the pairing payload (\(payloadPin))"
        case .exchange(let error): error.readableReason
        }
    }
}
