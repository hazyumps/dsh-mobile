import Foundation
import Testing

@testable import DSHRemoteKit

// `Fixtures/mux-stream-frames.json` holds its captures under `frames`, keyed by the frame's
// own name, so these helpers reach one frame out of the wrapper and decode it. The fixture's
// strings are redacted except the wire vocabulary: every assertion below is about shape,
// discriminants, and sequencing, never about the redacted content.

/// The twelve captured frames, keyed by name.
func muxFrameObjects() throws -> [String: JSONValue] {
    let root = try Fixtures.object(.muxStreamFrames)
    return try #require(root["frames"]?.objectValue)
}

/// One captured frame, as loose key/value pairs.
func muxFrameObject(_ name: String) throws -> [String: JSONValue] {
    let frames = try muxFrameObjects()
    return try #require(frames[name]?.objectValue, "no captured frame object named \(name)")
}

/// One captured frame, decoded.
func capturedMuxFrame(_ name: String) throws -> MuxFrame {
    try JSONDecoder().decode(MuxFrame.self, from: Fixtures.encode(object: try muxFrameObject(name)))
}

/// Returns `container` with the value at `path` replaced. `path` walks object keys and array
/// indices mixed; a `nil` value removes the key. Used to build the tolerances the fixture
/// cannot show — an unknown discriminant, or an optional field left out.
func mutating(_ container: JSONValue, at path: [String], with newValue: JSONValue?) throws -> JSONValue {
    guard let key = path.first else { return newValue ?? .null }
    let rest = Array(path.dropFirst())

    if var object = container.objectValue {
        if rest.isEmpty {
            object[key] = newValue
        } else {
            let child = try #require(object[key], "path \(path) has no key \(key)")
            object[key] = try mutating(child, at: rest, with: newValue)
        }
        return .object(object)
    }

    var array = try #require(container.arrayValue, "path \(path) does not name an object or an array")
    let index = try #require(Int(key), "path \(path) needs an array index, not \(key)")
    array[index] = try mutating(array[index], at: rest, with: newValue)
    return .array(array)
}

/// A captured frame, decoded after one edit.
func capturedMuxFrame(_ name: String, at path: [String], with newValue: JSONValue?) throws -> MuxFrame {
    let edited = try mutating(.object(try muxFrameObject(name)), at: path, with: newValue)
    return try JSONDecoder().decode(MuxFrame.self, from: JSONEncoder().encode(edited))
}

/// The eight durable-event frame names in the capture.
let durableEventFrameNames = [
    "event/agent/inbox/spliced",
    "event/turn/start",
    "event/step/start",
    "event/user/message",
    "event/session-log-deepseek/delivery-accepted",
    "event/assistant/message",
    "event/step/end",
    "event/turn/end",
]

/// The three live assistant-stream frame names in the capture.
let assistantStreamFrameNames = [
    "assistant-stream/start",
    "assistant-stream/chunk",
    "assistant-stream/end",
]

@Test("the capture holds twelve frames and every one is an item")
func muxFrameSetIsComplete() throws {
    let frames = try muxFrameObjects()

    #expect(frames.count == 12)
    #expect(
        Set(frames.keys)
            == Set(["snapshot"] + durableEventFrameNames + assistantStreamFrameNames)
    )

    for name in frames.keys {
        let frame = try capturedMuxFrame(name)
        #expect(frame.type == .item, "\(name)")
        #expect(frame.value != nil, "\(name) had no value")
        // Opaque per SPEC §5, and redacted in the capture: presence is all that is asserted.
        #expect(frame.streamId != nil, "\(name)")
        // Nothing beside `type`, `streamId`, and `value` is left over, so no wire field is
        // being silently dropped or invented.
        #expect(frame.unknownFields.isEmpty, "\(name) left keys unmodelled: \(frame.unknownFields.keys)")
    }

    // The captured keys, verbatim.
    #expect(Set(try muxFrameObject("snapshot").keys) == ["type", "streamId", "value"])
}

