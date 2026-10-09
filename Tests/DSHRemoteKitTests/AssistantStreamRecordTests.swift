import Foundation
import Testing
@testable import DSHRemoteKit

// Slice C's riskiest pure logic: a reconnect baseline's `activeAttempt.stream` is a
// compact form, and expanding it wrongly renders one fragment instead of a paragraph, or
// places every fragment but the first at the wrong instant. The shapes asserted here come
// from the host's `validateRecord`, which requires exactly these keys.
//
// Every fixture below is **synthetic**. It is built to the shapes the installed host
// produces, not captured from a live attempt, and says nothing about how often the host
// emits any particular run.

@Suite("Assistant stream expansion")
struct AssistantStreamRecordTests {
    private func record(_ json: JSONValue) -> AssistantStreamRecord {
        AssistantStreamRecord(jsonValue: json)
    }

    private func textChunks(
        index: Int = 0,
        time0: Int64 = 100,
        dt: [Int64] = [],
        texts: [String]
    ) -> JSONValue {
        .object([
            "type": .string("text-chunks"),
            "time0": .int(time0),
            "index": .int(Int64(index)),
            "dt": .array(dt.map { .int($0) }),
            "texts": .array(texts.map { .string($0) }),
        ])
    }

    // MARK: - The timing rule

