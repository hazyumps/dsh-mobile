import Foundation

/// One attachment, read back from the host.
///
/// The shape is from a **live capture** (the installed host, 2026-10-09):
///
/// ```json
/// {"attachment":{"attachmentId":"sha256:64cf6b08…","mediaType":"image/png",
///                "width":300,"height":200,"bytes":107407,"name":"dsh-image-probe.png"},
///  "data":"<base64>"}
/// ```
public struct SessionAttachment: Sendable, Hashable {
    public var attachmentId: String
    public var mediaType: String
    public var byteCount: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var name: String?
    /// The bytes, decoded from the response's base64.
    public var data: Data

    public var isImage: Bool { mediaType.hasPrefix("image/") }

    public init(
        attachmentId: String,
        mediaType: String,
        byteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        name: String?,
        data: Data
    ) {
        self.attachmentId = attachmentId
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.name = name
        self.data = data
    }
}

/// Why an attachment could not be read.
public enum AttachmentReadFailure: Error, Sendable, Hashable {
    /// The host says the attachment is larger than this client will decode.
    ///
    /// SPEC §9's caution about unbounded payloads applies here twice over: this endpoint
    /// carries the whole file base64-encoded **inside one JSON response**, so a 20 MiB image
    /// arrives as 27 MiB of JSON and then decodes to 20 MiB of `Data` — three copies if the
    /// base64 string is kept. The ceiling stops the decode and the second copy.
    case tooLarge(byteCount: Int, limit: Int)
    /// The `data` field was not valid base64.
    case undecodableData
    /// The host refused the read.
    case refused(code: String, message: String)
    case transport(reason: String)
}

/// Reads attachments back from a session.
///
/// A read, so a failure changes nothing and the caller may retry — but nothing here retries
/// on its own: an image that failed to load should leave a placeholder, not a request storm.
public struct AttachmentReader: Sendable {
    /// The largest attachment this client will decode, in bytes.
    public static let defaultByteLimit = 32 * 1024 * 1024

    /// `namespace/method`, straight from `Protocol/endpoints.json`.
    public static let method = "session/attachment"

    private let makeClient: @Sendable () -> DshRpcClient
    private let byteLimit: Int

    public init(
        makeClient: @escaping @Sendable () -> DshRpcClient,
        byteLimit: Int = AttachmentReader.defaultByteLimit
    ) {
        self.makeClient = makeClient
        self.byteLimit = byteLimit
    }

    /// One attachment's bytes and metadata.
    public func attachment(sessionId: String, attachmentId: String) async throws -> SessionAttachment {
        let response: RPCResponse<SessionAttachmentValue>
        do {
            response = try await makeClient().call(
                Self.method,
                args: SessionAttachmentArguments(
                    request: SessionAttachmentRequest(
                        sessionId: sessionId,
                        attachmentId: attachmentId
                    )
                ),
                returning: SessionAttachmentValue.self
            )
        } catch let error as DshRPCError {
            throw Self.failure(from: error)
        } catch {
            throw AttachmentReadFailure.transport(reason: String(describing: error))
        }

        guard let value = response.result.value else {
            throw AttachmentReadFailure.refused(code: "session/attachment", message: "the host returned no attachment")
        }
        // The host's own byte count decides, before any base64 is decoded: a file this client
        // will not hold should cost it nothing to refuse.
        let declared = Int(value.attachment.bytes)
        guard declared <= byteLimit else {
            throw AttachmentReadFailure.tooLarge(byteCount: declared, limit: byteLimit)
        }
        guard let data = Data(base64Encoded: value.data) else {
            throw AttachmentReadFailure.undecodableData
        }
        return SessionAttachment(
            attachmentId: value.attachment.attachmentId,
            mediaType: value.attachment.mediaType.rawValue,
            byteCount: declared,
            pixelWidth: Int(value.attachment.width),
            pixelHeight: Int(value.attachment.height),
            name: value.attachment.name,
            data: data
        )
    }

    /// The fetcher ``SessionImageCache`` asks for, so a thumbnail costs one request per
    /// attachment and one decode.
    public var fetcher: AttachmentFetcher {
        let read = attachment(sessionId:attachmentId:)
        return { sessionId, attachmentId in
            try await read(sessionId, attachmentId).data
        }
    }

    static func failure(from error: DshRPCError) -> AttachmentReadFailure {
        switch error {
        case .business(let business):
            return .refused(code: business.code, message: business.message)
        case .capabilityUnavailable(let endpoint):
            return .refused(code: "gateway/method-unavailable", message: "the host does not implement \(endpoint)")
        default:
            return .transport(reason: error.readableReason ?? "the attachment could not be read")
        }
    }
}
