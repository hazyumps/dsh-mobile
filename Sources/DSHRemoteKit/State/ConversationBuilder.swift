import Foundation

/// One line of a conversation, durable or still arriving.
public struct ConversationMessage: Sendable, Hashable, Identifiable {
    public enum Role: String, Sendable { case user, assistant }

    /// `seq:<n>` for a durable record, `attempt:<id>` while streaming.
    public let id: String
    public let role: Role
    public let text: String
    /// True while the harness is still producing this reply (SPEC §3.4).
    public let isProvisional: Bool
    /// Reasoning is kept apart from the answer (SPEC §3.4).
    public let reasoning: String?

    public init(id: String, role: Role, text: String, isProvisional: Bool, reasoning: String?) {
        self.id = id
        self.role = role
        self.text = text
        self.isProvisional = isProvisional
        self.reasoning = reasoning
    }
}

/// Folds mux frames into something a chat screen can render, applying the
/// recovery rules of SPEC §6.5 and nothing more.
///
/// Deliberately a value type with a dictionary of durable events and a small
/// provisional map. Ordering is derived on read from `seq`, so paging older
/// history in cannot reorder anything.
///
/// What it does *not* do: assemble assistant text from stream chunks. The only
/// chunk payload ever captured is a block boundary — `block-start` with an
/// index — and nothing proves where the text deltas live, so a provisional
/// message carries no text and the durable `assistant/message` supplies it.
/// Guessing that shape is how a decoder ends up rendering nothing useful.
public struct ConversationBuilder: Sendable {
    public private(set) var hasGap = false

    /// Durable events by `seq`. A dictionary, so a duplicate is a no-op.
    private var events: [Int64: DurableEventEnvelope] = [:]
    /// Open attempts: id, latest revision, chunks seen.
    private var open: [String: (revision: Int64, chunks: Int)] = [:]
    /// Attempts that ended, so late chunks for them are dropped.
    private var ended: Set<String> = []
    /// Attempts whose `committed` end named a durable `seq` that has not arrived
    /// yet: the preview is held until that record exists, so the reply never
    /// vanishes in the gap between the two.
    private var held: [String: Int64] = [:]
    private var highestSeq: Int64?

    public init() {}

    // MARK: - Ingest

    /// Apply one mux frame. Unknown frame kinds are ignored, not fatal.
    public mutating func apply(_ frame: MuxFrame) {
        if let snapshot = frame.value?.snapshot {
            apply(snapshot: snapshot)
        } else if let event = frame.value?.event {
            apply(event: event)
        } else if let stream = frame.value?.assistantStream {
            apply(stream: stream)
        }
    }

    /// The follow baseline. Records arrive in order and are durable.
    public mutating func apply(snapshot: MuxSnapshot) {
        for record in snapshot.records {
            guard let event = record.event else { continue }
            events[event.seq] = event
            highestSeq = max(highestSeq ?? event.seq, event.seq)
        }
    }

    /// A durable event. Duplicates are ignored; a jump forward is a gap.
    public mutating func apply(event: DurableEventEnvelope) {
        guard events[event.seq] == nil else { return }
        if let highestSeq, event.seq > highestSeq + 1 { hasGap = true }
        events[event.seq] = event
        highestSeq = max(highestSeq ?? event.seq, event.seq)
    }

    /// A live assistant-stream frame, keyed by attempt.
    public mutating func apply(stream frame: AssistantStreamFrame) {
        guard let attempt = frame.attemptId else { return }
        let revision = frame.revision ?? 0

        switch frame.type {
        case .start:
            guard !ended.contains(attempt) else { return }
            open[attempt] = (revision: revision, chunks: 0)

        case .chunk:
            // A chunk for a finished attempt, or one that goes backwards, is
            // stale: SPEC §6.5 says drop it rather than render it beside the
            // attempt that replaced it.
            guard !ended.contains(attempt), var current = open[attempt], revision >= current.revision else { return }
            current.revision = revision
            current.chunks += 1
            open[attempt] = current

        case .end:
            // Retire the provisional exactly once. Its durable record arrives as
            // its own event, and the two orders are not guaranteed: a committed
            // end that arrives first holds the preview until that record lands,
            // so the reply is never momentarily absent and never doubled.
            open[attempt] = nil
            ended.insert(attempt)
            if let outcome = frame.outcome, outcome.kind == .committed, let seq = outcome.seq {
                held[attempt] = seq
            }

        case .unknown:
            return
        }
    }

    /// Merge older history paged in through `session/page`. Anything already
    /// held is skipped, so a page cannot duplicate or reorder what is rendered.
    public mutating func merge(page: [DurableEventEnvelope]) {
        for event in page where events[event.seq] == nil {
            events[event.seq] = event
        }
    }

    // MARK: - Read

    public var messages: [ConversationMessage] {
        var result = events.values
            .sorted { $0.seq < $1.seq }
            .compactMap(Self.message(from:))

        for (attempt, state) in open.sorted(by: { $0.key < $1.key }) where state.chunks > 0 {
            result.append(
                ConversationMessage(
                    id: "attempt:\(attempt)",
                    role: .assistant,
                    text: "",
                    isProvisional: true,
                    reasoning: nil
                )
            )
        }
        for (attempt, awaited) in held.sorted(by: { $0.key < $1.key }) where events[awaited] == nil {
            result.append(
                ConversationMessage(
                    id: "attempt:\(attempt)",
                    role: .assistant,
                    text: "",
                    isProvisional: true,
                    reasoning: nil
                )
            )
        }
        return result
    }

    /// Durable events that carry no message of their own — tool calls, plan
    /// updates, permission changes. Kept, so the UI can show a generic card
    /// instead of silently dropping them (SPEC §3.4).
    public var unmodelledEvents: [DurableEventEnvelope] {
        events.values
            .sorted { $0.seq < $1.seq }
            .filter { Self.message(from: $0) == nil }
    }

    public var isEmpty: Bool { events.isEmpty && open.isEmpty }

    /// Whether at least one reply is still arriving.
    public var isStreaming: Bool { open.values.contains { $0.chunks > 0 } }

    // MARK: - Event projection

    private static func message(from event: DurableEventEnvelope) -> ConversationMessage? {
        switch event.type {
        case "user/message":
            let text = textParts(event.data["content"])
            guard !text.isEmpty else { return nil }
            return ConversationMessage(
                id: "seq:\(event.seq)", role: .user, text: text, isProvisional: false, reasoning: nil
            )

        case "assistant/message":
            let content = event.data["message"]?["content"]
            let answer = textParts(content, ofType: "text")
            let reasoning = textParts(content, ofType: "reasoning")
            guard !answer.isEmpty || !reasoning.isEmpty else { return nil }
            return ConversationMessage(
                id: "seq:\(event.seq)",
                role: .assistant,
                text: answer,
                isProvisional: false,
                reasoning: reasoning.isEmpty ? nil : reasoning
            )

        default:
            return nil
        }
    }

    /// Join the `text` of every part, optionally only parts of one `type`.
    private static func textParts(_ content: JSONValue?, ofType wanted: String? = nil) -> String {
        guard let parts = content?.arrayValue else { return "" }
        return parts
            .filter { wanted == nil || $0["type"]?.stringValue == wanted }
            .compactMap { $0["text"]?.stringValue }
            .joined()
    }
}
