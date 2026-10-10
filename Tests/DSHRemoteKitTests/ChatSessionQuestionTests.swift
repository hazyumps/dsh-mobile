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

    private func pushQuestion(to socket: StubRelaySocket) async throws {
        var frame = try #require(Self.frame.objectValue)
        frame["streamId"] = .string(try await followStreamID(on: socket))
        try await socket.push(json: .object(frame))
    }

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
        try await pushQuestion(to: socket)

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
        try await pushQuestion(to: socket)
        _ = await eventually { await !chat.pendingQuestions.isEmpty }

        await chat.markAnswered(questionId: "colour")
        #expect(await chat.pendingQuestions.isEmpty)
    }

    @Test("the same question arriving twice is one card")
    func duplicateEventIsIdempotent() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()
        try await pushQuestion(to: socket)
        _ = await eventually { await !chat.pendingQuestions.isEmpty }
        // A reconnect replays the snapshot, which carries the same tool call.
        try await pushQuestion(to: socket)

        try? await Task.sleep(for: .milliseconds(200))
        #expect(await chat.pendingQuestions.count == 1)
    }

    /// The host's own record that the question is over.
    ///
    /// Captured from `~/.dsh/sessions/--Users-patrick-.dsh-profiles-desktop--/
    /// session-3f46f792-…/session.v4.jsonl.zstd` after cancelling a parked question, 2026-10-09.
    /// The shapes are the point, and the first version of this test invented a `callId` on the
    /// result that the host never sends — so it passed while the app kept the card:
    ///
    ///   tool/call   → {"arguments", "callId", "name", "step", "turn"}
    ///   tool/result → {"error", "message", "step", "turn"}          (no callId)
    ///   turn/end    → {"turn": 1, "reason": {"kind": "aborted", …}}
    private func pushEvent(
        _ type: String,
        data: JSONValue,
        seq: Int64,
        to socket: StubRelaySocket
    ) async throws {
        var frame = try #require(Self.frame.objectValue)
        frame["streamId"] = .string(try await followStreamID(on: socket))
        var value = try #require(frame["value"]?.objectValue)
        value["event"] = .object([
            "type": .string(type),
            "seq": .int(seq),
            "time": .int(1791430225693),
            "data": data,
        ])
        frame["value"] = .object(value)
        try await socket.push(json: .object(frame))
    }

    @Test("a tool result for the asking step clears the question")
    func resultClearsTheQuestion() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()
        try await pushQuestion(to: socket)
        #expect(await eventually { await !chat.pendingQuestions.isEmpty })

        try await pushEvent(
            "tool/result",
            data: .object([
                "turn": .int(1), "step": .int(1),
                "error": .bool(true), "message": .string("stopped"),
            ]),
            seq: 22,
            to: socket
        )

        #expect(await eventually { await chat.pendingQuestions.isEmpty },
                "the question outlived the host's own result for it")
    }

    @Test("a turn that ends clears the question the turn was parked on")
    func turnEndClearsTheQuestion() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()
        try await pushQuestion(to: socket)
        #expect(await eventually { await !chat.pendingQuestions.isEmpty })

        try await pushEvent(
            "turn/end",
            data: .object([
                "turn": .int(1),
                "reason": .object([ "kind": .string("aborted"),
                                    "reason": .object(["kind": .string("user")]) ]),
            ]),
            seq: 24,
            to: socket
        )

        #expect(await eventually { await chat.pendingQuestions.isEmpty },
                "an aborted turn left its question on screen as if it were still open")
    }

    @Test("a result from another step leaves the question alone")
    func anotherStepsResultDoesNotClear() async throws {
        let (chat, socket) = makeSession()
        try await chat.start()
        try await pushQuestion(to: socket)
        #expect(await eventually { await !chat.pendingQuestions.isEmpty })

        // A different step in the same turn: the question is still open.
        try await pushEvent(
            "tool/result",
            data: .object(["turn": .int(1), "step": .int(9)]),
            seq: 22,
            to: socket
        )

        try? await Task.sleep(for: .milliseconds(200))
        #expect(await chat.pendingQuestions.count == 1,
                "a result from an unrelated step cleared the question")
    }
}
