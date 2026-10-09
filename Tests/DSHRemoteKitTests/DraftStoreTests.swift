import Foundation
import Testing
@testable import DSHRemoteKit

// Slice A's stated completion evidence is "draft survives app relaunch", so that is the
// first test here and the rest protect the rules that make persistence safe rather than
// merely present: a failed write must not eat the text, and an acceptance must not clear
// work the user did while the send was in flight.

@Suite("Draft store")
struct DraftStoreTests {
    private let hostA = UUID()
    private let hostB = UUID()

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func key(
        _ host: UUID,
        session: String = "session-1"
    ) -> DraftKey {
        DraftKey(hostId: host, owner: .session(session))
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: - Relaunch

    @Test("a draft survives a relaunch")
    func draftSurvivesRelaunch() async throws {
        let directory = try scratch()
        let key = key(hostA)

        let first = DraftStore(directory: directory)
        await first.setText("half a thought", for: key)
        await first.setSelection(
            agentPreset: "standard", modelProvider: "p1", model: "m1",
            reasoningEffort: "low", for: key
        )
        try await first.flush()

        // A new process: a second store over the same directory, reading at init.
        let second = DraftStore(directory: directory)
        let restored = await second.draft(for: key)

        #expect(restored.text == "half a thought")
        #expect(restored.agentPreset == "standard")
        #expect(restored.modelProvider == "p1")
        #expect(restored.model == "m1")
        #expect(restored.reasoningEffort == "low")
        // The revision survives too, which is what makes a late acceptance safe after a
        // relaunch rather than only within one process.
        #expect(restored.revision == 2)
    }

    @Test("navigation round-trips separately from any draft")
    func navigationRoundTrips() async throws {
        let directory = try scratch()
        let first = DraftStore(directory: directory)
        await first.setNavigation(
            DraftNavigation(workspaceId: "w1", sessionId: "s1", scrollAnchor: "seq:41"),
            for: hostA
        )
        try await first.flush()

        let second = DraftStore(directory: directory)
        let restored = await second.navigation(for: hostA)
        #expect(restored.workspaceId == "w1")
        #expect(restored.sessionId == "s1")
        #expect(restored.scrollAnchor == "seq:41")
        // A different host has nothing, rather than inheriting another host's place.
        #expect(await second.navigation(for: hostB) == DraftNavigation())
    }

    // MARK: - Identity

    @Test("two new-session drafts in one workspace do not overwrite each other")
    func newSessionDraftsAreIndependent() async throws {
        // SPEC §5 names this exact failure: "Using only a workspace key would let two new
        // drafts overwrite each other."
        let directory = try scratch()
        let store = DraftStore(directory: directory)
        let one = DraftKey(hostId: hostA, owner: .newSession(UUID()))
        let two = DraftKey(hostId: hostA, owner: .newSession(UUID()))

        await store.setWorkspace("w1", for: one)
        await store.setWorkspace("w1", for: two)
        await store.setText("first draft", for: one)
        await store.setText("second draft", for: two)
        try await store.flush()

        #expect(await store.draft(for: one).text == "first draft")
        #expect(await store.draft(for: two).text == "second draft")
        #expect(await store.draftCount(hostId: hostA) == 2)

        // And across a relaunch, since the collision would show up in the file keys.
        let reloaded = DraftStore(directory: directory)
        #expect(await reloaded.draft(for: one).text == "first draft")
        #expect(await reloaded.draft(for: two).text == "second draft")
    }

    @Test("the same session id under two hosts stays separate")
    func hostsAreIsolated() async throws {
        let directory = try scratch()
        let store = DraftStore(directory: directory)
        await store.setText("for host A", for: key(hostA))
        await store.setText("for host B", for: key(hostB))
        try await store.flush()

        #expect(await store.draft(for: key(hostA)).text == "for host A")
        #expect(await store.draft(for: key(hostB)).text == "for host B")

        let reloaded = DraftStore(directory: directory)
        #expect(await reloaded.draft(for: key(hostA)).text == "for host A")
        #expect(await reloaded.draft(for: key(hostB)).text == "for host B")
    }

    @Test("forgetting a host leaves the other host's drafts alone")
    func removingOneHostIsScoped() async throws {
        let directory = try scratch()
        let store = DraftStore(directory: directory)
        await store.setText("A", for: key(hostA))
        await store.setText("B", for: key(hostB))
        await store.setNavigation(DraftNavigation(sessionId: "s1"), for: hostA)

        await store.remove(hostId: hostA)
        try await store.flush()

        #expect(await store.draftCount(hostId: hostA) == 0)
        #expect(await store.draftCount(hostId: hostB) == 1)
        #expect(await store.navigation(for: hostA) == DraftNavigation())
        #expect(await store.draft(for: key(hostB)).text == "B")
    }

    // MARK: - Revisions

    @Test("every edit moves the revision forward")
    func revisionsIncreaseMonotonically() async throws {
        let store = DraftStore(directory: try scratch())
        var seen: [Int] = []
        for step in 0..<4 {
            seen.append(await store.setText("step \(step)", for: key(hostA)).revision)
        }
        #expect(seen == seen.sorted())
        #expect(Set(seen).count == seen.count, "a revision was reused")
    }

    @Test("accepting the submitted revision clears exactly that content")
    func acceptanceClearsTheSubmittedRevision() async throws {
        let store = DraftStore(directory: try scratch())
        await store.setText("send me", for: key(hostA))
        let submission = await store.beginSubmission(requestId: "submission-1", for: key(hostA))

        #expect(await store.clearSubmitted(revision: submission.revision, for: key(hostA)))
        let cleared = await store.draft(for: key(hostA))
        #expect(cleared.text.isEmpty)
        #expect(cleared.hasUnresolvedSubmission == false)
    }

    @Test("text typed while a send was pending survives its acceptance")
    func newerTextSurvivesAcceptance() async throws {
        // The rule that stops a slow send from eating the next message.
        let store = DraftStore(directory: try scratch())
        await store.setText("first", for: key(hostA))
        let submission = await store.beginSubmission(requestId: "submission-1", for: key(hostA))

        // The user keeps typing before the host confirms.
        await store.setText("first and second", for: key(hostA))

        #expect(await store.clearSubmitted(revision: submission.revision, for: key(hostA)) == false)
        let kept = await store.draft(for: key(hostA))
        #expect(kept.text == "first and second")
        // The resolved submission is dropped so the send is no longer pending.
        #expect(kept.hasUnresolvedSubmission == false)
    }

    @Test("an acceptance for a submission this draft never made clears nothing")
    func staleAcceptanceIsIgnored() async throws {
        let store = DraftStore(directory: try scratch())
        await store.setText("keep me", for: key(hostA))
        #expect(await store.clearSubmitted(revision: 99, for: key(hostA)) == false)
        #expect(await store.draft(for: key(hostA)).text == "keep me")
    }

    @Test("an unresolved submission survives a relaunch")
    func unresolvedSubmissionSurvivesRelaunch() async throws {
        // SPEC §5 keeps the submission identity so an uncertain send can be reconciled
        // rather than silently replayed or silently lost.
        let directory = try scratch()
        let first = DraftStore(directory: directory)
        await first.setText("uncertain", for: key(hostA))
        let submission = await first.beginSubmission(requestId: "submission-7", for: key(hostA))
        try await first.flush()

        let second = DraftStore(directory: directory)
        let restored = await second.draft(for: key(hostA))
        #expect(restored.submission == submission)
        #expect(restored.text == "uncertain")
    }

    // MARK: - Failing to save

    @Test("a failed write keeps the text and reports the failure")
    func failedWriteKeepsText() async throws {
        let store = DraftStore(
            directory: try scratch(),
            write: { _, _ in throw DraftStoreError(operation: "write", reason: "disk full") }
        )
        await store.setText("do not lose me", for: key(hostA))

        await #expect(throws: DraftStoreError.self) {
            try await store.flush()
        }

        // The in-memory draft is untouched, and the failure is available for the UI to say
        // "Draft saved on this iPhone" only when it is true.
        #expect(await store.draft(for: key(hostA)).text == "do not lose me")
        #expect(await store.saveError?.reason == "disk full")
    }

    @Test("a debounced write lands without an explicit flush")
    func debouncedWriteHappens() async throws {
        let directory = try scratch()
        let store = DraftStore(directory: directory, debounce: .milliseconds(1))
        await store.setText("eventually on disk", for: key(hostA))

        let file = DraftStore.fileURL(for: "drafts", in: directory)
        #expect(await eventually { FileManager.default.fileExists(atPath: file.path) })

        let reloaded = DraftStore(directory: directory)
        #expect(await reloaded.draft(for: key(hostA)).text == "eventually on disk")
    }

    // MARK: - Diagnostics

    @Test("a draft's own description does not contain its text")
    func descriptionIsRedacted() async throws {
        // SPEC §5: draft text never reaches routine diagnostics. Without this, an
        // interpolated \(draft) in a log line would print the user's half-written message.
        let store = DraftStore(directory: try scratch())
        let draft = await store.setText("a private half-written thought", for: key(hostA))

        let described = String(describing: draft)
        #expect(!described.contains("private"))
        #expect(!described.contains("half-written"))
        // The size is reported so the line is still useful. Derived rather than
        // hand-counted, since a wrong literal here fails for the test rather than the code.
        #expect(described.contains("\(draft.text.count) chars"))
    }
}
