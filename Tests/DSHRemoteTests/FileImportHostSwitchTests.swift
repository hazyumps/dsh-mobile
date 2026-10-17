import DSHRemoteKit
import Foundation
import Testing
@testable import DSHRemote

/// #66 addendum (AC9–AC11): a host switch while an import is between its pick and its upload.
///
/// `importFile` awaits the staging copy and then the upload. A switch from host A to host B in
/// either await must not send A's file to B, and must not publish A's receipt or A's error into
/// B's state. The switch is `replaceHostForTesting(uploader:)`, which goes through the same
/// `resetHostScopedState()` as `select`, `disconnect` and forget.
///
/// How an import is held mid-flight without `Task.sleep`: the staging step is injected and
/// suspends on a gate after the real copy, and the upload transport suspends on a gate after
/// recording its request. The test waits for the "staged" or "request received" signal on a
/// stream that the import task also finishes when it returns, so an implementation that never
/// stages or never uploads ends the stream, fails a `#require` with a message, and cannot hang.
///
/// Every test has its own scratch directories, its own model and its own transports.
@MainActor
@Suite("File import across a host switch (#66)")
struct FileImportHostSwitchTests {

    private let sessionId = "session-1"
    private let receiptId = "ee7fc538-f01c-4513-a8d5-cf3675d845d3"

    // MARK: - Fixtures

    private struct Scratch {
        let root: URL
        let drafts: URL
        let staging: URL
        let source: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("file-import-switch-\(UUID().uuidString)", isDirectory: true)
            drafts = root.appendingPathComponent("Drafts", isDirectory: true)
            staging = root.appendingPathComponent("AttachmentStaging", isDirectory: true)
            source = root.appendingPathComponent("notes.txt")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("abcdef".utf8).write(to: source)
        }

