import Foundation

/// A file the host has accepted, and the receipt a prompt cites.
///
/// The shape is from a **live capture** (2026-10-09, installed host):
///
/// ```json
/// {"ok":true,"value":{"receiptId":"ee7fc538-…",
///                     "file":{"attachmentId":"sha256:25be…","name":"probe.txt","bytes":6}}}
/// ```
///
/// `receiptId` is what a prompt's `{type:"file",receiptId}` cites; SPEC §9 is explicit that
/// an `attachmentId` is not a substitute for it.
public struct UploadedAttachment: Sendable, Hashable {
    public var receiptId: String
    public var name: String
    public var byteCount: Int
    /// The host's own content-addressed id. Kept because it is what `session/attachment`
    /// takes to read an image back, but never sent in place of the receipt.
    public var attachmentId: String?

    public init(receiptId: String, name: String, byteCount: Int, attachmentId: String? = nil) {
        self.receiptId = receiptId
        self.name = name
        self.byteCount = byteCount
        self.attachmentId = attachmentId
    }
}

/// Why an upload did not produce a receipt.
public enum AttachmentUploadFailure: Error, Sendable, Hashable {
    /// The raw route is unavailable *and* the file is too big to send as base64.
    ///
    /// SPEC §6.8 keeps a 20 MiB cap on the fallback, and the cap is checked before the bytes
    /// are read: a file that cannot be sent should not be loaded into memory to find out. The
    /// size is the file's own, measured on disk, never a size the caller supplied (#66).
    case tooLargeForFallback(byteCount: Int, limit: Int)
    /// The file is larger than this app's per-file limit (SPEC §3.6), measured from the file
    /// on disk. Refused before anything is sent, on either route.
    case tooLarge(byteCount: Int, limit: Int)
    /// The file could not be measured as a regular file — missing, or a directory — so it is
    /// refused rather than sent as zero bytes. Nothing was sent, so unlike ``transport(reason:)``
    /// there is no outcome to reconcile.
    case unreadable(reason: String)
    /// The host answered successfully but named no receipt, so there is nothing to cite.
    case noReceipt
    /// The host refused the upload.
    case refused(code: String, message: String)
    /// The transfer itself failed — and it is *not* retried: an upload whose outcome is
    /// unknown is reconciled, never replayed (SPEC §3.4).
    case transport(reason: String)
}

/// Uploads a prepared file into a session.
///
/// SPEC §3.6 and §6.8's rules, in the order they apply:
///
/// 0. The file is **measured on disk** before anything is sent. A file that is not a readable
///    regular file, or is larger than ``byteLimit`` (20 MiB, this app's limit rather than the
///    harness's), is refused there, on either route. The caller's `byteCount` plays no part:
///    a size the caller under-reports must not be a way past the cap (#66).
/// 1. The **raw route** is preferred — `POST /api/session/uploadFileBinary?sessionId&name`
///    with the bytes as the body, streamed from disk so a large file never becomes a `Data`
///    in memory plus a base64 copy of it.
/// 2. The base64 `fileUploads/upload` fallback runs **only** for a 404 that says the raw route
///    is absent. Never around an auth, size or admission refusal: those are the host judging
///    this upload, and re-sending it another way would be evading the answer.
/// 3. The fallback is bounded too, by ``fallbackByteLimit``, from the same measurement.
///
/// It is a value type rather than an actor: it owns no state, and every call is scoped by the
/// arguments the caller already has.
public struct AttachmentUploader: Sendable {
    /// The base64 fallback's cap. It equals ``byteLimit`` by default, so today it can only
    /// refuse when a test injects a smaller one; it stays separate because base64 costs the
    /// file plus a third again in memory, which may justify a lower bound one day.
    public static let fallbackByteLimit = 20 * 1024 * 1024
    /// SPEC §3.6's per-file cap, the app's limit rather than the harness's (l.149). One cap,
    /// enforced on both routes, measured from the file on disk.
    public static let byteLimit = 20 * 1024 * 1024

