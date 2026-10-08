import Foundation
import Testing

@testable import DSHRemoteKit

/// The question path through ``ChatSession``: a `tool/call` event arriving on the
/// follow stream becomes a pending question, and answering it clears the card.
///
/// The frame is built from the captured event's shape — `arguments` as a JSON
/// string and all — because that indirection is the thing most likely to be
/// dropped by a later refactor.
@Suite("ChatSession questions")
struct ChatSessionQuestionTests {

    private static let streamId = "follow-session-1"

    private static let frame: JSONValue = .object([
        "type": .string("item"),
        "streamId": .string(streamId),
        "value": .object([
            "type": .string("event"),
            "event": .object([
                "type": .string("tool/call"),
                "seq": .int(21),
                "time": .int(1791430225693),
                "data": .object([
                    "turn": .int(1),
                    "step": .int(1),
                    "callId": .string("call_00_ET_EBIuBY8wfsMAMoUnsQ0P2566"),
                    "name": .string("ask_user_question"),
                    "arguments": .string(#"{"questions": [{"id": "colour", "header": "Colour", "question": "Which colour do you prefer?", "options": [{"label": "Blue"}, {"label": "Red"}]}]}"#),
                ]),
            ]),
        ]),
    ])

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

    @Test("a question arriving on the follow stream becomes pending")
    func questionBecomesPending() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()
        try await socket.push(json: Self.frame)

        let arrived = await eventually { await !chat.pendingQuestions.isEmpty }
        #expect(arrived, "the tool/call event never produced a pending question")

        let question = try #require(await chat.pendingQuestions.first)
        #expect(question.id == "colour")
        #expect(question.callId == "call_00_ET_EBIuBY8wfsMAMoUnsQ0P2566")
        #expect(question.options.map(\.label) == ["Blue", "Red"])
    }

    @Test("answering clears the card")
    func answeringClearsIt() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()
        try await socket.push(json: Self.frame)
        _ = await eventually { await !chat.pendingQuestions.isEmpty }

        await chat.markAnswered(questionId: "colour")
        #expect(await chat.pendingQuestions.isEmpty)
    }

    @Test("the same question arriving twice is one card")
    func duplicateEventIsIdempotent() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()
        try await socket.push(json: Self.frame)
        _ = await eventually { await !chat.pendingQuestions.isEmpty }
        // A reconnect replays the snapshot, which carries the same tool call.
        try await socket.push(json: Self.frame)

        try? await Task.sleep(for: .milliseconds(200))
        #expect(await chat.pendingQuestions.count == 1)
    }
}