@Test("the follow snapshot decodes its header, cursor, records, and paging flag")
func snapshotDecodes() throws {
    let frame = try capturedMuxFrame("snapshot")
    #expect(frame.type == .item)

    let value = try #require(frame.value)
    #expect(value.typeName == "snapshot")
    let snapshot = try #require(value.snapshot)

    // `header.version` is the harness format generation, and `cursor` the opening watermark
    // SPEC §6.5 says to keep with this follow generation.
    #expect(snapshot.header.version == 4)
    #expect(snapshot.cursor == 31)
    #expect(snapshot.hasMore == false)

    #expect(snapshot.records.count == 2)
    #expect(snapshot.records.map(\.type) == [.event, .event])
    #expect(snapshot.records.map { $0.event?.type } == ["permission/preset", "sandbox/mode"])
    #expect(snapshot.records.map { $0.event?.seq } == [0, 1] as [Int64?])
    #expect(snapshot.records.allSatisfy { $0.event?.time != nil })

    // The projection watermark, and the optional live baseline the first stream frame
    // continues from.
    #expect(snapshot.projections?.asOfSeq == 31)
    #expect(snapshot.projections?.values != nil)
    #expect(snapshot.assistantStream?.revision == 18)

    // The header's opaque host fields are present but never interpreted.
    #expect(snapshot.header.id != nil)
    #expect(snapshot.header.cwd != nil)
}

@Test("every durable event frame carries its type and sequence number")
func durableEventFramesDecode() throws {
    let expected: [String: (type: String, seq: Int64)] = [
        "event/agent/inbox/spliced": ("agent/inbox/spliced", 32),
        "event/turn/start": ("turn/start", 33),
        "event/step/start": ("step/start", 35),
        "event/user/message": ("user/message", 36),
        "event/session-log-deepseek/delivery-accepted": ("session-log-deepseek/delivery-accepted", 37),
        "event/assistant/message": ("assistant/message", 38),
        "event/step/end": ("step/end", 39),
        "event/turn/end": ("turn/end", 40),
    ]

    var seqs: [Int64] = []
    for (name, want) in expected {
        let value = try #require(try capturedMuxFrame(name).value)
        #expect(value.typeName == "event", "\(name)")

        let event = try #require(value.event, "\(name)")
        #expect(event.type == want.type, "\(name)")
        #expect(event.seq == want.seq, "\(name)")
        #expect(event.time != nil, "\(name)")
        #expect(!event.data.isNull, "\(name)")
        seqs.append(event.seq)
    }

    // Ascending and unique: the capture is one generation's ordered replay, with 34 outside
    // this fixture set rather than missing from the stream.
    #expect(seqs.sorted() == [32, 33, 35, 36, 37, 38, 39, 40])
    #expect(Set(seqs).count == seqs.count)
    #expect(expected.count == durableEventFrameNames.count)
}

@Test("event payloads stay lossless, so per-type fields survive untyped")
func eventDataIsLossless() throws {
    // Each of these lives under `data`, whose shape differs per event type — the reason
    // `data` is JSONValue rather than a typed struct.
    let turnStart = try #require(try capturedMuxFrame("event/turn/start").value?.event)
    #expect(turnStart.data["turn"]?.intValue == 3)

    let stepStart = try #require(try capturedMuxFrame("event/step/start").value?.event)
    #expect(stepStart.data["turn"]?.intValue == 3)
    #expect(stepStart.data["step"]?.intValue == 1)

    let stepEnd = try #require(try capturedMuxFrame("event/step/end").value?.event)
    #expect(stepEnd.data["step"]?.intValue == 1)

    let turnEnd = try #require(try capturedMuxFrame("event/turn/end").value?.event)
    #expect(turnEnd.data["turn"]?.intValue == 3)
    #expect(turnEnd.data["reason"]?["kind"]?.stringValue == "completed")

    let assistant = try #require(try capturedMuxFrame("event/assistant/message").value?.event)
    #expect(assistant.data["turn"]?.intValue == 3)
    #expect(assistant.data["step"]?.intValue == 1)
    #expect(assistant.data["usage"]?["outputTokens"]?.intValue == 3)
    // `stream[]` is the same chunk vocabulary the live frames use, one step later.
    #expect(assistant.data["stream"]?.arrayValue?.count == 2)
    #expect(assistant.data["stream"]?[1]?["chunk"]?["type"]?.stringValue == "block-end")

    // `surfaceOp` is modelled, and present on exactly the two message events.
    #expect(assistant.surfaceOp != nil)
    #expect(try #require(try capturedMuxFrame("event/user/message").value?.event).surfaceOp != nil)
    #expect(turnStart.surfaceOp == nil)
}

