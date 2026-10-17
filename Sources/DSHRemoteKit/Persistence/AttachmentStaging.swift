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

/// Copies an imported file into app storage while its security scope is held (SPEC §3.6: "copy
/// selected files into protected app staging storage; release security-scoped access promptly").
///
/// #66: the importer used to start the scope, `defer` the stop, and hand the URL to a `Task` that
/// read it after the scope had already ended. `stage` exists so that cannot happen: the scope is
/// started, the file measured and copied, and the scope stopped, all inside one synchronous call.
/// **Keep it synchronous** — an `async` `stage` would let a suspension point reintroduce the bug
/// inside the function written to prevent it. `Tools/lint.sh` allows
/// `startAccessingSecurityScopedResource` in this file and nowhere else.
///
/// Each copy lives in its own `<directory>/<UUID>/` folder, so two picks with the same name never
/// collide and the upload still sends the original name. Copies only need to last one upload:
/// the caller `discard`s a copy once its upload settles, and `sweep`s the whole directory at
/// launch to clear anything a killed launch left behind.
public struct AttachmentStaging: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Copies `source` into staging and returns the copy.
    ///
    /// Throws `AttachmentUploadFailure.unreadable` when the source cannot be measured as a regular
    /// file (missing, a directory, a package) and `.tooLarge` when it is over `byteLimit`. Both are
    /// checked **before** copying, so an oversized pick is never copied (SPEC §3.6, S5). The copy
    /// is measured again, so a source that grew during the copy is still refused. Error reasons
    /// never carry the file name (S9).
    public func stage(
        _ source: URL,
        byteLimit: Int = AttachmentUploader.byteLimit
    ) throws -> StagedFile {
        // `false` for a URL that needs no scope (a plain file, every macOS test); only a scope
        // this call started is stopped.
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
        }

        let byteCount = try Self.measure(source)
        guard byteCount <= byteLimit else {
            throw AttachmentUploadFailure.tooLarge(byteCount: byteCount, limit: byteLimit)
        }

        let name = source.lastPathComponent
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: Self.protection
            )
            try FileManager.default.copyItem(at: source, to: copy)
            // The same class `DraftStore.writeAtomically` uses. A copy keeps its source's
            // protection, not the folder's, so it is set on the file explicitly.
            if let protection = Self.protection {
                try FileManager.default.setAttributes(protection, ofItemAtPath: copy.path)
            }
            // The source may have changed between the measurement and the copy; the copy is
            // what gets uploaded, so the copy is what is bounded.
            let copied = try Self.measure(copy)
            guard copied <= byteLimit else {
                throw AttachmentUploadFailure.tooLarge(byteCount: copied, limit: byteLimit)
            }
            return StagedFile(url: copy, name: name, byteCount: copied)
        } catch {
            // Nothing half-copied is left in staging, whatever failed.
            try? FileManager.default.removeItem(at: folder)
            throw error as? AttachmentUploadFailure
                ?? AttachmentUploadFailure.unreadable(reason: "the file could not be copied")
        }
    }

    /// Removes a staged copy and its UUID folder. Best effort: a copy that is already gone is fine.
    public func discard(_ staged: StagedFile) {
        let folder = staged.url.deletingLastPathComponent()
        // Only ever delete inside the staging directory, whatever URL was handed in.
        guard folder.deletingLastPathComponent().standardizedFileURL.path
            == directory.standardizedFileURL.path
        else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes everything in the staging directory: copies left by a launch that was killed
    /// mid-upload. Run it before anything is staged in this launch.
    public func sweep() {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Private

    /// The size of a regular file, read from disk. Absent is not zero: a size that cannot be read
    /// is a refusal, not a 0-byte file.
    private static func measure(_ url: URL) throws -> Int {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard let values, values.isRegularFile == true, let size = values.fileSize else {
            throw AttachmentUploadFailure.unreadable(reason: "not a readable regular file")
        }
        return size
    }

    /// File protection for staged copies. Genuine on iOS; macOS has no data-protection classes
    /// for ordinary files, so nothing is set there.
    private static var protection: [FileAttributeKey: Any]? {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        nil
        #endif
    }
}
