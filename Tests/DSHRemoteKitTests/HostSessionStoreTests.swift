import Foundation
import Testing
@testable import DSHRemoteKit

// The six behaviours the store's contract names, driven offline: a stub transport for the
// unary `session/list` call and a stub socket for the two streams, so nothing here touches
// the network (SPEC §2 "Testing").

@Suite("Host session store")
struct HostSessionStoreTests {
    // MARK: - Doubles

    /// Collects what the store publishes, so a test can assert on the pushed snapshot as
    /// well as the pulled one.
    private actor SnapshotRecorder {
        private(set) var snapshots: [HostSessionStore.Snapshot] = []
        func record(_ snapshot: HostSessionStore.Snapshot) { snapshots.append(snapshot) }
        var latest: HostSessionStore.Snapshot? { snapshots.last }
    }

    private func makeCoordinator(_ transport: StubRelayTransport) -> ConnectionCoordinator {
        ConnectionCoordinator(
            origin: .init(
                baseURL: URL(string: "https://relay.test")!,
                authorization: .bearer("saved-token")
            ),
            makeTransport: { _ in transport }
        )
    }

    /// A `$events` ready frame on the given generation, so `connect()` can complete.
    private func ready(_ socket: StubRelaySocket, generation: UInt64) async throws {
        try await socket.push(json: .object([
            "type": .string("item"),
            "streamId": .string(ConnectionCoordinator.eventsStreamID(for: generation)),
            "value": .object([
                "type": .string("ready"),
                "clientId": .string("client-\(generation)"),
            ]),
        ]))
    }

    private func itemFrame(_ value: JSONValue, streamId: String) -> JSONValue {
        .object([
            "type": .string("item"),
            "streamId": .string(streamId),
            "value": value,
        ])
    }

    private func workspace(
        _ workspaceId: String,
        _ path: String,
        _ title: String,
        _ sessionIds: [String]
    ) -> JSONValue {
        .object([
            "workspaceId": .string(workspaceId),
            "path": .string(path),
            "title": .string(title),
            "sessionIds": .array(sessionIds.map { .string($0) }),
        ])
    }

    private func workspaceBaseline(_ workspaces: [JSONValue]) -> JSONValue {
        .object([
            "type": .string("baseline"),
            "value": .object([
                "items": .array(workspaces),
                "archivedSessionIds": .array([]),
                "pinnedSessionIds": .array([]),
            ]),
        ])
    }

    private func workspaceDelta(_ type: String, _ fields: [String: JSONValue]) -> JSONValue {
        .object(["type": .string(type)].merging(fields) { _, new in new })
    }

    private func projection(
        _ sessionId: String,
        _ key: String,
        _ value: JSONValue,
        _ seq: Int64
    ) -> JSONValue {
        .object([
            "type": .string("projection"),
            "sessionId": .string(sessionId),
            "key": .string(key),
            "value": value,
            "seq": .int(seq),
        ])
    }