        /// What is in the staging directory; a directory that was never created holds nothing.
        var stagedEntries: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        }
    }

    /// The **captured** response from the installed host on 2026-10-09 to
    /// `POST /api/session/uploadFileBinary` (the same body as
    /// `AttachmentUploaderTests.liveUploadBody`), with the ids kept.
    private static let liveUploadBody = Data("""
        {"ok":true,"value":{"receiptId":"ee7fc538-f01c-4513-a8d5-cf3675d845d3",
         "file":{"attachmentId":"sha256:25be323556dad377abb57fe7ec8c4b99a6527f488dda28d0c9b686528659c909",
         "name":"dsh-upload-probe.txt","bytes":6}}}
        """.utf8)

    private static let hostA = URL(string: "https://192.0.2.10:3443")!
    private static let hostB = URL(string: "https://192.0.2.20:3443")!

    private static func accepting() -> StubRelayTransport {
        StubRelayTransport(responsesByPath: [
            "/api/session/uploadFileBinary": .json(status: 200, liveUploadBody),
        ])
    }

    private static func offline() -> StubRelayTransport {
        StubRelayTransport(responsesByPath: [
            "/api/session/uploadFileBinary": .failure(.offline("the test host is unreachable")),
        ])
    }

    /// An uploader for one host: its own origin, its own credential, its own transport.
    private static func uploader(origin: URL, token: String, transport: any RelayTransport) -> AttachmentUploader {
        AttachmentUploader(
            makeBareClient: {
                DshBareEndpointClient(baseURL: origin, authorization: .bearer(token), transport: transport)
            },
            makeRPCClient: {
                DshRpcClient(baseURL: origin, authorization: .bearer(token), transport: transport)
            }
        )
    }

    /// A model whose imports stop after the real staging copy until `gate` opens, and report the
    /// copy on `staged` when they get there.
    private static func modelHeldAfterStaging(
        _ scratch: Scratch,
        staged: AsyncStream<StagedFile>.Continuation,
        gate: Gate
    ) -> AppModel {
        AppModel(
            draftsDirectory: scratch.drafts,
            stagingDirectory: scratch.staging,
            stageFile: { staging, url in
                let copy = try staging.stage(url)
                staged.yield(copy)
                await gate.wait()
                return copy
            }
        )
    }

    /// Starts an import, waits until it is held after staging, switches to `hostB`, lets the
    /// import go on, and waits for it to finish. Returns whether the copy existed while held, or
    /// `nil` if the import never reached staging.
    private func importSwitchingDuringStaging(
        _ scratch: Scratch,
        from hostA: AttachmentUploader,
        to hostB: AttachmentUploader
    ) async -> (model: AppModel, copyExistedWhileHeld: Bool)? {
        let (stream, staged) = AsyncStream.makeStream(of: StagedFile.self)
        let gate = Gate()
        let model = Self.modelHeldAfterStaging(scratch, staged: staged, gate: gate)
        model.replaceHostForTesting(uploader: hostA)

        let importing = Task { @MainActor in
            await model.importFile(at: scratch.source, to: sessionId)
            staged.finish()
        }
        var signals = stream.makeAsyncIterator()
        guard let copy = await signals.next() else {
            await importing.value
            return nil
        }
        let existed = FileManager.default.fileExists(atPath: copy.url.path)
        model.replaceHostForTesting(uploader: hostB)
        await gate.open()
        await importing.value
        return (model, existed)
    }

    /// Starts an import whose upload to host A is held after A records the request, switches to
    /// `hostB`, then lets A answer and waits for the import to finish. Returns whether a staged
    /// copy existed while the upload was held, or `nil` if no request ever reached host A.
    private func importSwitchingDuringUpload(
        _ scratch: Scratch,
        hostA: GatedUploadTransport,
        received: AsyncStream<Void>,
        receivedSignal: AsyncStream<Void>.Continuation,
        to hostB: AttachmentUploader
    ) async -> (model: AppModel, copyExistedWhileHeld: Bool)? {
        let model = AppModel(draftsDirectory: scratch.drafts, stagingDirectory: scratch.staging)
        model.replaceHostForTesting(
            uploader: Self.uploader(origin: Self.hostA, token: "token-a", transport: hostA)
        )

        let importing = Task { @MainActor in
            await model.importFile(at: scratch.source, to: sessionId)
            receivedSignal.finish()
        }
        var signals = received.makeAsyncIterator()
        guard await signals.next() != nil else {
            await importing.value
            return nil
        }
        let existed = !scratch.stagedEntries.isEmpty
        model.replaceHostForTesting(uploader: hostB)
        await hostA.release()
        await importing.value
        return (model, existed)
    }

    /// Starts an import whose staging step reaches the gate and then throws `failure`, switches
    /// to `hostB` while it is held, lets it throw, and waits for the import to finish. Returns
    /// the model, or `nil` if the import never reached staging.
    private func importFailingAfterSwitch(
        _ scratch: Scratch,
        throwing failure: any Error,
        from hostA: AttachmentUploader,
        to hostB: AttachmentUploader
    ) async -> AppModel? {
        let (stream, reached) = AsyncStream.makeStream(of: Void.self)
        let gate = Gate()
        let model = AppModel(
            draftsDirectory: scratch.drafts,
            stagingDirectory: scratch.staging,
            stageFile: { _, _ in
                reached.yield()
                await gate.wait()
                throw failure
            }
        )
        model.replaceHostForTesting(uploader: hostA)

        let importing = Task { @MainActor in
            await model.importFile(at: scratch.source, to: sessionId)
            reached.finish()
        }
        var signals = stream.makeAsyncIterator()
        guard await signals.next() != nil else {
            await importing.value
            return nil
        }
        model.replaceHostForTesting(uploader: hostB)
        await gate.open()
        await importing.value
        return model
    }

    // MARK: - AC9: a switch during staging sends the file nowhere and leaves no copy

    @Test("AC9: a file staged while host A was selected is not uploaded to host B after a switch")
    func stagedFileIsNotUploadedToTheNewHost() async throws {
        let scratch = try Scratch()
        let hostA = Self.accepting()
        let hostB = Self.accepting()

        let outcome = await importSwitchingDuringStaging(
            scratch,
            from: Self.uploader(origin: Self.hostA, token: "token-a", transport: hostA),
            to: Self.uploader(origin: Self.hostB, token: "token-b", transport: hostB)
        )
        _ = try #require(outcome, "the import never reached staging")

        let sentToA = await hostA.recordedRequests.count
        let sentToB = await hostB.recordedRequests.count
        #expect(sentToB == 0, "host B was sent a file picked for host A")
        #expect(sentToA == 0, "host A was sent a file after the user had left it")
    }

    @Test("AC9: an import abandoned by a host switch during staging leaves no copy")
    func abandonedImportLeavesNoCopy() async throws {
        let scratch = try Scratch()

        let outcome = await importSwitchingDuringStaging(
            scratch,
            from: Self.uploader(origin: Self.hostA, token: "token-a", transport: Self.accepting()),
            to: Self.uploader(origin: Self.hostB, token: "token-b", transport: Self.accepting())
        )
        let held = try #require(outcome, "the import never reached staging")

        try #require(held.copyExistedWhileHeld, "premise: the copy exists while staging is held")
        #expect(scratch.stagedEntries.isEmpty, "left behind: \(scratch.stagedEntries)")
    }

    @Test("AC9: with no switch, the staged file is uploaded once to the selected host and its receipt published")
    func withNoSwitchTheFileIsUploadedOnce() async throws {
        let scratch = try Scratch()
        let hostA = Self.accepting()
        let model = AppModel(draftsDirectory: scratch.drafts, stagingDirectory: scratch.staging)
        model.replaceHostForTesting(
            uploader: Self.uploader(origin: Self.hostA, token: "token-a", transport: hostA)
        )

        await model.importFile(at: scratch.source, to: sessionId)

        let sent = await hostA.recordedRequests
        #expect(sent.count == 1)
        #expect(sent.first?.url.host() == Self.hostA.host())
        #expect(model.stagedAttachments[sessionId]?.map(\.receiptId) == [receiptId])
        #expect(model.attachmentError == nil)
        #expect(scratch.stagedEntries.isEmpty, "left behind: \(scratch.stagedEntries)")
    }

    // MARK: - AC10: an import abandoned during staging publishes nothing

    @Test("AC10: an import abandoned during staging publishes no receipt into the new host")
    func abandonedImportPublishesNoReceipt() async throws {
        let scratch = try Scratch()

        let outcome = await importSwitchingDuringStaging(
            scratch,
            from: Self.uploader(origin: Self.hostA, token: "token-a", transport: Self.accepting()),
            to: Self.uploader(origin: Self.hostB, token: "token-b", transport: Self.accepting())
        )
        let held = try #require(outcome, "the import never reached staging")

        #expect(held.model.stagedAttachments[sessionId]?.count == nil)
        #expect(held.model.stagedAttachments.isEmpty)
    }

    @Test("AC10: an import abandoned during staging shows no error on the new host")
    func abandonedImportShowsNoError() async throws {
        let scratch = try Scratch()

        let outcome = await importSwitchingDuringStaging(
            scratch,
            from: Self.uploader(origin: Self.hostA, token: "token-a", transport: Self.accepting()),
            to: Self.uploader(origin: Self.hostB, token: "token-b", transport: Self.offline())
        )
        let held = try #require(outcome, "the import never reached staging")

        #expect(held.model.attachmentError == nil)
    }

    @Test("AC10: a staging refusal that arrives after a host switch is not shown on the new host")
    func lateStagingRefusalIsNotShown() async throws {
        let scratch = try Scratch()
        let hostA = Self.accepting()
        let hostB = Self.accepting()

        let model = await importFailingAfterSwitch(
            scratch,
            throwing: AttachmentUploadFailure.unreadable(reason: "host A's pick could not be read"),
            from: Self.uploader(origin: Self.hostA, token: "token-a", transport: hostA),
            to: Self.uploader(origin: Self.hostB, token: "token-b", transport: hostB)
        )
        let held = try #require(model, "the import never reached staging")

        #expect(held.attachmentError == nil, "host A's refusal was shown on host B")
        let sentToA = await hostA.recordedRequests.count
        let sentToB = await hostB.recordedRequests.count
        #expect(sentToA == 0)
        #expect(sentToB == 0)
    }

    @Test("AC10: a staging error that arrives after a host switch is not shown on the new host")
    func lateStagingErrorIsNotShown() async throws {
        let scratch = try Scratch()
        let hostA = Self.accepting()
        let hostB = Self.accepting()

        let model = await importFailingAfterSwitch(
            scratch,
            throwing: CocoaError(.fileReadNoPermission),
            from: Self.uploader(origin: Self.hostA, token: "token-a", transport: hostA),
            to: Self.uploader(origin: Self.hostB, token: "token-b", transport: hostB)
        )
        let held = try #require(model, "the import never reached staging")

        #expect(held.attachmentError == nil, "host A's staging error was shown on host B")
        let sentToA = await hostA.recordedRequests.count
        let sentToB = await hostB.recordedRequests.count
        #expect(sentToA == 0)
        #expect(sentToB == 0)
    }

    // MARK: - AC11: a switch during the upload does not publish into the new host

    @Test("AC11: a receipt that arrives after a host switch is not published into the new host")
    func lateReceiptIsNotPublished() async throws {
        let scratch = try Scratch()
        let (received, signal) = AsyncStream.makeStream(of: Void.self)
        let hostA = GatedUploadTransport(answer: .accept(Self.liveUploadBody), onRequest: signal)
        let hostB = Self.accepting()

        let outcome = await importSwitchingDuringUpload(
            scratch,
            hostA: hostA,
            received: received,
            receivedSignal: signal,
            to: Self.uploader(origin: Self.hostB, token: "token-b", transport: hostB)
        )
        let held = try #require(outcome, "no upload request ever reached host A")

        #expect(held.model.stagedAttachments[sessionId]?.count == nil)
        // S1: the request already sent is neither cancelled into a resend nor repeated anywhere.
        let sentToA = await hostA.recordedRequests.count
        let sentToB = await hostB.recordedRequests.count
        #expect(sentToA == 1)
        #expect(sentToB == 0)
    }

    @Test("AC11: an upload failure that arrives after a host switch is not shown on the new host")
    func lateFailureIsNotShown() async throws {
        let scratch = try Scratch()
        let (received, signal) = AsyncStream.makeStream(of: Void.self)
        let hostA = GatedUploadTransport(answer: .offline, onRequest: signal)
        let hostB = Self.accepting()

        let outcome = await importSwitchingDuringUpload(
            scratch,
            hostA: hostA,
            received: received,
            receivedSignal: signal,
            to: Self.uploader(origin: Self.hostB, token: "token-b", transport: hostB)
        )
        let held = try #require(outcome, "no upload request ever reached host A")

        #expect(held.model.attachmentError == nil)
        let sentToA = await hostA.recordedRequests.count
        let sentToB = await hostB.recordedRequests.count
        #expect(sentToA == 1)
        #expect(sentToB == 0)
    }

    @Test("AC11: a copy whose upload settles after a host switch is still discarded")
    func lateUploadCopyIsDiscarded() async throws {
        let scratch = try Scratch()
        let (received, signal) = AsyncStream.makeStream(of: Void.self)
        let hostA = GatedUploadTransport(answer: .accept(Self.liveUploadBody), onRequest: signal)

        let outcome = await importSwitchingDuringUpload(
            scratch,
            hostA: hostA,
            received: received,
            receivedSignal: signal,
            to: Self.uploader(origin: Self.hostB, token: "token-b", transport: Self.accepting())
        )
        let held = try #require(outcome, "no upload request ever reached host A")

        try #require(held.copyExistedWhileHeld, "premise: the copy exists while the upload is held")
        #expect(scratch.stagedEntries.isEmpty, "left behind: \(scratch.stagedEntries)")
    }
}

