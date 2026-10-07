import Foundation

// Server frames on the `/api/remote.mux` socket, as established by
// `Fixtures/mux-stream-frames.json`: twelve frames captured live from harness `0.2.0-rc.2`
// through the relay, on `session/follow` with `assistantStream: true`, while one prompt ran.
// Strings in that capture are redacted except the wire vocabulary, so these types encode
// shape and ordering only — never prose.
//
// Presence policy, applied throughout: a field is required only where the capture proves it
// and the client cannot work without it. Every other field is optional, and a field whose
// *shape* the capture does not establish is `JSONValue`, marked `// unverified`. Every
// discriminator that the capture shows as a string — frame type, value type, event type,
// record type, chunk type, outcome kind — is an open-ended string that decodes to an
// `unknown` case instead of failing (SPEC §5, SPEC §6.5).

// MARK: - Frame envelope

/// The `type` of a server frame on the multiplexed socket (SPEC §6.4: "Server frames are
/// `item`, `error`, or `end`, scoped by stream ID").
///
/// Only `item` is captured. `error` and `end` are named by SPEC §6.4 and appear in no
/// capture, so decoding them through ``unknown(_:)`` keeps a frame this build cannot
/// classify readable rather than fatal.
public enum MuxFrameType: Hashable, Sendable {
    case item
    case error
    case end
    case unknown(String)

    public static let itemRawValue = "item"
    public static let errorRawValue = "error"
    public static let endRawValue = "end"

    public var rawValue: String {
        switch self {
        case .item: Self.itemRawValue
        case .error: Self.errorRawValue
        case .end: Self.endRawValue
        case .unknown(let value): value
        }
    }

    /// Never fails: an unrecognised string becomes ``unknown(_:)``.
    public init(rawValue: String) {
        switch rawValue {
        case Self.itemRawValue: self = .item
        case Self.errorRawValue: self = .error
        case Self.endRawValue: self = .end
        default: self = .unknown(rawValue)
        }
    }
}

extension MuxFrameType: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MuxFrameType(rawValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One server frame on `remote.mux`: `{type, streamId, value}`.
///
/// The capture has exactly those three keys on all twelve frames, and every one of them is
/// an `item` whose `value` is the discriminated union of ``MuxFrameValue``.
public struct MuxFrame: Codable, Sendable, Hashable {
    public var type: MuxFrameType

    /// The logical stream this frame belongs to, as chosen by the client when it opened the
    /// stream. Opaque string (SPEC §5).
    ///
    /// unverified: every captured frame is an `item`; nothing shows whether an `error` or
    /// `end` frame carries a stream ID, so its absence is tolerated.
    public var streamId: String?

    /// The frame body on an `item`. Absent — or shaped differently — on `error` and `end`.
    public var value: MuxFrameValue?

    /// Any other key the host sent, kept losslessly.
    ///
    /// unverified: an `error` or `end` frame's payload keys are unknown because neither
    /// kind was captured. Rather than invent one, anything beside `type`, `streamId`, and
    /// `value` is preserved here, so SPEC §6.9 can still show an error's contents. Empty for
    /// every captured frame.
    public var unknownFields: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case type
        case streamId
        case value
    }

    public init(
        type: MuxFrameType,
        streamId: String? = nil,
        value: MuxFrameValue? = nil,
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.type = type
        self.streamId = streamId
        self.value = value
        self.unknownFields = unknownFields
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(MuxFrameType.self, forKey: .type)
        streamId = try container.decodeIfPresent(String.self, forKey: .streamId)
        value = try container.decodeIfPresent(MuxFrameValue.self, forKey: .value)

        // Re-read the same object losslessly to keep keys this build does not model.
        let raw = try decoder.container(keyedBy: DynamicKey.self)
        var extras: [String: JSONValue] = [:]
        for key in raw.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try raw.decode(JSONValue.self, forKey: key)
        }
        unknownFields = extras
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(type.rawValue, forKey: DynamicKey(CodingKeys.type.rawValue))
        if let streamId {
            try container.encode(streamId, forKey: DynamicKey(CodingKeys.streamId.rawValue))
        }
        if let value {
            try container.encode(value, forKey: DynamicKey(CodingKeys.value.rawValue))
        }
        for (key, extra) in unknownFields {
            try container.encode(extra, forKey: DynamicKey(key))
        }
    }

    private static let knownKeys: Set<String> = [
        CodingKeys.type.rawValue,
        CodingKeys.streamId.rawValue,
        CodingKeys.value.rawValue,
    ]
}

