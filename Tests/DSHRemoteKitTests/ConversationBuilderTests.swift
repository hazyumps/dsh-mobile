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

    @Test("the captured stream folds, and its one missing seq shows as a gap")
    func capturedFixtureFolds() throws {
        // The fixture holds one frame per kind by construction, so seq 34 is
        // absent and the gap flag is the correct reading, not a defect.
        let frames = try #require(Fixtures.object(.muxStreamFrames)["frames"]?.objectValue)
        var builder = ConversationBuilder()
        for (_, json) in frames.sorted(by: { $0.key < $1.key }) {
            builder.apply(try JSONDecoder().decode(MuxFrame.self, from: JSONEncoder().encode(json)))
        }
        #expect(!builder.isEmpty)
        #expect(builder.hasGap)
    }

    @Test("a duplicate seq is ignored rather than rendered twice")
    func duplicateSeqIgnored() throws {
        var builder = ConversationBuilder()
        let message = try event("user/message", seq: 7, data: #"{"content":[{"type":"text","text":"hi"}]}"#)
        builder.apply(event: message)
        builder.apply(event: message)
        #expect(builder.messages.count == 1)
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
            try event("user/message", seq: 2, data: #"{"content":[{"type":"text","text":"one"}]}"#),
            try event("assistant/message", seq: 3, data: #"{"message":{"content":[{"type":"text","text":"two"}]}}"#),
        ]
        builder.merge(page: page)
        let first = builder.messages.map(\.id)
        builder.merge(page: page)
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
}
