import Foundation
import Testing

@testable import DSHRemoteKit

/// #66: an imported file is copied into app-owned staging storage while its security scope is
/// held, and the upload reads the copy (SPEC §3.6: "copy selected files into protected app
/// staging storage; release security-scoped access promptly").
///
/// A unit test on macOS cannot hold or revoke a real security scope: for a plain file URL,
/// `startAccessingSecurityScopedResource()` returns `false`. So these tests pin what the scope bug
/// *causes*: before #66 the upload read the source, which can go away, instead of a copy. The
/// ordering "copy while the scope is held" is guarded by construction (`stage` is one synchronous
/// call with the stop in a `defer`) and by the `security-scope` lint rule.
///
/// Limits are injected at 16 bytes so no 20 MiB file is written. Every test has its own root
/// directory, so nothing is shared between tests running in parallel.
@Suite("Attachment staging (#66)")
struct AttachmentStagingTests {

    private let limit = 16

    /// A fresh root holding a `source` directory with files in it, and the path of a staging
    /// directory that does not exist yet (staging must create it).
    private struct Scratch {
        let source: URL
        let staging: URL

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("staging-test-\(UUID().uuidString)", isDirectory: true)
            source = root.appendingPathComponent("source", isDirectory: true)
            staging = root.appendingPathComponent("AttachmentStaging", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        }

        func file(_ name: String, bytes: Int) throws -> URL {
            let url = source.appendingPathComponent(name)
            try Data(repeating: 0x61, count: bytes).write(to: url)
            return url
        }

        /// What is in the staging directory; a directory that was never created holds nothing.
        var stagedEntries: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        }

        /// Whether `url` is `<staging>/<UUID>/<name>`.
        func isStagedCopy(_ url: URL) -> Bool {
            let folder = url.deletingLastPathComponent()
            return folder.deletingLastPathComponent().standardizedFileURL.path
                == staging.standardizedFileURL.path
                && UUID(uuidString: folder.lastPathComponent) != nil
        }
    }

    @Test("AC4: a staged copy stays readable after the source is gone")
    func stagedCopyOutlivesTheSource() throws {
        let scratch = try Scratch()
        let source = scratch.source.appendingPathComponent("notes.txt")
        try Data("abcdef".utf8).write(to: source)

        let staged = try AttachmentStaging(directory: scratch.staging).stage(source, byteLimit: limit)
        // What the scope bug amounts to: the picker's file is no longer readable by the time the
        // upload runs. The copy must not care.
        try FileManager.default.removeItem(at: source)

        #expect(FileManager.default.contents(atPath: staged.url.path) == Data("abcdef".utf8))
        #expect(scratch.isStagedCopy(staged.url), "\(staged.url.path) is not <staging>/<UUID>/<name>")
        #expect(staged.name == "notes.txt")
        #expect(staged.url.lastPathComponent == "notes.txt")
        #expect(staged.byteCount == 6)
    }

    @Test("AC5: a file one byte over the limit is refused before anything is copied")
    func oneByteOverIsRefused() throws {
        let scratch = try Scratch()
        let source = try scratch.file("big.bin", bytes: limit + 1)

        #expect(throws: AttachmentUploadFailure.tooLarge(byteCount: limit + 1, limit: limit)) {
            _ = try AttachmentStaging(directory: scratch.staging).stage(source, byteLimit: limit)
        }
        #expect(scratch.stagedEntries.isEmpty, "left behind: \(scratch.stagedEntries)")
    }

    @Test("AC5: a file exactly at the limit is staged")
    func fileAtTheLimitIsStaged() throws {
        let scratch = try Scratch()
        let source = try scratch.file("edge.bin", bytes: limit)

        let staged = try AttachmentStaging(directory: scratch.staging).stage(source, byteLimit: limit)

        #expect(scratch.isStagedCopy(staged.url), "\(staged.url.path) is not <staging>/<UUID>/<name>")
        #expect(staged.byteCount == limit)
    }

    @Test("AC5: a directory is refused and nothing is copied")
    func directoryIsRefused() throws {
        let scratch = try Scratch()
        let folder = scratch.source.appendingPathComponent("a folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("inside.txt"))

        let thrown = #expect(throws: AttachmentUploadFailure.self) {
            _ = try AttachmentStaging(directory: scratch.staging).stage(folder, byteLimit: limit)
        }
        #expect(scratch.stagedEntries.isEmpty, "left behind: \(scratch.stagedEntries)")
        guard case .unreadable = thrown else {
            Issue.record("expected .unreadable, got \(String(describing: thrown))")
            return
        }
    }

    @Test("AC6: discard removes the staged copy and its folder")
    func discardRemovesCopyAndFolder() throws {
        let scratch = try Scratch()
        let source = try scratch.file("notes.txt", bytes: 6)
        let staging = AttachmentStaging(directory: scratch.staging)
        let staged = try staging.stage(source, byteLimit: limit)

        staging.discard(staged)

        #expect(!FileManager.default.fileExists(atPath: staged.url.path), "still there: \(staged.url.path)")
        #expect(scratch.stagedEntries.isEmpty, "left behind: \(scratch.stagedEntries)")
    }

    @Test("AC6: sweep removes copies left by an earlier launch")
    func sweepRemovesLeftovers() throws {
        let scratch = try Scratch()
        // What a launch killed mid-upload leaves: `<staging>/<UUID>/<name>`.
        let leftover = scratch.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("abcdef".utf8).write(to: leftover.appendingPathComponent("old.txt"))

        AttachmentStaging(directory: scratch.staging).sweep()

        #expect(scratch.stagedEntries.count == 0, "left behind: \(scratch.stagedEntries)")
    }
}