// MARK: - The item value union

/// The `value` object of an `item` frame, discriminated by its own `type` (SPEC §6.4).
///
/// | `value.type` | captured | case |
/// |---|---|---|
/// | `snapshot` | yes | ``snapshot(_:)`` — the follow baseline |
/// | `event` | yes | ``event(_:)`` — one durable event |
/// | `assistant-stream` | yes | ``assistantStream(_:)`` — one live stream frame |
/// | anything else | no | ``unknown(type:value:)`` |
public enum MuxFrameValue: Sendable, Hashable {
    /// The `session/follow` baseline. Its own fields sit directly beside `type`.
    case snapshot(MuxSnapshot)
    /// A durable event, nested under `value.event`.
    case event(DurableEventEnvelope)
    /// One live assistant-stream frame, nested under `value.frame`.
    case assistantStream(AssistantStreamFrame)
    /// A `value.type` this build does not know, kept whole — `type` included — so nothing the
    /// host sent is dropped and no field is guessed.
    case unknown(type: String, value: JSONValue)

    public static let snapshotRawValue = "snapshot"
    public static let eventRawValue = "event"
    public static let assistantStreamRawValue = "assistant-stream"

    /// The wire discriminator, verbatim.
    public var typeName: String {
        switch self {
        case .snapshot: Self.snapshotRawValue
        case .event: Self.eventRawValue
        case .assistantStream: Self.assistantStreamRawValue
        case .unknown(let type, _): type
        }
    }

    public var snapshot: MuxSnapshot? {
        if case .snapshot(let value) = self { value } else { nil }
    }

    public var event: DurableEventEnvelope? {
        if case .event(let value) = self { value } else { nil }
    }

    public var assistantStream: AssistantStreamFrame? {
        if case .assistantStream(let value) = self { value } else { nil }
    }
}

extension MuxFrameValue: Codable {
    enum CodingKeys: String, CodingKey {
        case type
        case event
        case frame
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A non-string `type` is a hard failure, not an unknown value: without a
        // discriminator the union cannot be classified at all (SPEC §6.9).
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case Self.snapshotRawValue:
            // The snapshot's own fields are flattened into this same object, so it decodes
            // from `decoder` rather than from a nested key.
            self = .snapshot(try MuxSnapshot(from: decoder))
        case Self.eventRawValue:
            self = .event(try container.decode(DurableEventEnvelope.self, forKey: .event))
        case Self.assistantStreamRawValue:
            self = .assistantStream(try container.decode(AssistantStreamFrame.self, forKey: .frame))
        default:
            self = .unknown(type: type, value: try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .snapshot(let snapshot):
            // Flattened: the snapshot's keys go beside `type`, not under a `snapshot` key.
            var object = try Self.jsonValue(snapshot).objectValue ?? [:]
            object[CodingKeys.type.rawValue] = .string(Self.snapshotRawValue)
            try container.encode(JSONValue.object(object))
        case .event(let event):
            try container.encode(JSONValue.object([
                CodingKeys.type.rawValue: .string(Self.eventRawValue),
                CodingKeys.event.rawValue: try Self.jsonValue(event),
            ]))
        case .assistantStream(let frame):
            try container.encode(JSONValue.object([
                CodingKeys.type.rawValue: .string(Self.assistantStreamRawValue),
                CodingKeys.frame.rawValue: try Self.jsonValue(frame),
            ]))
        case .unknown(_, let value):
            // Stored whole, discriminator included, so this re-encodes verbatim.
            try container.encode(value)
        }
    }

