import DSHRemoteKit
import Foundation
import Testing

/// The five SPEC §6.5 rules the reducer owns, plus the things it must not lose.
@Suite("Conversation builder")
struct ConversationBuilderTests {
    private func frame(_ json: String) throws -> MuxFrame {
        try JSONDecoder().decode(MuxFrame.self, from: Data(json.utf8))
    }

    private func event(_ type: String, seq: Int64, data: String = "{}") throws -> DurableEventEnvelope {
        try JSONDecoder().decode(
            DurableEventEnvelope.self,
            from: Data(#"{"type":"\#(type)","seq":\#(seq),"time":1,"data":\#(data)}"#.utf8)
        )
    }

    private func streamFrame(_ json: String) throws -> MuxFrame {
        try frame(#"{"type":"item","streamId":"1","value":{"type":"assistant-stream","frame":\#(json)}}"#)
    }

    /// A `chunk` frame carrying one delta. **Synthetic**: no live
    /// `session/follow` frame carrying a delta was ever captured — the only
    /// captured live chunk is a `block-start` — so this shape comes from
    /// installed source and `SPEC §7`.
    private func deltaFrame(
        _ attempt: String,
        revision: Int64,
        outerIndex: Int64,
        type: String,
        blockIndex: Int,
        text: String
    ) -> String {
        let chunk = #"{"type":"\#(type)","index":\#(blockIndex),"text":"\#(text)"}"#
        return #"{"type":"chunk","attemptId":"\#(attempt)","revision":\#(revision),"index":\#(outerIndex),"chunk":\#(chunk)}"#
    }

    /// A snapshot baseline. The `{header, cursor, records, hasMore}` envelope is
    /// **captured** (`Fixtures/mux-stream-frames.json`); the `assistantStream`
    /// baseline is **synthetic**, because no capture holds an `activeAttempt`.
    private func snapshot(
        cursor: Int64,
        records: String = "[]",
        assistantStream: String? = nil
    ) throws -> MuxSnapshot {
        var json = #"{"header":{"version":4},"cursor":\#(cursor),"records":\#(records),"hasMore":false"#
        if let assistantStream {
            json += #","assistantStream":\#(assistantStream)"#
        }
        json += "}"
        return try JSONDecoder().decode(MuxSnapshot.self, from: Data(json.utf8))
    }

    /// One `event` record for a snapshot's `records` array.
    private func userRecord(seq: Int64, text: String) -> String {
        #"{"type":"event","event":{"type":"user/message","seq":\#(seq),"time":1,"data":{"content":[{"type":"text","text":"\#(text)"}],"source":{"kind":"user"}}}}"#
    }

    @Test("the captured stream folds, and its one missing seq shows as a gap")
    func capturedFixtureFolds() throws {
        // The fixture holds one frame per kind by construction, so seq 34 is
        // absent and the gap flag is the correct reading, not a defect.
        let frames = try #require(Fixtures.object(.muxStreamFrames)["frames"]?.objectValue)
        // The baseline goes first, as it does on the wire. A snapshot now replaces
        // the window, so applying it last — which this test did while the builder
        // merged — would wipe the very history the fold is checking.
        let keys = frames.keys.sorted().filter { $0 == "snapshot" }
            + frames.keys.sorted().filter { $0 != "snapshot" }
        var builder = ConversationBuilder()
        for key in keys {
            guard let json = frames[key] else { continue }
            builder.apply(try JSONDecoder().decode(MuxFrame.self, from: JSONEncoder().encode(json)))
        }
        #expect(!builder.isEmpty)
        #expect(builder.hasGap)
    }

    @Test("a duplicate seq is ignored rather than rendered twice")
    func duplicateSeqIgnored() throws {
        var builder = ConversationBuilder()
        let message = try event("user/message", seq: 7, data: #"{"content":[{"type":"text","text":"hi"}],"source":{"kind":"user"}}"#)
        builder.apply(event: message)
        builder.apply(event: message)
        #expect(builder.messages.count == 1)
    }

    @Test("the host's injected content is not shown as the user's own words")
    func injectedContentIsNotTheUsers() throws {
        // The host delivers workspace instructions, the runtime-context snapshot and the
        // skill catalog as `user/message` with `role: "user"`. Only `source.kind == "user"`
        // is a person; anything else rendered as a user bubble would put the harness's
        // plumbing in the user's mouth (SPEC §6.5 records the discriminator).
        var builder = ConversationBuilder()
        builder.apply(event: try event(
            "user/message",
            seq: 1,
            data: #"{"content":[{"type":"text","text":"<system-reminder>…"}],"source":{"kind":"agent-instructions"}}"#
        ))
        #expect(builder.messages.isEmpty)
        // Still reachable behind a restrained activity row rather than dropped.
        #expect(builder.unmodelledEvents.count == 1)

        builder.apply(event: try event(
            "user/message",
            seq: 2,
            data: #"{"content":[{"type":"text","text":"mine"}],"source":{"kind":"user","rpcId":"r"}}"#
        ))
        #expect(builder.messages.map(\.text) == ["mine"])
    }

    @Test("a message that carried a file shows the file, not just its text")
    func filePartsSurviveTheFold() throws {
        // The host stores a durable `file` part with `{attachmentId, name, bytes}` once the
        // prompt becomes a message — the receipt is retired — so this is the only thing left
        // that says what the user attached.
        var builder = ConversationBuilder()
        builder.apply(event: try event(
            "user/message",
            seq: 1,
            data: #"{"content":[{"type":"text","text":"look at this"},{"type":"file","attachment":{"attachmentId":"sha256:abc","name":"probe.txt","bytes":28}}],"source":{"kind":"user"}}"#
        ))
        #expect(builder.messages.count == 1)
        #expect(builder.messages.first?.text == "look at this")
        #expect(builder.messages.first?.attachments == ["probe.txt"])

        // A prompt whose only content is a file is still a message.
        var onlyFile = ConversationBuilder()
        onlyFile.apply(event: try event(
            "user/message",
            seq: 2,
            data: #"{"content":[{"type":"file","attachment":{"attachmentId":"sha256:abc","name":"probe.txt","bytes":28}}],"source":{"kind":"user"}}"#
        ))
        #expect(onlyFile.messages.first?.attachments == ["probe.txt"])
        #expect(onlyFile.messages.first?.text == "")

        // An image resolves the same way, with the host's own metadata — captured from the
        // installed host on 2026-10-09, and previously invisible in the transcript.
        var withImage = ConversationBuilder()
        withImage.apply(event: try event(
            "user/message",
            seq: 3,
            data: #"{"content":[{"type":"text","text":"what is this"},{"type":"image","attachment":{"attachmentId":"sha256:64cf6b08","mediaType":"image/png","width":300,"height":200,"bytes":107407,"name":"probe.png"}}],"source":{"kind":"user"}}"#
        ))
        #expect(withImage.messages.first?.attachments == ["probe.png"])
    }

    @Test("a jump forward sets the gap flag")
    func gapSetsFlag() throws {
        var builder = ConversationBuilder()
        builder.apply(event: try event("turn/start", seq: 1))
        #expect(!builder.hasGap)
        builder.apply(event: try event("turn/start", seq: 3))
        #expect(builder.hasGap)
    }

    @Test("a chunk that goes backwards does not open a second provisional reply")
    func staleChunkDropped() throws {
        var builder = ConversationBuilder()
        builder.apply(try streamFrame(#"{"type":"start","attemptId":"a1","revision":5}"#))
        builder.apply(try streamFrame(#"{"type":"chunk","attemptId":"a1","revision":6,"index":0}"#))
        builder.apply(try streamFrame(#"{"type":"chunk","attemptId":"a1","revision":4,"index":0}"#))
        #expect(builder.messages.filter(\.isProvisional).count == 1)
        #expect(builder.isStreaming)
    }

    @Test("settlement retires the provisional and leaves one durable reply")
    func settlementRetiresProvisional() throws {
        var builder = ConversationBuilder()
        builder.apply(try streamFrame(#"{"type":"start","attemptId":"a1","revision":5}"#))
        builder.apply(try streamFrame(#"{"type":"chunk","attemptId":"a1","revision":6,"index":0}"#))
        #expect(builder.isStreaming)

        builder.apply(try streamFrame(#"{"type":"end","attemptId":"a1","revision":7,"index":1,"outcome":{"kind":"committed","eventType":"assistant/message","seq":48}}"#))
        builder.apply(event: try event(
            "assistant/message",
            seq: 48,
            data: #"{"message":{"role":"assistant","content":[{"type":"reasoning","text":"because"},{"type":"text","text":"done"}]}}"#
        ))

        let messages = builder.messages
        #expect(!builder.isStreaming)
        #expect(messages.count == 1)
        #expect(messages.first?.text == "done")
        #expect(messages.first?.reasoning == "because")
        #expect(messages.first?.isProvisional == false)

        // A chunk arriving after the end is dropped, not resurrected.
        builder.apply(try streamFrame(#"{"type":"chunk","attemptId":"a1","revision":8,"index":2}"#))
        #expect(builder.messages.count == 1)
    }

    @Test("paging the same history twice changes nothing")
    func pagingMergesWithoutDuplicates() throws {
        var builder = ConversationBuilder()
        let page = [
            try event("user/message", seq: 2, data: #"{"content":[{"type":"text","text":"one"}],"source":{"kind":"user"}}"#),
            try event("assistant/message", seq: 3, data: #"{"message":{"content":[{"type":"text","text":"two"}]}}"#),
        ]
        builder.merge(page: page, generation: builder.generation)
        let first = builder.messages.map(\.id)
        builder.merge(page: page, generation: builder.generation)
        #expect(builder.messages.map(\.id) == first)
        #expect(builder.messages.count == 2)
    }

    @Test("an empty builder renders nothing")
    func emptyIsEmpty() {
        let builder = ConversationBuilder()
        #expect(builder.messages.isEmpty)
        #expect(builder.isEmpty)
        #expect(!builder.hasGap)
        #expect(!builder.isStreaming)
    }

    @Test("events with no message of their own are kept, not dropped")
    func unmodelledEventsKept() throws {
        var builder = ConversationBuilder()
        builder.apply(event: try event("turn/start", seq: 1, data: #"{"turn":1}"#))
        builder.apply(event: try event("permission/preset", seq: 2, data: #"{"preset":"workspace-write"}"#))
        #expect(builder.messages.isEmpty)
        #expect(builder.unmodelledEvents.count == 2)
    }

    @Test("a committed end arriving before its durable record holds the preview")
    func settledPreviewHeldUntilItsRecordArrives() throws {
        var builder = ConversationBuilder()
        builder.apply(try streamFrame(#"{"type":"start","attemptId":"a1","revision":5}"#))
        builder.apply(try streamFrame(#"{"type":"chunk","attemptId":"a1","revision":6,"index":0}"#))
        // The end names seq 48, which has not arrived yet. The reply must not
        // disappear in the gap between settlement and its durable record.
        builder.apply(try streamFrame(#"{"type":"end","attemptId":"a1","revision":7,"index":1,"outcome":{"kind":"committed","eventType":"assistant/message","seq":48}}"#))
        #expect(!builder.isStreaming)
        #expect(builder.messages.count == 1)
        #expect(builder.messages.first?.isProvisional == true)

        // The record lands: exactly one message, and it is the durable one.
        builder.apply(event: try event(
            "assistant/message",
            seq: 48,
            data: #"{"message":{"content":[{"type":"text","text":"done"}]}}"#
        ))
        #expect(builder.messages.count == 1)
        #expect(builder.messages.first?.text == "done")
        #expect(builder.messages.first?.isProvisional == false)
    }

    // MARK: - A snapshot replaces the window

    @Test("a second snapshot replaces the transcript instead of merging into it")
    func secondSnapshotReplacesTheTranscript() throws {
        var builder = ConversationBuilder()
        builder.apply(snapshot: try snapshot(cursor: 1, records: "[\(userRecord(seq: 1, text: "first"))]"))
        // A preview from the first generation must not survive the second either.
        builder.apply(try streamFrame(#"{"type":"start","attemptId":"a1","revision":1}"#))
        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 2, outerIndex: 0, type: "text-delta", blockIndex: 0, text: "draft"
        )))
        #expect(builder.messages.map(\.text) == ["first", "draft"])

        builder.apply(snapshot: try snapshot(cursor: 9, records: "[\(userRecord(seq: 9, text: "second"))]"))

        #expect(builder.messages.map(\.text) == ["second"])
        #expect(builder.messages.allSatisfy { !$0.isProvisional })
        #expect(!builder.isStreaming)
        #expect(!builder.hasGap)
    }

    @Test("the snapshot cursor is exposed for paging and the generation advances")
    func cursorAndGenerationExposed() throws {
        var builder = ConversationBuilder()
        #expect(builder.cursor == nil)
        #expect(builder.generation == 0)

        builder.apply(snapshot: try snapshot(cursor: 48))
        #expect(builder.cursor == 48)
        #expect(builder.generation == 1)

        builder.apply(snapshot: try snapshot(cursor: 50))
        #expect(builder.cursor == 50)
        #expect(builder.generation == 2)
    }

    @Test("a page fetched for an older generation is dropped")
    func stalePageFromAnOlderGenerationIsDropped() throws {
        var builder = ConversationBuilder()
        builder.apply(snapshot: try snapshot(cursor: 1, records: "[\(userRecord(seq: 1, text: "first"))]"))
        let staleGeneration = builder.generation
        let page = [try event("user/message", seq: 0, data: #"{"content":[{"type":"text","text":"older"}],"source":{"kind":"user"}}"#)]

        builder.apply(snapshot: try snapshot(cursor: 9, records: "[\(userRecord(seq: 9, text: "second"))]"))

        // The page was requested against the previous baseline; merging it would
        // splice another generation's history into this one.
        builder.merge(page: page, generation: staleGeneration)
        #expect(builder.messages.map(\.text) == ["second"])

        // The current generation's page still merges, in seq order.
        builder.merge(page: page, generation: builder.generation)
        #expect(builder.messages.map(\.text) == ["older", "second"])
    }

    // MARK: - The expected live sequence comes from the cursor

    @Test("an empty baseline seeds the expected sequence from the cursor, not from a record")
    func emptyBaselineSeedsExpectedSequence() throws {
        var skipped = ConversationBuilder()
        skipped.apply(snapshot: try snapshot(cursor: 7))
        skipped.apply(event: try event("turn/start", seq: 9))
        #expect(skipped.hasGap)

        var contiguous = ConversationBuilder()
        contiguous.apply(snapshot: try snapshot(cursor: 7))
        contiguous.apply(event: try event("turn/start", seq: 8))
        #expect(!contiguous.hasGap)

        // `-1` is the host's "before the first event", so the expectation is 0
        // and the event at 0 is contiguous rather than a gap.
        var fromZero = ConversationBuilder()
        fromZero.apply(snapshot: try snapshot(cursor: -1))
        fromZero.apply(event: try event("turn/start", seq: 0))
        #expect(!fromZero.hasGap)

        // A cursor at the top of the range wraps; a corrupt value must not trap.
        var overflowing = ConversationBuilder()
        overflowing.apply(snapshot: try snapshot(cursor: .max))
        overflowing.apply(event: try event("turn/start", seq: 0))
        #expect(overflowing.hasGap)
    }

    @Test("a settlement the window has already passed is missing, not held")
    func settlementBehindTheWindowIsMissing() throws {
        var builder = ConversationBuilder()
        builder.apply(snapshot: try snapshot(cursor: 4))
        builder.apply(try streamFrame(#"{"type":"start","attemptId":"a1","revision":1}"#))
        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 2, outerIndex: 0, type: "text-delta", blockIndex: 0, text: "half"
        )))
        builder.apply(try streamFrame(#"{"type":"end","attemptId":"a1","revision":3,"index":1,"outcome":{"kind":"committed","eventType":"assistant/message","seq":6}}"#))
        #expect(builder.messages.count == 1)

        // Seq 7 lands without seq 6, so the record the end named is not late — it
        // is missing, and holding the preview would promise a reply forever.
        builder.apply(event: try event("turn/start", seq: 7))
        #expect(builder.messages.isEmpty)
        #expect(builder.hasGap)
    }

    // MARK: - Provisional text from the stream

    @Test("text accumulates per block index and reasoning never merges into it (synthetic deltas)")
    func textAccumulatesAcrossBlockIndices() throws {
        var builder = ConversationBuilder()
        builder.apply(try streamFrame(#"{"type":"start","attemptId":"a1","revision":1}"#))
        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 2, outerIndex: 0, type: "reasoning-delta", blockIndex: 0, text: "why "
        )))
        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 3, outerIndex: 1, type: "text-delta", blockIndex: 0, text: "Hel"
        )))
        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 4, outerIndex: 2, type: "text-delta", blockIndex: 0, text: "lo"
        )))
        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 5, outerIndex: 3, type: "text-delta", blockIndex: 1, text: " world"
        )))
        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 6, outerIndex: 4, type: "reasoning-delta", blockIndex: 1, text: "more"
        )))

        let preview = try #require(builder.messages.first { $0.isProvisional })
        #expect(preview.text == "Hello world")
        #expect(preview.reasoning == "why more")
        #expect(builder.isStreaming)
    }

    @Test("a duplicate and an out-of-order chunk neither double nor reorder the text (synthetic deltas)")
    func duplicateAndOutOfOrderChunksDoNotDoubleText() throws {
        var builder = ConversationBuilder()
        builder.apply(try streamFrame(#"{"type":"start","attemptId":"a1","revision":1}"#))
        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 2, outerIndex: 0, type: "text-delta", blockIndex: 0, text: "ab"
        )))
        // The same frame replayed: same revision, same outer index.
        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 2, outerIndex: 0, type: "text-delta", blockIndex: 0, text: "ab"
        )))
        #expect(builder.messages.first?.text == "ab")

        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 3, outerIndex: 1, type: "text-delta", blockIndex: 0, text: "cd"
        )))
        #expect(builder.messages.first?.text == "abcd")

        // A late frame carries a lower outer index; its fragment must not land
        // after "cd" and must not be appended at all.
        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 2, outerIndex: 0, type: "text-delta", blockIndex: 0, text: "XX"
        )))
        #expect(builder.messages.first?.text == "abcd")
    }

    @Test("a reconnect baseline's compact prefix becomes provisional text (synthetic)")
    func reconnectBaselineBecomesProvisionalText() throws {
        // A run of n fragments carries n - 1 gaps, which is the expander's rule.
        let textRun = #"{"type":"text-chunks","time0":1,"index":0,"dt":[1],"texts":["Hel","lo"]}"#
        let reasoningRun = #"{"type":"reasoning-chunks","time0":9,"index":0,"dt":[],"texts":["why "]}"#
        let baseline = #"{"revision":19,"activeAttempt":{"attemptId":"a1","startedAfterSeq":36,"nextIndex":3,"stream":[\#(textRun),\#(reasoningRun)]}}"#

        var builder = ConversationBuilder()
        builder.apply(snapshot: try snapshot(cursor: 36, assistantStream: baseline))
        let preview = try #require(builder.messages.first { $0.isProvisional })
        #expect(preview.text == "Hello")
        #expect(preview.reasoning == "why ")
        #expect(builder.isStreaming)

        // `nextIndex` is 3, so a frame at index 2 is already inside the prefix and
        // must not be appended twice.
        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 20, outerIndex: 2, type: "text-delta", blockIndex: 0, text: "Hello"
        )))
        #expect(builder.messages.first?.text == "Hello")

        // The next frame, index 3, continues the same block.
        builder.apply(try streamFrame(deltaFrame(
            "a1", revision: 21, outerIndex: 3, type: "text-delta", blockIndex: 0, text: "!"
        )))
        #expect(builder.messages.first?.text == "Hello!")
    }
}
