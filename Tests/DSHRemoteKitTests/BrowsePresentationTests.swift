import Foundation
import Testing

@testable import DSHRemoteKit

/// Home's two lists and a project's grouped sessions (issue #61).
///
/// These rules moved out of the app target into the kit in the same change: `BrowseState`
/// was pure values with no SwiftUI in it, and living behind the app target meant the
/// ordering and filtering below could not be tested at all.
@Suite("Browse presentation")
struct BrowsePresentationTests {

    // MARK: - Fixtures

    /// A fixed calendar and reference date, because "today" is the assertion.
    ///
    /// Chicago, matching the machine the app is used on, and a Wednesday at 2 pm so a
    /// session a few hours old is still *today* and one 30 hours old is *yesterday* —
    /// an early-morning reference makes "an hour ago" cross midnight, which is how the
    /// first version of this fixture asserted the wrong thing.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private static let now = Date(timeIntervalSince1970: 1_772_049_600) // 2026-02-25 14:00 CT, a Wednesday

    private func at(hoursAgo: Double) -> Date {
        Self.now.addingTimeInterval(-hoursAgo * 3_600)
    }

    private func session(
        _ id: String,
        _ title: String = "A session",
        updated: Date?,
        running: Bool = false,
        needsInput: Bool = false,
        subagent: Bool = false
    ) -> BrowseSession {
        BrowseSession(
            id: id,
            title: title,
            running: running,
            updatedAt: updated,
            isSubagent: subagent,
            needsInput: needsInput,
            isLoaded: updated != nil
        )
    }

    private func workspace(_ id: String, _ sessions: [BrowseSession]) -> BrowseWorkspace {
        BrowseWorkspace(id: id, title: id, path: "/Users/example/repo/\(id)", sessions: sessions)
    }

    private func state(_ workspaces: [BrowseWorkspace]) -> BrowseState {
        BrowseState(workspaces: workspaces, workspacesState: .current, sessionsState: .current)
    }

    // MARK: - Projects

    @Test("projects puts the workspace worked in most recently first")
    func projectsNewestFirst() {
        let state = state([
            workspace("old", [session("a", updated: at(hoursAgo: 500))]),
            workspace("fresh", [session("b", updated: at(hoursAgo: 1))]),
            workspace("middle", [session("c", updated: at(hoursAgo: 30))]),
        ])

        #expect(state.projects.map(\.id) == ["fresh", "middle", "old"])
    }

    @Test("projects ranks a workspace by its newest session, not its first or its last")
    func projectsUseTheNewestSession() {
        let state = state([
            workspace("mixed", [
                session("a", updated: at(hoursAgo: 900)),
                session("b", updated: at(hoursAgo: 2)),
                session("c", updated: at(hoursAgo: 400)),
            ]),
            workspace("other", [session("d", updated: at(hoursAgo: 10))]),
        ])

        #expect(state.projects.map(\.id) == ["mixed", "other"])
    }

    @Test("a workspace with no timed session keeps registry order behind the timed ones")
    func projectsWithoutDatesGoLast() {
        // The host reports a workspace before its index arrives, so this is a real state:
        // an empty or dateless workspace is not "old", it is unknown, and it must not
        // displace a workspace we can date.
        let state = state([
            workspace("empty", []),
            workspace("timed", [session("a", updated: at(hoursAgo: 5))]),
            workspace("dateless", [session("b", updated: nil)]),
        ])

        #expect(state.projects.map(\.id) == ["timed", "empty", "dateless"])
    }

    @Test("the ungrouped sentinel sorts last even when it holds the newest session")
    func ungroupedSortsLast() {
        // Sessions the registry did not file under a workspace are still reachable, but
        // "Ungrouped" is not a project and does not head the list.
        let state = state([
            workspace(BrowseWorkspace.ungroupedId, [session("a", updated: at(hoursAgo: 0.5))]),
            workspace("homelab", [session("b", updated: at(hoursAgo: 40))]),
        ])

        #expect(state.projects.map(\.id) == ["homelab", BrowseWorkspace.ungroupedId])
    }

    // MARK: - Recents

    @Test("recents spans every project, newest first, and stops at the limit")
    func recentsAreCrossProject() {
        let state = state([
            workspace("homelab", [session("a", updated: at(hoursAgo: 1))]),
            workspace("nst", [session("b", updated: at(hoursAgo: 2))]),
            workspace("thrifter", [session("c", updated: at(hoursAgo: 3))]),
            workspace("gaia", [session("d", updated: at(hoursAgo: 4))]),
            workspace("cortex", [session("e", updated: at(hoursAgo: 5))]),
        ])

        #expect(state.recent(limit: 4).map(\.id) == ["a", "b", "c", "d"])
    }

