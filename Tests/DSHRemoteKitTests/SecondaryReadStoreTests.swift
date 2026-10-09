import Foundation
import Testing
@testable import DSHRemoteKit

// SPEC §10's capability gating and SPEC §3's per-resource state, against the two wire
// shapes the drawer's secondary panels read: `schedule/catalog`'s **bare array** of a
// six-arm union, and `pluginInventory/list`'s snapshot whose `meta.title` may be a string
// or a translation map.

@Suite("Secondary reads")
struct SecondaryReadStoreTests {
    // MARK: - Fixtures

    private func store(
        transport: StubRelayTransport,
        ledger: CapabilityLedger = CapabilityLedger(),
        origin: URL = URL(string: "https://192.0.2.10:3443")!
    ) -> SecondaryReadStore {
        SecondaryReadStore(
            makeClient: {
                DshRpcClient(
                    baseURL: origin,
                    authorization: .bearer("device-token"),
                    transport: transport
                )
            },
            ledger: ledger
        )
    }

    private func envelope(_ value: String) -> Data {
        Data(#"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":\#(value)}}"#.utf8)
    }

    private func success(_ value: String) -> StubRelayTransport.Stub {
        .json(status: 200, envelope(value))
    }

    /// One entry of each arm the drawer shows, in the bare array `schedule/catalog` and
    /// `schedule/list` return — no `items` key anywhere in the envelope.
    private static let catalogJSON = """
    [
     {"id":"a1","kind":"after","title":"After","prompt":"p1","afterSeconds":120,"scheduledAt":"2026-10-09T10:00:00Z","sessionId":"s1","status":"active","lastDelivery":{"scheduledAt":"2026-10-08T09:00:00Z","deliveredAt":"2026-10-08T09:00:01Z","messageId":"m1"}},
     {"id":"a2","kind":"at","title":"At","prompt":"p2","scheduledAt":"2026-10-09T11:00:00Z","sessionId":"s1","status":"inactive"},
     {"id":"a3","kind":"every","title":"Every","prompt":"p3","everySeconds":60,"scheduledAt":"2026-10-09T12:00:00Z","sessionId":"s1","status":"active"}
    ]
    """

    /// The `schedule/list` arm is the *bare* scheduling object: the descriptor intersects
    /// the catalog arms with `{sessionId, status, lastDelivery?}` but not this one.
    private static let listJSON = """
    [{"id":"e1","kind":"after","title":"After","prompt":"p","afterSeconds":30,"scheduledAt":"2026-10-09T10:00:00Z"}]
    """

    /// Four entries covering both `meta.title` forms and both an unknown and a null phase.
    private static let pluginJSON = """
    {"managementAvailable":true,"entries":[
     {"entryId":"e1","moduleName":"mod.plain","enabled":true,"fiberPhase":"active","meta":{"title":"Plain","description":"Plain description"}},
     {"entryId":"e2","moduleName":"mod.translated","enabled":false,"fiberPhase":null,"meta":{"title":{"en":"Hello","fr":"Bonjour"},"description":{"en":"English description"}}},
     {"entryId":"e3","moduleName":"mod.french","enabled":false,"fiberPhase":"hibernating","meta":{"title":{"fr":"Bonjour"}}},
     {"entryId":"e4","moduleName":"mod.multilingual","enabled":true,"fiberPhase":"pending","meta":{"title":{"de":"Hallo","fr":"Bonjour"}}}
    ],"agentPresets":[]}
    """

    // MARK: - schedule/catalog: the union

    @Test("a bare-array catalog decodes one entry per arm, each reading only its own parameter")
    func bareArrayCatalog() async throws {
        let store = store(transport: StubRelayTransport(responses: [success(Self.catalogJSON)]))

        #expect(await store.loadScheduleCatalog() == .loaded(itemCount: 3))
        #expect(await store.scheduleCatalogState == .current)

        let entries = await store.scheduleCatalog
        #expect(entries.map(\.id) == ["a1", "a2", "a3"])
        #expect(entries.map(\.kind) == [.after, .at, .every])

        let after = try #require(entries.first { $0.id == "a1" })
        #expect(after.afterSeconds == 120)
        #expect(after.everySeconds == nil)

        let at = try #require(entries.first { $0.id == "a2" })
        #expect(at.afterSeconds == nil)
        #expect(at.everySeconds == nil)

        let every = try #require(entries.first { $0.id == "a3" })
        #expect(every.everySeconds == 60)
        #expect(every.afterSeconds == nil)
    }

    @Test("an at entry carrying a stray afterSeconds does not report one")
    func strayArmParameterIsNotRead() async throws {
        let json = #"""
        [{"id":"a2","kind":"at","title":"At","prompt":"p","scheduledAt":"2026-10-09T11:00:00Z","sessionId":"s1","status":"active","afterSeconds":999}]
        """#
        let store = store(transport: StubRelayTransport(responses: [success(json)]))

        #expect(await store.loadScheduleCatalog() == .loaded(itemCount: 1))
        let entry = try #require(await store.scheduleCatalog.first)
        #expect(entry.kind == .at)
        // The arm is chosen by `kind` before any key is read, so the stray key is invisible.
        #expect(entry.afterSeconds == nil)
        #expect(entry.everySeconds == nil)
    }

    @Test("an unmodelled kind decodes without inventing another arm's parameter")
    func unknownScheduleKind() async throws {
        let json = #"""
        [{"id":"x","kind":"lunar","title":"Lunar","prompt":"p","scheduledAt":"t","afterSeconds":1,"everySeconds":2,"sessionId":"s","status":"active"}]
        """#
        let store = store(transport: StubRelayTransport(responses: [success(json)]))

        #expect(await store.loadScheduleCatalog() == .loaded(itemCount: 1))
        let entry = try #require(await store.scheduleCatalog.first)
        #expect(entry.kind == .other("lunar"))
        #expect(entry.afterSeconds == nil)
        #expect(entry.everySeconds == nil)
        // The keys every arm shares still read.
        #expect(entry.title == "Lunar")
        #expect(entry.status == .active)
    }

    @Test("lastDelivery decodes when present, and is nil when absent or explicitly null")
    func lastDelivery() async throws {
        let json = """
        [
         {"id":"a1","kind":"after","title":"A","prompt":"p","afterSeconds":1,"scheduledAt":"t","sessionId":"s","status":"active","lastDelivery":{"scheduledAt":"t1","deliveredAt":"t2","messageId":"m1"}},
         {"id":"a2","kind":"at","title":"B","prompt":"p","scheduledAt":"t","sessionId":"s","status":"active"},
         {"id":"a3","kind":"every","title":"C","prompt":"p","everySeconds":5,"scheduledAt":"t","sessionId":"s","status":"active","lastDelivery":null}
        ]
        """
        let store = store(transport: StubRelayTransport(responses: [success(json)]))

        #expect(await store.loadScheduleCatalog() == .loaded(itemCount: 3))
        let entries = await store.scheduleCatalog
        let delivered = try #require(entries.first { $0.id == "a1" })
        let notYet = try #require(entries.first { $0.id == "a2" })
        let nulled = try #require(entries.first { $0.id == "a3" })

        #expect(delivered.lastDelivery?.scheduledAt == "t1")
        #expect(delivered.lastDelivery?.deliveredAt == "t2")
        #expect(delivered.lastDelivery?.messageId == "m1")
        #expect(notYet.lastDelivery == nil)
        #expect(nulled.lastDelivery == nil)
    }

    // MARK: - schedule/list and schedule/history

    @Test("schedule/list sends its one `request` argument and decodes the bare scheduling object")
    func listWireArguments() async throws {
        let transport = StubRelayTransport(responses: [success(Self.listJSON)])
        let store = store(transport: transport)

        #expect(await store.loadScheduleList(sessionId: "s1") == .loaded(itemCount: 1))

        let request = try #require(await transport.recordedRequests.first)
        #expect(request.url.path == "/api/schedule/list")
        let body = try #require(request.body)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: body)
        let args = try #require(decoded["payload"]?["args"])
        #expect(args["request"]?["sessionId"]?.stringValue == "s1")

        // A list entry must not claim a session id or a status the descriptor never sends.
        let entry = try #require(await store.scheduleList.first)
        #expect(entry.kind == .after)
        #expect(entry.afterSeconds == 30)
        #expect(entry.sessionId == nil)
        #expect(entry.status == nil)
    }

    @Test("schedule/history decodes both union arms and sends the cursor")
    func historyUnion() async throws {
        let page = #"{"id":"h1","records":[{"prompt":"p","scheduledAt":"t1","deliveredAt":"t2","messageId":"m1"}],"earlierRecordsUnavailable":false,"earlierRecordsPruned":true,"retention":{"days":30,"records":500},"nextBefore":"c1"}"#
        let refusal = #"{"id":"h1","code":"delivery_cursor_not_found"}"#
        let transport = StubRelayTransport(responses: [success(page), success(refusal)])
        let store = store(transport: transport)

        #expect(await store.loadScheduleHistory(sessionId: "s1", id: "h1", limit: 20) == .loaded(itemCount: 1))
        let first = try #require(await store.scheduleHistory)
        guard case .records(let historyPage) = first else {
            Issue.record("expected a page, got \(first)")
            return
        }
        #expect(historyPage.records.first?.prompt == "p")
        #expect(historyPage.records.first?.messageId == "m1")
        #expect(historyPage.earlierRecordsPruned)
        #expect(historyPage.retention.days == 30)
        #expect(historyPage.nextBefore == "c1")

        // A refusal is the host answering, so the section loaded rather than failed.
        #expect(
            await store.loadScheduleHistory(sessionId: "s1", id: "h1", limit: 20, before: "c0")
                == .loaded(itemCount: 0)
        )
        let second = try #require(await store.scheduleHistory)
        guard case .refused(let id, let code) = second else {
            Issue.record("expected a refusal, got \(second)")
            return
        }
        #expect(id == "h1")
        #expect(code == ScheduleHistoryResult.deliveryCursorNotFoundCode)

        let request = try #require(await transport.recordedRequests.last)
        #expect(request.url.path == "/api/schedule/history")
        let body = try #require(request.body)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: body)
        let args = try #require(decoded["payload"]?["args"])
        #expect(args["request"]?["sessionId"]?.stringValue == "s1")
        #expect(args["request"]?["id"]?.stringValue == "h1")
        #expect(args["request"]?["limit"]?.intValue == 20)
        #expect(args["request"]?["before"]?.stringValue == "c0")
    }

    // MARK: - pluginInventory/list

    @Test("a plugin whose meta.title is a plain string decodes")
    func pluginPlainTitle() async throws {
        let store = store(transport: StubRelayTransport(responses: [success(Self.pluginJSON)]))

        #expect(await store.loadPluginInventory() == .loaded(itemCount: 4))
        let inventory = try #require(await store.pluginInventory)
        #expect(inventory.managementAvailable == true)
        #expect(inventory.offersManagementControls)

        let entry = try #require(inventory.entries.first { $0.entryId == "e1" })
        #expect(entry.meta?.title == .plain("Plain"))
        #expect(entry.meta?.title?.preferredText == "Plain")
        #expect(entry.meta?.description?.preferredText == "Plain description")
    }

    @Test("a localized meta.title prefers en, and falls back to another language rather than dropping")
    func pluginLocalizedTitle() async throws {
        let store = store(transport: StubRelayTransport(responses: [success(Self.pluginJSON)]))
        #expect(await store.loadPluginInventory() == .loaded(itemCount: 4))

        let inventory = try #require(await store.pluginInventory)
        let english = try #require(inventory.entries.first { $0.entryId == "e2" })
        // Decoding the union as a String is what renders nothing here; both forms are modelled.
        #expect(english.meta?.title?.preferredText == "Hello")
        #expect(english.meta?.description?.preferredText == "English description")

        let french = try #require(inventory.entries.first { $0.entryId == "e3" })
        #expect(french.meta?.title?.preferredText == "Bonjour")

        // Several non-English keys: some value survives rather than the title vanishing.
        let multilingual = try #require(inventory.entries.first { $0.entryId == "e4" })
        #expect(multilingual.meta?.title?.preferredText != nil)
    }

    @Test("an unknown fiberPhase decodes without failing the inventory")
    func unknownFiberPhase() async throws {
        let store = store(transport: StubRelayTransport(responses: [success(Self.pluginJSON)]))

        #expect(await store.loadPluginInventory() == .loaded(itemCount: 4))
        let inventory = try #require(await store.pluginInventory)

        #expect(inventory.entries.first { $0.entryId == "e1" }?.fiberPhase == .active)
        // The wire's `null` is "no fiber", not a failure.
        #expect(inventory.entries.first { $0.entryId == "e2" }?.fiberPhase == .absent)
        #expect(inventory.entries.first { $0.entryId == "e3" }?.fiberPhase == .other("hibernating"))
        #expect(inventory.entries.first { $0.entryId == "e4" }?.fiberPhase == .pending)
        #expect(inventory.entries.first { $0.entryId == "e3" }?.fiberPhase.wireValue == "hibernating")
    }

    // MARK: - Gating

    @Test("a capability the host does not implement produces no request at all")
    func unavailableEndpointIsNotRequested() async {
        var ledger = CapabilityLedger()
        let reason = "the host does not implement \(SecondaryReadStore.scheduleCatalogMethod)"
        ledger.set(.unavailable(reason: reason), for: SecondaryReadStore.scheduleCatalogMethod)

        // Nothing is scripted: a request would throw rather than mislead. The assertion
        // that matters is that the transport saw none.
        let transport = StubRelayTransport()
        let store = store(transport: transport, ledger: ledger)

        #expect(await store.loadScheduleCatalog() == .gated(reason: reason))
        #expect(await transport.recordedRequests.isEmpty)
        // Gating is not a load: nothing is left spinning.
        #expect(await store.scheduleCatalogState == nil)
    }

    @Test("a failed capability still permits a retry, because failure is not absence")
    func failedCapabilityStillAttempts() async {
        var ledger = CapabilityLedger()
        ledger.set(.failed(reason: "the connection was interrupted"), for: SecondaryReadStore.scheduleCatalogMethod)
        let transport = StubRelayTransport(responses: [success("[]")])
        let store = store(transport: transport, ledger: ledger)

        #expect(await store.loadScheduleCatalog() == .loaded(itemCount: 0))
        #expect(await transport.recordedRequests.count == 1)
        #expect(await store.scheduleCatalogState == .empty)
    }

    @Test("a 404 on the plugin inventory is recorded as absence, and the next read sends nothing")
    func pluginAbsenceIsRecorded() async {
        let transport = StubRelayTransport(responses: [.json(status: 404, Data("{}".utf8))])
        let store = store(transport: transport)

        let first = await store.loadPluginInventory()
        guard case .failed = first else {
            Issue.record("expected a failure, got \(first)")
            return
        }
        // A 404 is the host saying it has no such endpoint, which is the one state that
        // justifies hiding the section — and the one that then stops the request.
        #expect(await store.capabilityLedger.state(of: SecondaryReadStore.pluginInventoryMethod).isAbsent)
        #expect(await store.pluginInventory == nil)

        #expect(
            await store.loadPluginInventory()
                == .gated(reason: "the host does not implement pluginInventory/list")
        )
        #expect(await transport.recordedRequests.count == 1)
    }

    // MARK: - Failure isolation

    @Test("a failed list read leaves the loaded list intact, and stale is not the same as empty")
    func failedReadKeepsLoadedList() async throws {
        let transport = StubRelayTransport(responses: [
            success(Self.listJSON),
            .json(status: 500, Data()),
            success("[]"),
        ])
        let store = store(transport: transport)

        #expect(await store.loadScheduleList(sessionId: "s1") == .loaded(itemCount: 1))
        #expect(await store.scheduleListState == .current)

        let outcome = await store.loadScheduleList(sessionId: "s1")
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        // Not blanked: the section keeps what it had and only loses freshness.
        #expect(await store.scheduleList.count == 1)
        let stale = try #require(await store.scheduleListState)
        guard case .stale = stale else {
            Issue.record("expected a stale state, got \(stale)")
            return
        }
        #expect(stale != .empty)
        // A 500 says nothing about whether the endpoint exists.
        #expect(await store.capabilityLedger.state(of: SecondaryReadStore.scheduleListMethod).isAbsent == false)

        // An empty answer for another session is a successful empty list — the state a
        // stale failure must stay distinguishable from.
        #expect(await store.loadScheduleList(sessionId: "s2") == .loaded(itemCount: 0))
        #expect(await store.scheduleListState == .empty)
    }

    @Test("a failed plugin read does not blank a schedule catalog that already loaded")
    func pluginFailureKeepsScheduleCatalog() async {
        let transport = StubRelayTransport(responses: [
            success(Self.catalogJSON),
            .json(status: 500, Data()),
        ])
        let store = store(transport: transport)

        #expect(await store.loadScheduleCatalog() == .loaded(itemCount: 3))

        let outcome = await store.loadPluginInventory()
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(await store.scheduleCatalog.count == 3)
        #expect(await store.scheduleCatalogState == .current)
        #expect(await store.pluginInventory == nil)
        #expect(await store.pluginInventoryState?.hasData == false)
    }
}
