import Foundation
import Testing

#if canImport(Security)
import Security
#endif

@testable import DSHRemoteKit

// MARK: - In-memory store

@Test("the in-memory store round-trips a relay token by host UUID")
func inMemoryRelayTokenRoundTrip() async throws {
    let store = InMemorySecretStore()
    let host = UUID()
    let other = UUID()

    #expect(try await store.relayDeviceToken(forHostUUID: host) == nil)

    try await store.setRelayDeviceToken("token-for-first-host", forHostUUID: host)
    #expect(try await store.relayDeviceToken(forHostUUID: host) == "token-for-first-host")
    // A second saved host is isolated by its own UUID (SPEC §5 SavedHost).
    #expect(try await store.relayDeviceToken(forHostUUID: other) == nil)

    try await store.setRelayDeviceToken("rotated", forHostUUID: host)
    #expect(try await store.relayDeviceToken(forHostUUID: host) == "rotated")
    #expect(await store.count == 1)

    try await store.deleteRelayDeviceToken(forHostUUID: host)
    #expect(try await store.relayDeviceToken(forHostUUID: host) == nil)
    #expect(await store.count == 0)
}

@Test("each in-memory store instance is separate — no shared global state")
func inMemoryStoresDoNotShareState() async throws {
    let a = InMemorySecretStore()
    let b = InMemorySecretStore()
    let account = SecretAccount(service: "net.fernlabs.dshremote.tests", account: "host")

    try await a.setSecret("only-in-a", for: account)
    #expect(try await a.secret(for: account) == "only-in-a")
    #expect(try await b.secret(for: account) == nil)
}

@Test("deleting an absent secret is not an error")
func deleteIsIdempotent() async throws {
    let inMemory = InMemorySecretStore()
    let account = SecretAccount(service: "net.fernlabs.dshremote.tests", account: "absent")

    try await inMemory.deleteSecret(for: account)
    try await inMemory.deleteSecret(for: account)

    guard await keychainIsReachable() else {
        print("SKIP: Keychain delete not exercised here — no keychain reachable")
        return
    }
    try await KeychainSecretStore().deleteSecret(for: account)
}

@Test("relay accounts are keyed by the local host UUID under one service")
func relayAccountNaming() {
    let host = UUID(uuidString: "1F0C4A9E-2B3D-4E5F-6A7B-8C9D0E1F2A3B")!
    let account = RelayDeviceCredential.account(hostUUID: host)

    #expect(account.service == "net.fernlabs.dshremote.relay-device-token")
    #expect(account.account == "1F0C4A9E-2B3D-4E5F-6A7B-8C9D0E1F2A3B")
    #expect(account != RelayDeviceCredential.account(hostUUID: UUID()))
}

// MARK: - Keychain

@Test("the Keychain store is a generic password with device-only after-first-unlock accessibility")
func keychainItemAttributes() throws {
    #if canImport(Security)
    // Pinned independently of the live round-trip below: on a headless or sandboxed
    // box SecItem refuses writes, and SPEC §2's accessibility class is still the thing
    // most likely to be silently wrong.
    let account = RelayDeviceCredential.account(hostUUID: UUID())
    let base = KeychainSecretStore.baseQuery(for: account)
    let write = KeychainSecretStore.writeQuery(for: account, data: Data("secret".utf8))

    #expect(base[kSecClass as String] as? String == kSecClassGenericPassword as String)
    #expect(base[kSecAttrService as String] as? String == account.service)
    #expect(base[kSecAttrAccount as String] as? String == account.account)
    #expect(Set(base.keys) == [kSecClass as String, kSecAttrService as String, kSecAttrAccount as String])

    #expect(write[kSecClass as String] as? String == kSecClassGenericPassword as String)
    #expect(
        write[kSecAttrAccessible as String] as? String
            == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    )
    #expect(write[kSecValueData as String] as? Data == Data("secret".utf8))
    #else
    Issue.record("Security framework is unavailable on this platform")
    #endif
}

@Test("the Keychain store round-trips a relay token by host UUID")
func keychainRelayTokenRoundTrip() async throws {
    guard await keychainIsReachable() else {
        // Not a failure of this code: the environment refuses keychain writes. Say so
        // in the output rather than pretending the round-trip ran. See the README.
        print("SKIP: Keychain round-trip not exercised here — no keychain reachable")
        return
    }

    let store = KeychainSecretStore()
    let host = UUID()

    #expect(try await store.relayDeviceToken(forHostUUID: host) == nil)

    try await store.setRelayDeviceToken("first", forHostUUID: host)
    #expect(try await store.relayDeviceToken(forHostUUID: host) == "first")

    // Overwrite goes down the `errSecDuplicateItem` → `SecItemUpdate` branch.
    try await store.setRelayDeviceToken("two", forHostUUID: host)
    #expect(try await store.relayDeviceToken(forHostUUID: host) == "two")

    try await store.deleteRelayDeviceToken(forHostUUID: host)
    #expect(try await store.relayDeviceToken(forHostUUID: host) == nil)
}

/// Whether this process can write, read back, and delete a Keychain item. A probe
/// rather than an error-code allowlist, because the statuses that mean "no keychain
/// here" differ across macOS versions, entitlements, and sandboxes.
private func keychainIsReachable() async -> Bool {
    let store = KeychainSecretStore()
    let account = SecretAccount(
        service: RelayDeviceCredential.service,
        account: "reachability-probe-\(UUID().uuidString)"
    )
    do {
        try await store.setSecret("probe", for: account)
        let read = try await store.secret(for: account)
        try await store.deleteSecret(for: account)
        return read == "probe"
    } catch {
        return false
    }
}
