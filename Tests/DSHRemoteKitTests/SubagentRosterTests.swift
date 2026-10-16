import Foundation
import Testing

@testable import DSHRemoteKit

/// #13: the parent's `subagentCatalog`, and what the three subagent projections mean.
///
/// The rules come from two installed sources, and both are quoted in
/// ``SubagentRoster``: the host's `subagentTimingProjectionDefinition`
/// (`@deepseek-ai/dsh-subagent/lib/index.js`) for the timing, and the desktop's `activityDuration`
/// (`@deepseek-ai/dsh-client-ui-subagent/lib/client.js`) for how it is read.
///
/// `Fixtures/rpc-response-subagent-roster.json` is the capture those shapes were checked against
/// — a running child, one whose last turn completed, and one whose last turn did not. The two
/// states the capture does not contain (an entry with no label, a child the session index has not
/// heard of) are built here from the descriptor's own optionality, and each says so.
@Suite("Subagent roster (#13)")
struct SubagentRosterTests {

    // MARK: - The captured roster

    /// The capture, through the same two inputs the app assembles: the parent's catalog array and
    /// one ``SubagentFacts`` per child.
    private func capturedRoster() throws -> SubagentRoster {
        let fixture = try Fixtures.object(.rpcSubagentRoster)
        return SubagentRoster(
            catalog: fixture["parentSubagentCatalog"]?.arrayValue,
            facts: Self.facts(in: fixture)
        )
    }

    /// A child row as the client assembles it: `running` and `title` from the session index, and
    /// the projection values the roster reads.
    private static func facts(in fixture: [String: JSONValue]) -> [String: SubagentFacts] {
        var facts: [String: SubagentFacts] = [:]
        for row in fixture["childRows"]?.arrayValue ?? [] {
            guard let id = row["sessionId"]?.stringValue else { continue }
            var values: [String: JSONValue] = [:]
            if let timing = row["subagentTiming"] { values["subagentTiming"] = timing }
            if let usage = row["tokenUsage"] { values["tokenUsage"] = usage }
            facts[id] = SubagentFacts(
                projections: values,
                title: row["title"]?.stringValue,
                isRunning: row["running"]?.boolValue
            )
        }
        return facts
    }

    /// One entry, so a rule can be stated about a single child without a fixture.
    private func single(_ facts: SubagentFacts, mode: SubagentMode = .continuable) -> SubagentRoster {
        let catalog: [JSONValue] = [
            .object(["mode": .string(mode.rawValue), "label": .string("One child"), "id": .string("subagent-1"), "createdAt": .int(0)])
        ]
        return SubagentRoster(catalog: catalog, facts: ["subagent-1": facts])
    }

    // MARK: - AC1: membership, order, labels

