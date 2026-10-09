import Foundation

/// The bridge between the two spellings of the same delta vocabulary (SPEC §7).
///
/// A live `assistant-stream` frame's `chunk` decodes to ``AssistantStreamChunkBody``,
/// while a reconnect baseline's compact `stream` prefix expands through
/// ``AssistantStreamRecord`` into ``ModelStreamChunk``. One accumulator cannot be
/// fed by two types, so the live body is converted here — at the edge — and the
/// model chunk stays the only thing the accumulator ever sees.
///
/// The conversion runs this direction on purpose. Going the other way, a model
/// chunk back into a chunk body, would have meant filling in fields the compact
/// form does not carry (a live frame's `time`, its outer `index`) and writing a
/// second append loop over the body type. Two loops over one vocabulary is the
/// seam an earlier attempt died on; one loop over one type is the fix.
extension AssistantStreamChunkBody {
    /// This live chunk as the type the reconnect expander already produces.
    ///
    /// `nil` means "nothing to append", not "malformed": a `block-start`,
    /// `block-end`, or unknown kind carries no answer text, and a delta that
    /// omits its inner `index` cannot be attributed to a content block at all.
    /// Inventing block `0` for that case would drop a reasoning fragment into the
    /// answer, which SPEC §7 forbids; the frame still counts as a chunk, so the
    /// attempt keeps reporting as streaming either way.
    ///
    /// `index` is the *inner* content-block index, never the outer frame's
    /// (`SPEC §7`: "The outer frame index is not the inner content-block index").
    public func modelChunk() -> ModelStreamChunk? {
        guard let blockIndex = index.flatMap({ Int(exactly: $0) }), blockIndex >= 0 else {
            return nil
        }

        switch type {
        case .textDelta:
            guard let text else { return nil }
            return .textDelta(index: blockIndex, text: text)

        case .reasoningDelta:
            guard let text else { return nil }
            return .reasoningDelta(index: blockIndex, text: text)

        case .toolCallDelta:
            guard let id, let argumentsDelta else { return nil }
            return .toolCallDelta(index: blockIndex, id: id, name: name, argumentsDelta: argumentsDelta)

        case .blockStart, .blockEnd, .unknown:
            return nil
        }
    }
}
