import Foundation

/// Why a change to the saved hosts did not fully happen.
///
/// Each case says which half was left behind. The reason carries a file or Keychain error,
/// never a token (RISK-FLAGS S9).
public enum HostRegistryError: Error, Equatable, Sendable {
    /// `hosts.json` could not be written. Nothing else was changed.
    case listNotSaved(reason: String)
    /// The token could not be stored. Nothing else was changed.
    case credentialNotSaved(reason: String)
    /// The host is gone from disk, but its token could not be deleted. Reported, not retried.
    case credentialNotRemoved(reason: String)
    /// The host is gone from disk, but its drafts could not be written away.
    case draftsNotRemoved(reason: String)
}

/// The one owner of the saved hosts: the list, each host's relay token, the selection, and
/// what forgetting a host has to remove (#65).
///
/// STUB (planner, #65 `Tests:` commit): edits memory only, which is the bug #65 reports. The
/// builder replaces the bodies; the signatures are the contract in
/// `design/plans/issue-65-forget-persisted.md`.
public actor HostRegistry {
    /// The list as `init` loaded it, readable synchronously by a caller whose own `init` is
    /// synchronous (the app's), so a launch does not flash the pairing introduction.
    public nonisolated let initialHosts: [SavedHost]
    public private(set) var hosts: [SavedHost]
    public private(set) var selection: HostSelection?

    private let store: HostStore
    private let secrets: any SecretStore
    private let drafts: DraftStore

    public init(
        store: HostStore = HostStore(),
        secrets: any SecretStore = KeychainSecretStore(),
        drafts: DraftStore
    ) {
        self.store = store
        self.secrets = secrets
        self.drafts = drafts
        let loaded = store.load()
        initialHosts = loaded
        hosts = loaded
        selection = store.loadSelection()
    }

    /// Stores the token, then the list. Stub: memory only.
    public func add(_ host: SavedHost, token: String) async throws {
        hosts.append(host)
    }

    /// Saves the list without the host, then reconciles the selection, deletes the token and
    /// removes the drafts. Stub: memory only.
    public func forget(_ id: UUID) async throws {
        hosts.removeAll { $0.id == id }
    }

    /// Records the selected host, or clears it with `nil`. Stub: writes nothing.
    public func setSelection(_ id: UUID?) throws {}

    /// The relay device token for a saved host. Stub: always `nil`.
    public func relayDeviceToken(for id: UUID) async throws -> String? {
        nil
    }
}
