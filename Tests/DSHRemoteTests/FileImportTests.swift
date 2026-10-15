import DSHRemoteKit
import Foundation
import Testing
@testable import DSHRemote

/// #66: the app's file-import glue. The rules (copy, size, type, discard, sweep) are pinned in the
/// kit by `AttachmentStagingTests` and `AttachmentUploadLimitTests`; these pin that `AppModel`
/// actually uses them: an import goes through staging, leaves nothing behind once it settles, says
/// why it failed, and a launch clears what an earlier launch left.
///
/// No host is connected in these tests, so `attachFile` stops at "not connected" and nothing is
/// sent. Every test gets its own drafts and staging directories, so nothing is shared.
@MainActor
@Suite("File import (#66)")
struct FileImportTests {

    private struct Scratch {
        let root: URL
        let drafts: URL
        let staging: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("file-import-\(UUID().uuidString)", isDirectory: true)
            drafts = root.appendingPathComponent("Drafts", isDirectory: true)
            staging = root.appendingPathComponent("AttachmentStaging", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        /// What is in the staging directory; a directory that was never created holds nothing.
        var stagedEntries: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        }
    }

    @Test("AC7: an import that cannot upload leaves nothing staged and says why")
    func importThatCannotUploadLeavesNothing() async throws {
        let scratch = try Scratch()
        let source = scratch.root.appendingPathComponent("notes.txt")
        try Data("abcdef".utf8).write(to: source)
        let model = AppModel(draftsDirectory: scratch.drafts, stagingDirectory: scratch.staging)

        await model.importFile(at: source, to: "session-1")

        #expect(model.attachmentError == "This phone is not connected to a harness.")
        #expect(scratch.stagedEntries.isEmpty, "left behind: \(scratch.stagedEntries)")
    }

    @Test("AC7: an import over the app limit is refused with a message naming the app's 20 MiB limit")
    func importOverTheLimitSaysItIsThisAppsLimit() async throws {
        let scratch = try Scratch()
        // One byte over SPEC §3.6's 20 MiB. Sparse: `truncate` sets the length without writing
        // the bytes, so the test costs no disk.
        let source = scratch.root.appendingPathComponent("huge.bin")
        #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(AttachmentUploader.byteLimit + 1))
        try handle.close()
        let model = AppModel(draftsDirectory: scratch.drafts, stagingDirectory: scratch.staging)

        await model.importFile(at: source, to: "session-1")

        // Refused before the copy: a file that cannot be sent is not duplicated to find out.
        #expect(scratch.stagedEntries.isEmpty, "left behind: \(scratch.stagedEntries)")
        let message = try #require(model.attachmentError)
        // SPEC §3.6: the 20 MiB is this app's limit, not the harness's, and the message says so.
        #expect(message.contains("20 MiB"), "\(message)")
        #expect(message.lowercased().contains("this app"), "\(message)")
    }

    @Test("AC7: launch clears copies an earlier launch left behind")
    func launchSweepsStaging() throws {
        let scratch = try Scratch()
        // What a launch killed mid-upload leaves: `<staging>/<UUID>/<name>`.
        let leftover = scratch.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("abcdef".utf8).write(to: leftover.appendingPathComponent("old.txt"))

        _ = AppModel(draftsDirectory: scratch.drafts, stagingDirectory: scratch.staging)

        #expect(scratch.stagedEntries.count == 0, "left behind: \(scratch.stagedEntries)")
    }
}