    private let makeBareClient: @Sendable () -> DshBareEndpointClient
    private let makeRPCClient: @Sendable () -> DshRpcClient
    private let fallbackLimit: Int
    private let byteLimit: Int

    /// - Parameters:
    ///   - fallbackLimit: injected so a test can exercise the cap without a 20 MiB file.
    ///   - byteLimit: the same, for the per-file cap that applies to both routes.
    public init(
        makeBareClient: @escaping @Sendable () -> DshBareEndpointClient,
        makeRPCClient: @escaping @Sendable () -> DshRpcClient,
        fallbackLimit: Int = AttachmentUploader.fallbackByteLimit,
        byteLimit: Int = AttachmentUploader.byteLimit
    ) {
        self.makeBareClient = makeBareClient
        self.makeRPCClient = makeRPCClient
        self.fallbackLimit = fallbackLimit
        self.byteLimit = byteLimit
    }

    /// Uploads one prepared file and returns the receipt a prompt can cite.
    ///
    /// - Parameter byteCount: **ignored.** The size is measured from `fileURL` instead, so a
    ///   caller that under-reports it, or passes 0 because it could not stat the file, cannot
    ///   get a file past the cap (#66). It stays only so existing callers compile; a later MINOR
    ///   can drop it.
    /// - Throws: ``AttachmentUploadFailure/unreadable(reason:)`` or
    ///   ``AttachmentUploadFailure/tooLarge(byteCount:limit:)`` before any request is made.
    public func upload(
        sessionId: String,
        name: String,
        fileURL: URL,
        byteCount: Int
    ) async throws -> UploadedAttachment {
        let size = try Self.measure(fileURL)
        guard size <= byteLimit else {
            throw AttachmentUploadFailure.tooLarge(byteCount: size, limit: byteLimit)
        }
        do {
            let result = try await makeBareClient().uploadFileBinary(
                sessionId: sessionId,
                name: name,
                fileURL: fileURL
            )
            return try Self.decode(result.value)
        } catch let failure as AttachmentUploadFailure {
            // Already classified: a missing receipt is not a transport problem, and rewrapping
            // it as one would erase the only detail that explains it.
            throw failure
        } catch let error as DshRPCError {
            guard case .capabilityUnavailable = error else {
                throw Self.failure(from: error)
            }
            // Only here: the raw route is not implemented on this host.
            return try await uploadAsBase64(
                sessionId: sessionId,
                name: name,
                fileURL: fileURL,
                byteCount: size
            )
        } catch {
            throw AttachmentUploadFailure.transport(reason: String(describing: error))
        }
    }

    /// The bounded fallback, for a host whose raw route 404s.
    ///
    /// unverified: this route does not exist on the installed host built 2026-10-09 — its raw
    /// route answers — so the request shape is the spec's sentence and the result is decoded
    /// permissively, requiring only the receipt it is used for.
    ///
    /// - Parameter byteCount: the size ``upload(sessionId:name:fileURL:byteCount:)`` measured
    ///   from the file, never the caller's.
    private func uploadAsBase64(
        sessionId: String,
        name: String,
        fileURL: URL,
        byteCount: Int
    ) async throws -> UploadedAttachment {
        guard byteCount <= fallbackLimit else {
            throw AttachmentUploadFailure.tooLargeForFallback(byteCount: byteCount, limit: fallbackLimit)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw AttachmentUploadFailure.transport(reason: "the prepared file could not be read")
        }
        do {
            let response = try await makeRPCClient().mutate(
                Self.fallbackMethod,
                args: FileUploadArguments(
                    agentId: sessionId,
                    request: FileUploadBody(data: data.base64EncodedString(), name: name)
                ),
                returning: FileUploadValue.self
            )
            guard let value = response.result.value else { throw AttachmentUploadFailure.noReceipt }
            return try Self.decode(value)
        } catch let failure as AttachmentUploadFailure {
            throw failure
        } catch let error as DshRPCError {
            throw Self.failure(from: error)
        } catch {
            throw AttachmentUploadFailure.transport(reason: String(describing: error))
        }
    }

