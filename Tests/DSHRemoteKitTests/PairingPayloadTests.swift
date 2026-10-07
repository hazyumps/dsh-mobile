import Foundation
import Testing

@testable import DSHRemoteKit

/// A fixed clock inside the captured payload's validity window. The fixture's
/// `expiresAt` is 2025-08-18T06:13:20Z, so a real clock today is already past it —
/// validation must take the clock from the caller.
let captureClock = FixedEpochClock(millis: 1_755_500_000_000 - 60_000)

/// The decoded capture, ready to mutate for refusal tests.
func capturedPairingPayload() throws -> PairingPayload {
    try Fixtures.decode(PairingPayload.self, .pairingPayload)
}

@Test("pairing-payload.json decodes field for field")
func pairingPayloadDecodes() throws {
    let payload = try capturedPairingPayload()

    #expect(payload.version == 1)
    #expect(payload.kind == "dsh-relay-pair")
    #expect(payload.url == "https://192.0.2.10:3443")
    #expect(payload.plainUrl == "http://192.0.2.10:3444")
    #expect(payload.fingerprint == "3q2+7wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
    #expect(payload.code == "48213977")
    #expect(payload.expiresAt == 1_755_500_000_000)
    #expect(payload.hostname == "192.0.2.10")
    #expect(payload.relayURL?.scheme == "https")
}

@Test("PairingPayload re-encodes with the captured wire keys")
func pairingPayloadRoundTrips() throws {
    let payload = try capturedPairingPayload()
    let encoded = try JSONEncoder().encode(payload)
    let redecoded = try JSONDecoder().decode(PairingPayload.self, from: encoded)
    let encodedObject = try #require(
        try JSONDecoder().decode(JSONValue.self, from: encoded).objectValue
    )

    #expect(Set(encodedObject.keys) == ["v", "kind", "url", "plainUrl", "fingerprint", "code", "expiresAt"])
    #expect(redecoded == payload)
}

@Test("a payload that passes every check validates")
func validPairingPayloadAccepts() throws {
    let payload = try capturedPairingPayload()
    try payload.validate(clock: captureClock)
    #expect(!payload.isExpired(clock: captureClock))
}

@Test("an unexpired code expiring exactly now is refused")
func pairingExpiryBoundary() throws {
    let payload = try capturedPairingPayload()
    let exact = FixedEpochClock(millis: payload.expiresAt)

    #expect(payload.isExpired(clock: exact))
    #expect(throws: PairingPayload.ValidationError.expired(
        expiresAt: payload.expiresAt,
        now: payload.expiresAt
    )) {
        try payload.validate(clock: exact)
    }
}

@Test("A02: the wrong kind is refused, and still decodes")
func wrongKindRejected() throws {
    // Decoding must not reject an unrecognised value, so the refusal is a validation
    // error the UI can explain — not a parse failure.
    let payload = try Fixtures.decode(
        PairingPayload.self,
        mutatedFrom: .pairingPayload,
        setting: ["kind": .string("dsh-relay-pair-v2")]
    )

    #expect(payload.kind == "dsh-relay-pair-v2")
    #expect(throws: PairingPayload.ValidationError.unexpectedKind("dsh-relay-pair-v2")) {
        try payload.validate(clock: captureClock)
    }
}

@Test("A02: an unsupported version is refused")
func wrongVersionRejected() throws {
    let payload = try capturedPairingPayload()
    var bumped = payload
    bumped.version = 2

    #expect(throws: PairingPayload.ValidationError.unsupportedVersion(2)) {
        try bumped.validate(clock: captureClock)
    }

    // Same refusal through the wire bytes, proving `v` is not decoded as an enum.
    let decoded = try Fixtures.decode(
        PairingPayload.self,
        mutatedFrom: .pairingPayload,
        setting: ["v": .int(7)]
    )
    #expect(throws: PairingPayload.ValidationError.unsupportedVersion(7)) {
        try decoded.validate(clock: captureClock)
    }
}

@Test("A02: a non-HTTPS url is refused with an actionable reason")
func nonHTTPSPairingURLRejected() throws {
    var plain = try capturedPairingPayload()
    plain.url = try #require(plain.plainUrl)

    #expect(throws: PairingPayload.ValidationError.httpsRequired("http://192.0.2.10:3444")) {
        try plain.validate(clock: captureClock)
    }

    // The captured plainUrl is ignored by validation: an HTTPS `url` plus an HTTP
    // `plainUrl` still pairs (SPEC §3.2 step 1).
    try capturedPairingPayload().validate(clock: captureClock)
}

@Test("a url that is not an absolute URL with a host is refused")
func unusablePairingURLRejected() throws {
    for bad in ["", "not a url", "192.0.2.10:3443", "https://"] {
        var payload = try capturedPairingPayload()
        payload.url = bad
        #expect(throws: PairingPayload.ValidationError.invalidURL(bad), "url \(bad.debugDescription)") {
            try payload.validate(clock: captureClock)
        }
    }
}

@Test("an empty code is refused")
func emptyCodeRejected() throws {
    var payload = try capturedPairingPayload()
    payload.code = ""

    #expect(throws: PairingPayload.ValidationError.emptyCode) {
        try payload.validate(clock: captureClock)
    }
}

@Test("an expired code is refused")
func expiredCodeRejected() throws {
    let payload = try capturedPairingPayload()
    let later = FixedEpochClock(millis: payload.expiresAt + 1)

    #expect(payload.isExpired(clock: later))
    #expect(throws: PairingPayload.ValidationError.expired(
        expiresAt: payload.expiresAt,
        now: payload.expiresAt + 1
    )) {
        try payload.validate(clock: later)
    }
}

@Test("an unknown pairing payload key decodes and is ignored")
func unknownPairingPayloadKeyTolerated() throws {
    let payload = try Fixtures.decode(
        PairingPayload.self,
        mutatedFrom: .pairingPayload,
        setting: [
            "futureField": .object(["nested": .array([.int(1), .string("x"), .null])]),
            "attestation": .string("proof-of-possession"),
        ]
    )

    let original = try capturedPairingPayload()
    #expect(payload == original)
    try payload.validate(clock: captureClock)
}

@Test("fingerprint and plainUrl are optional on the wire")
func optionalPairingFieldsDecode() throws {
    let payload = try Fixtures.decode(
        PairingPayload.self,
        mutatedFrom: .pairingPayload,
        setting: ["fingerprint": .null, "plainUrl": .null]
    )

    #expect(payload.fingerprint == nil)
    #expect(payload.plainUrl == nil)
    try payload.validate(clock: captureClock)
}
