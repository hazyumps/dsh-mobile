import Foundation

/// One row of `session/list` (`Fixtures/rpc-response-session-list.json`).
///
/// The item's keys in the capture are exactly `agentAvailable`, `blank`, `cwd`,
/// `projections`, `running`, `sessionId`, `updatedAt`. Only `sessionId` is required:
/// SPEC §3.3 wants status "when known" and last activity "when supplied", and SPEC §5
/// treats everything else as available metadata, so a host that omits a field must not
/// break the whole list.
public struct SessionSummary: Codable, Sendable, Hashable {
    /// Host session ID. Opaque string (SPEC §5).
    public var sessionId: String
    /// Last activity in epoch milliseconds. Same unit as `updatedAt` in the capture.
    public var updatedAt: Int64?
    public var agentAvailable: Bool?
    /// Whether the session is executing. `false` is not the same as "waiting" —
    /// unverified: the capture has no waiting flag.
    public var running: Bool?
    /// A session with no user prompt yet. Also mirrored inside
    /// ``SessionListMetadata/blank``; the capture has both and does not say which is
    /// authoritative.
    public var blank: Bool?
    /// Working directory of the session on the host.
    ///
    /// unverified: SPEC §3.3 groups sessions by the host's workspace registry, and no
    /// capture shows how `cwd` maps to a workspace ID, so this is kept as the raw
    /// string and nothing is derived from it.
    public var cwd: String?
    public var projections: SessionProjections?

    enum CodingKeys: String, CodingKey {
        case agentAvailable
        case blank
        case cwd
        case projections
        case running
        case sessionId
        case updatedAt
    }

    public init(
        sessionId: String,
        updatedAt: Int64? = nil,
        agentAvailable: Bool? = nil,
        running: Bool? = nil,
        blank: Bool? = nil,
        cwd: String? = nil,
        projections: SessionProjections? = nil
    ) {
        self.sessionId = sessionId
        self.updatedAt = updatedAt
        self.agentAvailable = agentAvailable
        self.running = running
        self.blank = blank
        self.cwd = cwd
        self.projections = projections
    }

    /// Convenience path to the projected title, which is the label SPEC §3.3 shows.
    public var title: String? { projections?.values?.title }
}

/// The `projections` wrapper.
///
/// unverified: every capture has `kind: "sequenced"`. Kept as a `String` so another
/// kind decodes; what the alternatives mean is unknown. `asOfSeq` is the ordering
/// watermark SPEC §6.5 says to use instead of arrival time.
public struct SessionProjections: Codable, Sendable, Hashable {
    public var kind: String?
    public var asOfSeq: Int64?
    public var values: SessionProjectionValues?

    enum CodingKeys: String, CodingKey {
        case kind
        case asOfSeq
        case values
    }

    public init(
        kind: String? = nil,
        asOfSeq: Int64? = nil,
        values: SessionProjectionValues? = nil
    ) {
        self.kind = kind
        self.asOfSeq = asOfSeq
        self.values = values
    }
}

/// The `projections.values` object.
///
/// Every field is optional. The capture proves it: `goal`, `subagent`, and `todos` are
/// `null`; item 3's ``ContextPressure`` is `{}`; item 3's
/// ``ModelSelection/lastUsed`` is `null`; and item 3's
/// ``SessionListMetadata/lastPromptAt`` is `null`.
///
/// Fields whose shape the capture only ever shows as `null` are typed
/// ``JSONValue`` with an `unverified` note — SPEC §6.1 forbids inferring a schema from
/// a method name.
public struct SessionProjectionValues: Codable, Sendable, Hashable {
    public var title: String?
    public var agentPreset: String?

    /// unverified: `null` in all three captured items. SPEC §5 wants a read-only goal
    /// summary; the object shape is not in any capture.
    public var goal: JSONValue?
    /// unverified: `null` in all three captured items.
    public var todos: JSONValue?
    /// unverified: `null` in all three captured items.
    public var subagent: JSONValue?
    /// unverified: `[]` in all three captured items, so the element shape is unknown.
    public var subagentCatalog: [JSONValue]?

    public var plan: SessionPlan?
    public var permissions: SessionPermissions?
    public var modelSelection: SessionModelSelection?
    public var tokenUsage: SessionTokenUsage?
    public var contextPressure: SessionContextPressure?
    public var contextBreakdown: SessionContextBreakdown?
    public var sessionStats: SessionStats?
    public var sessionListMetadata: SessionListMetadata?
    public var imageLimits: SessionImageLimits?
    public var turnOutline: [SessionTurnOutlineEntry]?

    /// unverified: both lists are `[]` in every captured item, so the element shape of
    /// an active or settled question is unknown. Stage 2 needs it for SPEC §6.7.
    public var userQuestions: SessionUserQuestionState?
    /// unverified: both queues are `[]` in every captured item, so the element shape is
    /// unknown.
    public var inbox: SessionInbox?

