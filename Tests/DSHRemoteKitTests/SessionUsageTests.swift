import Foundation
import Testing

@testable import DSHRemoteKit

/// Session usage, read from the host's projections and nothing else.
///
/// Every payload here is the installed host's own answer for a real session on 2026-10-09, and
/// the derivations are tested for the case SPEC §10 warns about: a number this client would have
/// to invent is nil rather than a plausible-looking zero.
@Suite("Session usage")
struct SessionUsageTests {

    /// The live projections, verbatim.
    private var live: [String: JSONValue] {
        [
            "tokenUsage": .object([
                "uncachedInputTokens": .int(82_962),
                "outputTokens": .int(131),
                "cacheReadTokens": .int(286_720),
                "cacheWriteTokens": .int(0),
            ]),
            "sessionStats": .object([
                "turns": .int(5),
                "steps": .int(5),
                "llmMs": .int(43_627),
                "toolMs": .int(0),
                "ttftMs": .int(42_663),
                "ttftSteps": .int(5),
                "decodeMs": .int(964),
                "decodeTokens": .int(131),
            ]),
            "contextBreakdown": .object([
                "systemTokens": .int(4_189),
                "toolsTokens": .int(51_081),
                "messageTokens": .int(12_798),
            ]),
            "contextPressure": .object([
                "pressureTokens": .int(74_288),
                "projectedTokens": .int(74_319),
                "contextWindow": .int(524_288),
            ]),
        ]
    }

    @Test("the live projections decode, and the totals are the host's own arithmetic")
    func readsTheLiveProjections() {
        let usage = SessionUsage(projections: live)

        #expect(usage.tokens.uncachedInput == 82_962)
        #expect(usage.tokens.output == 131)
        #expect(usage.tokens.cacheRead == 286_720)
        // Input includes cache reads — the host counts them as input tokens it did not have to
        // recompute, not as no input at all.
        #expect(usage.tokens.totalInput == 82_962 + 286_720 + 0)
        #expect(usage.tokens.total == 369_682 + 131)

        #expect(usage.timing.turns == 5)
        #expect(usage.timing.llmMilliseconds == 43_627)
        #expect(usage.timing.firstTokenMilliseconds == 42_663)
    }

    @Test("a rate is nil when its denominator is unknown, never zero")
    func ratesRefuseToGuess() {
        let usage = SessionUsage(projections: live)

        // 286720 of 369682 input tokens came from cache.
        let hitRate = try? #require(usage.tokens.cacheHitRate)
        #expect(abs((hitRate ?? 0) - 0.7756) < 0.001)

        // 131 tokens in 964 ms is ~136 tok/s.
        let speed = try? #require(usage.timing.tokensPerSecond)
        #expect(abs((speed ?? 0) - 135.9) < 0.5)

        // The case that matters: a session with no decode window has no speed. Reporting 0
        // tok/s would be a measurement, and the host never made one.
        let noWindow = SessionUsage(projections: [
            "sessionStats": .object(["decodeMs": .int(0), "decodeTokens": .int(50)]),
        ])
        #expect(noWindow.timing.tokensPerSecond == nil)

        let noInput = SessionUsage(projections: [
            "tokenUsage": .object(["uncachedInputTokens": .int(0), "outputTokens": .int(10)]),
        ])
        #expect(noInput.tokens.cacheHitRate == nil)
    }

    @Test("the context fill is the host's ratio, clamped to the window")
    func contextFill() throws {
        let usage = SessionUsage(projections: live)

        let fill = try #require(usage.context.fill)
        #expect(abs(fill - 0.1417) < 0.001)
        #expect(usage.context.breakdownTotal == 4_189 + 51_081 + 12_798)
        #expect(usage.context.projectsWithinWindow == true)

        // A projection that exceeds its window is a real state; the bar must not draw past its
        // end, so the value is clamped rather than trusted.
        let over = SessionUsage(projections: [
            "contextPressure": .object([
                "pressureTokens": .int(600_000), "contextWindow": .int(524_288),
            ]),
        ])
        #expect(over.context.fill == 1)
        #expect(over.context.projectsWithinWindow == nil)

        // And a window of zero is not "100% full", it is unknown.
        let zeroWindow = SessionUsage(projections: [
            "contextPressure": .object(["pressureTokens": .int(10), "contextWindow": .int(0)]),
        ])
        #expect(zeroWindow.context.fill == nil)
    }

    @Test("a host that reports nothing produces nothing, not zeros")
    func absentIsNotZero() {
        let usage = SessionUsage(projections: [:])
        #expect(usage.isEmpty)
        #expect(usage.tokens.total == nil)
        #expect(usage.tokens.totalInput == nil)
        #expect(usage.tokens.cacheHitRate == nil)
        #expect(usage.timing.tokensPerSecond == nil)
        #expect(usage.context.fill == nil)

        // A partial projection is partial: the keys it has are read, the rest stay unknown.
        let partial = SessionUsage(projections: [
            "tokenUsage": .object(["outputTokens": .int(131)]),
        ])
        #expect(!partial.isEmpty)
        #expect(partial.tokens.output == 131)
        #expect(partial.tokens.totalInput == nil)
        // Output with no input still totalises: it is a real measurement of one half.
        #expect(partial.tokens.total == 131)
        #expect(partial.timing.isEmpty)
        #expect(partial.context.isEmpty)
    }

    @Test("malformed values are ignored rather than coerced")
    func malformedValuesAreIgnored() {
        let usage = SessionUsage(projections: [
            "tokenUsage": .object(["uncachedInputTokens": .string("82962"), "outputTokens": .bool(true)]),
            "sessionStats": .array([]),
            "contextPressure": .string("nope"),
        ])
        #expect(usage.isEmpty)
    }
}
