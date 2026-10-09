import Foundation

// The compact form a reconnect baseline uses for an in-flight assistant attempt.
//
// `session/follow`'s `assistantStream.activeAttempt.stream` is not an array of live
// frames: the host folds consecutive same-block deltas into a run with a timing array.
// A client that appends the run without expanding it renders one fragment instead of a
// paragraph, and a client that expands it with the wrong timing rule places every
// fragment but the first at the wrong instant.
//
// The shapes and the loop below are read from `dsh-llm/lib/types/assistant-stream.js`.
// `validateRecord` is the host's own validating path at a durable boundary, and it
// requires *exactly* these keys, which is what makes the model here complete rather than
// merely sufficient:
//
//     text-chunks      type, time0, index, dt, texts
//     reasoning-chunks type, time0, index, dt, texts
//     tool-call-chunks type, time0, index, dt, id, args [, name]
//     chunk            type, time, chunk
//
// The accumulator that builds these keeps a `lastTime` while merging runs, and strips it
// when publishing the durable form, so no real record carries one.

/// One model-stream chunk, reconstructed from a compact record.
///
/// Only the three delta kinds are modelled. The host's `chunk` fallback carries every
/// other kind — `block-start`, `block-end`, `usage`, `finish` — and the expander must
/// pass those through untouched rather than drop them, so they land in ``other``.
public enum ModelStreamChunk: Sendable, Hashable {
    /// Visible text for one content block.
    case textDelta(index: Int, text: String)
    /// The model's reasoning for one content block, which is not part of the answer.
    case reasoningDelta(index: Int, text: String)
    /// A fragment of a tool call's arguments. `argumentsDelta` is a fragment and is
    /// deliberately not parsed: a partial argument string is usually not valid JSON.
    case toolCallDelta(index: Int, id: String, name: String?, argumentsDelta: String)
    /// A chunk kind this build does not model, kept whole.
    case other(type: String, value: JSONValue)

    /// The wire discriminator, or an empty string when the raw value carried none.
    public var typeName: String {
        switch self {
        case .textDelta: "text-delta"
        case .reasoningDelta: "reasoning-delta"
        case .toolCallDelta: "tool-call-delta"
        case .other(let type, _): type
        }
    }

    public var index: Int? {
        switch self {
        case .textDelta(let index, _), .reasoningDelta(let index, _), .toolCallDelta(let index, _, _, _):
            index
        case .other:
            nil
        }
    }
}

/// One expanded chunk and the time the host recorded for it.
public struct TimedModelStreamChunk: Sendable, Hashable {
    /// Epoch milliseconds, reconstructed from the run's `time0` and its gaps.
    public var time: Int64
    public var chunk: ModelStreamChunk

    public init(time: Int64, chunk: ModelStreamChunk) {
        self.time = time
        self.chunk = chunk
    }
}

/// One entry of a compact `activeAttempt.stream`.
public enum AssistantStreamRecord: Sendable, Hashable {
    /// A merged run of `text-delta` chunks for one content block.
    case textChunks(index: Int, time0: Int64, dt: [Int64], texts: [String])
    /// A merged run of `reasoning-delta` chunks for one content block.
    case reasoningChunks(index: Int, time0: Int64, dt: [Int64], texts: [String])
    /// A merged run of `tool-call-delta` chunks. `name` is present only when the run
    /// carried one, which is why it is optional rather than defaulted.
    case toolCallChunks(index: Int, time0: Int64, dt: [Int64], id: String, name: String?, args: [String])
    /// One raw chunk the host did not fold, kept verbatim.
    case chunk(time: Int64, chunk: JSONValue)
    /// A record this build cannot expand, retained whole.
    case unknown(type: String, value: JSONValue)

    /// The wire discriminator, verbatim.
    public var typeName: String {
        switch self {
        case .textChunks: "text-chunks"
        case .reasoningChunks: "reasoning-chunks"
        case .toolCallChunks: "tool-call-chunks"
        case .chunk: "chunk"
        case .unknown(let type, _): type
        }
    }
}

