import Foundation
import Testing

@testable import DSHRemoteKit

/// #13, slice C: the roster is assembled from two sources that are not the same age.
///
/// `session/control` is live and sparse — its baseline carried 39 sessions where `session/list`
/// carried 200, measured against the relay on 2026-10-15 — while `session/list` is a whole-index
/// refresh carrying every projection key for every row. The rule is per key rather than per
/// session, and these tests pin both halves of that: the live value wins where it exists, and the
/// index row still supplies everything else.
@Suite("Subagent roster sources (#13)")
struct SubagentRosterSourceTests {

    private static let parent = "session-parent-1"

    private func catalogJSON(_ ids: [String]) -> JSONValue {
        .array(ids.map { .object(["mode": .string("continuable"), "label": .string("Child \($0)"), "id": .string($0), "createdAt": .int(1)]) })
    }

    private func row(
        _ id: String,
        values: [String: JSONValue],
        title: String? = nil,
        running: Bool? = nil
    ) -> HostSessionStore.SessionRecord {
        HostSessionStore.SessionRecord(
            sessionId: id,
            running: running,
            projections: nil,
            projectionValues: values
        )
    }

    private func live(_ key: String, _ value: JSONValue, seq: Int64 = 1) -> HostSessionStore.Projection {
        HostSessionStore.Projection(key: key, value: value, seq: seq)
    }

    @Test("AC9: the live control value wins per key over the session index row")
    func liveControlWinsPerKey() {
        // The index row has one timing and one usage bucket; the live stream has a newer timing and
        // says nothing about usage.
        let rows = [
            Self.parent: row(Self.parent, values: ["subagentCatalog": catalogJSON(["subagent-1"])]),
            "subagent-1": row(
                "subagent-1",
                values: [
                    "subagentTiming": .object(["settledMs": .int(100)]),
                    "tokenUsage": .object(["outputTokens": .int(30)]),
                ],
                title: "The row's title",
                running: false
            ),
        ]
        let live: [String: [String: HostSessionStore.Projection]] = [
            "subagent-1": ["subagentTiming": live("subagentTiming", .object(["settledMs": .int(250)]), seq: 9)],
        ]

        let roster = SubagentRoster(parentSessionId: Self.parent, rows: rows, live: live)
        let child = roster.entries.first

        #expect(child?.id == "subagent-1")
        // The live timing, not the row's 100.
        #expect(child?.durationMs(now: 5_000) == 250)
        // The row's usage, because the live stream never sent that key.
        #expect(child?.tokenTotal == 30)
        // `running` and `title` are `session/list` fields and have no other source.
        #expect(child?.isRunning == false)
        #expect(child?.title == "The row's title")
    }

    @Test("AC9: a child with no live value and no row still lists, with nothing reported")
    func aChildWithNoSourceStillLists() {
        let rows = [
            Self.parent: row(Self.parent, values: ["subagentCatalog": catalogJSON(["subagent-absent"])])
        ]

        let roster = SubagentRoster(parentSessionId: Self.parent, rows: rows, live: [:])
        let child = roster.entries.first

        #expect(roster.entries.count == 1)
        #expect(child?.id == "subagent-absent")
        #expect(child?.label == "Child subagent-absent")
        #expect(child?.activity == nil)
        #expect(child?.tokenTotal == nil)
        #expect(child?.durationMs(now: 5_000) == nil)
    }

    @Test("AC9: the live catalog is membership too, and the index row is not membership")
    func membershipIsTheCatalogFromEitherSource() {
        // The index row names two children; the live stream names one. The live one wins, because
        // it is the newer statement — and a child only in the index row is not a child.
        let rows = [
            Self.parent: row(Self.parent, values: ["subagentCatalog": catalogJSON(["subagent-1", "subagent-2"])]),
            "subagent-1": row("subagent-1", values: [:]),
            "subagent-2": row("subagent-2", values: [:]),
        ]
        let live: [String: [String: HostSessionStore.Projection]] = [
            Self.parent: ["subagentCatalog": live("subagentCatalog", catalogJSON(["subagent-1"]))]
        ]

        let roster = SubagentRoster(parentSessionId: Self.parent, rows: rows, live: live)

        #expect(roster.isReported == true)
        #expect(roster.entries.map(\.id) == ["subagent-1"])
    }

    @Test("AC9: no catalog in either source is not reported, not empty")
    func noCatalogAnywhereIsNotReported() {
        let roster = SubagentRoster(parentSessionId: Self.parent, rows: [:], live: [:])

        #expect(roster.isReported == false)
        #expect(roster.entries.isEmpty)
        #expect(roster.showsEntryPoint == false)
    }

    @Test("AC9: the captured fixture assembles through this path too")
    func capturedFixtureAssemblesThroughTheStorePath() throws {
        // The same capture `SubagentRosterTests` reads directly, put through the two-source factory
        // as `session/list` would have delivered it: the parent's catalog and each child's values
        // are exactly the rows' `projections.values`.
        let fixture = try Fixtures.object(.rpcSubagentRoster)
        let parentId = try #require(fixture["parentSessionId"]?.stringValue)
        var rows: [String: HostSessionStore.SessionRecord] = [
            parentId: row(parentId, values: ["subagentCatalog": try #require(fixture["parentSubagentCatalog"])])
        ]
        for child in fixture["childRows"]?.arrayValue ?? [] {
            let id = try #require(child["sessionId"]?.stringValue)
            var values: [String: JSONValue] = [:]
            if let timing = child["subagentTiming"] { values["subagentTiming"] = timing }
            if let usage = child["tokenUsage"] { values["tokenUsage"] = usage }
            rows[id] = row(
                id,
                values: values,
                title: child["title"]?.stringValue,
                running: child["running"]?.boolValue
            )
        }

        let roster = SubagentRoster(parentSessionId: parentId, rows: rows, live: [:])

        #expect(roster.entries.map(\.id) == ["subagent-child-1", "subagent-child-2", "subagent-child-3"])
        #expect(roster.entries.map(\.activity) == [.running, .completed, .inactive])
        #expect(roster.runningCount == 1)
        #expect(roster.needsTick == true)
        // `first`, not `[0]`: against a stub that reports no members an index would kill the whole
        // run and hide every other result, which is what `WORKFLOW.md` step 2 forbids.
        let child = try #require(roster.entries.first)
        #expect(child.durationMs(now: 1792106727891) == 9_634_145)
        #expect(child.tokenTotal == 112_414_835)
    }
}
