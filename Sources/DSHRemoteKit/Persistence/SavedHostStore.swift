import Foundation

/// SPEC §5 `SavedHost`: the nonsensitive half of a paired host.
///
/// The relay device token is deliberately not a field here. It belongs in the
/// keychain under `RelayDeviceCredential`, keyed by `id` — this app's own UUID,
/// not the relay's `deviceId` — so host metadata can be written, backed up, or
/// displayed without carrying a credential (SPEC §3.2 step 5).
public struct SavedHost: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public var origin: URL
    public var pinnedFingerprint: String?
    public var relayDeviceId: String?
    public var lastConnectedAt: Date?
    public var lastSessionId: String?

    public init(
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

/// Host metadata as one Codable file, replaced atomically so an interrupted
/// write cannot leave a half-file that fails to decode (SPEC §2).
///
/// A store whose file is missing or unreadable loads as empty rather than
/// throwing: losing the list must not stop the app from pairing again, and a
/// corrupt file is not evidence of a paired host.
public struct HostStore: Sendable {
    public let fileURL: URL

    /// - Parameter directory: Defaults to `Application Support/DSHRemote`.
    ///   Tests pass a temporary directory.
    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DSHRemote", directoryHint: .isDirectory)
        fileURL = base.appending(path: "hosts.json")
    }

    public func load() -> [SavedHost] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SavedHost].self, from: data)) ?? []
    }

    public func save(_ hosts: [SavedHost]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(hosts).write(to: fileURL, options: .atomic)
    }
}
