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

    private static let streamId = "follow-session-1"

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
        frame["streamId"] = .string(Self.streamId)
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
        try? await Task.sleep(for: .milliseconds(100))
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
}
