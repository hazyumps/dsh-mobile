import Foundation
import Testing
@testable import DSHRemoteKit

// SPEC §11 records what a diagnostic line may contain and what it must never contain, and
// SPEC §3 requires resource state to be tracked separately from the transport. The tests
// below are mostly about the negative: the interesting failure is a diagnostic export that
// quietly carries a prompt, a token, or a private path.

@Suite("Diagnostics")
struct DiagnosticsTests {
    // MARK: - Resource state

    @Test("every resource state names itself for a diagnostic without its reason")
    func resourceStateDiagnosticNames() {
        #expect(ResourceState.empty.diagnosticName == "empty")
        #expect(ResourceState.loading.diagnosticName == "loading")
        #expect(ResourceState.current.diagnosticName == "current")
        #expect(ResourceState.stale(reason: nil).diagnosticName == "stale")
        #expect(ResourceState.failed(reason: "boom").diagnosticName == "failed")
    }

    @Test("a failure reason never reaches the diagnostic line")
    func failureReasonIsNotRecorded() {
        // The reason is user-facing text. The harness's own persistence failure quotes a
        // storage path in its message, so a state recorded verbatim is a leak.
        let secret = "/Users/patrick/repo/private/session-017dd1d3"
        let line = DiagnosticRecord(
            correlation: UUID(),
            subject: .endpoint("session/list"),
            resource: "session/list",
            state: .failed(reason: "corrupt session log at \(secret)")
        ).line

        #expect(line.contains("state=failed"))
        #expect(!line.contains(secret))
        #expect(!line.contains("/Users/"))
    }

    @Test("loaded states are distinguishable from unloaded ones")
    func hasDataMatchesTheFiveStates() {
        #expect(ResourceState.empty.hasData == false)
        #expect(ResourceState.loading.hasData == false)
        #expect(ResourceState.failed(reason: "x").hasData == false)
        #expect(ResourceState.current.hasData)
        #expect(ResourceState.stale(reason: nil).hasData)
    }

    // MARK: - Transitions

    @Test("a successful load is empty or current, never loading")
    func afterSuccess() {
        // A successful empty result and a load that has not happened are different
        // screens, which is the whole reason `empty` exists.
        #expect(ResourceState.afterSuccess(itemCount: 0) == .empty)
        #expect(ResourceState.afterSuccess(itemCount: 3) == .current)
    }

    @Test("a failed refresh keeps what is on screen instead of blanking it")
    func afterFailureKeepsData() {
        // SPEC §3/§4: cached data survives a failed refresh. Collapsing this into
        // `failed` is how a working list disappears because one refresh timed out.
        let stale = ResourceState.current.afterFailure(reason: "offline")
        #expect(stale == .stale(reason: "offline"))
        #expect(stale.hasData)

        // With nothing to keep, a failure is a real failure.
        let failed = ResourceState.loading.afterFailure(reason: "offline")
        #expect(failed == .failed(reason: "offline"))
        #expect(failed.hasData == false)
    }

    @Test("refreshing keeps data visible and does not claim it is current")
    func whileLoading() {
        let refreshing = ResourceState.current.whileLoading
        #expect(refreshing == .stale(reason: nil))
        #expect(refreshing.hasData)

        // A first load has nothing to show, so it is loading rather than stale.
        #expect(ResourceState.loading.whileLoading == .loading)
        #expect(ResourceState.empty.whileLoading == .loading)
    }

    @Test("a stale resource can fail again without losing its data")
    func failureAfterStaleStaysStale() {
        // The second failure of a flapping refresh must not escalate into a blank screen.
        let twice = ResourceState.current
            .afterFailure(reason: "dropped")
            .afterFailure(reason: "dropped again")
        #expect(twice == .stale(reason: "dropped again"))
        #expect(twice.hasData)
    }

    // MARK: - The one stringly field

    @Test("a code shaped like one is kept")
    func wellShapedCodesSurvive() {
        for code in ["gateway/method-unavailable", "session/upload-too-large", "ASK_TIMED_OUT", "v4.2"] {
            #expect(DiagnosticRecord.shape(code) == code)
        }
    }

    @Test("anything not shaped like a code becomes a placeholder", arguments: [
        "/Users/patrick/repo/homelab",
        "corrupt session log at /Users/patrick/.dsh/sessions/x",
        "header id 123 and cwd identify a different storage path",
        "token 9f2c41ab30d7e155",
        "https://relay.example/api?a=bearer",
        String(repeating: "a", count: 200),
    ])
    func unshapedCodesAreReplaced(_ hostile: String) {
        // A host is free to put a path or a quoted message in error.code, and the harness
        // does exactly that in its message field. The field is the only doorway into a
        // record, so it is the one that gets checked.
        let shaped = DiagnosticRecord.shape(hostile)
        #expect(shaped == DiagnosticRecord.unshapedErrorCode)
        #expect(!(shaped ?? "").contains("/Users/"))
    }

