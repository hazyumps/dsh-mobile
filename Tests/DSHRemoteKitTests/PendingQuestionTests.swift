import Foundation
import Testing

@testable import DSHRemoteKit

/// The input here is the captured event, copied verbatim from a live session
/// rather than invented — including the awkward part: `arguments` is a JSON
/// *string*, so the questions live one parse deeper than they look.
@Suite("Pending questions")
struct PendingQuestionTests {

    private static let capturedArguments = #"{"questions": [{"id": "colour", "header": "Colour", "question": "Which colour do you prefer?", "options": [{"label": "Blue"}, {"label": "Red"}]}]}"#

    private func capturedCall() -> JSONValue {
        .object([
            "callId": .string("call_00_ET_EBIuBY8wfsMAMoUnsQ0P2566"),
            "name": .string("ask_user_question"),
            "arguments": .string(Self.capturedArguments),
        ])
    }

    @Test("a captured ask_user_question call becomes one question")
    func parsesCapturedCall() throws {
        let questions = try #require(PendingQuestion.questions(inToolCall: capturedCall()))

        #expect(questions.count == 1)
        let question = try #require(questions.first)
        #expect(question.id == "colour")
        #expect(question.header == "Colour")
        #expect(question.question == "Which colour do you prefer?")
        #expect(question.options.map(\.label) == ["Blue", "Red"])
        #expect(question.allowsMultiple == false)
        // The answer call needs this, and it comes from the event, not the question.
        #expect(question.callId == "call_00_ET_EBIuBY8wfsMAMoUnsQ0P2566")
    }

    @Test("another tool's call is not a question")
    func ignoresOtherTools() {
        let bash = JSONValue.object([
            "callId": .string("call_x"),
            "name": .string("bash"),
            "arguments": .string(#"{"command":"ls"}"#),
        ])
        #expect(PendingQuestion.questions(inToolCall: bash) == nil)
    }

    @Test("a malformed question is skipped, not fatal")
    func tolerantOfGarbage() throws {
        // One good question, one missing its text: the good one still renders.
        let mixed = #"{"questions": [{"id": "a", "question": "Keep me"}, {"id": "b"}]}"#
        let data = JSONValue.object([
            "callId": .string("call_y"),
            "name": .string("ask_user_question"),
            "arguments": .string(mixed),
        ])
        let questions = try #require(PendingQuestion.questions(inToolCall: data))
        #expect(questions.map(\.id) == ["a"])
    }

    @Test("unparseable arguments yield nothing rather than throwing")
    func unparseableArguments() {
        let data = JSONValue.object([
            "callId": .string("call_z"),
            "name": .string("ask_user_question"),
            "arguments": .string("not json at all"),
        ])
        #expect(PendingQuestion.questions(inToolCall: data) == nil)
    }
}