// MARK: - Decoding

extension AssistantStreamRecord {
    /// Decodes one compact record.
    ///
    /// Never fails, and never invents a shape. A record that is structurally inconsistent
    /// — a run whose gap array does not match its member count, an empty member list, an
    /// empty tool-call identity — becomes ``unknown(type:value:)`` rather than being
    /// expanded into something the host never sent. That is the same trade the host's own
    /// `validateRecord` makes, minus the throw: the value stays readable and one bad
    /// record cannot end the stream.
    public init(jsonValue: JSONValue) {
        guard let object = jsonValue.objectValue,
              let type = object["type"]?.stringValue
        else {
            self = .unknown(type: "", value: jsonValue)
            return
        }

        switch type {
        case "text-chunks", "reasoning-chunks":
            guard let time0 = object["time0"]?.intValue,
                  let index = object["index"]?.intValue.flatMap(Int.init(exactly:)),
                  index >= 0,
                  let texts = object["texts"]?.arrayValue?.compactMap(\.stringValue),
                  let rawTexts = object["texts"]?.arrayValue, texts.count == rawTexts.count,
                  !texts.isEmpty,
                  let dt = Self.gaps(object["dt"], memberCount: texts.count)
            else {
                self = .unknown(type: type, value: jsonValue)
                return
            }
            self = type == "text-chunks"
                ? .textChunks(index: index, time0: time0, dt: dt, texts: texts)
                : .reasoningChunks(index: index, time0: time0, dt: dt, texts: texts)

        case "tool-call-chunks":
            guard let time0 = object["time0"]?.intValue,
                  let index = object["index"]?.intValue.flatMap(Int.init(exactly:)),
                  index >= 0,
                  let id = object["id"]?.stringValue, !id.isEmpty,
                  let rawArgs = object["args"]?.arrayValue,
                  let args = rawArgs.compactMap(\.stringValue) as [String]?,
                  args.count == rawArgs.count,
                  !args.isEmpty,
                  let dt = Self.gaps(object["dt"], memberCount: args.count)
            else {
                self = .unknown(type: type, value: jsonValue)
                return
            }
            // Present-but-empty is as invalid as a non-string, and the host's accumulator
            // refuses to fold such a run at all — it emits a raw `chunk` instead.
            var name: String?
            if let candidate = object["name"] {
                guard let text = candidate.stringValue, !text.isEmpty else {
                    self = .unknown(type: type, value: jsonValue)
                    return
                }
                name = text
            }
            self = .toolCallChunks(index: index, time0: time0, dt: dt, id: id, name: name, args: args)

        case "chunk":
            guard let time = object["time"]?.intValue, let raw = object["chunk"], !raw.isNull else {
                self = .unknown(type: type, value: jsonValue)
                return
            }
            self = .chunk(time: time, chunk: raw)

        default:
            self = .unknown(type: type, value: jsonValue)
        }
    }

    /// Validates the gap array against the run it times.
    ///
    /// A run of `n` members has exactly `n - 1` gaps. Tolerating a short array by
    /// substituting zeros would silently place fragments at the wrong instant, so a
    /// mismatch is treated as an unreadable record instead.
    private static func gaps(_ value: JSONValue?, memberCount: Int) -> [Int64]? {
        guard let array = value?.arrayValue else { return memberCount == 1 ? [] : nil }
        guard array.count == memberCount - 1 else { return nil }
        var gaps: [Int64] = []
        gaps.reserveCapacity(array.count)
        for element in array {
            guard let gap = element.intValue else { return nil }
            gaps.append(gap)
        }
        return gaps
    }
}

// MARK: - Expansion

