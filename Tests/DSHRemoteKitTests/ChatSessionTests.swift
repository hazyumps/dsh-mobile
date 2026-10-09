import Foundation
import Testing

@testable import DSHRemoteKit

/// `ChatSession` is the logic half of the chat screen: it follows one session and
/// folds frames into messages. These tests drive it through the stub socket.
///
/// Two things about the fixtures shape these tests, and both cost time to learn:
/// the captured stream id is redacted, so it has to be rewritten to the id this
/// session opened (the mux client drops frames for unregistered ids, by design);
/// and the captured snapshot carries `permission/preset` and `sandbox/mode`
/// records, which produce no messages — a message has to come from a
/// message-bearing event such as `event/user/message`.
@Suite("ChatSession")
struct ChatSessionTests {

    private func makeSession() -> (chat: ChatSession, socket: StubRelaySocket) {
        let socket = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [socket])
        let client = MuxClient(
            baseURL: URL(string: "https://relay.test")!,
            authorization: .bearer("test-token"),
            transport: transport
        )
        return (ChatSession(client: client, sessionId: "session-1"), socket)
    }

    /// Pushes a captured frame as the wire would carry it, addressed to the
    /// stream this session opened. `StubRelaySocket` is an actor.
    private func push(_ name: String, to socket: StubRelaySocket) async throws {
        var frame = try muxFrameObject(name)
        frame["streamId"] = .string(try await followStreamID(on: socket))
        try await socket.push(json: .object(frame))
    }

    /// Frames are folded on the pump's own task, which nothing here can await, so
    /// conditions are polled rather than assumed.
    private func eventually(
        _ condition: @Sendable () async -> Bool,
        attempts: Int = 200
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test("a followed user message becomes a renderable message")
    func foldsUserMessage() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()
        try await push("event/user/message", to: socket)

        let arrived = await eventually { await !chat.messages.isEmpty }
        #expect(arrived, "the user/message frame never reached the conversation")
    }

    @Test("the snapshot baseline is accepted without inventing messages")
    func snapshotBaselineProducesNoMessages() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()
        try await push("snapshot", to: socket)

        // The captured snapshot's two records are permission and sandbox state,
        // so the conversation stays empty. Asserting this pins what the fixture
        // actually demonstrates rather than what its name suggests.
        #expect(await eventually { await chat.hasSnapshot })
        #expect(await chat.messages.isEmpty)

        // And a message still arrives afterwards, so the snapshot did not wedge it.
        try await push("event/user/message", to: socket)
        let arrived = await eventually { await !chat.messages.isEmpty }
        #expect(arrived)
    }

    @Test("starting twice does not open a second stream")
    func startIsIdempotent() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()
        try await chat.start()

        try await push("event/user/message", to: socket)
        let arrived = await eventually { await !chat.messages.isEmpty }
        #expect(arrived)
    }

    @Test("stopping releases the stream")
    func stopClearsStreaming() async throws {
        let (chat, _) = makeSession()
        try await chat.start()
        await chat.stop()

        #expect(await chat.isStreaming == false)
    }

    @Test("a dead socket leaves what was already read intact")
    func socketFailureIsSurvivable() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()
        try await push("event/user/message", to: socket)

        let arrived = await eventually { await !chat.messages.isEmpty }
        #expect(arrived)

        // The socket dies. The pump ends, but the conversation already folded must
        // survive: the connection's status owns that failure, not this type.
        await socket.fail()
        #expect(await !chat.messages.isEmpty)
    }

    @Test("reopening creates a fresh follow and ignores frames addressed to the old one")
    func freshSubscriptionIgnoresLateFrames() async throws {
        let socket = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [socket])
        let client = MuxClient(
            baseURL: URL(string: "https://relay.test")!,
            authorization: .bearer("test-token"), transport: transport
        )
        let old = ChatSession(client: client, sessionId: "session-1")
        try await old.start()
        let oldID = try await followStreamID(on: socket)
        await old.stop()
        let fresh = ChatSession(client: client, sessionId: "session-1")
        try await fresh.start()
        #expect(try await followStreamID(on: socket) != oldID)
        var late = try muxFrameObject("event/user/message")
        late["streamId"] = .string(oldID)
        try await socket.push(json: .object(late))
        try await push("snapshot", to: socket)
        #expect(await eventually { await fresh.hasSnapshot })
        #expect(await fresh.messages.isEmpty)
        try await push("event/user/message", to: socket)
        #expect(await eventually { await fresh.messages.count == 1 })
        await fresh.stop()
        await client.close()
    }

    @Test("a rejected follow reports an error before any snapshot")
    func rejectedFollowIsVisible() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()
        try await socket.push(json: .object([
            "type": .string("error"), "streamId": .string(try await followStreamID(on: socket)),
            "error": .object(["message": .string("session unavailable")]),
        ]))
        #expect(await eventually { await chat.followError != nil })
        #expect(await chat.followError == "session unavailable")
        #expect(await !chat.hasSnapshot)
        await chat.stop()
    }

    // MARK: - Snapshots

    /// A follow baseline with durable message records, written here rather than loaded
    /// from `Fixtures/`: the captured snapshot carries `hasMore: false` and no message
    /// records at all, so it can exercise neither the rendered window nor paging.
    ///
    /// It is synthetic and says so — the shape is the capture's, the contents are not.
    private func syntheticSnapshot(
        cursor: Int64,
        hasMore: Bool,
        messages: [(seq: Int64, text: String)]
    ) -> JSONValue {
        // Assembled in explicitly typed steps: one nested literal of this size does not
        // type-check in reasonable time.
        let records: [JSONValue] = messages.map { message in
            let content: JSONValue = .array([
                .object(["type": .string("text"), "text": .string(message.text)])
            ])
            let event: JSONValue = .object([
                "type": .string("user/message"),
                "seq": .int(message.seq),
                "time": .int(1),
                "data": .object([
                    "content": content,
                    // A human message carries this discriminator; without it the fold
                    // treats the event as host-injected content, which is correct.
                    "source": .object(["kind": .string("user"), "rpcId": .string("test")]),
                ]),
            ])
            return .object(["type": .string("event"), "event": event])
        }
        let header: JSONValue = .object(["version": .int(4)])
        return .object([
            "type": .string("snapshot"),
            "header": header,
            "cursor": .int(cursor),
            "hasMore": .bool(hasMore),
            "records": .array(records),
        ])
    }

    private func push(_ value: JSONValue, to socket: StubRelaySocket) async throws {
        try await socket.push(json: .object([
            "type": .string("item"),
            "streamId": .string(try await followStreamID(on: socket)),
            "value": value,
        ]))
    }

    private func makeClientAndSocket() -> (MuxClient, StubRelaySocket) {
        let socket = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [socket])
        let client = MuxClient(
            baseURL: URL(string: "https://relay.test")!,
            authorization: .bearer("test-token"),
            transport: transport
        )
        return (client, socket)
    }

    /// Records what the page loader was asked for, and answers from a script.
    private actor PageRecorder {
        private(set) var requests: [ConversationPageRequest] = []
        private var answers: [ConversationPage]

        init(answers: [ConversationPage]) {
            self.answers = answers
        }

        func load(_ request: ConversationPageRequest) -> ConversationPage {
            requests.append(request)
            // A loader whose script runs out keeps serving the last answer: a test that
            // expects another call wants another answer, not a crash.
            if answers.count > 1 { return answers.removeFirst() }
            return answers.first ?? ConversationPage(events: [], hasMore: false)
        }
    }

    @Test("the follow baseline is bounded, so the snapshot can be received at all")
    func followRequestsABoundedBaseline() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()

        // The open frame on the wire, not an inference: an unbounded follow asks the host
        // for the whole transcript, and a real session's baseline then exceeds what
        // URLSessionWebSocketTask will accept, killing the socket with EMSGSIZE.
        let opened = await socket.sentTexts
            .compactMap { text -> JSONValue? in
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                      value["endpoint"]?.stringValue == "session/follow"
                else { return nil }
                return value
            }
            .first
        let request = try #require(opened?["payload"]?["args"]?["request"])
        #expect(request["maxMessages"]?.intValue == Int64(ChatSession.pageMessages))
        #expect(request["assistantStream"]?.boolValue == true)
        #expect(request["address"]?["sessionId"]?.stringValue == "session-1")
        await chat.stop()
    }

    @Test("a snapshot stream starts with the current state, not with nothing")
    func snapshotsStartFromTheCurrentState() async throws {
        let (chat, socket) = makeSession()
        var iterator = await chat.snapshots().makeAsyncIterator()

        let current = await iterator.next()
        #expect(current?.hasSnapshot == false)
        #expect(current?.messages.isEmpty == true)

        try await chat.start()
        try await push("event/user/message", to: socket)
        #expect(await eventually { await !chat.messages.isEmpty })

        // The fold provably happened, so a publish is buffered, and newest-only
        // buffering means this returns rather than waiting for a later frame.
        let published = await iterator.next()
        #expect(published?.messages.count == 1)
        // No baseline was pushed, so the window is still waiting for one — the
        // distinction the screen needs in order to show loading rather than an empty
        // conversation.
        #expect(published?.hasSnapshot == false)
        await chat.stop()
    }

    @Test("a host that says there is no older history is not asked for a page")
    func noPageWhenTheHostSaysThereIsNone() async throws {
        let (client, socket) = makeClientAndSocket()
        let recorder = PageRecorder(answers: [ConversationPage(events: [], hasMore: false)])
        let chat = ChatSession(
            client: client,
            sessionId: "session-1",
            loadPage: { await recorder.load($0) }
        )
        try await chat.start()
        try await push(syntheticSnapshot(cursor: 31, hasMore: false, messages: [(10, "hello")]), to: socket)
        #expect(await eventually { await chat.hasSnapshot })
        #expect(await chat.snapshot().canLoadOlder == false)

        #expect(await chat.loadOlder() == false)
        #expect(await recorder.requests.isEmpty)
        await chat.stop()
    }

    @Test("an older page is asked for with the window's cursor and merges in front")
    func loadOlderMergesThePage() async throws {
        let (client, socket) = makeClientAndSocket()
        let older = DurableEventEnvelope(
            type: "user/message",
            seq: 4,
            time: 1,
            data: .object([
                "content": .array([.object(["type": .string("text"), "text": .string("older")])]),
                "source": .object(["kind": .string("user")]),
            ]),
            surfaceOp: nil
        )
        let recorder = PageRecorder(answers: [ConversationPage(events: [older], hasMore: false)])
        let chat = ChatSession(
            client: client,
            sessionId: "session-1",
            loadPage: { await recorder.load($0) }
        )
        try await chat.start()
        try await push(syntheticSnapshot(cursor: 31, hasMore: true, messages: [(10, "hello")]), to: socket)
        #expect(await eventually { await chat.hasSnapshot })
        #expect(await chat.snapshot().canLoadOlder)

        #expect(await chat.loadOlder())

        // SPEC §7: `throughSeq` is the opening snapshot's cursor, and `beforeSeq` is
        // exclusive — the oldest sequence already held.
        let requests = await recorder.requests
        #expect(requests.count == 1)
        #expect(requests.first?.sessionId == "session-1")
        #expect(requests.first?.throughSeq == 31)
        #expect(requests.first?.beforeSeq == 10)
        #expect(requests.first?.maxMessages == ChatSession.pageMessages)

        let snapshot = await chat.snapshot()
        #expect(snapshot.messages.map(\.text) == ["older", "hello"])
        // The page's own `hasMore` is the authority from then on.
        #expect(snapshot.canLoadOlder == false)
        #expect(snapshot.isLoadingOlder == false)
        #expect(snapshot.pageError == nil)
        await chat.stop()
    }

    @Test("a second older page is refused while the first is in flight")
    func concurrentOlderLoadsAreRefused() async throws {
        let (client, socket) = makeClientAndSocket()
        let gate = AsyncGate()
        let recorder = PageRecorder(answers: [ConversationPage(events: [], hasMore: true)])
        let chat = ChatSession(
            client: client,
            sessionId: "session-1",
            loadPage: { request in
                await gate.wait()
                return await recorder.load(request)
            }
        )
        try await chat.start()
        try await push(syntheticSnapshot(cursor: 31, hasMore: true, messages: [(10, "hello")]), to: socket)
        #expect(await eventually { await chat.hasSnapshot })

        async let first = chat.loadOlder()
        // Let the first call reach the loader before the second is attempted, so this
        // tests the guard rather than the scheduler.
        try await Task.sleep(for: .milliseconds(50))
        async let second = chat.loadOlder()
        await gate.open()
        _ = await (first, second)

        #expect(await recorder.requests.count == 1)
        await chat.stop()
    }
}

/// A one-shot gate, so a test can hold a page load open and then release it.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
