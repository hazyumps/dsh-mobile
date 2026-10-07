import Foundation
import Testing

@testable import DSHRemoteKit

@Test("pairing-claim-response.json decodes field for field")
func pairingClaimResponseDecodes() throws {
    let claim = try Fixtures.decode(PairingClaimResponse.self, .pairingClaimResponse)

    #expect(claim.deviceId == "9f2c41ab30d7e155")
    #expect(claim.token == "REDACTED-43-CHAR-BASE64URL-TOKEN--------")
    #expect(claim.expiresAt == 1_794_004_238_912)
    #expect(claim.fingerprint == "7pcXvn2Kosz4qWgFpUmIao9YQ05bXYTLbfP0IskaeN4=")

    let object = try Fixtures.object(.pairingClaimResponse)
    #expect(Set(object.keys) == ["deviceId", "token", "expiresAt", "fingerprint"])
}

@Test("a claim response whose fingerprint is JSON null decodes")
func claimFingerprintOptional() throws {
    let payload = try JSONEncoder().encode(JSONValue.object([
        "deviceId": .string("dev-1"),
        "token": .string("tok"),
        "expiresAt": .int(1_794_004_238_912),
        "fingerprint": .null,
    ]))
    let claim = try JSONDecoder().decode(PairingClaimResponse.self, from: payload)

    #expect(claim.fingerprint == nil)
    #expect(claim.deviceId == "dev-1")

    // Absent is accepted too.
    let without = try Fixtures.decode(
        PairingClaimResponse.self,
        mutatedFrom: .pairingClaimResponse,
        removing: ["fingerprint"]
    )
    #expect(without.fingerprint == nil)
    #expect(without.deviceId == "9f2c41ab30d7e155")
}

@Test("a claim credential is expired against a caller-supplied clock")
func claimExpiryUsesSuppliedClock() throws {
    let claim = try Fixtures.decode(PairingClaimResponse.self, .pairingClaimResponse)

    #expect(!claim.isExpired(clock: FixedEpochClock(millis: claim.expiresAt - 1)))
    #expect(claim.isExpired(clock: FixedEpochClock(millis: claim.expiresAt)))
    #expect(claim.isExpired(clock: FixedEpochClock(millis: claim.expiresAt + 1)))
}

@Test("forbidden-unpaired.json decodes as the relay's 403 body")
func forbiddenUnpairedDecodes() throws {
    let refusal = try Fixtures.decode(RelayErrorResponse.self, .forbiddenUnpaired)

    #expect(refusal.error == "forbidden")
    #expect(refusal.message == "pair this device with the relay first")
}

@Test("the relay refusal carries no credential material to redact")
func relayRefusalEncodesOnlyItsTwoFields() throws {
    let refusal = try Fixtures.decode(RelayErrorResponse.self, .forbiddenUnpaired)
    let object = try #require(
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(refusal)).objectValue
    )

    #expect(Set(object.keys) == ["error", "message"])
}
