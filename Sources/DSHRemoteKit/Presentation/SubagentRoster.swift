import Foundation

/// A session's own subagents, as the harness projects them (SPEC §3; issue #13).
///
/// Three session projections describe a delegation and none of them was read before this:
///
/// - `subagentCatalog` on the **parent**: the direct children, in the host's order, as
///   `[{mode, label?, id, createdAt}]`. Membership is this array and nothing else — never a scan
///   for `parentSessionId`, which is a `session/list` field the catalog does not need.
/// - `subagentTiming` on the **child**: `{settledMs, active?: {since, through}, lastTurnCompleted?}`.
/// - `tokenUsage` on the child, whose four buckets are disjoint and therefore add up.
///
/// The host's own definition of the timing, from the installed
/// `@deepseek-ai/dsh-subagent/lib/index.js` (`subagentTimingProjectionDefinition`): `turn/start`
/// opens `active = {since: event.time, through: event.time}`; every later event advances `through`;
/// `turn/end` folds `settledMs += max(0, end − active.since)` and sets
/// `lastTurnCompleted = reason.kind == "completed"`; a `subagent/descriptor` resets `settledMs` to
/// 0 because a fork seed may replay an ancestor's turns. `since` and `through` are epoch
/// milliseconds — the same unit as ``EpochClock`` and `session/list`'s `updatedAt`.
///
/// The desktop's `activityDuration` is the same arithmetic (`@deepseek-ai/dsh-client-ui-subagent`,
/// `client.js`), and it is deliberately not improved on here:
///
/// ```js
/// if (timing.active === undefined) return timing.settledMs;
/// const end = activity === "running" ? now : timing.active.through;
/// return timing.settledMs + Math.max(0, end - timing.active.since);
/// ```
///
/// Two rules this type keeps from the rest of the client. **Absent is not zero**: a host that
/// reported no timing, no usage, or no catalog has said nothing, and a row that rendered `0`
/// would be claiming a measurement. And **an unknown activity is not "inactive"**: a child the
/// session index has not heard of reports `nil`, so the row can draw nothing rather than a
/// confident idle dot.
public struct SubagentRoster: Sendable, Hashable {

    /// What a child is doing, from the index's `running` and the child's own last turn.
    public enum Activity: Sendable, Hashable {
        case running
        case completed
        case inactive
    }

    /// One child of the parent session.
    public struct Entry: Sendable, Hashable, Identifiable {
        /// The child's session id, which is also its identity in the catalog.
        public var id: String
        /// The catalog's label. Optional on the wire for a `one-shot` and an `unknown` row.
        public var label: String? = nil
        public var mode: SubagentMode
        /// When the child was created, epoch milliseconds.
        public var createdAt: Int64? = nil
        /// The child's own projected title, when the index supplied one.
        public var title: String? = nil
        /// The session index's `running` for this child, or `nil` when it has no row.
        public var isRunning: Bool? = nil
        /// The sum of the child's four `tokenUsage` buckets, or `nil` when it reported none.
        public var tokenTotal: Int64? = nil
        public var timing: SubagentTiming? = nil

        /// What to call the row.
        ///
        /// The desktop's rule, verbatim: `entry.label ?? entry.id`. A *title* is not a
        /// substitute — it is a derived summary of the child's work, and the desktop puts it on
        /// the row's secondary line instead.
        public var displayLabel: String { label ?? id }

        /// What the child is doing, or `nil` when nothing said.
        public var activity: Activity? { .inactive }

        /// How long the child has been working, in the host's own terms.
        ///
        /// `now` is epoch milliseconds and is only consulted for a **running** child with an open
        /// turn: for any other child the end is the turn's own `through`, so a figure does not keep
        /// climbing after the work stopped.
        public func durationMs(now: Int64) -> Int64? { timing?.settledMs }
    }

    /// The children, in the order the host's catalog gave them.
    public var entries: [Entry]
    /// Whether the parent projected a catalog at all. `false` is "not reported", which is not
    /// the same screen as a known-empty roster.
    public var isReported: Bool

