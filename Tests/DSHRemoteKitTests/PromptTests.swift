import Foundation
import Testing

@testable import DSHRemoteKit

/// `ConnectionCoordinator.prompt` is the write half of the chat screen.
///
/// The behaviour that matters most is a negative one: SPEC §3.4 forbids resending
/// a prompt whose outcome is unknown, because a duplicate turn costs real work and
/// the user cannot tell it happened. So the tests below mostly prove that a second
/// request is *not* made.
@Suite("Prompt sending")
struct PromptTests {

    private func makeCoordinator(_ transport: StubRelayTransport) -> ConnectionCoordinator {
        ConnectionCoordinator(
            origin: ConnectionCoordinator.Origin(
                baseURL: URL(string: "https://192.0.2.10:3443")!,
                authorization: .bearer("device-token")
            ),
            budgets: .init(establishmentSeconds: 5, readinessSeconds: 5),
            makeTransport: { _ in transport }
        )
    }

    /// Mirrors the helper in `StateTests`, which is private to that file.
    private func failure<T>(_ operation: () async throws -> T) async -> (any Error)? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    @Test("a rejected prompt is not sent a second time", arguments: [429, 502, 500])
    func rejectedPromptIsNotRetried(status: Int) async throws {
        // 429 and 502 trigger the generic policy. Writes must override it.
        let transport = StubRelayTransport(responses: [.json(status: status, Data("{}".utf8))])
        let coordinator = makeCoordinator(transport)

        let thrown = await failure {
            try await coordinator.prompt(requestId: "submission-1", sessionId: "session-1", text: "hello")
        }
        #expect(thrown != nil, "a refusal should surface as a failure")

        #expect(
            await transport.authorizationHeader(at: 0) != nil,
            "no request reached the transport at all"
        )
        #expect(
            await transport.authorizationHeader(at: 1) == nil,
            "the prompt was sent more than once — SPEC §3.4 forbids that"
        )
    }

    @Test("the submission identity reaches the wire and can be reused on a retry")
    func requestIdIsCarriedAndReusable() async throws {
        // SPEC §5: a retry of an uncertain send reuses the original request ID with the
        // same content, because the host deduplicates on exactly that value --
        // `hasPromptRequest(agent, request.requestId)` returns the earlier acceptance
        // rather than admitting a second turn. So the identity has to come from the
        // caller: a method that minted its own would make every retry look like a new
        // submission, the deduplication would never match, and the duplicate turn
        // SPEC §3.4 forbids would be created silently.
        let accepted = Data(
            #"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":{"accepted":true}}}"#.utf8
        )
        let transport = StubRelayTransport(responses: [
            .json(status: 200, accepted),
            .json(status: 200, accepted),
        ])
        let coordinator = makeCoordinator(transport)

        try await coordinator.prompt(requestId: "submission-1", sessionId: "session-1", text: "hello")
        // The same human submission, deliberately retried. The host is expected to answer
        // `accepted: true` from its deduplication rather than start a second turn.
        try await coordinator.prompt(requestId: "submission-1", sessionId: "session-1", text: "hello")

        let sent = await transport.recordedRequests
        #expect(sent.count == 2)
        for request in sent {
            let body = try #require(request.body)
            let envelope = try JSONDecoder().decode(JSONValue.self, from: body)
            #expect(envelope["method"]?.stringValue == "session/prompt")
            // `session/prompt` names its argument object `request`.
            let args = envelope["payload"]?["args"]
            #expect(args?["request"]?["requestId"]?.stringValue == "submission-1")
            #expect(args?["request"]?["sessionId"]?.stringValue == "session-1")
            #expect(args?["request"]?["content"]?[0]?["text"]?.stringValue == "hello")
        }
    }

    @Test("an uncertain answer is not repeated", arguments: [429, 502])    func answerIsNotRetried(status: Int) async throws {
        let transport = StubRelayTransport(responses: [.json(status: status, Data("{}".utf8))])
        let coordinator = makeCoordinator(transport)
        let thrown = await failure {
            try await coordinator.answer(
                agentId: "session-1", callId: "call-1", questionId: "question-1", selected: ["Yes"]
            )
        }
        #expect(thrown != nil)
        #expect(await transport.recordedRequests.count == 1)
    }

    // Note: an accepted-prompt test is deliberately absent. Building a success
    // body needs the RPC envelope helper the network tests use (the value alone
    // is not the response), and asserting "either it threw or it did not" would
    // be a test that passes regardless. The two behaviours below are the ones
    // SPEC §3.4 actually turns on.

    @Test("the prompt is a bearer-authenticated request")
    func promptCarriesTheCredential() async throws {
        // SPEC §6.2: every relay request carries the token, including this one.
        let transport = StubRelayTransport(responses: [.json(status: 200, Data(#"{"ok":true}"#.utf8))])
        let coordinator = makeCoordinator(transport)

        _ = await failure { try await coordinator.prompt(requestId: "submission-1", sessionId: "session-1", text: "hello") }

        let header = await transport.authorizationHeader(at: 0)
        #expect(header?.hasPrefix("Bearer ") == true, "expected a bearer header, got \(String(describing: header))")
    }
}
