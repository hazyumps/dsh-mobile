import Foundation

/// SPEC §5 `SavedHost`. This is deliberately the nonsensitive half: the relay
/// device token lives in the keychain under `RelayDeviceCredential` keyed by
/// `id`, which is this app's own UUID and not the relay's `deviceId`.
struct SavedHost: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    var origin: URL
    var pinnedFingerprint: String?
    var relayDeviceId: String?
    var lastConnectedAt: Date?
    var lastSessionId: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        origin: URL,
        pinnedFingerprint: String? = nil,
        relayDeviceId: String? = nil,
        lastConnectedAt: Date? = nil,
        lastSessionId: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.origin = origin
        self.pinnedFingerprint = pinnedFingerprint
        self.relayDeviceId = relayDeviceId
        self.lastConnectedAt = lastConnectedAt
        self.lastSessionId = lastSessionId
    }
}

/// Host metadata as a Codable file in Application Support, replaced atomically
/// so an interrupted write cannot leave a half-file behind (SPEC §2).
struct HostStore: Sendable {
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DSHRemote", directoryHint: .isDirectory)
        fileURL = base.appending(path: "hosts.json")
    }

    func load() -> [SavedHost] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SavedHost].self, from: data)) ?? []
    }

    func save(_ hosts: [SavedHost]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(hosts).write(to: fileURL, options: .atomic)
    }
}