    public var count: Int { entries.count }

    /// How many children are running, for the entry point's count.
    public var runningCount: Int { 0 }

    /// Whether the duration has anything to advance this second.
    public var needsTick: Bool { false }

    /// Whether the conversation should offer the roster at all.
    ///
    /// The desktop's own rule for its header trigger: an absent catalog, an empty loading catalog,
    /// or a successfully loaded empty catalog hides the count. A session with nothing delegated has
    /// no subagents surface, rather than an empty one.
    public var showsEntryPoint: Bool { true }

    /// Builds the roster from the parent's catalog and one ``SubagentFacts`` per child.
    ///
    /// - Parameters:
    ///   - catalog: the parent's `subagentCatalog` array, or `nil` when the host projected none.
    ///   - facts: keyed by child session id. A child the catalog names with no facts still gets a
    ///     row: the catalog is the authority on membership, and a missing row means the host has
    ///     not reported that child's own state yet.
    public init(catalog: [JSONValue]?, facts: [String: SubagentFacts]) {
        // STUB: membership only. Each catalog member becomes a row, but its mode, label and every
        // figure derived from `facts` are missing — so `SubagentRosterTests` fails on its
        // assertions rather than crashing on an empty roster. See the plan's AC1–AC6.
        self.isReported = catalog != nil
        self.entries = (catalog ?? []).compactMap { entry in
            guard let id = entry["id"]?.stringValue else { return nil }
            return Entry(id: id, mode: .unknown)
        }
    }
}

/// What one child's own projections and index row say about it.
public struct SubagentFacts: Sendable, Hashable {
    public var title: String?
    public var isRunning: Bool?
    public var tokenTotal: Int64?
    public var timing: SubagentTiming?

    /// - Parameters:
    ///   - projections: the child's projection values by key, as ``HostSessionStore`` holds them.
    ///     `subagentTiming` and `tokenUsage` are read; every other key is ignored.
    ///   - title: the child's projected title from the session index.
    ///   - isRunning: the session index's `running` for the child.
    public init(projections: [String: JSONValue]?, title: String?, isRunning: Bool?) {
        self.title = title
        self.isRunning = isRunning
        self.tokenTotal = 0
        self.timing = nil
    }
}

/// The child's own `subagentTiming`.
public struct SubagentTiming: Sendable, Hashable {
    /// The sum of the durations of the turns that have closed, in milliseconds.
    public var settledMs: Int64
    /// The open turn's start, epoch milliseconds. `nil` when no turn is open.
    public var activeSince: Int64?
    /// The open turn's latest event, epoch milliseconds.
    public var activeThrough: Int64?
    /// Whether the latest **closed** turn ended normally. `nil` until one has.
    public var lastTurnCompleted: Bool?

    /// Decodes the wire value. `settledMs` is required by the descriptor's schema, so a value
    /// without it is not a timing this client understands and is reported as absent rather than
    /// as zero.
    public init?(json: JSONValue) { return nil }

    /// The host's own arithmetic. See ``SubagentRoster`` for the definition and its source.
    public func durationMs(isRunning: Bool, now: Int64) -> Int64 { settledMs }
}

/// How a child was delegated, as the catalog states it.
///
/// The descriptor's union is `one-shot | continuable | unknown` and it is **open**: an
/// unrecognised value keeps its raw string rather than failing the whole catalog.
public enum SubagentMode: Sendable, Hashable {
    case oneShot
    case continuable
    case unknown
    case unrecognized(String)

    public init(rawValue: String) {
        switch rawValue {
        case "one-shot": self = .oneShot
        case "continuable": self = .continuable
        case "unknown": self = .unknown
        default: self = .unrecognized(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .oneShot: "one-shot"
        case .continuable: "continuable"
        case .unknown: "unknown"
        case .unrecognized(let value): value
        }
    }
}