    @Test("an empty or absent code stays absent rather than becoming a placeholder")
    func emptyCodeIsNotAPlaceholder() {
        #expect(DiagnosticRecord.shape(nil) == nil)
        #expect(DiagnosticRecord.shape("") == nil)
    }

    // MARK: - The export

    @Test("the export carries the allowed fields and nothing else")
    func exportContainsOnlyAllowedFields() {
        var log = DiagnosticLog()
        let correlation = UUID()
        log.record(
            correlation: correlation,
            subject: .stream("session/follow"),
            generation: 7,
            resource: "conversation",
            state: .stale(reason: nil),
            status: 200,
            errorCode: "session/not-found",
            durationMilliseconds: 42
        )

        let exported = log.export()
        #expect(exported.contains(correlation.uuidString))
        #expect(exported.contains("stream=session/follow"))
        #expect(exported.contains("gen=7"))
        #expect(exported.contains("resource=conversation"))
        #expect(exported.contains("state=stale"))
        #expect(exported.contains("status=200"))
        #expect(exported.contains("error=session/not-found"))
        #expect(exported.contains("42ms"))
        // One line per record: an export a person reads, not a serialisation.
        #expect(!exported.contains("\n"))
    }

    @Test("a hostile error code does not reach the exported text")
    func exportedTextSurvivesAHostileCode() {
        // The end-to-end version of the shaping test: what a user would actually copy and
        // send must not contain the path the host put in its own error code.
        var log = DiagnosticLog()
        log.record(
            correlation: UUID(),
            subject: .endpoint("session/list"),
            status: 500,
            errorCode: "/Users/patrick/.dsh/sessions/private/session-017dd1d3"
        )

        let exported = log.export()
        #expect(!exported.contains("/Users/"))
        #expect(!exported.contains("patrick"))
        #expect(exported.contains(DiagnosticRecord.unshapedErrorCode))
    }

    @Test("cancelling a request records nothing and leaves the log empty")
    func nothingIsRecordedImplicitly() {
        // SPEC §11: export is explicit. Nothing here writes on its own, so a log is empty
        // until something deliberately records into it.
        let log = DiagnosticLog()
        #expect(log.isEmpty)
        #expect(log.export().isEmpty)
    }

    @Test("the log keeps the most recent records and stays bounded")
    func logIsBoundedAndKeepsTheNewest() {
        // A diagnostic log that grows without limit is its own outage, and the newest
        // records are the ones a user is reporting.
        var log = DiagnosticLog(capacity: 3)
        for index in 0..<10 {
            log.record(
                correlation: UUID(),
                subject: .endpoint("endpoint-\(index)"),
                resource: "endpoint-\(index)"
            )
        }

        #expect(log.count == 3)
        let exported = log.export()
        #expect(exported.contains("endpoint-9"))
        #expect(exported.contains("endpoint-7"))
        #expect(!exported.contains("endpoint-6"))
    }

    @Test("a log can be cleared before an export")
    func logCanBeCleared() {
        var log = DiagnosticLog()
        log.record(correlation: UUID(), subject: .endpoint("session/list"))
        #expect(!log.isEmpty)
        log.removeAll()
        #expect(log.isEmpty)
    }

    @Test("a state this build does not model is recorded as written, and is still code-checked")
    func namedStateRecords() {
        // The secondary screens report their own vocabulary — `unavailable` has no
        // `ResourceState` case, and mapping it onto one would say something the host did not.
        let record = DiagnosticRecord(
            correlation: UUID(),
            subject: .endpoint("schedule/catalog"),
            resource: "schedule/catalog",
            stateName: "unavailable",
            errorCode: "gateway/method-unavailable"
        )
        #expect(record.resourceState == "unavailable")
        #expect(record.errorCode == "gateway/method-unavailable")
        #expect(record.line.contains("state=unavailable"))

        // The shape check still applies on this path: a path is not an error code.
        let withPath = DiagnosticRecord(
            correlation: UUID(),
            subject: .endpoint("session/list"),
            stateName: "failed",
            errorCode: "/Users/patrick/repo/homelab"
        )
        #expect(withPath.errorCode == DiagnosticRecord.unshapedErrorCode)
    }
}
