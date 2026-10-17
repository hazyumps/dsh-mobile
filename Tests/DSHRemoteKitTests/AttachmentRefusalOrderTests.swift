import Foundation
import Testing

@testable import DSHRemoteKit

/// #66, follow-up from verification: two refusals that every earlier test passed **without**.
///
/// 1. Staging refuses an oversized file *before* copying it (AC5, S5). With that check removed,
///    the re-measure after the copy still throws `.tooLarge` and the cleanup removes the copy, so a
///    test that only looks at the error and the staging directory cannot tell "never copied" from
///    "copied in full, then deleted". These tests use a source that can be measured but not read
///    (`chmod 000`): checked first, it is `.tooLarge`; copied first, the copy fails, `.unreadable`.
/// 2. Staging and the uploader refuse a file that is not a regular file (AC3, AC5). The only such
///    input in the earlier tests is a directory, and a directory has no `fileSize`, so the
///    nil-size branch refused it whether or not `isRegularFile` was checked.
///
/// Why a symbolic link and not a FIFO (probed 2026-10-15, macOS 27, `swiftc` probe calling
/// `url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .fileResourceTypeKey])`):
///
/// ```
/// symlink->file  isRegular=false size=107  type=NSURLFileResourceTypeSymbolicLink
/// fifo           isRegular=false size=nil  type=NSURLFileResourceTypeNamedPipe   (also with 30 bytes buffered)
/// socket         isRegular=false size=nil  type=NSURLFileResourceTypeSocket
/// /dev/null      isRegular=false size=nil  type=NSURLFileResourceTypeCharacterSpecial
/// x.app (dir)    isRegular=false size=nil  type=NSURLFileResourceTypeDirectory
/// ```
///
/// A FIFO reports no size, so it would be refused by the nil-size branch just as a directory is.
/// A symbolic link is the one non-regular file that reports a size (its own, the length of the
/// target path), because URL resource values describe the link, not what it points at. Refusing it
/// is also the right answer for staging: `FileManager.copyItem` copies a link as a link, so a
/// "staged copy" would still read the source, which is the #66 bug again. Nothing here opens
/// anything that can block, so no test can hang.
///
/// Every test has its own root directory; nothing is shared between tests running in parallel.
@Suite("Attachment refusal order (#66)")
struct AttachmentRefusalOrderTests {

    private let limit = 16

    /// A fresh root holding a `source` directory, and the path of a staging directory that does
    /// not exist yet.
    private struct Scratch {
        let source: URL
        let staging: URL

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("refusal-order-\(UUID().uuidString)", isDirectory: true)
            source = root.appendingPathComponent("source", isDirectory: true)
            staging = root.appendingPathComponent("AttachmentStaging", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        }

        func file(_ name: String, bytes: Int) throws -> URL {
            let url = source.appendingPathComponent(name)
            try Data(repeating: 0x61, count: bytes).write(to: url)
            return url
        }

        /// A symbolic link in `source` to a small regular file beside it.
        func symbolicLink(_ name: String) throws -> URL {
            let target = try file("\(name)-target.txt", bytes: 6)
            let link = source.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            return link
        }

        var stagedEntries: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        }
    }

    // MARK: - Staging

    @Test("AC5: an over-limit file is refused on its size before any copy is attempted")
    func overLimitIsRefusedBeforeTheCopy() throws {
        let scratch = try Scratch()
        let source = try scratch.file("big.bin", bytes: limit + 1)
        // Measurable (stat needs only the directory) but not copyable (the read is denied).
        try #require(chmod(source.path, 0) == 0, "chmod failed: errno \(errno)")
        defer { _ = chmod(source.path, 0o600) }
        // Running as root, 000 would not deny the read, and the test could not tell the order.
        try #require(
            !FileManager.default.isReadableFile(atPath: source.path),
            "chmod 000 did not make the source unreadable (running as root?); this test cannot tell check-then-copy from copy-then-check"
        )

        let thrown = #expect(throws: AttachmentUploadFailure.self) {
            _ = try AttachmentStaging(directory: scratch.staging).stage(source, byteLimit: limit)
        }
        // `.unreadable` here means staging tried to copy the file before checking its size.
        #expect(thrown == .tooLarge(byteCount: limit + 1, limit: limit))
        #expect(scratch.stagedEntries.isEmpty, "left behind: \(scratch.stagedEntries)")
    }

    @Test("AC5: a symbolic link, which reports a size, is refused as not a regular file and nothing is copied")
    func symbolicLinkIsRefusedByStaging() throws {
        let scratch = try Scratch()
        let link = try scratch.symbolicLink("link.txt")
        let size = try link.resourceValues(forKeys: [.fileSizeKey]).fileSize
        // The premise: the size branch alone would let this through.
        try #require(size != nil, "the link reports no size, so this test would not guard the type check")

        // The default 20 MiB limit, so only the type check can refuse it.
        let thrown = #expect(throws: AttachmentUploadFailure.self) {
            _ = try AttachmentStaging(directory: scratch.staging).stage(link)
        }
        #expect(scratch.stagedEntries.isEmpty, "left behind: \(scratch.stagedEntries)")
        guard case .unreadable = thrown else {
            Issue.record("expected .unreadable, got \(String(describing: thrown))")
            return
        }
    }

    // MARK: - Uploader

    private var liveUploadBody: Data {
        // The **captured** response from the installed host on 2026-10-09 (the same body as
        // `AttachmentUploaderTests.liveUploadBody`).
        Data("""
        {"ok":true,"value":{"receiptId":"ee7fc538-f01c-4513-a8d5-cf3675d845d3",
         "file":{"attachmentId":"sha256:25be323556dad377abb57fe7ec8c4b99a6527f488dda28d0c9b686528659c909",
         "name":"dsh-upload-probe.txt","bytes":6}}}
        """.utf8)
    }

    private func uploader(bare: StubRelayTransport) -> AttachmentUploader {
        let origin = URL(string: "https://192.0.2.10:3443")!
        return AttachmentUploader(
            makeBareClient: {
                DshBareEndpointClient(baseURL: origin, authorization: .bearer("device-token"), transport: bare)
            },
            makeRPCClient: {
                DshRpcClient(baseURL: origin, authorization: .bearer("device-token"), transport: StubRelayTransport())
            }
        )
    }

    @Test("AC3: the uploader refuses a symbolic link as not a regular file and sends nothing")
    func symbolicLinkIsRefusedByTheUploader() async throws {
        let scratch = try Scratch()
        let link = try scratch.symbolicLink("link.txt")
        let size = try link.resourceValues(forKeys: [.fileSizeKey]).fileSize
        try #require(size != nil, "the link reports no size, so this test would not guard the type check")
        let bare = StubRelayTransport(responsesByPath: [
            "/api/session/uploadFileBinary": .json(status: 200, liveUploadBody),
        ])

        // The default 20 MiB limit, so only the type check can refuse it.
        let thrown = await #expect(throws: AttachmentUploadFailure.self) {
            try await uploader(bare: bare).upload(
                sessionId: "session-1",
                name: "link.txt",
                fileURL: link,
                byteCount: 6
            )
        }
        let sent = await bare.recordedRequests.count
        #expect(sent == 0)
        guard case .unreadable = thrown else {
            Issue.record("expected .unreadable, got \(String(describing: thrown))")
            return
        }
    }
}
