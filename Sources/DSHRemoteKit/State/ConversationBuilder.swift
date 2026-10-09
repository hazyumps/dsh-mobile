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
/// Deliberately a value type with a dictionary of durable events, a per-attempt
/// preview, and the generation both belong to. Ordering is derived on read from
/// `seq`, so paging older history in cannot reorder anything.
///
/// Durable history and transient chunks are kept apart (SPEC §6.5), which is what
/// makes a preview disposable: a fresh snapshot replaces the whole window, and a
/// durable `assistant/message` retires exactly the preview whose `seq` it names.
///
/// Provisional text is assembled from the stream's own deltas. Earlier this type
/// carried none, because the only chunk ever captured was a block boundary; the
/// delta kinds are established by installed source (`SPEC §7`), so they are read
/// there and joined per content-block index rather than reordered by arrival.
public struct ConversationBuilder: Sendable {
    public private(set) var hasGap = false

    /// Which follow baseline this window belongs to. `session/page` must name the
    /// generation it was fetched against, so a page that raced a reconnect is
    /// dropped instead of merged into a conversation it does not describe
    /// (SPEC §6.5: "never combine a page from an old generation with a new
    /// baseline").
    public private(set) var generation = 0

    /// The opening baseline's cursor, for paging. `nil` until a snapshot arrives;
    /// a page request uses this value, never a delivery event's watermark.
    public private(set) var cursor: Int64?

    /// Durable events by `seq`. A dictionary, so a duplicate is a no-op.
    private var events: [Int64: DurableEventEnvelope] = [:]
    /// Attempts still arriving, with whatever the host has published for each.
    private var open: [String: Attempt] = [:]
    /// Attempts that ended, so late chunks for them are dropped.
    private var ended: Set<String> = []
    /// Attempts whose `committed` end named a durable `seq` that has not arrived
    /// yet: the preview is held, text and all, until that record exists, so the
    /// reply never vanishes in the gap between the two.
    private var held: [String: HeldAttempt] = [:]
    /// Highest durable `seq` held. Kept separate from ``expectedSeq`` on purpose:
    /// this one is a fact about what is here, and its only job is to prove that a
    /// settlement the stream named is missing rather than merely late.
    private var highestSeq: Int64?
    /// The next durable `seq` the window expects, seeded from the baseline's
    /// `cursor` — `cursor + 1`. The host represents the position before any event
    /// as `-1`, so an empty baseline expects `0` and a live event that skips
    /// sequences is a gap even though no durable event has been seen yet.
    private var expectedSeq: Int64?

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

    /// A new baseline. It *replaces* the window rather than merging into it: the
    /// records, previews, and settlement holds all describe the generation this
    /// snapshot opens, and keeping the previous conversation around would
    /// interleave two unrelated attempts on screen.
    ///
    /// `hasGap` is cleared with the rest. A snapshot is the recovery SPEC §6.5
    /// names for a gap, so carrying the old flag forward would report a hole in a
    /// window that is no longer rendered.
    public mutating func apply(snapshot: MuxSnapshot) {
        generation += 1
        cursor = snapshot.cursor
        events.removeAll()
        open.removeAll()
        ended.removeAll()
        held.removeAll()
        highestSeq = nil
        hasGap = false
        // The expectation is `cursor + 1`, not one past the highest record: a
        // baseline whose records are unreadable or windowed still fixes the
        // sequence a live event has to continue from. Additions wrap because a
        // corrupt cursor must never crash the client (SPEC §5).
        expectedSeq = snapshot.cursor &+ 1

        for record in snapshot.records {
            guard let event = record.event else { continue }
            events[event.seq] = event
            highestSeq = max(highestSeq ?? event.seq, event.seq)
        }

        if let baseline = snapshot.assistantStream {
            adopt(baseline)
        }
    }

