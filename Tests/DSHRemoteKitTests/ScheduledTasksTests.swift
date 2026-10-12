import Foundation
import Testing
@testable import DSHRemoteKit

// `scheduledTasks/list` — the namespace the desktop profile actually serves, and the reason
// the Scheduled tasks screen was empty. `schedule/catalog` 404s on this host because the
// bundle that registers it is not loaded (PUSH-NOTIFICATIONS-SPEC §1); this is the peer
// feature that is loaded, and its wire shape is a third one:
//
//   * `session/list` wraps its array in `items`;
//   * `schedule/catalog` is a **bare array**;
//   * `scheduledTasks/list` wraps its array in `tasks`.
//
// The first test decodes the live capture, so a key renamed on the host fails here rather
// than showing an empty screen.

@Suite("Scheduled tasks")
struct ScheduledTasksTests {
    // MARK: - Decoding the capture

    @Test("the captured list decodes every task with its schedule, target and last run")
    func capturedListDecodes() throws {
        let response = try Fixtures.decode(RPCResponse<ScheduledTaskList>.self, .rpcScheduledTasksList)

        #expect(response.result.ok)
        let tasks = try #require(response.result.value?.tasks)
        #expect(tasks.count == 3)
        #expect(tasks.map(\.id) == ["task-0001", "task-0002", "task-0003"])
        #expect(tasks.map(\.title) == ["Morning brief", "Daily reflection", "Weekly plan"])
        #expect(tasks.allSatisfy { $0.enabled })
    }

    @Test("the two weekly arms keep their own weekdays and no other arm's parameters")
    func weeklyArmsReadOnlyTheirOwnKeys() throws {
        let tasks = try #require(
            try Fixtures.decode(RPCResponse<ScheduledTaskList>.self, .rpcScheduledTasksList)
                .result.value?.tasks
        )
        let weekdaysOnly = try #require(tasks.first { $0.id == "task-0001" })
        #expect(weekdaysOnly.schedule.kind == .weekly)
        #expect(weekdaysOnly.schedule.weekdays == [1, 2, 3, 4, 5])
        #expect(weekdaysOnly.schedule.time == "07:00:00.000")
        #expect(weekdaysOnly.schedule.timeZone == "America/Chicago")
        // An arm that carries no `everySeconds` must not report one.
        #expect(weekdaysOnly.schedule.everySeconds == nil)
        #expect(weekdaysOnly.schedule.afterSeconds == nil)

        let sunday = try #require(tasks.first { $0.id == "task-0003" })
        #expect(sunday.schedule.weekdays == [7])

