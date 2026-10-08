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

    @Test("a rejected prompt is not sent a second time")
    func rejectedPromptIsNotRetried() async throws {
        // A 500 is the kind of response a retry policy would act on. The prompt
        // path must not: an uncertain send is reported, never repeated.
        let transport = StubRelayTransport(responses: [.json(status: 500, Data("{}".utf8))])
        let coordinator = makeCoordinator(transport)

        let thrown = await failure {
            try await coordinator.prompt(sessionId: "session-1", text: "hello")
        }
        #expect(thrown != nil, "a 500 should surface as a failure")

        #expect(
            await transport.authorizationHeader(at: 0) != nil,
            "no request reached the transport at all"
        )
        #expect(
            await transport.authorizationHeader(at: 1) == nil,
            "the prompt was sent more than once — SPEC §3.4 forbids that"
        )
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

        _ = await failure { try await coordinator.prompt(sessionId: "session-1", text: "hello") }

        let header = await transport.authorizationHeader(at: 0)
        #expect(header?.hasPrefix("Bearer ") == true, "expected a bearer header, got \(String(describing: header))")
    }
}
