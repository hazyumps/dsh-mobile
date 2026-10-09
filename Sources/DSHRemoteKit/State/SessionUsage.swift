import Foundation

/// One session's usage, as the host itself reports it.
///
/// SPEC §10 is specific about this surface: "Session-level usage only where durable assistant
/// events or verified projections supply it. No verified host-wide usage endpoint here; do not
/// treat account balance as token usage or estimate totals from a partial transcript."
///
/// So everything here comes from four session projections — `tokenUsage`, `sessionStats`,
/// `contextBreakdown`, `contextPressure` — and nothing is derived from the transcript, counted
/// by this client, or extrapolated to a host total. Every field is optional because the host
/// may project only some of them, and **absent is not zero**: a session that has not run has no
/// tokens, and inventing a zero would read as a measurement.
///
/// The installed host's answer on 2026-10-09, which the tests use verbatim:
///
/// ```json
/// tokenUsage       {"uncachedInputTokens":82962,"outputTokens":131,"cacheReadTokens":286720,"cacheWriteTokens":0}
/// sessionStats     {"turns":5,"steps":5,"llmMs":43627,"toolMs":0,"ttftMs":42663,"ttftSteps":5,
///                   "decodeMs":964,"decodeTokens":131}
/// contextBreakdown {"systemTokens":4189,"toolsTokens":51081,"messageTokens":12798}
/// contextPressure  {"pressureTokens":74288,"projectedTokens":74319,"contextWindow":524288}
/// ```
public struct SessionUsage: Sendable, Hashable {
    /// What the host counted for this session's model calls.
    public struct Tokens: Sendable, Hashable {

        public init(
        uncachedInput: Int? = nil,
        output: Int? = nil,
        cacheRead: Int? = nil,
        cacheWrite: Int? = nil
        ) {
            self.uncachedInput = uncachedInput
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }
        public var uncachedInput: Int?
        public var output: Int?
        public var cacheRead: Int?
        public var cacheWrite: Int?

        /// Input the host counted, cache reads and writes included.
        ///
        /// Nil unless at least one input figure is present, so "no input reported" never
        /// renders as "0 tokens in".
        public var totalInput: Int? {
            [uncachedInput, cacheRead, cacheWrite].compactMap { $0 }.isEmpty
                ? nil
                : [uncachedInput, cacheRead, cacheWrite].compactMap { $0 }.reduce(0, +)
        }

        public var total: Int? {
            guard let input = totalInput else { return output }
            guard let output else { return input }
            return input + output
        }

        /// The share of input that came from the prompt cache.
        ///
        /// Nil when there is no input to take a share of. A ratio with a zero denominator is
        /// not zero — it is unknown, and a "0% cached" label would be a claim the host never made.
        public var cacheHitRate: Double? {
            guard let input = totalInput, input > 0 else { return nil }
            let cached = (cacheRead ?? 0) + (cacheWrite ?? 0)
            return min(1, max(0, Double(cached) / Double(input)))
        }

        public var isEmpty: Bool {
            totalInput == nil && output == nil
        }
    }

    /// What the host timed, in its own units.
    public struct Timing: Sendable, Hashable {

        public init(
        turns: Int? = nil,
        steps: Int? = nil,
        llmMilliseconds: Int? = nil,
        toolMilliseconds: Int? = nil,
        firstTokenMilliseconds: Int? = nil,
        firstTokenSteps: Int? = nil,
        decodeMilliseconds: Int? = nil,
        decodeTokens: Int? = nil
        ) {
            self.turns = turns
            self.steps = steps
            self.llmMilliseconds = llmMilliseconds
            self.toolMilliseconds = toolMilliseconds
            self.firstTokenMilliseconds = firstTokenMilliseconds
            self.firstTokenSteps = firstTokenSteps
            self.decodeMilliseconds = decodeMilliseconds
            self.decodeTokens = decodeTokens
        }
        public var turns: Int?
        public var steps: Int?
        public var llmMilliseconds: Int?
        public var toolMilliseconds: Int?
        /// Time to first token, and how many steps it was measured over.
        public var firstTokenMilliseconds: Int?
        public var firstTokenSteps: Int?
        public var decodeMilliseconds: Int?
        public var decodeTokens: Int?

        /// Output tokens per second across the decode window.
        ///
        /// Nil unless both halves are known and the window is positive: a speed computed from a
        /// zero-length window is a division this client has no business inventing.
        public var tokensPerSecond: Double? {
            guard let milliseconds = decodeMilliseconds, milliseconds > 0,
                  let tokens = decodeTokens
            else { return nil }
            return Double(tokens) / (Double(milliseconds) / 1000)
        }