@Test("the live assistant stream frames carry their sequencing fields")
func assistantStreamFramesDecode() throws {
    let startValue = try #require(try capturedMuxFrame("assistant-stream/start").value)
    #expect(startValue.typeName == "assistant-stream")
    let start = try #require(startValue.assistantStream)
    #expect(start.type == .start)
    #expect(start.revision == 19)
    #expect(start.turn == 3)
    #expect(start.step == 1)
    #expect(start.startedAfterSeq == 36)
    #expect(start.attemptId != nil)
    #expect(start.index == nil)
    #expect(start.outcome == nil)

    let chunkValue = try #require(try capturedMuxFrame("assistant-stream/chunk").value)
    #expect(chunkValue.typeName == "assistant-stream")
    let chunk = try #require(chunkValue.assistantStream)
    #expect(chunk.type == .chunk)
    #expect(chunk.revision == 20)
    #expect(chunk.index == 0)
    #expect(chunk.attemptId != nil)
    #expect(chunk.time != nil)
    let body = try #require(chunk.chunk)
    #expect(body.type == .blockStart)
    #expect(body.index == 0)
    #expect(body.blockType != nil)

    let endValue = try #require(try capturedMuxFrame("assistant-stream/end").value)
    #expect(endValue.typeName == "assistant-stream")
    let end = try #require(endValue.assistantStream)
    #expect(end.type == .end)
    #expect(end.revision == 28)
    #expect(end.index == 8)
    #expect(end.attemptId != nil)
    #expect(end.chunk == nil)

    // Revisions only move forward within one attempt.
    #expect([start, chunk, end].compactMap(\.revision) == [19, 20, 28])
    #expect(Set([start, chunk, end].compactMap(\.attemptId)).count == 1)
}

@Test("a committed outcome ties the provisional stream to the durable event that replaced it")
func committedOutcomePointsAtDurableEvent() throws {
    let end = try #require(try capturedMuxFrame("assistant-stream/end").value?.assistantStream)
    let outcome = try #require(end.outcome)

    #expect(outcome.kind == .committed)
    // Redacted on the wire, so only presence is asserted; the durable `seq` is the tie.
    #expect(outcome.eventType != nil)

    let durable = try #require(try capturedMuxFrame("event/assistant/message").value?.event)
    #expect(outcome.seq == durable.seq)
    #expect(durable.seq == 38)
}

@Test("an unknown frame type decodes with its value intact")
func unknownFrameTypeIsTolerated() throws {
    let frame = try capturedMuxFrame("event/turn/start", at: ["type"], with: .string("close"))

    #expect(frame.type == .unknown("close"))
    #expect(frame.type.rawValue == "close")
    #expect(try #require(frame.value).event?.seq == 33)
}

@Test("an unknown value type is kept whole instead of failing the item")
func unknownValueTypeIsTolerated() throws {
    let frame = try capturedMuxFrame("snapshot", at: ["value", "type"], with: .string("snapshot-v5"))
    let value = try #require(frame.value)

    #expect(value.typeName == "snapshot-v5")
    #expect(value.snapshot == nil)
    guard case .unknown(let type, let raw) = value else {
        Issue.record("expected the unknown case, got \(value.typeName)")
        return
    }
    #expect(type == "snapshot-v5")
    #expect(raw["cursor"]?.intValue == 31)
    #expect(raw["records"]?.arrayValue?.count == 2)
}