    @Test("recents leaves out a subagent, which is a session nobody means to continue")
    func recentsDropSubagents() {
        let state = state([
            workspace("dsh-mobile", [
                session("sub", updated: at(hoursAgo: 0.1), subagent: true),
                session("real", updated: at(hoursAgo: 1)),
            ]),
        ])

        #expect(state.recent(limit: 4).map(\.id) == ["real"])
    }

    // MARK: - A project's sessions

    @Test("a project's sessions are newest first and leave out its subagents")
    func projectSessions() {
        let state = state([
            workspace("homelab", [
                session("old", updated: at(hoursAgo: 40)),
                session("sub", updated: at(hoursAgo: 1), subagent: true),
                session("new", updated: at(hoursAgo: 2)),
            ]),
        ])

        #expect(state.sessions(in: "homelab").map(\.id) == ["new", "old"])
    }

    @Test("a project's visible count equals the list it opens")
    func visibleCountMatchesTheList() {
        // The row says "2 sessions" and the screen it opens must show two. Counting
        // subagents in the row but hiding them in the list is how those disagree.
        let state = state([
            workspace("homelab", [
                session("a", updated: at(hoursAgo: 1)),
                session("sub", updated: at(hoursAgo: 2), subagent: true),
                session("b", updated: at(hoursAgo: 3)),
            ]),
        ])

        #expect(state.workspace(id: "homelab")?.visibleSessionCount == 2)
        #expect(state.sessions(in: "homelab").count == 2)
    }

    // MARK: - Date groups

    @Test("sessions are grouped into today, yesterday and earlier against the reference date")
    func grouping() {
        let state = state([
            workspace("homelab", [
                session("t1", updated: at(hoursAgo: 1)),
                session("t2", updated: at(hoursAgo: 6)),
                session("y1", updated: at(hoursAgo: 30)),
                session("e1", updated: at(hoursAgo: 100)),
            ]),
        ])

        let groups = state.groupedSessions(in: "homelab", now: Self.now, calendar: Self.calendar)

        // One comparison of the whole shape, and no subscripting: an expectation that
        // fails still runs the next line, so `groups[2]` on a two-group result crashed
        // the suite instead of reporting a failure.
        #expect(groups.map(\.title) == ["Today", "Yesterday", "Earlier"])
        #expect(groups.map { $0.sessions.map(\.id) } == [["t1", "t2"], ["y1"], ["e1"]])
    }

    @Test("a span with nothing in it is omitted rather than shown empty")
    func emptySpansAreOmitted() {
        let state = state([
            workspace("homelab", [session("t1", updated: at(hoursAgo: 1))]),
        ])

        let groups = state.groupedSessions(in: "homelab", now: Self.now, calendar: Self.calendar)

        #expect(groups.map(\.title) == ["Today"])
    }

    @Test("a session with no timestamp gets its own heading, never a claim that it is old")
    func undatedSessionsAreNotEarlier() {
        // "Earlier" asserts the session is older than yesterday, and the host did not say
        // that — this is the registry listing a session whose record never arrived.
        let state = state([
            workspace("homelab", [
                session("t1", updated: at(hoursAgo: 1)),
                session("unknown", updated: nil),
            ]),
        ])

        let groups = state.groupedSessions(in: "homelab", now: Self.now, calendar: Self.calendar)

        #expect(groups.map(\.title) == ["Today", "No date reported"])
        #expect(groups.map { $0.sessions.map(\.id) } == [["t1"], ["unknown"]])
    }

    @Test("grouping a workspace with nothing in it produces no headings at all")
    func emptyProjectHasNoGroups() {
        let state = state([workspace("cortex", [])])

        #expect(state.groupedSessions(in: "cortex", now: Self.now, calendar: Self.calendar).isEmpty)
    }

    @Test("grouping a workspace the host never reported is empty, not a crash")
    func unknownWorkspaceIsEmpty() {
        let state = state([workspace("homelab", [session("a", updated: at(hoursAgo: 1))])])

        #expect(state.sessions(in: "nope").isEmpty)
        #expect(state.groupedSessions(in: nil, now: Self.now, calendar: Self.calendar).isEmpty)
    }

    @Test("grouped sessions keep the live state each row needs")
    func groupingKeepsState() {
        let state = state([
            workspace("homelab", [
                session("waiting", "Find NAS disk activity", updated: at(hoursAgo: 1), running: true, needsInput: true),
            ]),
        ])

        let row = state.groupedSessions(in: "homelab", now: Self.now, calendar: Self.calendar).first?.sessions.first

        #expect(row?.needsInput == true)
        #expect(row?.running == true)
    }
}
