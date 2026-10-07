import Foundation

#if canImport(Security)
import Security
#endif

/// Identifies one stored secret. `service` scopes it to a capability of the app and
/// `account` scopes it within that capability — for relay credentials, the local host
/// UUID (SPEC §5 SavedHost: "Keychain credential reference").
public struct SecretAccount: Hashable, Sendable {
    public var service: String
    public var account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

/// Storage for values that must never land in a metadata file or a log (SPEC §2, §8
/// A03).
///
/// Asynchronous so an in-memory or actor-backed implementation can satisfy it too.
/// Implementations must be `Sendable`: calls arrive from UI-isolated stores.
public protocol SecretStore: Sendable {
    /// Returns the stored value, or `nil` when nothing is stored for `account`.
    func secret(for account: SecretAccount) async throws -> String?

    /// Replaces any existing value for `account`.
    func setSecret(_ secret: String, for account: SecretAccount) async throws

    /// Removes the value. Idempotent: removing an absent secret is not an error.
    func deleteSecret(for account: SecretAccount) async throws
}

/// Naming for the relay device credential, plus the three operations SPEC §3.2 step 5
/// requires of it, keyed by the local host UUID.
public enum RelayDeviceCredential {
    /// Keychain service for relay device tokens. Changing it orphans stored tokens.
    public static let service = "net.fernlabs.dshremote.relay-device-token"

    /// The account for one saved host. `hostUUID` is the app's local UUID, not the
    /// relay's `deviceId` — the two are independent (SPEC §5 SavedHost).
    public static func account(hostUUID: UUID) -> SecretAccount {
        SecretAccount(service: service, account: hostUUID.uuidString)
    }
}

extension SecretStore {
    /// Read the relay device token for a saved host.
    public func relayDeviceToken(forHostUUID hostUUID: UUID) async throws -> String? {
        try await secret(for: RelayDeviceCredential.account(hostUUID: hostUUID))
    }

    /// Store the relay device token for a saved host.
    public func setRelayDeviceToken(_ token: String, forHostUUID hostUUID: UUID) async throws {
        try await setSecret(token, for: RelayDeviceCredential.account(hostUUID: hostUUID))
    }

    /// Remove the relay device token. Part of "Forget host" (SPEC §3.2, §8 A20); it
    /// does not revoke the device at the relay.
    public func deleteRelayDeviceToken(forHostUUID hostUUID: UUID) async throws {
        try await deleteSecret(for: RelayDeviceCredential.account(hostUUID: hostUUID))
    }
}

// MARK: - Keychain

/// Errors from the Security framework. The secret value is never part of a message.
public enum KeychainError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A `SecItem` call failed. `status` is the raw OSStatus.
    case operationFailed(operation: String, status: Int)
    /// The stored bytes were not valid UTF-8.
    case undecodableValue(account: String)
    /// This platform cannot provide the Security framework.
    case unavailable

    public var description: String {
        switch self {
        case .operationFailed(let operation, let status):
            "Keychain \(operation) failed with OSStatus \(status)"
        case .undecodableValue(let account):
            "Keychain value for \(account) is not valid UTF-8"
        case .unavailable:
            "Keychain is unavailable on this platform"
        }
    }
}

/// `SecretStore` backed by the macOS/iOS Keychain.
///
/// Items are `kSecClassGenericPassword` with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, the device-only class SPEC §2
/// asks for: unreadable until the device has been unlocked once, and never migrated to
/// another device by backup restore.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func secret(for account: SecretAccount) async throws -> String? {
        #if canImport(Security)
        var query = Self.baseQuery(for: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.undecodableValue(account: account.account)
            }
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.undecodableValue(account: account.account)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.operationFailed(operation: "copy", status: Int(status))
        }
        #else
        throw KeychainError.unavailable
        #endif
    }

    public func setSecret(_ secret: String, for account: SecretAccount) async throws {
        #if canImport(Security)
        guard let data = secret.data(using: .utf8) else {
            throw KeychainError.undecodableValue(account: account.account)
        }
        var status = SecItemAdd(Self.writeQuery(for: account, data: data) as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Replace in place. The identity attributes stay identical, so only the
            // value and its accessibility are written.
            status = SecItemUpdate(
                Self.baseQuery(for: account) as CFDictionary,
                Self.updatedAttributes(data: data) as CFDictionary
            )
        }
        guard status == errSecSuccess else {
            throw KeychainError.operationFailed(operation: "add", status: Int(status))
        }
        #else
        throw KeychainError.unavailable
        #endif
    }

    public func deleteSecret(for account: SecretAccount) async throws {
        #if canImport(Security)
        let status = SecItemDelete(Self.baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(operation: "delete", status: Int(status))
        }
        #else
        throw KeychainError.unavailable
        #endif
    }

    #if canImport(Security)
    /// Attributes that identify one item: a generic password scoped by service and
    /// account. Internal so a test can pin the class this store uses even on a machine
    /// where `SecItem` writes are refused.
    static func baseQuery(for account: SecretAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: account.service,
            kSecAttrAccount as String: account.account,
        ]
    }

    /// The `SecItemAdd` attributes: identity plus the value and the device-only
    /// accessibility class SPEC §2 requires.
    static func writeQuery(for account: SecretAccount, data: Data) -> [String: Any] {
        var query = baseQuery(for: account)
        for (key, value) in updatedAttributes(data: data) { query[key] = value }
        return query
    }

    static func updatedAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
    #endif
}

// MARK: - In-memory

/// `SecretStore` for tests and previews. Process-local to the instance — no shared
/// global dictionary — so each test gets a clean store.
public actor InMemorySecretStore: SecretStore {
    private var values: [SecretAccount: String] = [:]

    public init() {}

    public func secret(for account: SecretAccount) async throws -> String? {
        values[account]
    }

    public func setSecret(_ secret: String, for account: SecretAccount) async throws {
        values[account] = secret
    }

    public func deleteSecret(for account: SecretAccount) async throws {
        values[account] = nil
    }

    /// How many secrets are currently held. For test assertions about cleanup, e.g.
    /// SPEC §8 A20's "Forget host removes local credentials".
    public var count: Int {
        get { values.count }
    }
}