@Test("unknown event, record, chunk, and outcome kinds all decode")
func unknownWireVocabularyIsTolerated() throws {
    // An event type no build has a case for, with its payload and sequence intact.
    let event = try #require(
        try capturedMuxFrame("event/turn/start", at: ["value", "event", "type"], with: .string("future/thing"))
            .value?.event
    )
    #expect(event.type == "future/thing")
    #expect(event.seq == 33)
    #expect(event.data["turn"]?.intValue == 3)

    // A snapshot record kind the client does not know.
    let record = try #require(
        try capturedMuxFrame("snapshot", at: ["value", "records", "0", "type"], with: .string("projection"))
            .value?.snapshot?.records.first
    )
    #expect(record.type == .unknown("projection"))
    #expect(record.event?.seq == 0)

    // A stream frame kind the client does not know still exposes its revision.
    let frame = try #require(
        try capturedMuxFrame("assistant-stream/chunk", at: ["value", "frame", "type"], with: .string("tool-preview"))
            .value?.assistantStream
    )
    #expect(frame.type == .unknown("tool-preview"))
    #expect(frame.revision == 20)
    #expect(frame.index == 0)

    // A chunk kind the client does not know.
    let chunk = try #require(
        try capturedMuxFrame("assistant-stream/chunk", at: ["value", "frame", "chunk", "type"], with: .string("block-delta"))
            .value?.assistantStream?.chunk
    )
    #expect(chunk.type == .unknown("block-delta"))
    #expect(chunk.index == 0)

    // An outcome kind other than `committed`, which SPEC §6.5 implies exists on a gap.
    let outcome = try #require(
        try capturedMuxFrame("assistant-stream/end", at: ["value", "frame", "outcome", "kind"], with: .string("abandoned"))
            .value?.assistantStream?.outcome
    )
    #expect(outcome.kind == .unknown("abandoned"))
    #expect(outcome.seq == 38)
}

@Test("a non-string discriminant is a decode failure, not an unknown value")
func nonStringDiscriminantsFailToDecode() throws {
    // An unknown *value* is tolerated; a wrong *kind* leaves the union unclassifiable, which
    // SPEC §6.9 treats as a protocol incompatibility.
    #expect(throws: (any Error).self) {
        try capturedMuxFrame("snapshot", at: ["type"], with: .int(7))
    }
    #expect(throws: (any Error).self) {
        try capturedMuxFrame("snapshot", at: ["value", "type"], with: .int(7))
    }
    #expect(throws: (any Error).self) {
        try capturedMuxFrame("event/turn/start", at: ["value", "event", "type"], with: .array([.int(1)]))
    }
    #expect(throws: (any Error).self) {
        try capturedMuxFrame("snapshot", at: ["value", "records", "0", "type"], with: .bool(true))
    }
}

@Test("a frame missing its optional fields still decodes")
func absentOptionalFieldsDecode() throws {
    // `surfaceOp` is on two of the ten captured events only.
    let event = try #require(
        try capturedMuxFrame("event/user/message", at: ["value", "event", "surfaceOp"], with: nil).value?.event
    )
    #expect(event.surfaceOp == nil)
    #expect(event.seq == 36)

    // A snapshot with no live assistant baseline (SPEC §6.5 calls it optional) and no
    // projections.
    let stripped = try mutating(
        .object(try muxFrameObject("snapshot")),
        at: ["value", "assistantStream"],
        with: nil
    )
    let withoutBaseline = try mutating(stripped, at: ["value", "projections"], with: nil)
    let snapshot = try #require(
        try JSONDecoder().decode(MuxFrame.self, from: JSONEncoder().encode(withoutBaseline))
            .value?.snapshot
    )
    #expect(snapshot.assistantStream == nil)
    #expect(snapshot.projections == nil)
    #expect(snapshot.cursor == 31)

    // A stream frame without attempt identity or a timestamp.
    let frame = try #require(
        try capturedMuxFrame("assistant-stream/chunk", at: ["value", "frame", "attemptId"], with: nil)
            .value?.assistantStream
    )
    #expect(frame.attemptId == nil)
    #expect(frame.revision == 20)
    #expect(frame.index == 0)
}