// MARK: - Test doubles

/// A one-shot gate: `wait()` suspends until `open()`, and returns at once after it.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resumed = waiters
        waiters = []
        for waiter in resumed { waiter.resume() }
    }
}

/// A host whose upload is held: it records the request, signals, waits for `release()`, then
/// answers from its script. Test-local, so the hold is visible here rather than in the kit.
private actor GatedUploadTransport: RelayTransport {
    enum Answer: Sendable {
        case accept(Data)
        case offline
    }

    private let answer: Answer
    private let onRequest: AsyncStream<Void>.Continuation
    private let gate = Gate()

    /// Every request this host was sent, in order.
    private(set) var recordedRequests: [RelayHTTPRequest] = []

    init(answer: Answer, onRequest: AsyncStream<Void>.Continuation) {
        self.answer = answer
        self.onRequest = onRequest
    }

    func send(_ request: RelayHTTPRequest) async throws -> RelayHTTPResponse {
        recordedRequests.append(request)
        onRequest.yield()
        await gate.wait()
        switch answer {
        case .accept(let body):
            return RelayHTTPResponse(status: 200, headers: [:], body: body)
        case .offline:
            throw RelayTransportError.offline("host A dropped the connection")
        }
    }

    func openSocket(_ request: RelayHTTPRequest) async throws -> any RelaySocket {
        throw RelayTransportError.other("GatedUploadTransport opens no sockets")
    }

    func release() async {
        await gate.open()
    }
}