    /// A durable event. Duplicates are ignored; a jump past what the window
    /// expects is a gap.
    public mutating func apply(event: DurableEventEnvelope) {
        guard events[event.seq] == nil else { return }
        if let expected = expectedSeq {
            if event.seq > expected { hasGap = true }
            // A late event filling a hole must not drag the expectation
            // backwards; what is still expected is what comes after the highest.
            expectedSeq = max(expected, event.seq &+ 1)
        } else if let highestSeq, event.seq > highestSeq &+ 1 {
            // No baseline yet, so the highest sequence held is the best
            // expectation available. This is the pre-snapshot path only.
            hasGap = true
        }
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
            open[attempt] = Attempt(revision: revision)

        case .chunk:
            // A chunk for a finished attempt is stale, and one the host has
            // already counted is a replay: SPEC §6.5 says drop either rather than
            // append the same fragment twice or place it out of order.
            guard !ended.contains(attempt), var current = open[attempt],
                  current.accepts(index: frame.index, revision: revision)
            else { return }
            current.revision = max(current.revision, revision)
            if let index = frame.index { current.lastIndex = index }
            current.chunks += 1
            // One accumulator, fed by one type: the live body is converted at
            // this boundary into the same `ModelStreamChunk` the reconnect
            // baseline's expander produces.
            Self.accumulate(frame.chunk?.modelChunk(), into: &current)
            open[attempt] = current

        case .end:
            // Retire the provisional exactly once. Its durable record arrives as
            // its own event, and the two orders are not guaranteed: a committed
            // end that arrives first holds the preview — with the text already
            // streamed — until that record lands, so the reply is neither
            // momentarily absent nor doubled.
            let preview = open[attempt]
            open[attempt] = nil
            ended.insert(attempt)
            if let outcome = frame.outcome, outcome.kind == .committed, let seq = outcome.seq {
                held[attempt] = HeldAttempt(seq: seq, preview: preview ?? Attempt(revision: revision))
            }

        case .unknown:
            return
        }
    }

    /// Merge older history paged in through `session/page`.
    ///
    /// The caller passes the ``generation`` it read before requesting the page.
    /// A page that raced a reconnect names an older generation and is dropped,
    /// because merging it would splice another baseline's history into this one
    /// (SPEC §6.5). Anything already held is skipped, so a page cannot duplicate
    /// or reorder what is rendered.
    public mutating func merge(page: [DurableEventEnvelope], generation: Int) {
        guard generation == self.generation else { return }
        for event in page where events[event.seq] == nil {
            events[event.seq] = event
            highestSeq = max(highestSeq ?? event.seq, event.seq)
        }
    }

    // MARK: - Read

    public var messages: [ConversationMessage] {
        var result = events.values
            .sorted { $0.seq < $1.seq }
            .compactMap(Self.message(from:))

        for (attempt, state) in open.sorted(by: { $0.key < $1.key }) where state.chunks > 0 {
            result.append(Self.preview(id: attempt, of: state))
        }
        for (attempt, settled) in held.sorted(by: { $0.key < $1.key }) where events[settled.seq] == nil {
            // If the window already holds a sequence at or past the one this end
            // named, that settlement is not late — it is missing, so the preview
            // is dropped instead of held forever.
            if let highestSeq, settled.seq <= highestSeq { continue }
            result.append(Self.preview(id: attempt, of: settled.preview))
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

    public var isEmpty: Bool { events.isEmpty && open.isEmpty && held.isEmpty }

    /// The oldest durable sequence held, or `nil` when nothing is.
    ///
    /// This is `session/page`'s exclusive `beforeSeq`: the window ends here, so the
    /// next page is what came before it (SPEC §7).
    public var oldestSeq: Int64? { events.keys.min() }

    /// Whether at least one reply is still arriving.
    public var isStreaming: Bool { open.values.contains { $0.chunks > 0 } }

    // MARK: - Live state

    /// What the host has published for one attempt so far.
    private struct Attempt {
        /// Latest revision seen. Monotonic, *not* strictly increasing, so it is a
        /// staleness hint and not a duplicate key on its own.
        var revision: Int64
        /// Answer fragments by inner content-block index. A map joined in index
        /// order on read, so a fragment for a later block can never land inside an
        /// earlier one, and the order text is rendered in is block order rather
        /// than arrival order.
        var text: [Int: String] = [:]
        /// Reasoning fragments by inner content-block index. A separate map,
        /// because SPEC §7 keeps reasoning out of the answer.
        var reasoning: [Int: String] = [:]
        /// Chunk frames counted, so an attempt whose only frame so far was a block
        /// boundary still reports as streaming.
        var chunks = 0
        /// Highest outer frame index accepted. The host counts frames with its own
        /// `nextIndex`, so a chunk at or below this one is already counted.
        var lastIndex: Int64?

        init(revision: Int64) {
            self.revision = revision
        }

        /// Whether an incoming chunk frame is new to this attempt.
        ///
        /// The outer `index` is the host's own dedup key: a replay repeats it, and
        /// a late frame carries a lower one. Revision is only the fallback for a
        /// frame that omits `index`, and it stays permissive there (`>=`): a
        /// revision is monotonic rather than strictly increasing, so two distinct
        /// chunks can share one, and a strict test would drop the second half of
        /// an answer.
        func accepts(index: Int64?, revision incoming: Int64) -> Bool {
            if let index, let lastIndex { return index > lastIndex }
            if index != nil { return true }
            return incoming >= revision
        }

        /// The answer: fragments joined in content-block order.
        var answer: String { Self.joined(text) }

        var reasoningText: String? { reasoning.isEmpty ? nil : Self.joined(reasoning) }

        private static func joined(_ fragments: [Int: String]) -> String {
            fragments.keys.sorted().compactMap { fragments[$0] }.joined()
        }
    }

    /// A settled attempt whose durable record has not arrived yet.
    private struct HeldAttempt {
        var seq: Int64
        var preview: Attempt
    }

    /// The one place a fragment is appended to an attempt.
    ///
    /// Both arrivals funnel through here: a live `chunk` frame, converted to
    /// ``ModelStreamChunk`` at the boundary, and a reconnect baseline's compact
    /// prefix, which the expander already produces in that type. Kinds that carry
    /// no answer text — a tool call's partial arguments, an unmodelled chunk, a
    /// boundary — are no-ops rather than failures.
    private static func accumulate(_ chunk: ModelStreamChunk?, into attempt: inout Attempt) {
        switch chunk {
        case .textDelta(let index, let text):
            attempt.text[index, default: ""] += text
        case .reasoningDelta(let index, let text):
            attempt.reasoning[index, default: ""] += text
        case .toolCallDelta, .other, .none:
            // A partial argument string is usually not valid JSON, and this view
            // renders text only. The frame is still counted.
            return
        }
    }

    /// Adopts the optional live baseline a reconnect snapshot carries.
    ///
    /// The prefix is not a list of live frames but compact runs with timing
    /// arrays, so it is expanded with ``AssistantStreamRecord`` and then
    /// accumulated by the live path's own method. Without this, reconnecting
    /// during a reply would show only the fragments that arrived after it — the
    /// truncation provisional text exists to avoid.
    ///
    /// unverified: no capture holds an `activeAttempt`, so `nextIndex` is trusted
    /// only as the host's own frame count; where it is absent, a replayed prefix
    /// frame cannot be told from a new one.
    private mutating func adopt(_ baseline: MuxAssistantStreamBaseline) {
        guard let prefix = baseline.activeAttempt, let attempt = prefix.attemptId else { return }

        var state = Attempt(revision: baseline.revision ?? 0)
        let expanded = AssistantStreamRecord.expand(stream: prefix.stream ?? [])
        state.chunks = expanded.count
        for timed in expanded {
            Self.accumulate(timed.chunk, into: &state)
        }
        // The host names an active attempt only while it is still producing, so
        // the preview exists even before the prefix carries a frame.
        state.chunks = max(state.chunks, 1)
        // Frames below `nextIndex` are already inside the prefix. The outer index
        // is zero-based, so the last counted frame is `nextIndex - 1`.
        if let next = prefix.nextIndex { state.lastIndex = next - 1 }
        open[attempt] = state
    }

    private static func preview(id attempt: String, of state: Attempt) -> ConversationMessage {
        ConversationMessage(
            id: "attempt:\(attempt)",
            role: .assistant,
            text: state.answer,
            isProvisional: true,
            reasoning: state.reasoningText
        )
    }

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
