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
        ///
        /// `running` is a `session/list` field, not a projection, so it is the only thing that can
        /// say a child is working and its absence is not evidence of anything. A child with a
        /// timing and no index row still reports `nil`: a turn left open by an interrupted run is
        /// not a running child (see ``durationMs(now:)``).
        public var activity: Activity? {
            guard let isRunning else { return nil }
            if isRunning { return .running }
            // Not running: the last *closed* turn is what tells a normal finish from every other
            // way a child stops. The desktop's own three-way split, and the reason it has three.
            return timing?.lastTurnCompleted == true ? .completed : .inactive
        }

        /// How long the child has been working, in the host's own terms.
        ///
        /// `now` is epoch milliseconds and is only consulted for a **running** child with an open
        /// turn: for any other child the end is the turn's own `through`, so a figure does not keep
        /// climbing after the work stopped.
        public func durationMs(now: Int64) -> Int64? {
            guard let timing else { return nil }
            return timing.durationMs(isRunning: isRunning == true, now: now)
        }
    }

    /// The children, in the order the host's catalog gave them.
    public var entries: [Entry]
    /// Whether the parent projected a catalog at all. `false` is "not reported", which is not
    /// the same screen as a known-empty roster.
    public var isReported: Bool

    public var count: Int { entries.count }

    /// How many children are running, for the entry point's count.
    public var runningCount: Int { entries.filter { $0.activity == .running }.count }

    /// Whether the duration has anything to advance this second.
    ///
    /// The screen's clock reads this rather than counting actors: an open turn on an inactive child
    /// is already frozen at its own `through`, so ticking for it would redraw the same number.
    public var needsTick: Bool { runningCount > 0 }

    /// Whether the conversation should offer the roster at all.
    ///
    /// The desktop's own rule for its header trigger: an absent catalog, an empty loading catalog,
    /// or a successfully loaded empty catalog hides the count. A session with nothing delegated has
    /// no subagents surface, rather than an empty one.
    public var showsEntryPoint: Bool { isReported && !entries.isEmpty }

    /// Builds the roster from the parent's catalog and one ``SubagentFacts`` per child.
    ///
    /// - Parameters:
    ///   - catalog: the parent's `subagentCatalog` array, or `nil` when the host projected none.
    ///   - facts: keyed by child session id. A child the catalog names with no facts still gets a
    ///     row: the catalog is the authority on membership, and a missing row means the host has
    ///     not reported that child's own state yet.
    public init(catalog: [JSONValue]?, facts: [String: SubagentFacts]) {
        self.isReported = catalog != nil
        self.entries = (catalog ?? []).compactMap { value in
            // The id is the one field the catalog needs for a row to be addressable at all; an
            // entry without one cannot be opened, so it is dropped rather than drawn dead.
            guard let id = value["id"]?.stringValue else { return nil }
            let child = facts[id]
            return Entry(
                id: id,
                label: value["label"]?.stringValue,
                // A catalog entry with no mode is the union's own `unknown` — "not established" —
                // rather than a refusal to show the row.
                mode: SubagentMode(rawValue: value["mode"]?.stringValue ?? "unknown"),
                createdAt: value["createdAt"]?.intValue,
                title: child?.title,
                isRunning: child?.isRunning,
                tokenTotal: child?.tokenTotal,
                timing: child?.timing
            )
        }
    }

    /// Builds the roster from what a store knows about a host.
    ///
    /// Two sources describe the same session and they are not the same age. The
    /// `session/control` stream is live and per-session sparse — its baseline carried 39 sessions
    /// where `session/list` carried 200 on 2026-10-15 — while `session/list` is a whole-index
    /// refresh that carries every projection key for every row. So a key is read from the live
    /// stream when that stream has sent it and from the index row otherwise, **per key**: reading
    /// only the live stream would leave older children with no timing, and reading only the index
    /// would freeze a running child between refreshes.
    ///
    /// Membership is still the catalog and nothing else, whichever source supplied it.
    ///
    /// - Parameters:
    ///   - parentSessionId: the session whose children are wanted.
    ///   - rows: the `session/list` index, keyed by session id.
    ///   - live: the `session/control` values, keyed by session id and then by projection key.
    public init(
        parentSessionId: String,
        rows: [String: HostSessionStore.SessionRecord],
        live: [String: [String: HostSessionStore.Projection]]
    ) {
        // STUB: no catalog and no children, so the assertions in `SubagentRosterSourceTests` fail
        // rather than the sources being ignored. See the plan's AC9.
        self.init(catalog: nil, facts: [:])
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
        self.tokenTotal = projections?["tokenUsage"].flatMap(Self.tokenTotal(_:))
        self.timing = projections?["subagentTiming"].flatMap(SubagentTiming.init(json:))
    }

    /// The four buckets are disjoint, so the total is their sum.
    ///
    /// A host that reported only some of them has still reported those: the sum of what is there
    /// beats a total withheld. None at all is `nil` — "absent is not zero" (`AGENTS.md`), and a
    /// child that has not run has no tokens rather than 0 of them.
    static func tokenTotal(_ usage: JSONValue) -> Int64? {
        let buckets = ["uncachedInputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"]
        let reported = buckets.compactMap { usage[$0]?.intValue }
        return reported.isEmpty ? nil : reported.reduce(0, +)
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
    ///
    /// `active` is all-or-nothing for the same reason: a half-interval has no bounded duration, and
    /// a guessed `through` would be a figure the host never stated.
    public init?(json: JSONValue) {
        guard let settledMs = json["settledMs"]?.intValue else { return nil }
        self.settledMs = settledMs

        if let active = json["active"],
           let since = active["since"]?.intValue,
           let through = active["through"]?.intValue {
            self.activeSince = since
            self.activeThrough = through
        } else {
            self.activeSince = nil
            self.activeThrough = nil
        }

        // Absent until a turn has closed: the host clears it when a turn opens and only sets it on
        // `turn/end`, so `nil` says "no closed turn to judge" rather than "did not complete".
        self.lastTurnCompleted = json["lastTurnCompleted"]?.boolValue
    }

    /// The host's own arithmetic. See ``SubagentRoster`` for the definition and its source.
    ///
    /// - Parameters:
    ///   - isRunning: whether the session index says the child is working. Only a running child's
    ///     open turn is measured to `now`; every other open turn is bounded by its own `through`,
    ///     which is what keeps an interrupted turn's figure from climbing.
    ///   - now: epoch milliseconds, ignored unless `isRunning` and a turn is open.
    public func durationMs(isRunning: Bool, now: Int64) -> Int64 {
        guard let since = activeSince else { return settledMs }
        let end = isRunning ? now : (activeThrough ?? since)
        return settledMs + max(0, end - since)
    }
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
