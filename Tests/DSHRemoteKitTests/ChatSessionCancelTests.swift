import Foundation
import Testing

@testable import DSHRemoteKit

/// Stopping a turn, which is the only way out of a question nobody wants to answer.
///
/// `userQuestions` has `answer` and `attachWait` and nothing else — there is no dismiss, no
/// reject, no decline. A question the host is parked on is released by stopping the turn it
/// belongs to, so this is the path that makes a pending question escapable rather than a wall.
@Suite("ChatSession cancel")
struct ChatSessionCancelTests {

    private static let frame: JSONValue = .object([
        "type": .string("item"),
        "streamId": .string("follow-session-1"),
        "value": .object([
            "type": .string("event"),
            "event": .object([
                "type": .string("tool/call"),
                "seq": .int(21),
                "time": .int(1791430225693),
                "data": .object([
                    "turn": .int(1),
                    "step": .int(1),
                    "callId": .string("call_cancel"),
                    "name": .string("ask_user_question"),
                    "arguments": .string(#"{"questions": [{"id": "colour", "header": "Colour", "question": "Which colour do you prefer?", "options": [{"label": "Blue"}]}]}"#),
                ]),
            ]),
        ]),
    ])

    /// Records what the session asked the transport to do, and what it should answer.
    private actor Recorder {
        var cancels = 0
        var failure: (any Error)?
        func record() { cancels += 1 }
        func setFailure(_ error: any Error) { failure = error }
        func count() -> Int { cancels }
    }

    private func makeSession(
        recorder: Recorder
    ) -> (chat: ChatSession, socket: StubRelaySocket) {
        let socket = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [socket])
        let client = MuxClient(
            baseURL: URL(string: "https://relay.test")!,
            authorization: .bearer("test-token"),
            transport: transport
        )
        let chat = ChatSession(
            client: client,
            sessionId: "session-1",
            cancelRun: {
                await recorder.record()
                if let failure = await recorder.failure { throw failure }
            }
        )
        return (chat, socket)
    }

    private func pushQuestion(to socket: StubRelaySocket) async throws {
        var frame = try #require(Self.frame.objectValue)
        frame["streamId"] = .string(try await followStreamID(on: socket))
        try await socket.push(json: .object(frame))
    }

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

    @Test("cancelling stops the turn and clears the question it was waiting on")
    func cancelClearsTheQuestion() async throws {
        let recorder = Recorder()
        let (chat, socket) = makeSession(recorder: recorder)
        try await chat.start()
        try await pushQuestion(to: socket)
        #expect(await eventually { await !chat.pendingQuestions.isEmpty })

        let failure = await chat.cancel()

        #expect(failure == nil, "a successful cancel reported a failure: \(failure ?? "")")
        #expect(await recorder.count() == 1, "the turn was never actually stopped")
        #expect(await chat.pendingQuestions.isEmpty, "the question outlived the turn that asked it")
    }

    @Test("a failed cancel keeps the question")
    func failedCancelKeepsTheQuestion() async throws {
        let recorder = Recorder()
        await recorder.setFailure(RelayTransportError.other("relay refused"))
        let (chat, socket) = makeSession(recorder: recorder)
        try await chat.start()
        try await pushQuestion(to: socket)
        #expect(await eventually { await !chat.pendingQuestions.isEmpty })

        let failure = await chat.cancel()

        #expect(failure != nil, "a refused cancel reported success")
        // The turn is still running, so the question is still open — and the card has to say so
        // rather than vanish and leave the agent waiting on an answer nothing will send.
        #expect(await chat.pendingQuestions.count == 1)
    }

    @Test("a session with no way to cancel says so instead of pretending")
    func missingCancelPathIsReported() async throws {
        let socket = StubRelaySocket()
        let client = MuxClient(
            baseURL: URL(string: "https://relay.test")!,
            authorization: .bearer("test-token"),
            transport: StubRelayTransport(sockets: [socket])
        )
        let chat = ChatSession(client: client, sessionId: "session-1")

        #expect(await chat.cancel() != nil)
    }

    @Test("clearing the question is published to a subscriber")
    func clearingPublishes() async throws {
        let recorder = Recorder()
        let (chat, socket) = makeSession(recorder: recorder)
        try await chat.start()
        try await pushQuestion(to: socket)
        #expect(await eventually { await !chat.pendingQuestions.isEmpty })

        // Subscribe *after* the question arrived, which is the case that matters: a screen that
        // was already watching has to be told the card is gone, not left rendering it.
        let stream = await chat.snapshots()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        _ = await chat.cancel()

        let after = await iterator.next()
        #expect(after != nil, "the session published nothing when the question cleared")
        #expect(after?.pendingQuestions.isEmpty == true,
                "the subscriber was never told the question cleared")
    }
}
