import Foundation

/// One selectable option on a question.
public struct QuestionOption: Sendable, Hashable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

/// One question in a batch.
///
/// Decoded from the `user-questions/request` waterfall's `request.questions`, whose shape the
/// installed `SessionListValue` projection establishes: `id`, `question`, optional `detail`
/// and `header`, optional `options`, optional `multiSelect`, and an optional `intent`.
public struct Question: Sendable, Hashable, Identifiable {
    public var id: String
    public var question: String
    public var detail: String?
    public var header: String?
    public var options: [QuestionOption]
    /// Absent means single-select: SPEC §8 validates "single/multiple-selection rule" against
    /// what the request advertised, and the request only advertises multi-select when it is
    /// multi-select.
    public var multiSelect: Bool

    public init(
        id: String,
        question: String,
        detail: String? = nil,
        header: String? = nil,
        options: [QuestionOption] = [],
        multiSelect: Bool = false
    ) {
        self.id = id
        self.question = question
        self.detail = detail
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// A batch of questions from one tool call.
public struct QuestionBatch: Sendable, Hashable {
    public var callId: String?
    public var questions: [Question]

    public init(callId: String? = nil, questions: [Question]) {
        self.callId = callId
        self.questions = questions
    }

    /// Decodes a waterfall's `request` payload.
    ///
    /// Tolerant: a question without an id or text is dropped rather than failing the batch,
    /// because a malformed entry must not cost the user the questions they can answer.
    public init?(request: JSONValue) {
        guard let questions = request["questions"]?.arrayValue else { return nil }
        self.callId = request["callId"]?.stringValue
        self.questions = questions.compactMap { raw in
            guard let id = raw["id"]?.stringValue,
                  let text = raw["question"]?.stringValue,
                  !id.isEmpty
            else { return nil }
            return Question(
                id: id,
                question: text,
                detail: raw["detail"]?.stringValue,
                header: raw["header"]?.stringValue,
                options: (raw["options"]?.arrayValue ?? []).compactMap { option in
                    guard let label = option["label"]?.stringValue else { return nil }
                    return QuestionOption(label: label, description: option["description"]?.stringValue)
                },
                multiSelect: raw["multiSelect"]?.boolValue ?? false
            )
        }
    }
}

/// One proposed answer.
public struct QuestionAnswer: Sendable, Hashable {
    public var id: String
    public var selected: [String]
    public var custom: String?

    public init(id: String, selected: [String] = [], custom: String? = nil) {
        self.id = id
        self.selected = selected
        self.custom = custom
    }

    /// The wire object, with `custom` omitted rather than sent empty.
    ///
    /// SPEC §8: "Omit blank custom input." An explicit `""` is a third thing the host did
    /// not advertise, so it is dropped here rather than sent and refused.
    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "selected": .array(selected.map { .string($0) }),
        ]
        if let custom, !custom.isEmpty { object["custom"] = .string(custom) }
        return .object(object)
    }
}

/// Why a proposed answer was refused before it was sent.
///
/// SPEC §8 lists six constraints and says they are validated "before submission". Refusing
/// locally matters: the host would refuse the same answer, and a round trip that fails tells
/// the user less than a sentence naming the question that is wrong.
public enum QuestionAnswerError: Error, Sendable, Hashable {
    /// A question in the batch has no answer.
    case missingAnswer(questionId: String)
    /// An answer names a question the batch does not contain.
    case unknownQuestion(questionId: String)
    /// A selection is not one of the labels the request advertised.
    case unknownOption(questionId: String, label: String)
    /// The same label twice.
    case duplicateSelection(questionId: String, label: String)
    /// More than one selection on a single-select question.
    case multipleSelectionsForSingleSelect(questionId: String)
    /// Custom input where the question permits none.
    case customNotPermitted(questionId: String)
    /// Free text and a selection together, which a single-select question cannot express.
    case customWithSelection(questionId: String)
}

/// Validates a batch of answers against the questions that asked for them.
public enum QuestionAnswerValidator {
    /// Checks one complete answer set.
    ///
    /// The rules, in the order they are checked, are SPEC §8's: exactly one entry per
    /// question; ids and selected labels must match the request; no duplicate selections; a
    /// single-select question cannot combine a non-empty custom answer with a selection; and
    /// an intentionally skipped item uses `selected: []`.
    ///
    /// - Throws: ``QuestionAnswerError`` naming the question at fault.
    public static func validate(_ answers: [QuestionAnswer], against batch: QuestionBatch) throws {
        let expected = Set(batch.questions.map(\.id))
        var seen: Set<String> = []

        for answer in answers {
            guard expected.contains(answer.id) else {
                throw QuestionAnswerError.unknownQuestion(questionId: answer.id)
            }
            guard seen.insert(answer.id).inserted else {
                // A second entry for one question would produce a body with two answers for
                // it, which is not "exactly one entry per question".
                throw QuestionAnswerError.unknownQuestion(questionId: answer.id)
            }
            guard let question = batch.questions.first(where: { $0.id == answer.id }) else {
                throw QuestionAnswerError.unknownQuestion(questionId: answer.id)
            }
            try validate(answer, for: question)
        }

        // Exactly one entry per question: a missing one is not a skip, it is an omission.
        // A deliberate skip is `selected: []`, which is an entry.
        for question in batch.questions where !seen.contains(question.id) {
            throw QuestionAnswerError.missingAnswer(questionId: question.id)
        }
    }

    private static func validate(_ answer: QuestionAnswer, for question: Question) throws {
        // Labels must be the ones the request advertised: SPEC §8 says to use the request's
        // permitted responses rather than inferring options from prose.
        let advertised = Set(question.options.map(\.label))
        var chosen: Set<String> = []
        for label in answer.selected {
            if !question.options.isEmpty, !advertised.contains(label) {
                throw QuestionAnswerError.unknownOption(questionId: question.id, label: label)
            }
            guard chosen.insert(label).inserted else {
                throw QuestionAnswerError.duplicateSelection(questionId: question.id, label: label)
            }
        }

        if !question.multiSelect, answer.selected.count > 1 {
            throw QuestionAnswerError.multipleSelectionsForSingleSelect(questionId: question.id)
        }

        if let custom = answer.custom, !custom.isEmpty {
            guard !question.options.isEmpty else {
                // Nowhere to put free text: the request advertised no custom input.
                throw QuestionAnswerError.customNotPermitted(questionId: question.id)
            }
            if !question.multiSelect, !answer.selected.isEmpty {
                // SPEC §8: "For single-select, nonempty custom input and a selected option
                // are mutually exclusive."
                throw QuestionAnswerError.customWithSelection(questionId: question.id)
            }
        }
    }

    /// The `{"answers":[…]}` body a live waterfall takes as its result value.
    public static func body(_ answers: [QuestionAnswer]) -> JSONValue {
        .object(["answers": .array(answers.map(\.jsonValue))])
    }
}
