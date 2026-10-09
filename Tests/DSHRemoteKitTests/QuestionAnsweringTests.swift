import Foundation
import Testing
@testable import DSHRemoteKit

// SPEC §8 lists six constraints on a question answer and says they are validated before
// submission. Each test below is one constraint, because getting any of them wrong produces
// a body the host refuses — and the user then learns less than the sentence this validation
// can give them locally.

@Suite("Question answering")
struct QuestionAnsweringTests {
    private func batch(
        multiSelect: Bool = false,
        options: [String] = ["Option A", "Option B"],
        custom: Bool = true
    ) -> QuestionBatch {
        QuestionBatch(callId: "call-1", questions: [
            Question(
                id: "q1",
                question: "Which one?",
                detail: "Pick carefully",
                options: custom ? options.map { QuestionOption(label: $0) } : [],
                multiSelect: multiSelect
            )
        ])
    }

    // MARK: - Decoding

    @Test("a batch decodes from the waterfall's request, tolerating a malformed entry")
    func decodesTolerantly() throws {
        let request = JSONValue.object([
            "callId": .string("call-1"),
            "questions": .array([
                .object([
                    "id": .string("q1"),
                    "question": .string("Which one?"),
                    "header": .string("Mode"),
                    "options": .array([
                        .object(["label": .string("A"), "description": .string("first")]),
                        .object(["label": .string("B")]),
                    ]),
                ]),
                // No id: dropped rather than costing the user the question above.
                .object(["question": .string("orphan")]),
                // No text: likewise.
                .object(["id": .string("q3")]),
            ]),
        ])
        let batch = try #require(QuestionBatch(request: request))
        #expect(batch.callId == "call-1")
        #expect(batch.questions.map(\.id) == ["q1"])
        #expect(batch.questions[0].options.map(\.label) == ["A", "B"])
        #expect(batch.questions[0].options[0].description == "first")
        // Absent multiSelect means single-select, because the request only advertises it
        // when it is multi-select.
        #expect(batch.questions[0].multiSelect == false)
    }

    @Test("a request with no questions decodes to nothing rather than an empty batch")
    func noQuestionsIsNotABatch() {
        #expect(QuestionBatch(request: .object(["callId": .string("c")])) == nil)
    }

    // MARK: - The six constraints

    @Test("a complete single-select answer passes")
    func validSingleSelect() throws {
        try QuestionAnswerValidator.validate(
            [QuestionAnswer(id: "q1", selected: ["Option A"])],
            against: batch()
        )
    }

    @Test("a deliberate skip is an empty selection, and a missing entry is not a skip")
    func missingVersusSkipped() throws {
        // Skipping is expressed, not omitted: SPEC §8 gives the skipped item an empty
        // selection, so an absent entry is an omission the host would refuse.
        try QuestionAnswerValidator.validate(
            [QuestionAnswer(id: "q1", selected: [])],
            against: batch()
        )

        #expect(throws: QuestionAnswerError.missingAnswer(questionId: "q1")) {
            try QuestionAnswerValidator.validate([], against: batch())
        }
    }

    @Test("an answer for a question the batch never asked is refused")
    func unknownQuestion() {
        #expect(throws: QuestionAnswerError.unknownQuestion(questionId: "q9")) {
            try QuestionAnswerValidator.validate(
                [
                    QuestionAnswer(id: "q1", selected: ["Option A"]),
                    QuestionAnswer(id: "q9", selected: []),
                ],
                against: batch()
            )
        }
    }

    @Test("two entries for one question are refused")
    func twoEntriesForOneQuestion() {
        #expect(throws: QuestionAnswerError.unknownQuestion(questionId: "q1")) {
            try QuestionAnswerValidator.validate(
                [
                    QuestionAnswer(id: "q1", selected: ["Option A"]),
                    QuestionAnswer(id: "q1", selected: ["Option B"]),
                ],
                against: batch()
            )
        }
    }

    @Test("a label the request never advertised is refused")
    func unknownOption() {
        // SPEC §8: use the request's permitted responses rather than inferring options from
        // prose.
        #expect(throws: QuestionAnswerError.unknownOption(questionId: "q1", label: "Option C")) {
            try QuestionAnswerValidator.validate(
                [QuestionAnswer(id: "q1", selected: ["Option C"])],
                against: batch()
            )
        }
    }

    @Test("the same label twice is refused")
    func duplicateSelection() {
        #expect(throws: QuestionAnswerError.duplicateSelection(questionId: "q1", label: "Option A")) {
            try QuestionAnswerValidator.validate(
                [QuestionAnswer(id: "q1", selected: ["Option A", "Option A"])],
                against: batch(multiSelect: true)
            )
        }
    }

    @Test("two selections on a single-select question are refused")
    func multipleSelectionsSingleSelect() {
        #expect(throws: QuestionAnswerError.multipleSelectionsForSingleSelect(questionId: "q1")) {
            try QuestionAnswerValidator.validate(
                [QuestionAnswer(id: "q1", selected: ["Option A", "Option B"])],
                against: batch(multiSelect: false)
            )
        }
        // The same answer is fine once the question says it is multi-select.
        try? QuestionAnswerValidator.validate(
            [QuestionAnswer(id: "q1", selected: ["Option A", "Option B"])],
            against: batch(multiSelect: true)
        )
    }

    @Test("free text and a selection cannot be combined on a single-select question")
    func customWithSelection() {
        // SPEC §8 states this one outright: "For single-select, nonempty custom input and a
        // selected option are mutually exclusive."
        #expect(throws: QuestionAnswerError.customWithSelection(questionId: "q1")) {
            try QuestionAnswerValidator.validate(
                [QuestionAnswer(id: "q1", selected: ["Option A"], custom: "something else")],
                against: batch(multiSelect: false)
            )
        }
    }

    @Test("custom input with no options to choose from is refused")
    func customNotPermitted() {
        #expect(throws: QuestionAnswerError.customNotPermitted(questionId: "q1")) {
            try QuestionAnswerValidator.validate(
                [QuestionAnswer(id: "q1", custom: "free text")],
                against: batch(custom: false)
            )
        }
    }

    @Test("multi-select allows a selection and free text together")
    func multiSelectAllowsBoth() throws {
        try QuestionAnswerValidator.validate(
            [QuestionAnswer(id: "q1", selected: ["Option A"], custom: "and more")],
            against: batch(multiSelect: true)
        )
    }

    // MARK: - The body

    @Test("the body carries answers, and omits blank custom input")
    func bodyShape() throws {
        let body = QuestionAnswerValidator.body([
            QuestionAnswer(id: "q1", selected: ["Option A"]),
            // SPEC §8: "Omit blank custom input." An explicit empty string is a third thing
            // the host did not advertise.
            QuestionAnswer(id: "q2", selected: [], custom: ""),
        ])

        let answers = try #require(body["answers"]?.arrayValue)
        #expect(answers.count == 2)
        #expect(answers[0]["id"]?.stringValue == "q1")
        #expect(answers[0]["selected"]?.arrayValue?.first?.stringValue == "Option A")
        #expect(answers[0]["custom"] == nil)
        #expect(answers[1]["id"]?.stringValue == "q2")
        #expect(answers[1]["selected"]?.arrayValue?.isEmpty == true)
        #expect(answers[1]["custom"] == nil)
    }

    @Test("a non-blank custom answer is carried")
    func bodyCarriesCustom() throws {
        let body = QuestionAnswerValidator.body([
            QuestionAnswer(id: "q1", selected: [], custom: "a typed answer"),
        ])
        #expect(body["answers"]?.arrayValue?.first?["custom"]?.stringValue == "a typed answer")
    }
}
