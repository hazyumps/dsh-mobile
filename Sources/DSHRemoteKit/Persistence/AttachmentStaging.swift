import Foundation

/// A file copied into app-owned staging storage, ready to upload.
public struct StagedFile: Sendable, Hashable {
    /// The copy, at `<staging directory>/<UUID>/<name>`.
    public var url: URL
    /// The source's file name, kept for the upload.
    public var name: String
    /// The copy's size, measured from the file on disk.
    public var byteCount: Int

    public init(url: URL, name: String, byteCount: Int) {
        self.url = url
        self.name = name
        self.byteCount = byteCount
    }
}

/// Copies an imported file into app storage while its security scope is held (SPEC §3.6).
///
/// #66: a stub for the planner's red tests. `stage` hands back the source itself and copies
/// nothing, which is exactly the behaviour the issue reports; `discard` and `sweep` do nothing.
public struct AttachmentStaging: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func stage(
        _ source: URL,
        byteLimit: Int = AttachmentUploader.byteLimit
    ) throws -> StagedFile {
        StagedFile(url: source, name: source.lastPathComponent, byteCount: 0)
    }

    public func discard(_ staged: StagedFile) {}

    public func sweep() {}
}
