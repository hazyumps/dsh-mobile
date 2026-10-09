import Foundation
import Testing

@testable import DSHRemoteKit

/// Reading an attachment back through `session/attachment`.
///
/// The payload is the installed host's answer for the PNG the app uploaded on 2026-10-09, so
/// the decode is written against a real response rather than the schema's shape.
@Suite("Attachment reader")
struct AttachmentReaderTests {

    /// The live response, with the base64 shortened to a decodable stand-in of the right
    /// length: the metadata is verbatim, including `bytes: 107407`.
    private var liveResponse: Data {
        let body = """
        {"type":"server-response","rpcId":"t","result":{"ok":true,"value":{
          "attachment":{"attachmentId":"sha256:64cf6b08bc1ad1d481aa753fab4a8ac0a03aa4a98d72c7adfb65fdf751b8961c",
            "mediaType":"image/png","width":300,"height":200,"bytes":107407,"name":"dsh-image-probe.png"},
          "data":"\(Data(repeating: 0x41, count: 10_000).base64EncodedString())"}}}
        """
        return Data(body.utf8)
    }

    private func reader(_ transport: StubRelayTransport, byteLimit: Int = AttachmentReader.defaultByteLimit) -> AttachmentReader {
        AttachmentReader(
            makeClient: {
                DshRpcClient(
                    baseURL: URL(string: "https://192.0.2.10:3443")!,
                    authorization: .bearer("device-token"),
                    transport: transport
                )
            },
            byteLimit: byteLimit
        )
    }

    @Test("an attachment decodes into its metadata and bytes")
    func readsAnAttachment() async throws {
        let transport = StubRelayTransport(responsesByPath: [
            "/api/session/attachment": .json(status: 200, liveResponse),
        ])

        let attachment = try await reader(transport).attachment(
            sessionId: "session-1",
            attachmentId: "sha256:64cf6b08bc1ad1d481aa753fab4a8ac0a03aa4a98d72c7adfb65fdf751b8961c"
        )

        #expect(attachment.mediaType == "image/png")
        #expect(attachment.isImage)
        #expect(attachment.pixelWidth == 300)
        #expect(attachment.pixelHeight == 200)
        #expect(attachment.byteCount == 107_407)
        #expect(attachment.name == "dsh-image-probe.png")
        #expect(attachment.data.count == 10_000)

        // The arguments are `{request:{sessionId, attachmentId}}`.
        let requests = await transport.recordedRequests
        let request = try #require(requests.first)
        #expect(request.url.path == "/api/session/attachment")
        let envelope = try JSONDecoder().decode(JSONValue.self, from: #require(request.body))
        let args = try #require(envelope["payload"]?["args"]?["request"])
        #expect(args["sessionId"]?.stringValue == "session-1")
        #expect(args["attachmentId"]?.stringValue?.hasPrefix("sha256:") == true)
    }

    @Test("an attachment over the byte limit is refused before any base64 is decoded")
    func refusesAnOversizedAttachment() async throws {
        let transport = StubRelayTransport(responsesByPath: [
            "/api/session/attachment": .json(status: 200, liveResponse),
        ])

        // 107407 declared bytes against a 1024-byte ceiling: the host's own count decides, so
        // the client never decodes — and never holds — a payload it will not use.
        let thrown = await #expect(throws: AttachmentReadFailure.self) {
            try await self.reader(transport, byteLimit: 1024).attachment(
                sessionId: "session-1",
                attachmentId: "sha256:64cf6b08"
            )
        }
        #expect(thrown == .tooLarge(byteCount: 107_407, limit: 1024))
    }

    @Test("data that is not base64 is its own failure, not a transport error")
    func refusesUndecodableData() async throws {
        let transport = StubRelayTransport(responsesByPath: [
            "/api/session/attachment": .json(
                status: 200,
                Data("""
                {"type":"server-response","rpcId":"t","result":{"ok":true,"value":{
                  "attachment":{"attachmentId":"sha256:x","mediaType":"image/png",
                    "width":1,"height":1,"bytes":4},
                  "data":"not base64 !!"}}}
                """.utf8)
            ),
        ])
        let thrown = await #expect(throws: AttachmentReadFailure.self) {
            try await self.reader(transport).attachment(sessionId: "s", attachmentId: "sha256:x")
        }
        #expect(thrown == .undecodableData)
    }

    @Test("the host's refusal keeps its own code and words")
    func keepsTheHostsRefusal() async throws {
        let transport = StubRelayTransport(responsesByPath: [
            "/api/session/attachment": .json(
                status: 200,
                Data("""
                {"type":"server-response","rpcId":"t","result":{"ok":false,"error":
                  {"code":"session/attachment-not-found","message":"no such attachment"}}}
                """.utf8)
            ),
        ])
        let thrown = await #expect(throws: AttachmentReadFailure.self) {
            try await self.reader(transport).attachment(sessionId: "s", attachmentId: "sha256:missing")
        }
        guard case .refused(let code, let message) = thrown else {
            Issue.record("expected a refusal, got \(String(describing: thrown))")
            return
        }
        #expect(code == "session/attachment-not-found")
        #expect(message == "no such attachment")
    }

    @Test("the reader is the fetcher the image cache wants")
    func fetcherReturnsTheBytes() async throws {
        let transport = StubRelayTransport(responsesByPath: [
            "/api/session/attachment": .json(status: 200, liveResponse),
        ])
        // The cache holds `(sessionId, attachmentId)` and asks for `Data`, so this is the
        // seam that makes a thumbnail possible at all.
        let data = try await reader(transport).fetcher("session-1", "sha256:64cf6b08")
        #expect(data.count == 10_000)
    }
}