extension AssistantStreamRecord {
    /// Expands this record into the chunks it stands for.
    ///
    /// Exactly the host's `expandAssistantStream`: time accumulates from the run's start
    /// rather than being measured from the previous member, so `dt` is read once per
    /// member after the first.
    ///
    /// The additions wrap rather than trap. A corrupt run can carry gaps that overflow
    /// `Int64`, and SPEC §5's rule that an unknown shape must never crash the client
    /// outranks the accuracy of a timestamp that is only used for ordering.
    public func expand() -> [TimedModelStreamChunk] {
        switch self {
        case .textChunks(let index, let time0, let dt, let texts):
            return Self.expanded(time0: time0, dt: dt, members: texts) {
                .textDelta(index: index, text: $0)
            }

        case .reasoningChunks(let index, let time0, let dt, let texts):
            return Self.expanded(time0: time0, dt: dt, members: texts) {
                .reasoningDelta(index: index, text: $0)
            }

        case .toolCallChunks(let index, let time0, let dt, let id, let name, let args):
            return Self.expanded(time0: time0, dt: dt, members: args) {
                .toolCallDelta(index: index, id: id, name: name, argumentsDelta: $0)
            }

        case .chunk(let time, let chunk):
            return [TimedModelStreamChunk(time: time, chunk: Self.modelChunk(chunk))]

        case .unknown:
            // Nothing is invented for a record this build cannot read. The caller still
            // holds it whole and can show it as unsupported activity.
            return []
        }
    }

    private static func expanded(
        time0: Int64,
        dt: [Int64],
        members: [String],
        make: (String) -> ModelStreamChunk
    ) -> [TimedModelStreamChunk] {
        var chunks: [TimedModelStreamChunk] = []
        chunks.reserveCapacity(members.count)
        var time = time0
        for (offset, member) in members.enumerated() {
            if offset > 0 { time = time &+ dt[offset - 1] }
            chunks.append(TimedModelStreamChunk(time: time, chunk: make(member)))
        }
        return chunks
    }

    /// Classifies a raw `chunk` fallback into the modelled delta kinds where it can.
    ///
    /// The host folds text, reasoning and fully-identified tool-call deltas into runs, so
    /// a raw delta reaching here is unusual — it happens for a tool call whose `id` or
    /// `name` was empty, which cannot be folded. Recovering those keeps a partial tool call
    /// visible instead of filing it as unknown activity.
    private static func modelChunk(_ raw: JSONValue) -> ModelStreamChunk {
        guard let object = raw.objectValue else {
            return .other(type: "", value: raw)
        }
        let type = object["type"]?.stringValue ?? ""
        switch type {
        case "text-delta", "reasoning-delta":
            guard let index = object["index"]?.intValue.flatMap(Int.init(exactly:)),
                  let text = object["text"]?.stringValue
            else { return .other(type: type, value: raw) }
            return type == "text-delta"
                ? .textDelta(index: index, text: text)
                : .reasoningDelta(index: index, text: text)

        case "tool-call-delta":
            guard let index = object["index"]?.intValue.flatMap(Int.init(exactly:)),
                  let id = object["id"]?.stringValue,
                  let argumentsDelta = object["argumentsDelta"]?.stringValue
            else { return .other(type: type, value: raw) }
            var name: String?
            if let candidate = object["name"], let text = candidate.stringValue, !text.isEmpty {
                name = text
            }
            return .toolCallDelta(index: index, id: id, name: name, argumentsDelta: argumentsDelta)

        default:
            return .other(type: type, value: raw)
        }
    }
}

extension AssistantStreamRecord {
    /// Expands a whole `activeAttempt.stream`.
    ///
    /// Records that cannot be read contribute nothing to the chunks and are not silently
    /// dropped: they stay in the array the caller decoded, so a caller that wants to show
    /// unsupported activity still can.
    public static func expand(_ records: [AssistantStreamRecord]) -> [TimedModelStreamChunk] {
        records.flatMap { $0.expand() }
    }

    /// Decodes and expands a compact stream in one step.
    public static func expand(stream: [JSONValue]) -> [TimedModelStreamChunk] {
        expand(stream.map(AssistantStreamRecord.init(jsonValue:)))
    }
}
