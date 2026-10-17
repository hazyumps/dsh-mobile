import Foundation
import Testing

@testable import DSHRemoteKit

/// #66: one per-file cap on both upload routes, measured from the file on disk (SPEC §3.6, which
/// sets 20 MiB as *this app's* limit, not the harness's).
///
/// Before #66 only the base64 fallback was capped, and only from the `byteCount` its caller
/// passed; the raw route sent a file of any size. These tests inject a 16-byte limit so that no
/// 20 MiB file is ever written. Each test makes its own scratch directory: nothing is shared.
@Suite("Attachment upload limit (#66)")
struct AttachmentUploadLimitTests {

    private let sessionId = "session-1"
    private let limit = 16

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func scratchFile(bytes: Int) throws -> URL {
        let url = try scratchDirectory().appendingPathComponent("probe.txt")
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }

    /// The **captured** response from the installed host on 2026-10-09 (the same body as
    /// `AttachmentUploaderTests.liveUploadBody`), with the ids kept.
    private var liveUploadBody: Data {
        Data("""
        {"ok":true,"value":{"receiptId":"ee7fc538-f01c-4513-a8d5-cf3675d845d3",
         "file":{"attachmentId":"sha256:25be323556dad377abb57fe7ec8c4b99a6527f488dda28d0c9b686528659c909",
         "name":"dsh-upload-probe.txt","bytes":6}}}
        """.utf8)
    }

    private func rawRouteAccepts() -> StubRelayTransport {
        StubRelayTransport(responsesByPath: [
            "/api/session/uploadFileBinary": .json(status: 200, liveUploadBody),
        ])
    }

    private func uploader(
        bare: StubRelayTransport,
        rpc: StubRelayTransport = StubRelayTransport(),
        fallbackLimit: Int = AttachmentUploader.fallbackByteLimit,
        byteLimit: Int = AttachmentUploader.byteLimit
    ) -> AttachmentUploader {
        let origin = URL(string: "https://192.0.2.10:3443")!
        return AttachmentUploader(
            makeBareClient: {
                DshBareEndpointClient(
                    baseURL: origin,
                    authorization: .bearer("device-token"),
                    transport: bare
                )
            },
            makeRPCClient: {
                DshRpcClient(
                    baseURL: origin,
                    authorization: .bearer("device-token"),
                    transport: rpc
                )
            },
            fallbackLimit: fallbackLimit,
            byteLimit: byteLimit
        )
    }

    @Test("AC1: the raw route refuses a file one byte over the limit before sending anything")
    func rawRouteRefusesOneByteOver() async throws {
        let bare = rawRouteAccepts()
        let file = try scratchFile(bytes: limit + 1)

        let thrown = await #expect(throws: AttachmentUploadFailure.self) {
            try await uploader(bare: bare, byteLimit: limit).upload(
                sessionId: sessionId,
                name: "probe.txt",
                fileURL: file,
                byteCount: limit + 1
            )
        }
        #expect(thrown == .tooLarge(byteCount: limit + 1, limit: limit))
        // Refused before the request, not after: the bytes never left the phone.
        let sent = await bare.recordedRequests.count
        #expect(sent == 0)
    }

    @Test("AC1: a file exactly at the limit is sent")
    func rawRouteSendsAFileAtTheLimit() async throws {
        let bare = rawRouteAccepts()
        let file = try scratchFile(bytes: limit)

        let uploaded = try await uploader(bare: bare, byteLimit: limit).upload(
            sessionId: sessionId,
            name: "probe.txt",
            fileURL: file,
            byteCount: limit
        )

        #expect(uploaded.receiptId == "ee7fc538-f01c-4513-a8d5-cf3675d845d3")
        let sent = await bare.recordedRequests.count
        #expect(sent == 1)
    }

    @Test("AC2: a caller that under-reports the size cannot get an oversized file past the limit")
    func underReportedSizeIsIgnoredOnTheRawRoute() async throws {
        let bare = rawRouteAccepts()
        let file = try scratchFile(bytes: 64)

        let thrown = await #expect(throws: AttachmentUploadFailure.self) {
            try await uploader(bare: bare, byteLimit: limit).upload(
                sessionId: sessionId,
                name: "probe.txt",
                fileURL: file,
                byteCount: 1
            )
        }
        // The size in the error is the file's, not the 1 the caller claimed.
        #expect(thrown == .tooLarge(byteCount: 64, limit: limit))
        let sent = await bare.recordedRequests.count
        #expect(sent == 0)
    }

    @Test("AC2: the fallback measures the file, not the caller's byteCount")
    func underReportedSizeIsIgnoredOnTheFallback() async throws {
        let bare = StubRelayTransport(responsesByPath: [
            "/api/session/uploadFileBinary": .json(status: 404, Data("not found".utf8)),
        ])
        let rpc = StubRelayTransport(responsesByPath: [
            "/api/fileUploads/upload": .json(
                status: 200,
                Data("""
                {"type":"server-response","rpcId":"t","result":{"ok":true,"value":
                  {"receiptId":"receipt-from-fallback","file":{"name":"probe.txt","bytes":64}}}}
                """.utf8)
            ),
        ])
        let file = try scratchFile(bytes: 64)

        // The per-file cap stays at its 20 MiB default, so only the fallback's 16 can refuse.
        let thrown = await #expect(throws: AttachmentUploadFailure.self) {
            try await uploader(bare: bare, rpc: rpc, fallbackLimit: limit).upload(
                sessionId: sessionId,
                name: "probe.txt",
                fileURL: file,
                byteCount: 1
            )
        }
        #expect(thrown == .tooLargeForFallback(byteCount: 64, limit: limit))
        let sent = await rpc.recordedRequests.count
        #expect(sent == 0)
    }

    @Test("AC3: a file whose size cannot be read is refused, not sent as zero bytes")
    func unmeasurableFileIsRefused() async throws {
        let bare = rawRouteAccepts()
        let missing = try scratchDirectory().appendingPathComponent("gone.txt")

        let thrown = await #expect(throws: AttachmentUploadFailure.self) {
            try await uploader(bare: bare, byteLimit: limit).upload(
                sessionId: sessionId,
                name: "gone.txt",
                fileURL: missing,
                byteCount: 0
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