    /// Encodes a modelled value back to ``JSONValue`` for the flattened cases above.
    ///
    /// Only the fields this build models survive; a key the host added that no type here
    /// covers is dropped by a re-encode. Nothing in the app writes item frames — decoding is
    /// the whole contract — so this exists for round-trip tests and diagnostics.
    private static func jsonValue(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

// MARK: - Snapshot

/// The `session/follow` baseline (SPEC §6.5: "establishes a complete snapshot and optional
/// live assistant baseline").
public struct MuxSnapshot: Codable, Sendable, Hashable {
    public var header: MuxSnapshotHeader
    /// The opening cursor to store for paging (`session/page` must use this generation's
    /// watermark, never an older one — SPEC §6.5).
    public var cursor: Int64
    /// Durable records replayed up to `cursor`.
    public var records: [MuxSnapshotRecord]
    /// Whether more records exist behind `cursor`.
    public var hasMore: Bool
    /// The projected state as of `cursor`. Same `{kind?, asOfSeq, values}` wrapper as a
    /// `session/list` row, so ``SessionProjections`` models both.
    ///
    /// Re-encoding a decoded snapshot drops explicit JSON nulls inside `values` — the capture
    /// carries `goal`, `todos`, and `subagent` as `null`, and a typed projection cannot tell a
    /// null from an absent key. Same limitation the README already records for `session/list`.
    /// Decoding keeps every null, so this costs the read path nothing.
    public var projections: SessionProjections?
    /// The live assistant baseline, `{revision: 18}` in the capture — the revision the first
    /// stream frame continues from.
    ///
    /// unverified: SPEC §6.5 calls the live baseline optional and this is the only capture of
    /// one; whether the host ever omits the object, or adds fields to it, is unknown.
    public var assistantStream: MuxAssistantStreamBaseline?
}

/// The `header` of a snapshot.
///
/// `version` is required: the harness generation a snapshot came from is what SPEC §6.1
/// gates compatibility on. The rest are optional because the capture is a single snapshot,
/// and a host that leaves one out must not kill the socket (SPEC §5). `id`, `cwd`, and
/// `agentPreset` are opaque strings — no workspace or preset semantics are derived here.
public struct MuxSnapshotHeader: Codable, Sendable, Hashable {
    /// Session format version; `4` in the capture.
    public var version: Int
    /// Host session ID. Opaque string.
    public var id: String?
    /// Epoch milliseconds.
    public var createdAt: Int64?
    public var cwd: String?
    public var isSeeded: Bool?
    public var agentPreset: String?

    enum CodingKeys: String, CodingKey {
        case version
        case id
        case createdAt
        case cwd
        case isSeeded
        case agentPreset
    }

    public init(
        version: Int,
        id: String? = nil,
        createdAt: Int64? = nil,
        cwd: String? = nil,
        isSeeded: Bool? = nil,
        agentPreset: String? = nil
    ) {
        self.version = version
        self.id = id
        self.createdAt = createdAt
        self.cwd = cwd
        self.isSeeded = isSeeded
        self.agentPreset = agentPreset
    }
}

/// The live assistant baseline inside a snapshot: `{revision: 18}`.
///
/// unverified: `revision` is the only key the capture shows; whether a baseline can also
/// carry attempt identity, a partial chunk list, or nothing at all is unknown, so every field
/// is optional.
public struct MuxAssistantStreamBaseline: Codable, Sendable, Hashable {
    /// The revision a following ``AssistantStreamFrame`` continues from.
    public var revision: Int64?
}

/// One entry of a snapshot's `records` array: `{type, event}`.
public struct MuxSnapshotRecord: Codable, Sendable, Hashable {
    /// `event` is the only captured value. The field is a string rather than an enum member
    /// because a snapshot could replay kinds of record this build has no case for.
    public var type: MuxSnapshotRecordType
    /// The durable event. Optional so a record whose `type` this build does not know — and
    /// which therefore may not even hold an `event` — still decodes.
    public var event: DurableEventEnvelope?
}

/// The `type` discriminator on a snapshot record.
public enum MuxSnapshotRecordType: Hashable, Sendable {
    case event
    case unknown(String)

    public static let eventRawValue = "event"

    public var rawValue: String {
        switch self {
        case .event: Self.eventRawValue
        case .unknown(let value): value
        }
    }

    /// Never fails: an unrecognised string becomes ``unknown(_:)``.
    public init(rawValue: String) {
        switch rawValue {
        case Self.eventRawValue: self = .event
        default: self = .unknown(rawValue)
        }
    }
}

extension MuxSnapshotRecordType: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MuxSnapshotRecordType(rawValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Durable events

/// The `event` object of an `event` item frame, and of every replay record in a snapshot:
/// `{type, seq, time, data}`.
///
/// One envelope covers every event type. `data` stays ``JSONValue`` on purpose: its shape
/// differs per `type`, so typing it would mean guessing schemas the capture does not show
/// (SPEC §6.1, SPEC §6.5 "Maintain durable history separately from transient assistant
/// chunks").
public struct DurableEventEnvelope: Codable, Sendable, Hashable {
    /// An open-ended namespaced string. Captured: `permission/preset`, `sandbox/mode`,
    /// `agent/inbox/spliced`, `turn/start`, `step/start`, `user/message`,
    /// `session-log-deepseek/delivery-accepted`, `assistant/message`, `step/end`, `turn/end`.
    /// Known names get no Swift case — nothing in SPEC §4 needs to branch on them yet, and an
    /// unlisted one must stay readable (SPEC §5).
    public var type: String
    /// The ordering authority for durable state, unique and ascending within a capture. The
    /// fixture holds one frame per kind, so its seqs are not contiguous — 34 is simply not
    /// represented here, which says nothing about whether the live stream skipped it.
    public var seq: Int64
    /// Epoch milliseconds.
    ///
    /// Optional because `seq` alone orders the stream, so a missing timestamp must not cost
    /// the client an event.
    public var time: Int64?
    /// The event payload, lossless and untrusted in shape.
    public var data: JSONValue
    /// Present on `user/message` and `assistant/message` in the capture and absent elsewhere.
    ///
    /// unverified: only those two show it, and it is redacted there, so whether other event
    /// types carry it and what its values mean is unknown. Opaque string.
    public var surfaceOp: String?
}

// MARK: - Live assistant stream

/// One frame of the live assistant stream, `value.frame` of an `assistant-stream` item.
///
/// The three captured frames all share one flat shape and differ in which keys they carry:
/// `start` has `turn`, `step`, and `startedAfterSeq`; `chunk` has `index` and `chunk`; `end`
/// has `index` and `outcome`. Everything but `type` is therefore optional — a future frame
/// kind (an abort, a heartbeat) must decode with whatever subset it carries rather than
/// failing the stream (SPEC §6.5, "detect stale, duplicate, or gapped live frames").
public struct AssistantStreamFrame: Codable, Sendable, Hashable {
    public var type: AssistantStreamFrameType
    /// Attempt identity. Changes when the host retries the same step; a frame carrying an
    /// older attempt must not be merged into the current preview (SPEC §6.5).
    ///
    /// unverified: captured on all three frames, redacted, and never shown absent; optional
    /// so an unclassified frame kind still decodes.
    public var attemptId: String?
    /// Monotonic within an attempt. The capture runs 19 (start), 20 (chunk), 28 (end).
    public var revision: Int64?
    /// Set on `start` only.
    public var turn: Int64?
    /// Set on `start` only.
    public var step: Int64?
    /// Set on `start` only: the durable `seq` the stream begins after, so a client can tell
    /// whether its preview started from the baseline it holds.
    public var startedAfterSeq: Int64?
    /// Set on `chunk` and `end`. `0` on the captured `chunk` and `8` on the captured `end`,
    /// so on `end` it is the ordinal of the last chunk of the attempt rather than a count.
    public var index: Int64?
    /// Epoch milliseconds. Set on `chunk` in the capture and on neither of the other two
    /// frames.
    public var time: Int64?
    /// Set on `chunk` only.
    public var chunk: AssistantStreamChunkBody?
    /// Set on `end` only: how the provisional stream was retired.
    public var outcome: AssistantStreamOutcome?
}

/// The `type` discriminator on an assistant-stream frame.
public enum AssistantStreamFrameType: Hashable, Sendable {
    case start
    case chunk
    case end
    case unknown(String)

    public static let startRawValue = "start"
    public static let chunkRawValue = "chunk"
    public static let endRawValue = "end"

    public var rawValue: String {
        switch self {
        case .start: Self.startRawValue
        case .chunk: Self.chunkRawValue
        case .end: Self.endRawValue
        case .unknown(let value): value
        }
    }

    /// Never fails: an unrecognised string becomes ``unknown(_:)``.
    public init(rawValue: String) {
        switch rawValue {
        case Self.startRawValue: self = .start
        case Self.chunkRawValue: self = .chunk
        case Self.endRawValue: self = .end
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantStreamFrameType: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AssistantStreamFrameType(rawValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The nested `chunk` object of a `chunk` frame — itself a union discriminated by its own
/// `type`.
///
/// Only `block-start` is captured on a live frame. `block-end` is captured, with the same
/// `index` plus its finished `block`, inside the durable `assistant/message` event's `stream`
/// array — the same shapes one step later — so both are named here.
public struct AssistantStreamChunkBody: Codable, Sendable, Hashable {
    public var type: AssistantStreamChunkType
    /// Which content block of the message this chunk belongs to; `0` for the first.
    ///
    /// unverified: present as `0` on both captured chunk shapes; whether a chunk can omit it
    /// is unknown. Optional so an unknown chunk kind still decodes.
    public var index: Int64?
    /// Present on `block-start`.
    ///
    /// unverified: redacted in the capture, so the set of block types is unknown. Opaque
    /// string — `reasoning` and `text` are the two that appear as finished blocks in
    /// `assistant/message.data.message.content`, but nothing proves this field uses those
    /// names.
    public var blockType: String?
    /// Present on `block-end`, which is only captured inside `assistant/message.data.stream`.
    ///
    /// unverified: never seen on a live chunk frame; kept as ``JSONValue`` because the block
    /// shape differs per block type and the capture proves only `{"type":"reasoning","text":…}`.
    public var block: JSONValue?
}

/// The `type` discriminator on an assistant-stream chunk body.
public enum AssistantStreamChunkType: Hashable, Sendable {
    case blockStart
    case blockEnd
    case unknown(String)

    public static let blockStartRawValue = "block-start"
    public static let blockEndRawValue = "block-end"

    public var rawValue: String {
        switch self {
        case .blockStart: Self.blockStartRawValue
        case .blockEnd: Self.blockEndRawValue
        case .unknown(let value): value
        }
    }

    /// Never fails: an unrecognised string becomes ``unknown(_:)``.
    public init(rawValue: String) {
        switch rawValue {
        case Self.blockStartRawValue: self = .blockStart
        case Self.blockEndRawValue: self = .blockEnd
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantStreamChunkType: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AssistantStreamChunkType(rawValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The `outcome` object of an `end` frame: how the provisional stream was retired.
///
/// `{kind: "committed", eventType: <redacted>, seq: 38}` in the capture, where `seq` is the
/// durable `assistant/message` event that replaced the stream (SPEC §6.5: "On settlement,
/// retire the matching provisional response and show the durable result exactly once").
public struct AssistantStreamOutcome: Codable, Sendable, Hashable {
    public var kind: AssistantStreamOutcomeKind
    /// The durable event type that replaced the stream.
    ///
    /// unverified: redacted in the capture, so the string is opaque; `committed` in the one
    /// captured outcome means a `seq` exists to point at, but another kind may name an event
    /// type with no sequence number behind it, or none at all.
    public var eventType: String?
    /// Durable `seq` of that event. Optional for the same reason as `eventType`.
    public var seq: Int64?
}

/// The `kind` discriminator on an assistant-stream outcome.
///
/// Only `committed` is captured. SPEC §6.5 requires the client to drop an invalid preview and
/// recover on a gap, which implies at least one non-committing outcome exists — but no
/// capture names one, so none is invented here.
public enum AssistantStreamOutcomeKind: Hashable, Sendable {
    case committed
    case unknown(String)

    public static let committedRawValue = "committed"

    public var rawValue: String {
        switch self {
        case .committed: Self.committedRawValue
        case .unknown(let value): value
        }
    }

    /// Never fails: an unrecognised string becomes ``unknown(_:)``.
    public init(rawValue: String) {
        switch rawValue {
        case Self.committedRawValue: self = .committed
        default: self = .unknown(rawValue)
        }
    }
}

extension AssistantStreamOutcomeKind: Codable {
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AssistantStreamOutcomeKind(rawValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
