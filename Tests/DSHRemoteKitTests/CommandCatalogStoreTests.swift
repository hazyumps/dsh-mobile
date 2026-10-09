import Foundation
import Testing

@testable import DSHRemoteKit

/// `commands/list` and `commands/execute`, driven through the scripted transport.
///
/// The shapes here are the ones the live host answered with on 2026-10-09: the list is a
/// **bare array**, and an execute result can be a success with no text, a refusal with text,
/// or no value at all. Three of those four are "nothing to show" and none of them means the
/// same thing as the others.
@Suite("Command catalog")
struct CommandCatalogStoreTests {

    private func coordinatorTransport(_ responses: [String: StubRelayTransport.Stub]) -> StubRelayTransport {
        StubRelayTransport(responsesByPath: responses)
    }

    private func store(_ transport: StubRelayTransport) -> CommandCatalogStore {
        CommandCatalogStore(makeClient: {
            DshRpcClient(
                baseURL: URL(string: "https://192.0.2.10:3443")!,
                authorization: .bearer("device-token"),
                transport: transport
            )
        })
    }

    /// The live answer, trimmed to the fields that matter.
    private var liveListResponse: Data {
        Data("""
        {"type":"server-response","rpcId":"t","result":{"ok":true,"value":[
          {"definitionId":"@deepseek-ai/dsh-command-compact","name":"compact",
           "description":"Compact older conversation history"},
          {"definitionId":"@deepseek-ai/dsh-command-feedback","name":"feedback",
           "description":"Record feedback about this session","input":{"hint":"<text>"}},
          {"definitionId":"@deepseek-ai/dsh-command-goal","name":"goal",
           "description":"Set or view the goal","input":{"hint":"[<objective>]"}},
          {"definitionId":"@deepseek-ai/dsh-plan-mode","name":"plan",
           "description":"Enter or leave plan mode","input":{"hint":"[off|message]","attachments":true}}
        ]}}
        """.utf8)
    }

    @Test("the list decodes from a bare array, with each command's own input rule")
    func listDecodesTheBareArray() async throws {
        let transport = coordinatorTransport([
            "/api/commands/list": .json(status: 200, liveListResponse),
        ])
        let store = store(transport)

        let commands = try await store.commands(for: "session-1")

        #expect(commands.map(\.name) == ["compact", "feedback", "goal", "plan"])
        #expect(commands[0].hint == nil)
        // Absent means the host said nothing, which is why it is not the same as `true`.
        #expect(commands[0].acceptsAttachments == false)
        #expect(commands[1].hint == "<text>")
        #expect(commands[3].acceptsAttachments)

        // The arguments are `agentId` directly — not a `request` or `_request` wrapper.
        let requests = await transport.recordedRequests
        let request = try #require(requests.first)
        #expect(request.url.path == "/api/commands/list")
        let envelope = try JSONDecoder().decode(JSONValue.self, from: #require(request.body))
        #expect(envelope["payload"]?["args"]?["agentId"]?.stringValue == "session-1")
        #expect(envelope["payload"]?["args"]?.objectValue?.keys.sorted() == ["agentId"])
    }

    @Test("an empty list is a host with no commands, not a decode failure")
    func emptyListDecodes() async throws {
        let transport = coordinatorTransport([
            "/api/commands/list": .json(
                status: 200,
                Data(#"{"type":"server-response","rpcId":"t","result":{"ok":true}}"#.utf8)
            ),
        ])
        #expect(try await store(transport).commands(for: "session-1").isEmpty)
    }

    @Test("executing sends an explicit empty attachment list and reports what ran")
    func executeSendsAnEmptyAttachmentList() async throws {
        let transport = coordinatorTransport([
            "/api/commands/execute": .json(
                status: 200,
                Data("""
                {"type":"server-response","rpcId":"t","result":{"ok":true,"value":
                  {"commandId":"compact","result":{"kind":"success","text":"Compacted 12 turns"}}}}
                """.utf8)
            ),
        ])
        let store = store(transport)

        let outcome = try await store.execute(agentId: "session-1", line: "/compact")

        #expect(outcome == CommandOutcome.ran(text: "Compacted 12 turns", sourceEventSeq: nil))
        #expect(outcome.text == "Compacted 12 turns")

        let requests = await transport.recordedRequests
        let request = try #require(requests.first)
        let envelope = try JSONDecoder().decode(JSONValue.self, from: #require(request.body))
        let arguments = try #require(envelope["payload"]?["args"])
        #expect(arguments["agentId"]?.stringValue == "session-1")
        #expect(arguments["line"]?.stringValue == "/compact")
        // Sent, and sent empty: the host tells an empty list from an absent one.
        #expect(arguments["submittedAttachments"]?.arrayValue?.isEmpty == true)
    }

    @Test("a success with no text, a refusal, and an absent result are three different things")
    func theThreeNothingToShowCasesStayApart() async throws {
        // 1. Success with a durable source event: the transcript will render it, so a local
        //    echo would duplicate it.
        let sourced = store(coordinatorTransport([
            "/api/commands/execute": .json(
                status: 200,
                Data("""
                {"type":"server-response","rpcId":"t","result":{"ok":true,"value":
                  {"commandId":"plan","result":{"kind":"success","sourceEventSeq":42}}}}
                """.utf8)
            ),
        ]))
        let ran = try await sourced.execute(agentId: "s", line: "/plan")
        #expect(ran == CommandOutcome.ran(text: nil, sourceEventSeq: 42))
        #expect(ran.text == nil)
        #expect(ran.hasDurableSource)

        // 2. A refusal, which always carries the host's words.
        let refusing = store(coordinatorTransport([
            "/api/commands/execute": .json(
                status: 200,
                Data("""
                {"type":"server-response","rpcId":"t","result":{"ok":true,"value":
                  {"commandId":"plan","result":{"kind":"error","text":"plan mode is unavailable"}}}}
                """.utf8)
            ),
        ]))
        #expect(try await refusing.execute(agentId: "s", line: "/plan")
            == CommandOutcome.refused(text: "plan mode is unavailable"))

        // 3. The permitted absent result: the descriptor models the whole value as optional.
        let absent = store(coordinatorTransport([
            "/api/commands/execute": .json(
                status: 200,
                Data(#"{"type":"server-response","rpcId":"t","result":{"ok":true}}"#.utf8)
            ),
        ]))
        let completed = try await absent.execute(agentId: "s", line: "/compact")
        #expect(completed == CommandOutcome.completed)
        #expect(completed.text == nil)
        #expect(!completed.hasDurableSource)
    }

    @Test("only an exact command name matches, so /nameplate is ordinary prompt text")
    func commandMatchingIsExact() {
        let entry = CommandEntry(name: "plan", description: "Plan mode", hint: "[off|message]")
        #expect(entry.matches(line: "/plan"))
        #expect(entry.matches(line: "/plan off"))
        #expect(entry.matches(line: "  /plan off"))
        #expect(!entry.matches(line: "/planning"))
        #expect(!entry.matches(line: "/nameplate"))
        #expect(!entry.matches(line: "plan"))
    }

    @Test("a session's commands do not leak into another session's cache")
    func cacheIsScopedToTheSession() async throws {
        let transport = coordinatorTransport([
            "/api/commands/list": .json(status: 200, liveListResponse),
        ])
        let store = store(transport)
        _ = try await store.commands(for: "session-1")

        #expect(await store.cached(for: "session-1").count == 4)
        #expect(await store.cached(for: "session-2").isEmpty)
        await store.invalidate("session-1")
        #expect(await store.cached(for: "session-1").isEmpty)
    }
}
