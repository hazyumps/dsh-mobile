import DSHRemoteKit
import Foundation
import Testing

/// SPEC §3.2 step 5 and acceptance A03: the metadata file may hold hosts, and
/// must not hold a credential.
@Suite("Saved host metadata")
struct HostStoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "dsh-hoststore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleHost(name: String = "relay.local") -> SavedHost {
        SavedHost(
            displayName: name,
            origin: URL(string: "https://192.0.2.10:3443")!,
            pinnedFingerprint: "7pcXvn2Kosz4qWgFpUmIao9YQ05bXYTLbfP0IskaeN4=",
            relayDeviceId: "9f2c41ab30d7e155"
        )
    }

    @Test("a saved host round-trips, including the pinned key")
    func roundTrips() throws {
        let store = HostStore(directory: try temporaryDirectory())
        let host = sampleHost()
        try store.save([host])

        let loaded = store.load()
        #expect(loaded == [host])
        #expect(loaded.first?.pinnedFingerprint == "7pcXvn2Kosz4qWgFpUmIao9YQ05bXYTLbfP0IskaeN4=")
    }

    @Test("a missing file loads as empty rather than throwing")
    func missingFileIsEmpty() throws {
        let store = HostStore(directory: try temporaryDirectory())
        #expect(store.load().isEmpty)
    }

    @Test("saving creates the directory, so the first pair on a fresh install works")
    func createsDirectory() throws {
        let nested = try temporaryDirectory().appending(path: "a/b", directoryHint: .isDirectory)
        let store = HostStore(directory: nested)
        try store.save([sampleHost()])
        #expect(store.load().count == 1)
    }

    @Test("a corrupt file loads as empty instead of taking the app down")
    func corruptFileIsEmpty() throws {
        let directory = try temporaryDirectory()
        let store = HostStore(directory: directory)
        try Data("not json at all".utf8).write(to: store.fileURL)
        #expect(store.load().isEmpty)
    }

    @Test("the metadata file carries no credential")
    func metadataCarriesNoCredential() throws {
        let store = HostStore(directory: try temporaryDirectory())
        try store.save([sampleHost()])

        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        // The field names a credential would live under, and the token itself.
        for forbidden in ["token", "Bearer", "authorization", "secret"] {
            #expect(!raw.localizedCaseInsensitiveContains(forbidden), "metadata mentions \(forbidden)")
        }
    }

    @Test("forgetting a host leaves the others alone")
    func forgettingIsScoped() throws {
        let store = HostStore(directory: try temporaryDirectory())
        let keep = sampleHost(name: "keep.local")
        let drop = sampleHost(name: "drop.local")
        try store.save([keep, drop])

        try store.save(store.load().filter { $0.id != drop.id })
        #expect(store.load() == [keep])
    }

    @Test("the selected host round-trips, so a cold launch returns to its work")
    func selectionRoundTrips() throws {
        let store = HostStore(directory: try temporaryDirectory())
        let host = sampleHost()
        try store.save([host])
        try store.saveSelection(HostSelection(hostId: host.id))

        #expect(store.loadSelection()?.hostId == host.id)
    }

    @Test("no selection file reads as no selection, not as a failure")
    func missingSelectionIsNil() throws {
        let store = HostStore(directory: try temporaryDirectory())
        #expect(store.loadSelection() == nil)
    }

    @Test("a selection file that cannot be read is discarded rather than thrown")
    func corruptSelectionIsNil() throws {
        let store = HostStore(directory: try temporaryDirectory())
        try store.save([sampleHost()])
        try FileManager.default.createDirectory(
            at: store.selectionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{".utf8).write(to: store.selectionURL)

        #expect(store.loadSelection() == nil)
    }

    @Test("clearing the selection removes the file instead of writing a null")
    func clearingSelectionRemovesTheFile() throws {
        let store = HostStore(directory: try temporaryDirectory())
        let host = sampleHost()
        try store.save([host])
        try store.saveSelection(HostSelection(hostId: host.id))
        try store.saveSelection(nil)

        #expect(store.loadSelection() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.selectionURL.path))
    }

    @Test("forgetting the selected host drops the selection with it")
    func reconcileDropsAStaleSelection() throws {
        let store = HostStore(directory: try temporaryDirectory())
        let keep = sampleHost(name: "keep.local")
        let drop = sampleHost(name: "drop.local")
        try store.save([keep, drop])
        try store.saveSelection(HostSelection(hostId: drop.id))

        #expect(store.reconcileSelection(with: [keep, drop])?.hostId == drop.id)
        #expect(store.reconcileSelection(with: [keep]) == nil)
        // And it stays gone: the next launch must not chase a host the user forgot.
        #expect(store.loadSelection() == nil)
    }
}
