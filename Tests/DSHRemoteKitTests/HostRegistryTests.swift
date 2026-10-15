import DSHRemoteKit
import Foundation
import Testing

/// #65: forgetting a host must survive a relaunch. Every test here ends by reading the disk
/// through *fresh* stores, the way the next launch would, because the bug was invisible to a
/// test that asked the object that had just changed (`HostStoreTests.forgettingIsScoped`).
///
/// Each test owns its directories and its secret store; nothing is shared between tests.
@Suite("Host registry")
struct HostRegistryTests {
    /// One test's disk: the host list and selection in `hosts/`, drafts in `drafts/`.
    private struct Disk {
        let hostsDirectory: URL
        let draftsDirectory: URL

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "dsh-hostregistry-\(UUID().uuidString)", directoryHint: .isDirectory)
            hostsDirectory = root.appending(path: "hosts", directoryHint: .isDirectory)
            draftsDirectory = root.appending(path: "drafts", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: hostsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: draftsDirectory, withIntermediateDirectories: true)
        }

        var hostStore: HostStore { HostStore(directory: hostsDirectory) }
        func draftStore() -> DraftStore { DraftStore(directory: draftsDirectory) }

        /// A registry as the next launch would build it.
        func relaunch(secrets: any SecretStore) -> HostRegistry {
            HostRegistry(store: hostStore, secrets: secrets, drafts: draftStore())
        }

        /// Makes the host directory unwritable, so `hosts.json` cannot be replaced; returns a
        /// closure that restores it. Reads still work.
        func makeHostsReadOnly() throws -> () -> Void {
            let fm = FileManager.default
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: hostsDirectory.path)
            return { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hostsDirectory.path) }
        }
    }

    private func host(_ name: String) -> SavedHost {
        SavedHost(
            displayName: name,
            origin: URL(string: "https://192.0.2.10:3443")!,
            pinnedFingerprint: "7pcXvn2Kosz4qWgFpUmIao9YQ05bXYTLbfP0IskaeN4=",
            relayDeviceId: "9f2c41ab30d7e155"
        )
    }

    /// Two hosts paired in an earlier launch: both on disk, both with a token. Seeded without
    /// the registry so a test of `forget` cannot fail because of `add`.
    private func pairedEarlier(
        _ hosts: [SavedHost],
        on disk: Disk,
        secrets: any SecretStore
    ) async throws {
        try disk.hostStore.save(hosts)
        for host in hosts {
            try await secrets.setRelayDeviceToken("token-\(host.displayName)", forHostUUID: host.id)
        }
    }

    // MARK: - Forget

    @Test("AC1: a forgotten host stays forgotten after a relaunch")
    func forgetSurvivesRelaunch() async throws {
        let disk = try Disk()
        let secrets = InMemorySecretStore()
        let keep = host("keep.local")
        let drop = host("drop.local")
        try await pairedEarlier([keep, drop], on: disk, secrets: secrets)
        try disk.hostStore.saveSelection(HostSelection(hostId: drop.id))

        let registry = disk.relaunch(secrets: secrets)
        try await registry.forget(drop.id)

        let relaunched = disk.relaunch(secrets: secrets)
        #expect(await relaunched.hosts == [keep], "the forgotten host came back from hosts.json")
        #expect(disk.hostStore.load() == [keep])
        #expect(try await secrets.relayDeviceToken(forHostUUID: keep.id) == "token-keep.local")
        #expect(try await secrets.relayDeviceToken(forHostUUID: drop.id) == nil)
        #expect(disk.hostStore.loadSelection() == nil, "the selection still names the forgotten host")
        #expect(await relaunched.selection == nil)
    }

    @Test("AC2: a forgotten host's drafts and navigation are gone from disk when forget returns")
    func forgetRemovesDraftsOnDisk() async throws {
        let disk = try Disk()
        let secrets = InMemorySecretStore()
        let keep = host("keep.local")
        let drop = host("drop.local")
        try await pairedEarlier([keep, drop], on: disk, secrets: secrets)
        let dropKey = DraftKey(hostId: drop.id, owner: .session("s-drop"))
        let keepKey = DraftKey(hostId: keep.id, owner: .session("s-keep"))
        let seeded = disk.draftStore()
        await seeded.setText("half a thought", for: dropKey)
        await seeded.setText("keep this", for: keepKey)
        await seeded.setNavigation(DraftNavigation(workspaceId: "w1", sessionId: "s-drop"), for: drop.id)
        try await seeded.flush()

        let drafts = disk.draftStore()
        let registry = HostRegistry(store: disk.hostStore, secrets: secrets, drafts: drafts)
        try await registry.forget(drop.id)

        // A fresh store, read at once: no debounce may stand between forget and the disk.
        let reread = disk.draftStore()
        #expect(await reread.draft(for: dropKey).text == "", "the forgotten host's draft is still on disk")
        #expect(await reread.draftCount(hostId: drop.id) == 0)
        #expect(await reread.navigation(for: drop.id) == DraftNavigation())
        #expect(await reread.draft(for: keepKey).text == "keep this")
    }

    @Test("AC3: forgetting an unselected host keeps the selection")
    func forgetUnselectedKeepsSelection() async throws {
        let disk = try Disk()
        let secrets = InMemorySecretStore()
        let keep = host("keep.local")
        let drop = host("drop.local")
        try await pairedEarlier([keep, drop], on: disk, secrets: secrets)
        try disk.hostStore.saveSelection(HostSelection(hostId: keep.id))

        let registry = disk.relaunch(secrets: secrets)
        try await registry.forget(drop.id)

        #expect(disk.hostStore.loadSelection()?.hostId == keep.id)
        #expect(await disk.relaunch(secrets: secrets).selection?.hostId == keep.id)
    }

    @Test("AC4: a forget whose list cannot be saved throws and changes nothing")
    func forgetWithUnsavableListChangesNothing() async throws {
        let disk = try Disk()
        let secrets = InMemorySecretStore()
        let keep = host("keep.local")
        let drop = host("drop.local")
        try await pairedEarlier([keep, drop], on: disk, secrets: secrets)
        try disk.hostStore.saveSelection(HostSelection(hostId: drop.id))
        let dropKey = DraftKey(hostId: drop.id, owner: .session("s-drop"))
        let seeded = disk.draftStore()
        await seeded.setText("half a thought", for: dropKey)
        try await seeded.flush()

        let registry = HostRegistry(store: disk.hostStore, secrets: secrets, drafts: disk.draftStore())
        let restore = try disk.makeHostsReadOnly()
        defer { restore() }

        var thrown: HostRegistryError?
        do {
            try await registry.forget(drop.id)
        } catch let error as HostRegistryError {
            thrown = error
        }
        guard case .listNotSaved = thrown else {
            Issue.record("expected .listNotSaved, got \(String(describing: thrown))")
            return
        }
        #expect(await registry.hosts == [keep, drop], "the host left memory although the disk kept it")
        #expect(disk.hostStore.load() == [keep, drop])
        #expect(disk.hostStore.loadSelection()?.hostId == drop.id)
        #expect(try await secrets.relayDeviceToken(forHostUUID: drop.id) == "token-drop.local")
        #expect(await disk.draftStore().draft(for: dropKey).text == "half a thought")
    }

    @Test("AC5: a token that cannot be deleted is reported, and the host is still gone from disk")
    func forgetWithUndeletableTokenIsReported() async throws {
        let disk = try Disk()
        let secrets = FailingDeleteSecretStore()
        let keep = host("keep.local")
        let drop = host("drop.local")
        try await pairedEarlier([keep, drop], on: disk, secrets: secrets)
        let dropKey = DraftKey(hostId: drop.id, owner: .session("s-drop"))
        let seeded = disk.draftStore()
        await seeded.setText("half a thought", for: dropKey)
        try await seeded.flush()

        let registry = HostRegistry(store: disk.hostStore, secrets: secrets, drafts: disk.draftStore())
        var thrown: HostRegistryError?
        do {
            try await registry.forget(drop.id)
        } catch let error as HostRegistryError {
            thrown = error
        }
        guard case .credentialNotRemoved = thrown else {
            Issue.record("expected .credentialNotRemoved, got \(String(describing: thrown))")
            return
        }
        #expect(disk.hostStore.load() == [keep], "a failed token delete kept the host on disk")
        #expect(await registry.hosts == [keep])
        #expect(await disk.draftStore().draftCount(hostId: drop.id) == 0, "a failed token delete left the drafts")
        #expect(await secrets.deleteAttempts == 1, "a failed delete was retried")
    }

    // MARK: - Add

    @Test("AC6: an added host and its token survive a relaunch")
    func addSurvivesRelaunch() async throws {
        let disk = try Disk()
        let secrets = InMemorySecretStore()
        let paired = host("new.local")

        let registry = disk.relaunch(secrets: secrets)
        try await registry.add(paired, token: "fresh-token")

        let relaunched = disk.relaunch(secrets: secrets)
        #expect(await relaunched.hosts == [paired], "the paired host was not written to hosts.json")
        #expect(try await relaunched.relayDeviceToken(for: paired.id) == "fresh-token")
    }

    @Test("AC7: an add whose list cannot be saved throws and leaves no token")
    func addWithUnsavableListLeavesNoToken() async throws {
        let disk = try Disk()
        let secrets = InMemorySecretStore()
        let existing = host("existing.local")
        try await pairedEarlier([existing], on: disk, secrets: secrets)
        let paired = host("new.local")

        let registry = disk.relaunch(secrets: secrets)
        let restore = try disk.makeHostsReadOnly()
        defer { restore() }

        var thrown: HostRegistryError?
        do {
            try await registry.add(paired, token: "fresh-token")
        } catch let error as HostRegistryError {
            thrown = error
        }
        guard case .listNotSaved = thrown else {
            Issue.record("expected .listNotSaved, got \(String(describing: thrown))")
            return
        }
        #expect(await registry.hosts == [existing])
        #expect(disk.hostStore.load() == [existing])
        #expect(try await secrets.relayDeviceToken(forHostUUID: paired.id) == nil, "an orphaned token was left behind")
    }

    // MARK: - Selection

    @Test("AC8: a selection naming a host no longer saved is cleared at launch")
    func staleSelectionIsClearedAtLaunch() async throws {
        let disk = try Disk()
        let secrets = InMemorySecretStore()
        let keep = host("keep.local")
        try await pairedEarlier([keep], on: disk, secrets: secrets)
        try disk.hostStore.saveSelection(HostSelection(hostId: UUID()))

        let registry = disk.relaunch(secrets: secrets)

        #expect(await registry.selection == nil, "a launch kept a selection pointing at nothing")
        #expect(disk.hostStore.loadSelection() == nil)
    }

    @Test("AC8: a selection set through the registry is read by the next launch")
    func selectionSurvivesRelaunch() async throws {
        let disk = try Disk()
        let secrets = InMemorySecretStore()
        let keep = host("keep.local")
        try await pairedEarlier([keep], on: disk, secrets: secrets)

        let registry = disk.relaunch(secrets: secrets)
        try await registry.setSelection(keep.id)

        #expect(await disk.relaunch(secrets: secrets).selection?.hostId == keep.id)
    }
}

/// A secret store whose delete always fails, for AC5. It counts attempts so the test can
/// say a failed delete was reported once rather than retried.
private actor FailingDeleteSecretStore: SecretStore {
    private var values: [SecretAccount: String] = [:]
    private(set) var deleteAttempts = 0

    struct DeleteFailed: Error {}

    func secret(for account: SecretAccount) async throws -> String? { values[account] }
    func setSecret(_ secret: String, for account: SecretAccount) async throws { values[account] = secret }
    func deleteSecret(for account: SecretAccount) async throws {
        deleteAttempts += 1
        throw DeleteFailed()
    }
}