    private func session(
        _ sessionId: String,
        updatedAt: Int64,
        running: Bool = false,
        parentSessionId: String? = nil,
        origin: String? = nil
    ) -> JSONValue {
        var row: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "updatedAt": .int(updatedAt),
            "running": .bool(running),
            "blank": .bool(false),
            "agentAvailable": .bool(true),
        ]
        if let parentSessionId { row["parentSessionId"] = .string(parentSessionId) }
        if let origin { row["origin"] = .string(origin) }
        return .object(row)
    }

    private func successBody(_ value: JSONValue) throws -> Data {
        try JSONEncoder().encode(JSONValue.object([
            "type": .string("server-response"),
            "rpcId": .string("test"),
            "result": .object(["ok": .bool(true), "value": value]),
        ]))
    }

    private func refusalBody() throws -> Data {
        try JSONEncoder().encode(JSONValue.object([
            "type": .string("server-response"),
            "rpcId": .string("test"),
            "result": .object([
                "ok": .bool(false),
                "error": .object([
                    "code": .string("gateway/arguments-invalid"),
                    "message": .string("the gateway refused session/list"),
                ]),
            ]),
        ]))
    }

    /// Polls until `condition` holds. Generous on purpose: a flaky test teaches people to
    /// re-run failures, which is how a real regression gets waved through.
    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    // MARK: - 1. The ordered workspace registry

    @Test("a workspace baseline plus every delta builds the ordered registry")
    func workspaceRegistry() async throws {
        let socket = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [socket])
        try await ready(socket, generation: 1)
        let coordinator = makeCoordinator(transport)
        _ = try await coordinator.connect()
        let store = HostSessionStore(
            coordinator: coordinator,
            makeRPCClient: { makeTestRPCClient(transport) }
        )

        let updates = await store.snapshots()
        let recorder = SnapshotRecorder()
        let pump = Task { for await snapshot in updates { await recorder.record(snapshot) } }

        #expect(await store.start() == 1)

        // Both endpoints are opened with empty args: the stream ID is the store's own, and
        // `{}` is the whole argument object the contract gives them.
        let texts = await socket.sentTexts
        let opens = try texts
            .map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            .filter { $0["type"]?.stringValue == "open" }
        let endpoints = opens.compactMap { $0["endpoint"]?.stringValue }
        #expect(endpoints.contains(HostSessionStore.workspaceEndpoint))
        #expect(endpoints.contains(HostSessionStore.controlEndpoint))
        for open in opens {
            #expect(open["payload"]?["args"] == JSONValue.object([:]))
        }

        let streamId = HostSessionStore.workspaceStreamID(for: 1)
        try await socket.push(json: itemFrame(workspaceBaseline([
            workspace("w1", "/one", "One", ["s1", "s2"]),
            workspace("w2", "/two", "Two", ["s3"]),
            workspace("w3", "/three", "Three", []),
        ]), streamId: streamId))
        try await socket.push(json: itemFrame(workspaceDelta("upsert", [
            "workspace": workspace("w4", "/four", "Four", ["s4"]),
        ]), streamId: streamId))
        try await socket.push(json: itemFrame(workspaceDelta("upsert", [
            "workspace": workspace("w1", "/one", "One updated", ["s1", "s2"]),
        ]), streamId: streamId))
        try await socket.push(json: itemFrame(workspaceDelta("remove", [
            "workspaceId": .string("w2"),
        ]), streamId: streamId))
        try await socket.push(json: itemFrame(workspaceDelta("order", [
            "workspaceIds": .array([.string("w4"), .string("w1"), .string("w3")]),
        ]), streamId: streamId))
        try await socket.push(json: itemFrame(workspaceDelta("archived", [
            "archivedSessionIds": .array([.string("s7"), .string("s8")]),
        ]), streamId: streamId))
        try await socket.push(json: itemFrame(workspaceDelta("pinned", [
            "pinnedSessionIds": .array([.string("s2")]),
        ]), streamId: streamId))

        // The final state is the only safe thing to read: the last frame of the script
        // must have been applied, not merely the one that first made the order right.
        #expect(await eventually {
            guard let latest = await recorder.latest else { return false }
            return latest.workspaces.map(\.workspaceId) == ["w4", "w1", "w3"]
                && latest.archivedSessionIds == ["s7", "s8"]
                && latest.pinnedSessionIds == ["s2"]
        })

        let snapshot = await store.snapshot()
        #expect(snapshot.workspaces.map(\.workspaceId) == ["w4", "w1", "w3"])
        #expect(snapshot.workspaces.first?.title == "Four")
        // `upsert` replaces in place: it never moves a workspace.
        #expect(snapshot.workspaces[1].title == "One updated")
        #expect(snapshot.workspaces[1].sessionIds == ["s1", "s2"])
        #expect(snapshot.sections.map(\.workspaceId) == ["w4", "w1", "w3"])
        #expect(snapshot.archivedSessionIds == ["s7", "s8"])
        #expect(snapshot.pinnedSessionIds == ["s2"])
        #expect(snapshot.workspacesState.diagnosticName == "current")

        pump.cancel()
        await coordinator.shutdown()
    }

    // MARK: - 2. The session index and its sections

    @Test("session/list fills the index and workspace membership names the sections")
    func sessionIndexAndMembership() async throws {
        let socket = StubRelaySocket()
        let body = try successBody(.object(["items": .array([
            session("a", updatedAt: 1, running: true),
            session("b", updatedAt: 2),
            session("c", updatedAt: 3, parentSessionId: "a", origin: "subagent"),
        ])]))
        let transport = StubRelayTransport(responses: [.json(status: 200, body)], sockets: [socket])
        try await ready(socket, generation: 1)
        let coordinator = makeCoordinator(transport)
        _ = try await coordinator.connect()
        let store = HostSessionStore(
            coordinator: coordinator,
            makeRPCClient: { makeTestRPCClient(transport) }
        )
        #expect(await store.start() == 1)

        await store.refreshSessions()
        var snapshot = await store.snapshot()
        #expect(snapshot.sessions.keys.sorted() == ["a", "b", "c"])

        // One call, carrying the per-endpoint `_request` wrapper. There is no cursor, so a
        // second call would not be paging — and there is exactly one.
        let sent = await transport.recordedRequests
        #expect(sent.count == 1)
        #expect(sent.first?.url.path == "/api/\(HostSessionStore.sessionListMethod)")
        let envelope = try JSONDecoder().decode(JSONValue.self, from: #require(sent.first?.body))
        #expect(envelope["method"]?.stringValue == HostSessionStore.sessionListMethod)
        #expect(envelope["payload"]?["args"] == JSONValue.object(["_request": .object([:])]))

        #expect(snapshot.sessions["a"]?.updatedAt == 1)
        #expect(snapshot.sessions["a"]?.running == true)
        // The two keys `SessionSummary` does not model still arrive: the row is decoded
        // from the descriptor's own field list, not from that narrower type.
        #expect(snapshot.sessions["c"]?.parentSessionId == "a")
        #expect(snapshot.sessions["c"]?.origin == "subagent")
        #expect(snapshot.sessionsState.diagnosticName == "current")

        #expect(await store.applyWorkspace(workspaceBaseline([
            workspace("w1", "/one", "One", ["a", "b"]),
        ]), generation: 1))

        snapshot = await store.snapshot()
        #expect(snapshot.sections.count == 2)
        #expect(snapshot.sections[0].workspaceId == "w1")
        #expect(snapshot.sections[0].title == "One")
        #expect(snapshot.sections[0].sessionIds == ["a", "b"])
        #expect(snapshot.sections[1].workspaceId == nil)
        #expect(snapshot.sections[1].title == HostSessionStore.ungroupedSectionTitle)
        #expect(snapshot.sections[1].sessionIds == ["c"])

        // Membership is the workspace's own list: once it claims `c`, the named ungrouped
        // section has nothing left and is gone.
        #expect(await store.applyWorkspace(workspaceBaseline([
            workspace("w1", "/one", "One", ["a", "b", "c"]),
        ]), generation: 1))
        snapshot = await store.snapshot()
        #expect(snapshot.sections.count == 1)
        #expect(snapshot.sections[0].sessionIds == ["a", "b", "c"])

        await coordinator.shutdown()
    }

    // MARK: - 3. Projection versions

    @Test("projection versions are tracked per session and per key")
    func projectionVersions() async throws {
        let socket = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [socket])
        try await ready(socket, generation: 1)
        let coordinator = makeCoordinator(transport)
        _ = try await coordinator.connect()
        let store = HostSessionStore(
            coordinator: coordinator,
            makeRPCClient: { makeTestRPCClient(transport) }
        )
        #expect(await store.start() == 1)

        // A baseline's `asOfSeq` orders only the keys its own wrapper supplies.
        #expect(await store.applyControl(.object([
            "type": .string("baseline"),
            "value": .object([
                "projections": .object([
                    "s1": .object([
                        "kind": .string("sequenced"),
                        "asOfSeq": .int(5),
                        "values": .object([
                            "title": .string("from-baseline"),
                            "running": .bool(false),
                        ]),
                    ]),
                ]),
            ]),
        ]), generation: 1))

        // Two different keys arriving at the same `seq` both survive. A single high-water
        // mark per session would keep only the first of them.
        #expect(await store.applyControl(projection("s1", "title", .string("title-5"), 5), generation: 1))
        #expect(await store.applyControl(projection("s1", "running", .bool(true), 5), generation: 1))
        var snapshot = await store.snapshot()
        #expect(snapshot.projections["s1"]?.count == 2)
        #expect(snapshot.projections["s1"]?["title"]?.value == .string("title-5"))
        #expect(snapshot.projections["s1"]?["running"]?.value == .bool(true))

        // Strictly older for that key is ignored...
        #expect(await store.applyControl(projection("s1", "title", .string("stale"), 4), generation: 1) == false)
        // ...and a key's own first value is unaffected by another key's version.
        #expect(await store.applyControl(projection("s1", "plan", .string("plan-4"), 4), generation: 1))
        snapshot = await store.snapshot()
        #expect(snapshot.projections["s1"]?["title"]?.value == .string("title-5"))
        #expect(snapshot.projections["s1"]?["plan"]?.value == .string("plan-4"))

        // Independently newer is accepted.
        #expect(await store.applyControl(projection("s1", "title", .string("title-6"), 6), generation: 1))
        snapshot = await store.snapshot()
        #expect(snapshot.projections["s1"]?["title"]?.value == .string("title-6"))
        #expect(snapshot.projections["s1"]?["title"]?.seq == 6)
        #expect(snapshot.controlState.diagnosticName == "current")

        await coordinator.shutdown()
    }

    // MARK: - 4. A failed refresh keeps what it had

    @Test("a failed refresh retains the loaded sessions and leaves the status alone")
    func failedRefreshRetains() async throws {
        let socket = StubRelaySocket()
        let body = try successBody(.object(["items": .array([
            session("a", updatedAt: 1),
            session("b", updatedAt: 2),
        ])]))
        let refusal = try refusalBody()
        let transport = StubRelayTransport(
            responses: [.json(status: 200, body), .json(status: 200, refusal)],
            sockets: [socket]
        )
        try await ready(socket, generation: 1)
        let coordinator = makeCoordinator(transport)
        _ = try await coordinator.connect()
        let store = HostSessionStore(
            coordinator: coordinator,
            makeRPCClient: { makeTestRPCClient(transport) }
        )

        await store.refreshSessions()
        #expect(await store.snapshot().sessions.count == 2)
        #expect(await coordinator.status == .connected)

        await store.refreshSessions()
        let snapshot = await store.snapshot()
        #expect(snapshot.sessions.keys.sorted() == ["a", "b"])
        #expect(snapshot.sessionsState.diagnosticName == "stale")
        #expect(snapshot.sessionsState.hasData)
        // The store makes its own unary call precisely so this holds: a session list that
        // failed says nothing about the socket.
        #expect(await coordinator.status == .connected)

        await coordinator.shutdown()
    }

    // MARK: - 5. Generation isolation

    @Test("a result from an older generation is discarded")
    func olderGenerationDiscarded() async throws {
        let first = StubRelaySocket(), second = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [first, second])
        try await ready(first, generation: 1)
        try await ready(second, generation: 2)
        let coordinator = makeCoordinator(transport)
        _ = try await coordinator.connect()
        _ = try await coordinator.connect()
        let store = HostSessionStore(
            coordinator: coordinator,
            makeRPCClient: { makeTestRPCClient(transport) }
        )
        #expect(await store.start() == 2)

        let baseline = workspaceBaseline([workspace("w1", "/one", "One", ["s1"])])
        #expect(await store.applyWorkspace(baseline, generation: 1) == false)
        #expect(await store.applyControl(projection("s1", "title", .string("gen-1"), 3), generation: 1) == false)
        #expect(await store.snapshot().workspaces.isEmpty)
        #expect(await store.snapshot().projections.isEmpty)

        // The same frames on the generation that owns the connection are applied.
        #expect(await store.applyWorkspace(baseline, generation: 2))
        #expect(await store.applyControl(projection("s1", "title", .string("gen-2"), 3), generation: 2))
        let snapshot = await store.snapshot()
        #expect(snapshot.workspaces.map(\.workspaceId) == ["w1"])
        #expect(snapshot.projections["s1"]?["title"]?.value == .string("gen-2"))

        await coordinator.shutdown()
    }

    // MARK: - 6. Three distinguishable load states

    @Test("empty-loading, empty-success, and failed are three states")
    func loadStates() async throws {
        let empty = try successBody(.object(["items": .array([])]))
        let refusal = try refusalBody()
        let transport = StubRelayTransport(responses: [
            .json(status: 200, empty),
            .json(status: 200, refusal),
        ])
        let coordinator = makeCoordinator(transport)
        let store = HostSessionStore(
            coordinator: coordinator,
            makeRPCClient: { makeTestRPCClient(transport) }
        )

        // Nothing has loaded: a load in flight with nothing to show.
        var snapshot = await store.snapshot()
        #expect(snapshot.sessionsState.diagnosticName == "loading")
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.sessionsState.hasData == false)

        // The host answered, and the answer was nothing.
        await store.refreshSessions()
        snapshot = await store.snapshot()
        #expect(snapshot.sessionsState.diagnosticName == "empty")
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.sessionsState.hasData == false)

        // The host refused, and there was nothing to keep.
        await store.refreshSessions()
        snapshot = await store.snapshot()
        #expect(snapshot.sessionsState.diagnosticName == "failed")
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.sessionsState.hasData == false)

        // The streams are separate resources with their own states, so a failed list does
        // not relabel them.
        #expect(snapshot.workspacesState.diagnosticName == "loading")
        #expect(snapshot.controlState.diagnosticName == "loading")
    }
}