        let daily = try #require(tasks.first { $0.id == "task-0002" })
        #expect(daily.schedule.kind == .daily)
        #expect(daily.schedule.weekdays == nil)
    }

    @Test("scheduledAt is the next occurrence, read as an instant")
    func scheduledAtParsesAsAnInstant() throws {
        let tasks = try #require(
            try Fixtures.decode(RPCResponse<ScheduledTaskList>.self, .rpcScheduledTasksList)
                .result.value?.tasks
        )
        // The host writes fractional seconds; the planner depends on this parsing.
        let brief = try #require(tasks.first { $0.id == "task-0001" })
        #expect(WireTimestamp.date(from: brief.schedule.scheduledAt) != nil)
        #expect(brief.schedule.scheduledAt == "2026-10-13T12:00:00.000Z")
    }

    @Test("the target and the last run's session come through")
    func targetAndLastRunDecode() throws {
        let tasks = try #require(
            try Fixtures.decode(RPCResponse<ScheduledTaskList>.self, .rpcScheduledTasksList)
                .result.value?.tasks
        )
        let brief = try #require(tasks.first { $0.id == "task-0001" })
        #expect(brief.target.model == "Spark")
        #expect(brief.target.provider == "gaia-local")
        let run = try #require(brief.lastRun)
        #expect(run.ok)
        #expect(run.sessionId == "session-0001")
        #expect(run.error == nil)
    }

    // MARK: - Shapes the capture does not exercise

    /// A run that never started a session is `{sessionId: null, ok: false, error: "…"}`. The
    /// capture has no failed run, so this is built by hand from the plugin's own schema
    /// (`lib/schema.js`, `runRecord`) rather than pretended to be evidence.
    @Test("a run that never started decodes with no session and the host's reason")
    func failedRunDecodes() throws {
        let task = try decodeTask("""
        {"id":"t","title":"T","enabled":true,"workspaceId":"","createdAt":"2026-10-12T00:00:00Z",
         "updatedAt":"2026-10-12T00:00:00Z",
         "schedule":{"id":"t","kind":"daily","title":"T","prompt":"p","time":"07:00:00.000",
                     "timeZone":"America/Chicago","scheduledAt":"2026-10-13T12:00:00.000Z"},
         "target":{"provider":"p","model":"m","effort":"","preset":""},
         "lastRun":{"occurrenceAt":"2026-10-12T12:00:00.000Z","sessionId":null,
                    "finishedAt":"2026-10-12T12:00:00.100Z","ok":false,"error":"sessionController unavailable"}}
        """)

        let run = try #require(task.lastRun)
        #expect(run.ok == false)
        #expect(run.sessionId == nil)
        #expect(run.error == "sessionController unavailable")
    }

    /// SPEC §5: a `kind` this build does not know must stay readable, and its timing
    /// parameter must not be read from a sibling arm's key.
    @Test("an unknown schedule arm decodes and reports no timing it did not read")
    func unknownArmDecodes() throws {
        let task = try decodeTask("""
        {"id":"t","title":"T","enabled":true,"workspaceId":"","createdAt":"2026-10-12T00:00:00Z",
         "updatedAt":"2026-10-12T00:00:00Z",
         "schedule":{"id":"t","kind":"fortnightly","title":"T","prompt":"p",
                     "everySeconds":90,"scheduledAt":"2026-10-13T12:00:00.000Z"},
         "target":{"provider":"p","model":"m","effort":"","preset":""}}
        """)

        #expect(task.schedule.kind == .other("fortnightly"))
        #expect(task.schedule.kind.wireValue == "fortnightly")
        #expect(task.schedule.everySeconds == nil)
        #expect(task.lastRun == nil)
    }

    /// The absent case, which is not the same as an empty list: a task with no `lastRun` key
    /// has never run, and the screen must not draw a run for it.
    @Test("a task with no lastRun decodes rather than failing")
    func absentLastRunDecodes() throws {
        let task = try decodeTask("""
        {"id":"t","title":"T","enabled":false,"workspaceId":"","createdAt":"2026-10-12T00:00:00Z",
         "updatedAt":"2026-10-12T00:00:00Z",
         "schedule":{"id":"t","kind":"every","title":"T","prompt":"p","everySeconds":3600,
                     "scheduledAt":"2026-10-13T12:00:00.000Z"},
         "target":{"provider":"p","model":"m","effort":"","preset":""}}
        """)
        #expect(task.lastRun == nil)
        #expect(task.enabled == false)
    }

    // MARK: - The store

    private func store(transport: StubRelayTransport, ledger: CapabilityLedger = CapabilityLedger()) -> SecondaryReadStore {
        SecondaryReadStore(
            makeClient: {
                DshRpcClient(
                    baseURL: URL(string: "https://192.0.2.10:3443")!,
                    authorization: .bearer("device-token"),
                    transport: transport
                )
            },
            ledger: ledger
        )
    }

    @Test("the store reads scheduledTasks/list and reports its tasks")
    func storeReadsThePluginNamespace() async throws {
        let body = try Fixtures.data(.rpcScheduledTasksList)
        let transport = StubRelayTransport(responses: [.json(status: 200, body)])
        let store = store(transport: transport)

        #expect(await store.loadScheduledTasks() == .loaded(itemCount: 3))
        #expect(await store.scheduledTasksState == .current)
        #expect(await store.scheduledTasks.count == 3)
        #expect(await store.scheduledTasks.map(\.title) == ["Morning brief", "Daily reflection", "Weekly plan"])

        let requested = await transport.recordedRequests
        #expect(requested.first?.url.path == "/api/scheduledTasks/list")
    }

    /// The whole point of the correction: on a host that has the other namespace and not
    /// this one, the screen must say *unavailable*, which is a different answer from *failed*
    /// and a different one again from an empty list.
    @Test("a 404 for scheduledTasks/list is unavailable, not a failure")
    func missingNamespaceIsUnavailable() async throws {
        let transport = StubRelayTransport(responses: [
            .json(status: 404, Data("not found".utf8)),
        ])
        let store = store(transport: transport)

        guard case .failed = await store.loadScheduledTasks() else {
            Issue.record("a 404 must be reported as a failed read that the ledger then reads as absence")
            return
        }
        #expect(await store.capabilityLedger.state(of: SecondaryReadStore.scheduledTasksListMethod).isAbsent)
    }

    @Test("a second read is gated once the host has answered 404 for this endpoint")
    func absenceGatesTheNextRead() async throws {
        let transport = StubRelayTransport(responses: [
            .json(status: 404, Data("not found".utf8)),
            .json(status: 200, Data(#"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"tasks":[]}}}"#.utf8)),
        ])
        let store = store(transport: transport)

        _ = await store.loadScheduledTasks()
        let second = await store.loadScheduledTasks()

        guard case .gated = second else {
            Issue.record("a known-absent endpoint must not be asked again, got \(second)")
            return
        }
        #expect(await transport.recordedRequests.count == 1)
    }

    // MARK: - Helpers

    private func decodeTask(_ json: String) throws -> ScheduledTask {
        try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))
    }
}