    public var subagentTiming: SessionSubagentTiming?
}

/// `projections.values.plan` — the read-only plan summary of SPEC §3.7.
public struct SessionPlan: Codable, Sendable, Hashable {
    public var active: Bool?
    public var pending: Bool?
}

/// `projections.values.permissions`.
///
/// unverified: only `currentValue` appears in the capture, as `workspace-write`. The
/// value is kept as a `String`; the host's full set of modes is not established.
public struct SessionPermissions: Codable, Sendable, Hashable {
    public var currentValue: String?
}

/// `projections.values.modelSelection`. Both fields are `null` for the third captured
/// session, which is what makes them optional.
public struct SessionModelSelection: Codable, Sendable, Hashable {
    public var lastUsed: SessionModelReference?
    public var next: SessionModelReference?
}

/// One model choice. SPEC §3.7 and §6.6 want provider, model, and reasoning effort;
/// all three appear in the capture.
public struct SessionModelReference: Codable, Sendable, Hashable {
    public var provider: String?
    public var model: String?
    public var reasoningEffort: String?
}

/// `projections.values.tokenUsage`.
public struct SessionTokenUsage: Codable, Sendable, Hashable {
    public var uncachedInputTokens: Int64?
    public var outputTokens: Int64?
    public var cacheReadTokens: Int64?
    public var cacheWriteTokens: Int64?
}

/// `projections.values.contextPressure`. Item 3 of the capture is `{}`, so nothing here
/// is required. SPEC §3.7: show numeric usage only once units and shape are verified —
/// the unit of these counts is stated nowhere in the capture.
public struct SessionContextPressure: Codable, Sendable, Hashable {
    public var pressureTokens: Int64?
    public var projectedTokens: Int64?
    public var contextWindow: Int64?
}

/// `projections.values.contextBreakdown`.
public struct SessionContextBreakdown: Codable, Sendable, Hashable {
    public var systemTokens: Int64?
    public var toolsTokens: Int64?
    public var messageTokens: Int64?
}

/// `projections.values.sessionStats`.
///
/// unverified: the `Ms` and `Tokens` suffixes imply units but nothing proves them, and
/// SPEC §3.7 gates numeric usage on a verified shape.
public struct SessionStats: Codable, Sendable, Hashable {
    public var turns: Int64?
    public var steps: Int64?
    public var llmMs: Int64?
    public var toolMs: Int64?
    public var ttftMs: Int64?
    public var ttftSteps: Int64?
    public var decodeMs: Int64?
    public var decodeTokens: Int64?
}

/// `projections.values.sessionListMetadata`.
public struct SessionListMetadata: Codable, Sendable, Hashable {
    public var blank: Bool?
    /// Epoch milliseconds, or `null` for a session that has never been prompted.
    public var lastPromptAt: Int64?
}

/// `projections.values.imageLimits` — the host-side limits SPEC §3.6 enforces before
/// submission.
public struct SessionImageLimits: Codable, Sendable, Hashable {
    public var maxImageBytes: Int64?
    public var maxImagesPerMessage: Int64?
    public var maxMessageImageBytes: Int64?
    public var maxImagePixels: Int64?
    public var maxImageDimension: Int64?
    /// e.g. `image/png`, `image/jpeg`.
    public var mediaTypes: [String]?
}

/// One entry of `projections.values.turnOutline`.
///
/// unverified: `prompt` and `response` are truncated with an ellipsis in the capture,
/// so whether the host ever sends them in full is unknown.
public struct SessionTurnOutlineEntry: Codable, Sendable, Hashable {
    public var turn: Int64?
    public var seq: Int64?
    public var prompt: String?
    public var response: String?
}

/// `projections.values.userQuestions`.
public struct SessionUserQuestionState: Codable, Sendable, Hashable {
    public var active: [JSONValue]?
    public var settled: [JSONValue]?
}

/// `projections.values.inbox`. The wire keys contain dashes, so they need explicit
/// mapping.
public struct SessionInbox: Codable, Sendable, Hashable {
    public var nextTurn: [JSONValue]?
    public var nextStep: [JSONValue]?

    enum CodingKeys: String, CodingKey {
        case nextTurn = "next-turn"
        case nextStep = "next-step"
    }
}

/// `projections.values.subagentTiming`.
public struct SessionSubagentTiming: Codable, Sendable, Hashable {
    public var settledMs: Int64?
}

/// The `result.value` of `session/list`: a bare object holding `items`.
///
/// unverified: no capture carries a cursor or total, so paging state does not belong
/// here (SPEC §6.5 keeps the cursor with the `session/follow` generation instead).
public struct SessionListResult: Codable, Sendable, Hashable {
    public var items: [SessionSummary]

    public init(items: [SessionSummary] = []) {
        self.items = items
    }
}
