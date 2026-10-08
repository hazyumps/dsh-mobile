import Foundation

/// A question the harness asked a session and is waiting on.
///
/// Modelled from a live capture rather than from the schema alone: the carrier is
/// a durable `tool/call` event whose `data` is
///
/// ```json
/// {"turn":1,"step":1,"callId":"call_…","name":"ask_user_question",
///  "arguments":"{\"questions\":[{\"id\":\"colour\",\"header\":\"Colour\",
///                \"question\":\"Which colour do you prefer?\",
///                \"options\":[{\"label\":\"Blue\"},{\"label\":\"Red\"}]}]}"}
/// ```
///
/// `arguments` is a **JSON string**, not an object, so it is parsed a second time.
/// That is the mistake this type exists to make once instead of everywhere.
public struct PendingQuestion: Sendable, Hashable, Identifiable {
    /// The question's own id, which the answer echoes back.
    public let id: String
    /// The tool call this question belongs to. Required by `userQuestions/answer`.
    public let callId: String
    public let header: String?
    public let question: String
    public let options: [Option]
    /// Whether more than one option may be selected.
    public let allowsMultiple: Bool

    public struct Option: Sendable, Hashable, Identifiable {
        public var id: String { label }
        public let label: String
        public let detail: String?
    }

    /// The tool name the harness uses to ask.
    public static let toolName = "ask_user_question"

    /// Questions carried by one `tool/call` event's `data`, or `nil` when the
    /// event is not a question.
    ///
    /// Tolerant on purpose: an unparseable or absent `arguments` yields no
    /// questions rather than an error, because a conversation that cannot render
    /// one tool call should still render the rest of itself.
    public static func questions(inToolCall data: JSONValue) -> [PendingQuestion]? {
        guard let object = data.objectValue,
              object["name"]?.stringValue == toolName,
              let callId = object["callId"]?.stringValue,
              let raw = object["arguments"]?.stringValue,
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)),
              let list = parsed.objectValue?["questions"]?.arrayValue
        else { return nil }

        return list.compactMap { entry in
            guard let item = entry.objectValue,
                  let id = item["id"]?.stringValue,
                  let text = item["question"]?.stringValue
            else { return nil }

            let options = (item["options"]?.arrayValue ?? []).compactMap { option -> Option? in
                guard let o = option.objectValue, let label = o["label"]?.stringValue else { return nil }
                return Option(label: label, detail: o["description"]?.stringValue)
            }

            return PendingQuestion(
                id: id,
                callId: callId,
                header: item["header"]?.stringValue,
                question: text,
                options: options,
                allowsMultiple: item["multi_select"]?.boolValue ?? false
            )
        }
    }
}
