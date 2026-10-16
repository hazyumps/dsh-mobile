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
/// Disk is the source of truth. `hosts` changes only after `hosts.json` has been written, so a
/// caller that mirrors `hosts` never shows a list the next launch would not read back. Before
/// #65 the app removed a forgotten host from memory only, and it came back on relaunch with no
/// token.
///
/// Writes are never retried (AGENTS.md): a failure is thrown once, as a `HostRegistryError`
/// that says which half was left behind.
public actor HostRegistry {
    /// The list as `init` loaded it, readable synchronously by a caller whose own `init` is
    /// synchronous (the app's), so a launch does not flash the pairing introduction.
    public nonisolated let initialHosts: [SavedHost]
    public private(set) var hosts: [SavedHost]
    public private(set) var selection: HostSelection?

    private let store: HostStore
    private let secrets: any SecretStore
    private let drafts: DraftStore

    /// Loads the list and drops a saved selection that names a host no longer on disk, so a
    /// launch never chases a host the user forgot.
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
        selection = store.reconcileSelection(with: loaded)
    }

    /// Stores the token, then the list.
    ///
    /// The token goes first so a listed host always has one. If the list then cannot be
    /// saved, the token is deleted again rather than left orphaned, and `hosts` is unchanged.
    ///
    /// - Throws: `.credentialNotSaved` (nothing changed) or `.listNotSaved` (nothing listed,
    ///   token removed).
    public func add(_ host: SavedHost, token: String) async throws {
        do {
            try await secrets.setRelayDeviceToken(token, forHostUUID: host.id)
        } catch {
            throw HostRegistryError.credentialNotSaved(reason: Self.reason(error))
        }
        var updated = hosts.filter { $0.id != host.id }
        updated.append(host)
        do {
            try store.save(updated)
        } catch {
            // Roll back the token. If this delete fails too there is nothing more to do
            // without retrying a write; the list error is the one the caller can act on.
            try? await secrets.deleteRelayDeviceToken(forHostUUID: host.id)
            throw HostRegistryError.listNotSaved(reason: Self.reason(error))
        }
        hosts = updated
    }

    /// Saves the list without the host, then reconciles the selection, deletes the token and
    /// removes the drafts.
    ///
    /// If the list cannot be saved nothing else is touched: the host is still on disk, so its
    /// token and drafts must stay with it. After the list is saved, every remaining step runs
    /// even when an earlier one fails (a failed token delete is no reason to leave drafts
    /// behind), and the first failure is thrown. Nothing is retried.
    ///
    /// - Throws: `.listNotSaved`, `.credentialNotRemoved` or `.draftsNotRemoved`.
    public func forget(_ id: UUID) async throws {
        let remaining = hosts.filter { $0.id != id }
        do {
            try store.save(remaining)
        } catch {
            throw HostRegistryError.listNotSaved(reason: Self.reason(error))
        }
        hosts = remaining

        // Clears `selection.json` only when it names the forgotten host. The directory was
        // writable a moment ago (the list save succeeded), so removing the file is not a
        // failure worth its own error case.
        selection = store.reconcileSelection(with: remaining)

        var firstFailure: HostRegistryError?
        do {
            try await secrets.deleteRelayDeviceToken(forHostUUID: id)
        } catch {
            firstFailure = .credentialNotRemoved(reason: Self.reason(error))
        }

        // `remove(hostId:)` only schedules a debounced write; flush so the drafts are gone
        // from disk when `forget` returns, not a debounce later (or never, if suspended).
        await drafts.remove(hostId: id)
        do {
            try await drafts.flush()
        } catch {
            firstFailure = firstFailure ?? .draftsNotRemoved(reason: Self.reason(error))
        }

        if let firstFailure { throw firstFailure }
    }

    /// Records the selected host, or clears it with `nil`. A host that is not saved is not
    /// recorded: a selection that a `forget` overtook must not name it on disk (#104).
    ///
    /// - Throws: the file error from `HostStore.saveSelection`; `selection` is unchanged.
    public func setSelection(_ id: UUID?) throws {
        if let id, !hosts.contains(where: { $0.id == id }) { return }
        let next = id.map(HostSelection.init(hostId:))
        try store.saveSelection(next)
        selection = next
    }

    /// The relay device token for a saved host, or `nil` when none is stored or the host is not
    /// saved. Membership is checked after the read, so a `forget` that ran while the read was
    /// suspended wins and the forgotten host's token is not handed out (#104).
    public func relayDeviceToken(for id: UUID) async throws -> String? {
        let token = try await secrets.relayDeviceToken(forHostUUID: id)
        return hosts.contains { $0.id == id } ? token : nil
    }

    /// A file or Keychain error as text. Neither carries a secret value (RISK-FLAGS S9).
    private static func reason(_ error: any Error) -> String {
        String(describing: error)
    }
}
