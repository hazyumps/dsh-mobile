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
}