@Test("keys this build does not model are preserved rather than dropped")
func unmodelledFrameKeysArePreserved() throws {
    // The `error` and `end` frames are named by SPEC §6.4 and captured nowhere, so their
    // payload keys are unknown. Whatever they turn out to be must survive decoding, and
    // survive a re-encode, for SPEC §6.9 to present them.
    let payload: JSONValue = .object([
        "code": .string("gateway/stream-refused"),
        "details": .object(["streamId": .string("1")]),
    ])
    let frame = try JSONDecoder().decode(
        MuxFrame.self,
        from: JSONEncoder().encode(try mutating(
            .object(try muxFrameObject("event/turn/start")),
            at: ["error"],
            with: payload
        ))
    )

    #expect(frame.unknownFields.keys.sorted() == ["error"])
    #expect(frame.unknownFields["error"] == payload)
    #expect(try #require(frame.value).event?.seq == 33)

    let reEncoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(frame))
    #expect(reEncoded["error"] == payload)
    #expect(reEncoded["type"]?.stringValue == "item")
}

/// Removes every object entry whose value is an explicit JSON `null`.
///
/// ``SessionProjectionValues`` cannot tell an absent key from an explicit `null` (README:
/// "Absent versus JSON `null` is not distinguishable"), so re-encoding a decoded snapshot
/// omits the `goal`, `todos`, and `subagent` nulls the capture carries. Both sides of the
/// snapshot comparison below are normalised the same way; every other frame round-trips
/// exactly.
func droppingNulls(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let object):
        .object(object.compactMapValues { $0.isNull ? nil : droppingNulls($0) })
    case .array(let array):
        .array(array.map(droppingNulls))
    default:
        value
    }
}

@Test("every captured frame re-encodes to exactly the captured JSON")
func capturedFramesRoundTrip() throws {
    let captured = try muxFrameObjects()

    for (name, original) in captured {
        let decoded = try JSONDecoder().decode(MuxFrame.self, from: Fixtures.encode(object: try muxFrameObject(name)))
        let reEncoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded))

        // Nothing modelled is lost and nothing unmodelled is invented: the capture and the
        // re-encode have to be equal objects, key for key and type for type.
        if name == "snapshot" {
            // The one exception is the typed projection's explicit nulls; see `droppingNulls`.
            #expect(droppingNulls(reEncoded) == droppingNulls(original), "\(name) did not round-trip")
        } else {
            #expect(reEncoded == original, "\(name) did not round-trip")
        }
    }

    #expect(captured.count == 12)
}

@Test("a frame decoded by hand matches the capture's own shape")
func handBuiltFrameEncodesToCapturedShape() throws {
    // Round-tripping is the only encoding the app does with item frames (it never writes
    // one), so this pins the flat union the decoder expects back.
    let frame = MuxFrame(
        type: .item,
        streamId: "1",
        value: .assistantStream(AssistantStreamFrame(
            type: .start,
            attemptId: "a",
            revision: 19,
            turn: 3,
            step: 1,
            startedAfterSeq: 36
        ))
    )
    let object = try #require(
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(frame)).objectValue
    )

    #expect(object["type"]?.stringValue == "item")
    #expect(object["streamId"]?.stringValue == "1")
    #expect(object["value"]?["type"]?.stringValue == "assistant-stream")
    #expect(object["value"]?["frame"]?["type"]?.stringValue == "start")
    #expect(object["value"]?["frame"]?["startedAfterSeq"]?.intValue == 36)
}