    @Test("AC1: the roster is the catalog, in the host's order")
    func rosterIsTheCatalogInOrder() throws {
        let roster = try capturedRoster()

        // Membership and order are the host's: the array is the authority, not a scan for
        // `parentSessionId`.
        #expect(roster.entries.map(\.id) == ["subagent-child-1", "subagent-child-2", "subagent-child-3"])
        #expect(roster.entries.map(\.mode) == [.continuable, .continuable, .continuable])
        #expect(
            roster.entries.map(\.displayLabel) == [
                "Implement native compressor privately",
                "Review independent selector tests",
                "Audit existing postpool transforms",
            ]
        )
        #expect(roster.entries.map(\.createdAt) == [1792087375461, 1792012370832, 1792022629774])
    }

    @Test("AC1: an unlabelled entry falls back to its session id")
    func unlabelledEntryFallsBackToItsID() {
        // `label` is optional for `one-shot` and `unknown` in the descriptor; no capture has one
        // without, so this shape is built from the schema rather than from a host.
        let catalog: [JSONValue] = [
            .object(["mode": .string("one-shot"), "id": .string("subagent-unnamed"), "createdAt": .int(7)])
        ]
        let roster = SubagentRoster(catalog: catalog, facts: [:])

        #expect(roster.entries.first?.displayLabel == "subagent-unnamed")
        #expect(roster.entries.first?.label == nil)
        #expect(roster.entries.first?.mode == .oneShot)
    }

    @Test("AC1: an unrecognised mode keeps its raw value rather than failing the catalog")
    func unrecognisedModeIsKept() {
        let catalog: [JSONValue] = [
            .object(["mode": .string("cascading"), "label": .string("Something new"), "id": .string("subagent-x"), "createdAt": .int(1)])
        ]
        let roster = SubagentRoster(catalog: catalog, facts: [:])

        #expect(roster.entries.count == 1)
        #expect(roster.entries.first?.mode == .unrecognized("cascading"))
    }

    // MARK: - AC2: an absent catalog is not an empty one

    @Test("AC2: an absent catalog is not an empty one")
    func absentCatalogIsNotAnEmptyOne() {
        let absent = SubagentRoster(catalog: nil, facts: [:])
        #expect(absent.isReported == false)
        #expect(absent.entries.isEmpty)

        let empty = SubagentRoster(catalog: [], facts: [:])
        #expect(empty.isReported == true)
        #expect(empty.entries.isEmpty)
    }

    @Test("AC2: the entry point shows only for a reported, non-empty roster")
    func entryPointShowsOnlyWhenThereIsSomethingToShow() throws {
        // The desktop's own rule for its header trigger: an absent catalog, an empty loading
        // catalog, or a loaded empty catalog hides the count.
        #expect(SubagentRoster(catalog: nil, facts: [:]).showsEntryPoint == false)
        #expect(SubagentRoster(catalog: [], facts: [:]).showsEntryPoint == false)
        #expect(try capturedRoster().showsEntryPoint == true)
    }

    // MARK: - AC3: activity

    @Test("AC3: activity follows the index and the last turn")
    func activityFollowsTheIndexAndTheLastTurn() throws {
        let roster = try capturedRoster()

        // child-1 was running; child-2's last turn completed; child-3's did not.
        #expect(roster.entries.map(\.activity) == [.running, .completed, .inactive])
        #expect(roster.entries.map(\.isRunning) == [true, false, false])
    }

    @Test("AC3: a completed turn is told apart from an interrupted one")
    func completedIsToldApartFromInterrupted() throws {
        let roster = try capturedRoster()

        // The same two children are both inactive and both have a closed turn; only
        // `lastTurnCompleted` separates them.
        #expect(roster.entries[1].timing?.lastTurnCompleted == true)
        #expect(roster.entries[2].timing?.lastTurnCompleted == false)
    }

    @Test("AC3: a child the index does not know reports no activity, not inactive")
    func unknownChildReportsNoActivity() {
        // A catalog entry with no `session/list` row and no projections. Absent is not zero: an
        // idle dot would be a claim the host never made.
        let roster = SubagentRoster(
            catalog: [
                .object(["mode": .string("continuable"), "label": .string("Not in the index"), "id": .string("subagent-absent"), "createdAt": .int(1)])
            ],
            facts: [:]
        )

        #expect(roster.entries.count == 1)
        #expect(roster.entries.first?.activity == nil)
        #expect(roster.entries.first?.isRunning == nil)
        #expect(roster.entries.first?.timing == nil)
        #expect(roster.entries.first?.durationMs(now: 9_999) == nil)
    }

    // MARK: - AC4: the host's own duration arithmetic

    /// `{"settledMs":500,"active":{"since":1000,"through":1400}}` — a turn that is still open
    /// across 400 ms.
    private static let openTurn: JSONValue = .object([
        "settledMs": .int(500),
        "active": .object(["since": .int(1_000), "through": .int(1_400)]),
    ])
    /// `{"settledMs":500}` — closed turns only. `lastTurnCompleted` is deliberately absent: it is
    /// optional on the wire because a child whose descriptor reset the state has none.
    private static let closedTurns: JSONValue = .object(["settledMs": .int(500)])

    @Test("AC4: no reported timing is nil, not zero")
    func noTimingIsNil() {
        let entry = single(SubagentFacts(projections: [:], title: nil, isRunning: true)).entries[0]
        #expect(entry.timing == nil)
        #expect(entry.durationMs(now: 9_999) == nil)
    }

    @Test("AC4: with no turn open the duration is settledMs")
    func noOpenTurnIsSettledMs() {
        let entry = single(
            SubagentFacts(projections: ["subagentTiming": Self.closedTurns], title: nil, isRunning: false)
        ).entries[0]
        #expect(entry.durationMs(now: 9_999) == 500)
    }

    @Test("AC4: a running child's open turn runs to now")
    func runningOpenTurnRunsToNow() {
        let entry = single(
            SubagentFacts(projections: ["subagentTiming": Self.openTurn], title: nil, isRunning: true)
        ).entries[0]
        // 500 settled + (3000 − 1000) open.
        #expect(entry.durationMs(now: 3_000) == 2_500)
    }

    @Test("AC4: an inactive child's open turn is bounded by its own through")
    func inactiveOpenTurnIsBoundedByThrough() {
        // An interrupted turn leaves `active` behind with no `turn/end`. The desktop's rule is
        // that `through` bounds it — "never by newer session metadata" — so `now` is ignored.
        let entry = single(
            SubagentFacts(projections: ["subagentTiming": Self.openTurn], title: nil, isRunning: false)
        ).entries[0]
        #expect(entry.durationMs(now: 9_999) == 900)
    }

    @Test("AC4: the captured running child's duration is settled plus its open window")
    func capturedRunningChildDuration() throws {
        let roster = try capturedRoster()
        let child = roster.entries[0]

        // `{"settledMs":9634145,"active":{"since":1792106727891,"through":1792107446245}}`.
        // A `now` inside the window makes the sum testable without a clock.
        #expect(child.durationMs(now: 1792106727891) == 9_634_145)
        #expect(child.durationMs(now: 1792106728891) == 9_635_145)
    }

    // MARK: - AC5: token totals

    @Test("AC5: the token total sums the four disjoint buckets")
    func tokenTotalSumsTheFourBuckets() throws {
        let roster = try capturedRoster()

        // 1725429 + 232830 + 110456576 + 0, as the capture sent them.
        #expect(roster.entries[0].tokenTotal == 112_414_835)
        #expect(roster.entries[1].tokenTotal == 5_906_456)
    }

    @Test("AC5: a child with no reported usage has no token total")
    func noUsageIsNil() {
        let entry = single(SubagentFacts(projections: [:], title: nil, isRunning: false)).entries[0]
        #expect(entry.tokenTotal == nil)
    }

    @Test("AC5: a partial usage sums what the host reported")
    func partialUsageSumsWhatIsThere() {
        // The descriptor marks all four optional; a host that reports two has still reported two.
        let usage: JSONValue = .object(["outputTokens": .int(30), "cacheReadTokens": .int(70)])
        let entry = single(
            SubagentFacts(projections: ["tokenUsage": usage], title: nil, isRunning: false)
        ).entries[0]
        #expect(entry.tokenTotal == 100)
    }

    // MARK: - AC6: counts and the clock

    @Test("AC6: the running count is the running children, and the tick follows it")
    func runningCountAndTick() throws {
        let roster = try capturedRoster()
        #expect(roster.runningCount == 1)
        #expect(roster.count == 3)
        #expect(roster.needsTick == true)

        let idle = SubagentRoster(
            catalog: [.object(["mode": .string("continuable"), "label": .string("Done"), "id": .string("subagent-1"), "createdAt": .int(1)])],
            facts: ["subagent-1": SubagentFacts(projections: [:], title: nil, isRunning: false)]
        )
        #expect(idle.runningCount == 0)
        #expect(idle.needsTick == false)
    }

    // MARK: - The child's own identity

    @Test("the child's own subagent projection carries the same mode and label as the catalog")
    func childIdentityAgreesWithTheCatalog() throws {
        let fixture = try Fixtures.object(.rpcSubagentRoster)
        let rows = try #require(fixture["childRows"]?.arrayValue)
        let catalog = try #require(fixture["parentSubagentCatalog"]?.arrayValue)

        // The client uses the catalog for membership, so this pins that the two sources agree
        // about the child — the reason a missing catalog entry is the only thing that hides a row.
        for row in rows {
            let id = try #require(row["sessionId"]?.stringValue)
            let identity = try #require(row["subagent"])
            let entry = try #require(catalog.first { $0["id"]?.stringValue == id })
            #expect(identity["mode"]?.stringValue == entry["mode"]?.stringValue)
            #expect(identity["label"]?.stringValue == entry["label"]?.stringValue)
        }
    }
}