    // MARK: - Measuring

    /// The file's size on disk, or ``AttachmentUploadFailure/unreadable(reason:)`` when it is
    /// not a regular file whose size can be read. Absent is not zero: a size that cannot be
    /// read is never treated as an empty file.
    ///
    /// The reason names no path or file name: it can reach the screen (SPEC §3.6, S9).
    static func measure(_ fileURL: URL) throws -> Int {
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw AttachmentUploadFailure.unreadable(reason: "the file could not be read")
        }
        guard values.isRegularFile == true else {
            throw AttachmentUploadFailure.unreadable(reason: "it is not a regular file")
        }
        guard let size = values.fileSize else {
            throw AttachmentUploadFailure.unreadable(reason: "its size could not be read")
        }
        return size
    }

    // MARK: - Decoding

    /// Reads the receipt out of a bare upload `value`.
    ///
    /// `internal` rather than private so the captured payload can be decoded in a test without
    /// a transport.
    static func decode(_ value: JSONValue?) throws -> UploadedAttachment {
        guard let value,
              let receiptId = value["receiptId"]?.stringValue,
              !receiptId.isEmpty
        else { throw AttachmentUploadFailure.noReceipt }
        let file = value["file"]
        return UploadedAttachment(
            receiptId: receiptId,
            name: file?["name"]?.stringValue ?? "",
            byteCount: file?["bytes"]?.intValue.map(Int.init) ?? 0,
            attachmentId: file?["attachmentId"]?.stringValue
        )
    }

    /// The fallback's typed value, in the same shape the raw route's bare value decodes to.
    static func decode(_ value: FileUploadValue) throws -> UploadedAttachment {
        guard !value.receiptId.isEmpty else { throw AttachmentUploadFailure.noReceipt }
        return UploadedAttachment(
            receiptId: value.receiptId,
            name: value.file?.name ?? "",
            byteCount: value.file?.bytes ?? 0,
            attachmentId: value.file?.attachmentId
        )
    }

    static func failure(from error: DshRPCError) -> AttachmentUploadFailure {
        switch error {
        case .business(let business):
            return .refused(code: business.code, message: business.message)
        case .capabilityUnavailable(let endpoint):
            // The fallback itself 404ing means neither route exists on this host.
            return .refused(code: "gateway/method-unavailable", message: "the host does not implement \(endpoint)")
        case .credentialRejected, .relayedAuthenticationFailure:
            // Definitive, and never a reason to try another route (SPEC §9: do not fall back
            // around an auth failure).
            return .refused(code: "auth", message: error.readableReason ?? "the credential was refused")
        case .unexpectedStatus(let status, _) where (400..<500).contains(status):
            // A 4xx is this upload being judged — a size or admission refusal. A 5xx is not a
            // judgement, so it stays a transport failure.
            return .refused(code: "http/\(status)", message: error.readableReason ?? "the host refused the upload")
        default:
            return .transport(reason: error.readableReason ?? "the upload failed")
        }
    }

    /// SPEC §9's fallback endpoint. It has no generated descriptor in this build.
    public static let fallbackMethod = "fileUploads/upload"
}

/// `fileUploads/upload`'s body, hand-written because the descriptor does not carry it.
struct FileUploadBody: Codable, Sendable {
    var data: String
    var name: String?
}

struct FileUploadArguments: Codable, Sendable {
    var agentId: String
    var request: FileUploadBody
}

/// The fallback's result, decoded permissively: only the receipt is required.
struct FileUploadValue: Codable, Sendable {
    var receiptId: String
    var file: FileReference?

    struct FileReference: Codable, Sendable {
        var attachmentId: String?
        var name: String?
        var bytes: Int?
    }
}
