import Foundation
import Testing

@testable import DSHRemoteKit

/// The upload path's rules: the raw route first, the base64 fallback **only** for a 404, a
/// bound on that fallback, and a receipt or nothing.
@Suite("Attachment upload")
struct AttachmentUploaderTests {

    private let sessionId = "session-1"

    private func scratchFile(bytes: Int = 6) throws -> (url: URL, size: Int) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("probe.txt")
        let data = Data(repeating: 0x61, count: bytes)
        try data.write(to: url)
        return (url, bytes)
    }

    /// The **captured** response from the installed host on 2026-10-09, with the ids kept.
    private var liveUploadBody: Data {
        Data("""
        {"ok":true,"value":{"receiptId":"ee7fc538-f01c-4513-a8d5-cf3675d845d3",
         "file":{"attachmentId":"sha256:25be323556dad377abb57fe7ec8c4b99a6527f488dda28d0c9b686528659c909",
         "name":"dsh-upload-probe.txt","bytes":6}}}
        """.utf8)
    }

    private func uploader(
        bare: StubRelayTransport,
        rpc: StubRelayTransport = StubRelayTransport(),
        fallbackLimit: Int = AttachmentUploader.fallbackByteLimit
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
            fallbackLimit: fallbackLimit
        )
    }

    @Test("the raw route's receipt is read out of the captured body")
    func rawRouteReturnsTheReceipt() async throws {
        let transport = StubRelayTransport(responsesByPath: [
            "/api/session/uploadFileBinary": .json(status: 200, liveUploadBody),
        ])
        let file = try scratchFile()

        let uploaded = try await uploader(bare: transport).upload(
            sessionId: sessionId,
            name: "dsh-upload-probe.txt",
            fileURL: file.url,
            byteCount: file.size
        )

        #expect(uploaded.receiptId == "ee7fc538-f01c-4513-a8d5-cf3675d845d3")
        #expect(uploaded.name == "dsh-upload-probe.txt")
        #expect(uploaded.byteCount == 6)
        // The content-addressed id is kept for reading an image back — but never in place of
        // the receipt a prompt cites (SPEC §9).
        #expect(uploaded.attachmentId?.hasPrefix("sha256:") == true)

        // The raw route streams from disk: no body in memory, and the name is a query value.
        let requests = await transport.recordedRequests
        let request = try #require(requests.first)
        #expect(request.url.path == "/api/session/uploadFileBinary")
        #expect(request.url.query?.contains("sessionId=session-1") == true)
        #expect(request.url.query?.contains("name=dsh-upload-probe.txt") == true)
        #expect(request.bodyFile?.lastPathComponent == "probe.txt")
    }

    @Test("a 404 on the raw route falls back to base64, and only then")
    func rawRouteAbsenceFallsBack() async throws {
        let bare = StubRelayTransport(responsesByPath: [
            "/api/session/uploadFileBinary": .json(
                status: 404,
                Data("not found".utf8),
                headers: ["Content-Type": "text/plain"]
            ),
        ])
        let rpc = StubRelayTransport(responsesByPath: [
            "/api/fileUploads/upload": .json(
                status: 200,
                Data("""
                {"type":"server-response","rpcId":"t","result":{"ok":true,"value":
                  {"receiptId":"receipt-from-fallback","file":{"name":"café menu.txt","bytes":6}}}}
                """.utf8)
            ),
        ])
        let file = try scratchFile()

        let uploaded = try await uploader(bare: bare, rpc: rpc).upload(
            sessionId: sessionId,
            name: "café menu.txt",
            fileURL: file.url,
            byteCount: file.size
        )

        #expect(uploaded.receiptId == "receipt-from-fallback")
        #expect(uploaded.name == "café menu.txt")

        let requests = await rpc.recordedRequests
        let request = try #require(requests.first)
        #expect(request.url.path == "/api/fileUploads/upload")
        let envelope = try JSONDecoder().decode(JSONValue.self, from: #require(request.body))
        let arguments = try #require(envelope["payload"]?["args"])
        #expect(arguments["agentId"]?.stringValue == "session-1")
        // The bytes travel base64-encoded, with the name beside them.
        let body = try #require(arguments["request"])
        #expect(body["data"]?.stringValue == Data(repeating: 0x61, count: 6).base64EncodedString())
        #expect(body["name"]?.stringValue == "café menu.txt")
    }

    @Test("any refusal but a 404 is the host's answer, and is not re-sent another way")
    func onlyAnAbsentRouteFallsBack() async throws {
        // A 413 is the host judging this upload; SPEC §9 forbids falling back around it.
        let bare = StubRelayTransport(responsesByPath: [
            "/api/session/uploadFileBinary": .json(
                status: 413,
                Data(#"{"ok":false,"error":{"code":"gateway/payload-too-large","message":"too big"}}"#.utf8),
                headers: ["Content-Type": "application/json"]
            ),
        ])
        let rpc = StubRelayTransport(responsesByPath: [
            "/api/fileUploads/upload": .json(status: 200, Data("{}".utf8)),
        ])
        let file = try scratchFile()

        let thrown = await #expect(throws: AttachmentUploadFailure.self) {
            try await uploader(bare: bare, rpc: rpc).upload(
                sessionId: sessionId,
                name: "probe.txt",
                fileURL: file.url,
                byteCount: file.size
            )
        }
        guard case .refused = thrown else {
            Issue.record("expected a refusal, got \(String(describing: thrown))")
            return
        }
        // The fallback was never reached.
        #expect(await rpc.recordedRequests.isEmpty)
    }

    @Test("a file too big for the fallback is refused before it is read")
    func oversizedFallbackIsRefused() async throws {
        let bare = StubRelayTransport(responsesByPath: [
            "/api/session/uploadFileBinary": .json(status: 404, Data("not found".utf8)),
        ])
        let rpc = StubRelayTransport()
        let file = try scratchFile(bytes: 64)

        let thrown = await #expect(throws: AttachmentUploadFailure.self) {
            try await uploader(bare: bare, rpc: rpc, fallbackLimit: 16).upload(
                sessionId: sessionId,
                name: "probe.txt",
                fileURL: file.url,
                byteCount: file.size
            )
        }
        #expect(thrown == .tooLargeForFallback(byteCount: 64, limit: 16))
        #expect(await rpc.recordedRequests.isEmpty)
    }

    @Test("a successful upload with no receipt is a failure, not a silent success")
    func missingReceiptIsAFailure() async throws {
        let transport = StubRelayTransport(responsesByPath: [
            "/api/session/uploadFileBinary": .json(
                status: 200,
                Data(#"{"ok":true,"value":{"file":{"name":"probe.txt","bytes":6}}}"#.utf8)
            ),
        ])
        let file = try scratchFile()

        let thrown = await #expect(throws: AttachmentUploadFailure.self) {
            try await uploader(bare: transport).upload(
                sessionId: sessionId,
                name: "probe.txt",
                fileURL: file.url,
                byteCount: file.size
            )
        }
        // Without a receipt there is nothing a prompt could cite, so this cannot be reported
        // as an upload that worked.
        #expect(thrown == .noReceipt)
    }

    @Test("a unicode name survives as a query value")
    func unicodeNameIsEncoded() async throws {
        let transport = StubRelayTransport(responsesByPath: [
            "/api/session/uploadFileBinary": .json(status: 200, liveUploadBody),
        ])
        let file = try scratchFile()

        _ = try await uploader(bare: transport).upload(
            sessionId: sessionId,
            name: "café menu (1).txt",
            fileURL: file.url,
            byteCount: file.size
        )

        let requests = await transport.recordedRequests
        let request = try #require(requests.first)
        // Percent-encoded on the wire; the query parser reads it back as the original.
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first { $0.name == "name" }?.value == "café menu (1).txt")
    }
}
