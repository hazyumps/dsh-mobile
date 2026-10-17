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

        /// Replaces `hosts.json` with a non-empty directory, so the list write fails while the
        /// rest of the host directory, `selection.json` included, stays writable and deletable.
        /// (`makeHostsReadOnly` also blocks deleting the selection, which hides a reconcile run
        /// before the save.) Call it after the registry has loaded the list.
        func breakHostsFile() throws {
            let fm = FileManager.default
            let url = hostStore.fileURL
            try fm.removeItem(at: url)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("x".utf8).write(to: url.appending(path: "occupied"))
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

        // Before any relaunch: a relaunched registry reconciles the selection itself (AC8), which
        // would hide a forget that left it naming the forgotten host until the next launch.
        #expect(disk.hostStore.loadSelection() == nil, "forget left selection.json naming the forgotten host")
        #expect(await registry.selection == nil, "forget left the registry's selection on the forgotten host")

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

    @Test("AC4: a forget whose list cannot be saved leaves the selection alone")
    func forgetWithUnsavableListKeepsSelection() async throws {
        let disk = try Disk()
        let secrets = InMemorySecretStore()
        let keep = host("keep.local")
        let drop = host("drop.local")
        try await pairedEarlier([keep, drop], on: disk, secrets: secrets)
        try disk.hostStore.saveSelection(HostSelection(hostId: drop.id))

        let registry = disk.relaunch(secrets: secrets)
        try disk.breakHostsFile()

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
        #expect(disk.hostStore.loadSelection()?.hostId == drop.id, "a failed forget cleared selection.json")
        #expect(await registry.selection?.hostId == drop.id, "a failed forget cleared the registry's selection")
        #expect(await registry.hosts == [keep, drop])
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

    @Test("AC5: drafts that cannot be written away are reported, and the host and token are still gone")
    func forgetWithUnwritableDraftsIsReported() async throws {
        let disk = try Disk()
        let secrets = InMemorySecretStore()
        let keep = host("keep.local")
        let drop = host("drop.local")
        try await pairedEarlier([keep, drop], on: disk, secrets: secrets)
        let drafts = DraftStore(directory: disk.draftsDirectory, write: { _, _ in throw DraftsWriteFailed() })

        let registry = HostRegistry(store: disk.hostStore, secrets: secrets, drafts: drafts)
        var thrown: HostRegistryError?
        do {
            try await registry.forget(drop.id)
        } catch let error as HostRegistryError {
            thrown = error
        }
        guard case .draftsNotRemoved = thrown else {
            Issue.record("expected .draftsNotRemoved, got \(String(describing: thrown))")
            return
        }
        #expect(disk.hostStore.load() == [keep], "a failed drafts write kept the host on disk")
        #expect(await registry.hosts == [keep])
        #expect(try await secrets.relayDeviceToken(forHostUUID: drop.id) == nil, "a failed drafts write kept the token")
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

    // MARK: - Selection in flight (#104)
    //
    // `AppModel.select(B)` suspends on B's token read. These tests hold that read in a
    // `HeldReadSecretStore` and run a `forget` while it is held. That works because the
    // registry is an actor that lets other calls in at every `await`: `forget` runs while
    // `relayDeviceToken` is suspended in the store. The read is observed to have started through
    // the store's signal, never a sleep.

    @Test("#104 AC1: a token read that a forget overtakes yields no token", .timeLimit(.minutes(1)))
    func overtakenReadYieldsNoToken() async throws {
        let disk = try Disk()
        let secrets = HeldReadSecretStore()
        let a = host("a.local")
        let b = host("b.local")
        try await pairedEarlier([a, b], on: disk, secrets: secrets)
        let registry = disk.relaunch(secrets: secrets)

        let read = Task { try await registry.relayDeviceToken(for: b.id) }
        await secrets.readHasStarted()
        try await registry.forget(b.id)
        await secrets.release()

        #expect(try await read.value == nil, "a read started before forget handed out the forgotten host's token")
    }

    @Test(
        "#104 AC1: forgetting B while its token read is held leaves no current selection and no token",
        .timeLimit(.minutes(1))
    )
    func forgetDuringHeldReadEndsTheSelection() async throws {
        let disk = try Disk()
        let secrets = HeldReadSecretStore()
        let a = host("a.local")
        let b = host("b.local")
        try await pairedEarlier([a, b], on: disk, secrets: secrets)
        let registry = disk.relaunch(secrets: secrets)

        // The order `AppModel` uses: begin the selection, read the token; forget ends the
        // selection through the gate before it awaits the registry.
        var gate = HostSelectionGate()
        let ticket = gate.begin(b.id)
        let read = Task { try await registry.relayDeviceToken(for: b.id) }
        await secrets.readHasStarted()
        let ended = gate.forget(b.id)
        try await registry.forget(b.id)
        await secrets.release()
        let token = try await read.value

        #expect(ended, "forget did not end the pending selection of B, so nothing tears it down")
        #expect(!gate.isCurrent(ticket), "the pending selection of a forgotten host is still current")
        #expect(token == nil, "the pending selection of a forgotten host got its token")
    }

    @Test("#104 AC2: forgetting another host leaves a held token read intact", .timeLimit(.minutes(1)))
    func forgettingAnotherHostKeepsTheHeldRead() async throws {
        let disk = try Disk()
        let secrets = HeldReadSecretStore()
        let b = host("b.local")
        let c = host("c.local")
        try await pairedEarlier([b, c], on: disk, secrets: secrets)
        let registry = disk.relaunch(secrets: secrets)

        let read = Task { try await registry.relayDeviceToken(for: b.id) }
        await secrets.readHasStarted()
        try await registry.forget(c.id)
        await secrets.release()

        #expect(try await read.value == "token-b.local", "forgetting C cost B its token")
    }

    @Test("#104 AC4: no token is handed out for a host that is not saved")
    func noTokenForAnUnsavedHost() async throws {
        let disk = try Disk()
        let secrets = InMemorySecretStore()
        let saved = host("saved.local")
        let stray = host("stray.local")
        try await pairedEarlier([saved], on: disk, secrets: secrets)
        // A token left behind for an id the list does not hold.
        try await secrets.setRelayDeviceToken("token-stray.local", forHostUUID: stray.id)
        let registry = disk.relaunch(secrets: secrets)

        #expect(try await registry.relayDeviceToken(for: stray.id) == nil, "the registry handed out a token for a host it does not hold")
        #expect(try await registry.relayDeviceToken(for: saved.id) == "token-saved.local")
    }

    @Test("#104 AC5: a selection naming a host that is not saved is not recorded")
    func selectionOfAnUnsavedHostIsNotRecorded() async throws {
        let disk = try Disk()
        let secrets = InMemorySecretStore()
        let saved = host("saved.local")
        let stray = host("stray.local")
        try await pairedEarlier([saved], on: disk, secrets: secrets)
        let registry = disk.relaunch(secrets: secrets)

        try await registry.setSelection(stray.id)

        #expect(await registry.selection == nil, "the registry recorded a selection of a host it does not hold")
        #expect(disk.hostStore.loadSelection() == nil, "selection.json names a host that is not saved")
    }
}

/// A secret store whose reads are held until the test releases them (#104).
///
/// A read captures the stored value first, as a Keychain read that had already returned would,
/// then signals that it has started and suspends. Writes and deletes are never held, so a
/// `forget` can run to completion while a read is held. One instance per test.
actor HeldReadSecretStore: SecretStore {
    private var values: [SecretAccount: String] = [:]
    private var held: [CheckedContinuation<Void, Never>] = []
    private let started: AsyncStream<Void>
    private let startedSignal: AsyncStream<Void>.Continuation

    init() {
        (started, startedSignal) = AsyncStream<Void>.makeStream()
    }

    func secret(for account: SecretAccount) async throws -> String? {
        let captured = values[account]
        await withCheckedContinuation { continuation in
            held.append(continuation)
            startedSignal.yield()
        }
        return captured
    }

    func setSecret(_ secret: String, for account: SecretAccount) async throws { values[account] = secret }
    func deleteSecret(for account: SecretAccount) async throws { values[account] = nil }

    /// Returns once a read is held, so the caller knows the read is suspended in the store.
    func readHasStarted() async {
        var signals = started.makeAsyncIterator()
        _ = await signals.next()
    }

    /// Lets every held read return.
    func release() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
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

private struct DraftsWriteFailed: Error {}