        public var isEmpty: Bool {
            [turns, steps, llmMilliseconds, toolMilliseconds,
             firstTokenMilliseconds, firstTokenSteps, decodeMilliseconds, decodeTokens]
                .allSatisfy { $0 == nil }
        }
    }

    /// Where the context window is going.
    public struct Context: Sendable, Hashable {

        public init(
        systemTokens: Int? = nil,
        toolsTokens: Int? = nil,
        messageTokens: Int? = nil,
        pressureTokens: Int? = nil,
        projectedTokens: Int? = nil,
        contextWindow: Int? = nil
        ) {
            self.systemTokens = systemTokens
            self.toolsTokens = toolsTokens
            self.messageTokens = messageTokens
            self.pressureTokens = pressureTokens
            self.projectedTokens = projectedTokens
            self.contextWindow = contextWindow
        }
        public var systemTokens: Int?
        public var toolsTokens: Int?
        public var messageTokens: Int?
        /// What the host says is currently in context.
        public var pressureTokens: Int?
        /// What it projects after the next step.
        public var projectedTokens: Int?
        public var contextWindow: Int?

        /// How full the window is, clamped to `0...1`.
        ///
        /// Clamped because the host's own projection may exceed the window — that is a real
        /// state (a session over its window) and a bar that drew past its end would be a lie
        /// about the numbers rather than a bug in them.
        public var fill: Double? {
            guard let window = contextWindow, window > 0, let pressure = pressureTokens else {
                return nil
            }
            return min(1, max(0, Double(pressure) / Double(window)))
        }

        /// Whether the host predicts the next step still fits.
        public var projectsWithinWindow: Bool? {
            guard let window = contextWindow, let projected = projectedTokens else { return nil }
            return projected <= window
        }

        public var breakdownTotal: Int? {
            let parts = [systemTokens, toolsTokens, messageTokens].compactMap { $0 }
            return parts.isEmpty ? nil : parts.reduce(0, +)
        }

        public var isEmpty: Bool {
            [systemTokens, toolsTokens, messageTokens, pressureTokens, projectedTokens, contextWindow]
                .allSatisfy { $0 == nil }
        }
    }

    public var tokens: Tokens
    public var timing: Timing
    public var context: Context

    /// Whether the host reported anything at all.
    public var isEmpty: Bool { tokens.isEmpty && timing.isEmpty && context.isEmpty }

    public init(tokens: Tokens = Tokens(), timing: Timing = Timing(), context: Context = Context()) {
        self.tokens = tokens
        self.timing = timing
        self.context = context
    }

    /// Reads usage out of a session's projection map.
    ///
    /// - Parameter projections: the projection **values** by key, which is the shape
    ///   `HostSessionStore` keeps and `SessionInputSignal` already reads. A key the host does
    ///   not send leaves its fields nil.
    public init(projections: [String: JSONValue]) {
        self.init(
            tokens: Self.tokens(projections["tokenUsage"]),
            timing: Self.timing(projections["sessionStats"]),
            context: Self.context(
                breakdown: projections["contextBreakdown"],
                pressure: projections["contextPressure"]
            )
        )
    }

    private static func int(_ value: JSONValue?, _ key: String) -> Int? {
        value?[key]?.intValue.map(Int.init)
    }

    static func tokens(_ json: JSONValue?) -> Tokens {
        Tokens(
            uncachedInput: int(json, "uncachedInputTokens"),
            output: int(json, "outputTokens"),
            cacheRead: int(json, "cacheReadTokens"),
            cacheWrite: int(json, "cacheWriteTokens")
        )
    }

    static func timing(_ json: JSONValue?) -> Timing {
        Timing(
            turns: int(json, "turns"),
            steps: int(json, "steps"),
            llmMilliseconds: int(json, "llmMs"),
            toolMilliseconds: int(json, "toolMs"),
            firstTokenMilliseconds: int(json, "ttftMs"),
            firstTokenSteps: int(json, "ttftSteps"),
            decodeMilliseconds: int(json, "decodeMs"),
            decodeTokens: int(json, "decodeTokens")
        )
    }

    static func context(breakdown: JSONValue?, pressure: JSONValue?) -> Context {
        Context(
            systemTokens: int(breakdown, "systemTokens"),
            toolsTokens: int(breakdown, "toolsTokens"),
            messageTokens: int(breakdown, "messageTokens"),
            pressureTokens: int(pressure, "pressureTokens"),
            projectedTokens: int(pressure, "projectedTokens"),
            contextWindow: int(pressure, "contextWindow")
        )
    }
}