/// The unary client the store is given, over a stub transport so nothing opens a socket.
private func makeTestRPCClient(_ transport: StubRelayTransport) -> DshRpcClient {
    DshRpcClient(
        baseURL: URL(string: "https://relay.test")!,
        authorization: .bearer("saved-token"),
        transport: transport
    )
}

/// SPEC §4's archived rule, which the browse list has to honour.
@Suite("Session visibility")
struct SessionVisibilityTests {
    @Test("archived sessions are filtered out, and everything else keeps its order")
    func archivedAreHidden() {
        #expect(SessionVisibility.visible(
            sessionIds: ["a", "s7", "b", "s8"],
            archivedSessionIds: ["s7", "s8"]
        ) == ["a", "b"])

        // No archived ids is the common case and must not reorder or drop anything.
        #expect(SessionVisibility.visible(sessionIds: ["a", "b"], archivedSessionIds: []) == ["a", "b"])
        // An archived id that is not in the section changes nothing.
        #expect(SessionVisibility.visible(sessionIds: ["a"], archivedSessionIds: ["zz"]) == ["a"])
        #expect(SessionVisibility.isArchived("s7", archivedSessionIds: ["s7"]))
        #expect(!SessionVisibility.isArchived("s9", archivedSessionIds: ["s7"]))
    }
}