    @Test("a run's times accumulate from time0, not from the previous member")
    func cumulativeTiming() {
        // The distinction that matters: cumulative gives 100/110/115. Measuring each gap
        // from the previous member's *original* offset would give 100/110/105.
        let decoded = record(textChunks(time0: 100, dt: [10, 5], texts: ["a", "b", "c"]))
        #expect(decoded.expand() == [
            TimedModelStreamChunk(time: 100, chunk: .textDelta(index: 0, text: "a")),
            TimedModelStreamChunk(time: 110, chunk: .textDelta(index: 0, text: "b")),
            TimedModelStreamChunk(time: 115, chunk: .textDelta(index: 0, text: "c")),
        ])
    }

    @Test("a single-member run needs no gaps and still expands")
    func singleMemberRun() {
        let decoded = record(textChunks(time0: 42, dt: [], texts: ["only"]))
        #expect(decoded.expand() == [
            TimedModelStreamChunk(time: 42, chunk: .textDelta(index: 0, text: "only")),
        ])
    }

    @Test("zero gaps expand to identical times rather than being treated as absent")
    func zeroGaps() {
        let decoded = record(textChunks(time0: 7, dt: [0, 0], texts: ["a", "b", "c"]))
        #expect(decoded.expand().map(\.time) == [7, 7, 7])
    }

    @Test("reasoning expands with the same rule into reasoning deltas")
    func reasoningRun() {
        let decoded = record(.object([
            "type": .string("reasoning-chunks"),
            "time0": .int(1),
            "index": .int(2),
            "dt": .array([.int(3)]),
            "texts": .array([.string("think "), .string("harder")]),
        ]))
        #expect(decoded.expand() == [
            TimedModelStreamChunk(time: 1, chunk: .reasoningDelta(index: 2, text: "think ")),
            TimedModelStreamChunk(time: 4, chunk: .reasoningDelta(index: 2, text: "harder")),
        ])
    }

    // MARK: - Tool calls

    @Test("a tool-call run carries its identity on every expanded fragment")
    func toolCallRun() {
        let decoded = record(.object([
            "type": .string("tool-call-chunks"),
            "time0": .int(50),
            "index": .int(1),
            "dt": .array([.int(2)]),
            "id": .string("call-1"),
            "name": .string("bash"),
            "args": .array([.string("{\"cmd\":"), .string("\"ls\"}")]),
        ]))
        #expect(decoded.expand() == [
            TimedModelStreamChunk(
                time: 50,
                chunk: .toolCallDelta(index: 1, id: "call-1", name: "bash", argumentsDelta: "{\"cmd\":")
            ),
            TimedModelStreamChunk(
                time: 52,
                chunk: .toolCallDelta(index: 1, id: "call-1", name: "bash", argumentsDelta: "\"ls\"}")
            ),
        ])
    }

    @Test("a run without a name expands with no name rather than an empty one")
    func toolCallRunWithoutName() {
        let decoded = record(.object([
            "type": .string("tool-call-chunks"),
            "time0": .int(1),
            "index": .int(0),
            "dt": .array([]),
            "id": .string("call-1"),
            "args": .array([.string("{}")]),
        ]))
        // Absent `name` and empty `name` are different things, and the host encodes one by
        // omitting the key. Defaulting to "" would invent a name the model never gave.
        #expect(decoded.expand() == [
            TimedModelStreamChunk(
                time: 1,
                chunk: .toolCallDelta(index: 0, id: "call-1", name: nil, argumentsDelta: "{}")
            ),
        ])
    }

    // MARK: - The raw fallback

    @Test("a raw chunk is passed through, including kinds this build does not model")
    func rawChunkFallback() {
        // The accumulator cannot fold a tool call whose id or name is empty, so it emits
        // the delta raw. Dropping it would lose a partial tool call.
        let partialToolCall = record(.object([
            "type": .string("chunk"),
            "time": .int(9),
            "chunk": .object([
                "type": .string("tool-call-delta"),
                "index": .int(0),
                "id": .string(""),
                "argumentsDelta": .string("{\"a\":"),
            ]),
        ]))
        #expect(partialToolCall.expand() == [
            TimedModelStreamChunk(
                time: 9,
                chunk: .toolCallDelta(index: 0, id: "", name: nil, argumentsDelta: "{\"a\":")
            ),
        ])

        // Everything else that does not compact — block boundaries, usage, finish — must
        // survive as unsupported activity rather than vanish.
        let blockStart = record(.object([
            "type": .string("chunk"),
            "time": .int(3),
            "chunk": .object(["type": .string("block-start"), "index": .int(0)]),
        ]))
        #expect(blockStart.expand().count == 1)
        guard case .other(let type, _)? = blockStart.expand().first?.chunk else {
            Issue.record("expected a block-start to be preserved as unsupported activity")
            return
        }
        #expect(type == "block-start")
    }

    // MARK: - What must not be guessed at

    @Test("a run whose gap array does not match its members is not expanded", arguments: [
        // three members, one gap
        JSONValue.object([
            "type": .string("text-chunks"), "time0": .int(1), "index": .int(0),
            "dt": .array([.int(1)]), "texts": .array([.string("a"), .string("b"), .string("c")]),
        ]),
        // two members, two gaps
        JSONValue.object([
            "type": .string("text-chunks"), "time0": .int(1), "index": .int(0),
            "dt": .array([.int(1), .int(1)]), "texts": .array([.string("a"), .string("b")]),
        ]),
        // a non-integer gap
        JSONValue.object([
            "type": .string("text-chunks"), "time0": .int(1), "index": .int(0),
            "dt": .array([.string("soon")]), "texts": .array([.string("a"), .string("b")]),
        ]),
        // a positive-length run with no gaps at all
        JSONValue.object([
            "type": .string("text-chunks"), "time0": .int(1), "index": .int(0),
            "texts": .array([.string("a"), .string("b")]),
        ]),
    ])
    func inconsistentGapsAreNotExpanded(_ json: JSONValue) {
        let decoded = record(json)
        guard case .unknown(let type, let value) = decoded else {
            Issue.record("expected an unreadable run, got \(decoded)")
            return
        }
        #expect(type == "text-chunks")
        // Retained whole, so the run is still visible to whoever wants to show it.
        #expect(value == json)
        #expect(decoded.expand().isEmpty)
    }

    @Test("an empty member list or empty tool identity is not expanded", arguments: [
        JSONValue.object([
            "type": .string("text-chunks"), "time0": .int(1), "index": .int(0),
            "dt": .array([]), "texts": .array([]),
        ]),
        JSONValue.object([
            "type": .string("tool-call-chunks"), "time0": .int(1), "index": .int(0),
            "dt": .array([]), "id": .string(""), "args": .array([.string("{}")]),
        ]),
        JSONValue.object([
            "type": .string("tool-call-chunks"), "time0": .int(1), "index": .int(0),
            "dt": .array([]), "id": .string("call-1"), "name": .string(""),
            "args": .array([.string("{}")]),
        ]),
    ])
    func hollowRunsAreNotExpanded(_ json: JSONValue) {
        guard case .unknown = record(json) else {
            Issue.record("expected an unreadable run")
            return
        }
    }

    @Test("a negative or non-integral block index is not expanded")
    func badIndexIsNotExpanded() {
        let negative = textChunks(index: -1, texts: ["a"])
        guard case .unknown = record(negative) else {
            Issue.record("a negative block index is not a valid run")
            return
        }

        let fractional = JSONValue.object([
            "type": .string("text-chunks"), "time0": .int(1), "index": .double(1.5),
            "dt": .array([]), "texts": .array([.string("a")]),
        ])
        guard case .unknown = record(fractional) else {
            Issue.record("a fractional block index is not a valid run")
            return
        }
    }

    @Test("an unrecognised record kind is retained whole and expands to nothing")
    func unknownRecordKind() {
        let json = JSONValue.object([
            "type": .string("something-new"),
            "time0": .int(1),
        ])
        #expect(record(json) == .unknown(type: "something-new", value: json))
        #expect(record(json).expand().isEmpty)
    }

    // MARK: - Shape fidelity

    @Test("the host's internal lastTime is stripped before publication, and tolerated if seen")
    func lastTimeIsNotRequired() {
        // The accumulator keeps `lastTime` while merging and removes it for the durable
        // form, so a reader that *required* it would reject every real record. One that
        // appears anyway must not break decoding either.
        let withLastTime = JSONValue.object([
            "type": .string("text-chunks"), "time0": .int(5), "index": .int(0),
            "dt": .array([]), "texts": .array([.string("a")]), "lastTime": .int(5),
        ])
        #expect(record(withLastTime).expand() == [
            TimedModelStreamChunk(time: 5, chunk: .textDelta(index: 0, text: "a")),
        ])
    }

    @Test("a whole compact stream expands in order, runs and raw chunks together")
    func wholeStreamExpansion() {
        let stream: [JSONValue] = [
            textChunks(time0: 10, dt: [1], texts: ["Hel", "lo"]),
            .object([
                "type": .string("chunk"), "time": .int(20),
                "chunk": .object(["type": .string("usage"), "input": .int(3)]),
            ]),
            .object([
                "type": .string("reasoning-chunks"), "time0": .int(30), "index": .int(1),
                "dt": .array([]), "texts": .array([.string("because")]),
            ]),
        ]
        let expanded = AssistantStreamRecord.expand(stream: stream)
        #expect(expanded.map(\.time) == [10, 11, 20, 30])
        #expect(expanded.map(\.chunk.typeName) == [
            "text-delta", "text-delta", "usage", "reasoning-delta",
        ])
    }
}
