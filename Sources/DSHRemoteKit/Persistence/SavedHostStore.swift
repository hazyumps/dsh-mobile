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

/// Which saved host the app had selected.
///
/// SPEC §5 keeps the last host separate from the last workspace and session, and
/// the UX specification needs it for one row of its navigation table: a cold
/// launch with a valid saved selection returns to that host's work rather than
/// the host list. It is deliberately its own record — the host list is a set of
/// pairings, and the selection is a cursor into it, so a forgotten host must be
/// able to leave the list without leaving a selection pointing at nothing.
public struct HostSelection: Codable, Sendable, Hashable {
    public var hostId: UUID

    public init(hostId: UUID) {
        self.hostId = hostId
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

    // MARK: - Selection

    /// The selection file, beside the host list.
    public var selectionURL: URL {
        fileURL.deletingLastPathComponent().appending(path: "selection.json")
    }

    /// The last selected host, or `nil` when nothing was selected — including when the
    /// file is missing or unreadable, for the same reason a corrupt host list loads empty.
    public func loadSelection() -> HostSelection? {
        guard let data = try? Data(contentsOf: selectionURL) else { return nil }
        return try? JSONDecoder().decode(HostSelection.self, from: data)
    }

    /// Records the selection, or clears it with `nil`.
    ///
    /// Clearing removes the file rather than writing a null, so "nothing is selected"
    /// and "the file was never written" are one state on disk.
    public func saveSelection(_ selection: HostSelection?) throws {
        guard let selection else {
            try? FileManager.default.removeItem(at: selectionURL)
            return
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(selection).write(to: selectionURL, options: .atomic)
    }

    /// Drops the selection when it names a host that is no longer saved.
    ///
    /// Called after the host list changes. A stale selection is not an error to report —
    /// the host is simply gone — but leaving it would make the next launch chase a host
    /// the user deliberately forgot.
    @discardableResult
    public func reconcileSelection(with hosts: [SavedHost]) -> HostSelection? {
        guard let selection = loadSelection() else { return nil }
        guard hosts.contains(where: { $0.id == selection.hostId }) else {
            try? saveSelection(nil)
            return nil
        }
        return selection
    }
}
