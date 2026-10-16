import Foundation
import Testing

@testable import DSHRemoteKit

/// #13: a subagent conversation is read through its **durable parent address**, not its id.
///
/// The host is explicit about it. Probed against the live relay on 2026-10-15:
///
/// ```
/// POST /api/session/page  {"address":{"kind":"session","sessionId":"9b8e505c-…"}}
///   → ok: false, code "session/agent-busy",
///     message "subagent Sessions require their durable parent address"
/// ```
///
/// `session/follow` and `session/page` take the same union, so both are asserted here. A guard
/// pins the ordinary session's address, which is the form every existing caller relies on.
@Suite("Subagent addressing (#13)")
struct SubagentFollowTests {

    private static let parent = "session-4755645d-5216-436e-b438-4564982800f3"
    private static let child = "9b8e505c-5f6e-4eb8-b70c-ccef1b57141b"
    private static let subagent = SessionAddress.subagent(
        parentSessionId: parent,
        childSessionId: child,
        mode: .continuable
    )

    // MARK: - The follow

    private func makeSession(_ address: SessionAddress) -> (chat: ChatSession, socket: StubRelaySocket) {
        let socket = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [socket])
        let client = MuxClient(
            baseURL: URL(string: "https://relay.test")!,
            authorization: .bearer("test-token"),
            transport: transport
        )
        return (ChatSession(client: client, address: address), socket)
    }

    @Test("AC7: a subagent follow opens with the durable parent address")
    func subagentFollowCarriesTheParentAddress() async throws {
        let (chat, socket) = makeSession(Self.subagent)
        try await chat.start()

        let args = try await followArguments(on: socket)
        let address = try #require(args["request"]?["address"])

        #expect(address["kind"]?.stringValue == "subagent")
        #expect(address["parentSessionId"]?.stringValue == Self.parent)
        #expect(address["childSessionId"]?.stringValue == Self.child)
        #expect(address["mode"]?.stringValue == "continuable")
        // The session form is what the host refuses for a child, so its key must be absent rather
        // than merely outvoted.
        #expect(address["sessionId"] == nil)

        await chat.stop()
    }

    @Test("AC7: an ordinary session still follows by session address")
    func ordinarySessionFollowIsUnchanged() async throws {
        let (chat, socket) = makeSession(.session("session-1"))
        try await chat.start()

        let args = try await followArguments(on: socket)
        let address = try #require(args["request"]?["address"])

        #expect(address["kind"]?.stringValue == "session")
        #expect(address["sessionId"]?.stringValue == "session-1")
        #expect(address["parentSessionId"] == nil)

        // The rest of the follow request is what keeps the baseline receivable.
        #expect(args["request"]?["assistantStream"]?.boolValue == true)
        #expect(args["request"]?["maxMessages"]?.intValue == Int64(ChatSession.pageMessages))

        await chat.stop()
    }

    // MARK: - The page

    /// A coordinator whose `session/page` answer is scripted, so the request it built can be read
    /// back. The response body is the shape `SessionPage` has in the descriptor — one durable
    /// event, no more history — because this test is about the address, not the records.
    private func makeCoordinator() -> (coordinator: ConnectionCoordinator, transport: StubRelayTransport) {
        let response = """
        {"type":"server-response","rpcId":"test","result":{"ok":true,"value":{
          "records":[{"type":"event","event":{"type":"user/message","seq":12,"time":1,
            "data":{"content":[{"type":"text","text":"older"}]}}}],
          "hasMore":false}}}
        """
        let transport = StubRelayTransport(responsesByPath: [
            "/api/session/page": .json(status: 200, Data(response.utf8)),
        ])
        let coordinator = ConnectionCoordinator(
            origin: ConnectionCoordinator.Origin(
                baseURL: URL(string: "https://relay.test")!,
                authorization: .bearer("device-token")
            ),
            makeTransport: { _ in transport }
        )
        return (coordinator, transport)
    }

    @Test("AC7: a subagent page carries the durable parent address")
    func subagentPageCarriesTheParentAddress() async throws {
        let (coordinator, transport) = makeCoordinator()

        _ = try await coordinator.page(
            ConversationPageRequest(address: Self.subagent, throughSeq: 40, beforeSeq: 20, maxMessages: 20)
        )

        let requests = await transport.recordedRequests
        let request = try #require(requests.first)
        let envelope = try JSONDecoder().decode(JSONValue.self, from: #require(request.body))
        let address = try #require(envelope["payload"]?["args"]?["request"]?["address"])

        #expect(request.url.path == "/api/session/page")
        #expect(address["kind"]?.stringValue == "subagent")
        #expect(address["parentSessionId"]?.stringValue == Self.parent)
        #expect(address["childSessionId"]?.stringValue == Self.child)
        #expect(address["mode"]?.stringValue == "continuable")
        #expect(address["sessionId"] == nil)
    }

    @Test("AC7: an ordinary session's page is still the session address")
    func ordinarySessionPageIsUnchanged() async throws {
        let (coordinator, transport) = makeCoordinator()

        _ = try await coordinator.page(
            ConversationPageRequest(sessionId: "session-1", throughSeq: 40, beforeSeq: 20, maxMessages: 20)
        )

        let requests = await transport.recordedRequests
        let request = try #require(requests.first)
        let envelope = try JSONDecoder().decode(JSONValue.self, from: #require(request.body))
        let address = try #require(envelope["payload"]?["args"]?["request"]?["address"])

        #expect(address["kind"]?.stringValue == "session")
        #expect(address["sessionId"]?.stringValue == "session-1")
        #expect(address["parentSessionId"] == nil)
    }

    // MARK: - The address itself

    @Test("AC7: the address reports its own child, parent and kind")
    func addressReportsItsOwnParts() {
        #expect(Self.subagent.sessionId == Self.child)
        #expect(Self.subagent.parentSessionId == Self.parent)
        #expect(Self.subagent.isSubagent == true)

        let session = SessionAddress.session("session-1")
        #expect(session.sessionId == "session-1")
        #expect(session.parentSessionId == nil)
        #expect(session.isSubagent == false)
    }
}
