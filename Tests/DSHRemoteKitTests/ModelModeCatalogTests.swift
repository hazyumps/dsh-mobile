import Foundation
import Testing
@testable import DSHRemoteKit

// SPEC §6's rules that a picker can get wrong without anything crashing: the label shown
// versus the id sent, a broken preset, a provider that failed while others still work, and
// which refusals mean "leave the old selection displayed" versus "nothing was decided".

@Suite("Model and mode catalog")
struct ModelModeCatalogTests {
    private func catalog(
        clients: StubRelayTransport,
        origin: URL = URL(string: "https://192.0.2.10:3443")!
    ) -> ModelModeCatalogStore {
        ModelModeCatalogStore(makeClient: {
            DshRpcClient(baseURL: origin, authorization: .bearer("device-token"), transport: clients)
        })
    }

    private static let catalogJSON = """
    {"default":{"provider":"p1","model":"m1"},
     "routableProviders":["p1"],
     "groups":[{"id":"p1","name":"Provider One","models":[
        {"id":"m1","name":"Model One","reasoning":{"efforts":[{"id":"low","name":"Low"}],"defaultEffort":"low"}},
        {"id":"m2","name":"Model Two"}]}],
     "failures":[{"id":"p2","name":"Provider Two","message":"unreachable"}]}
    """

    private static let rosterJSON = """
    {"presets":[{"id":"standard","isDefault":true},
                {"id":"careful","isDefault":false,"name":"Careful"},
                {"id":"broken-one","isDefault":false,"name":"Broken","broken":"missing dependency"}]}
    """

    private static let permissionsJSON = """
    {"options":[{"value":"workspace-write","name":"Workspace write"}],
     "defaultOptions":[],"defaultPreset":"workspace-write"}
    """

    private func envelope(_ value: String) -> Data {
        Data(#"{"type":"server-response","rpcId":"r","result":{"ok":true,"value":\#(value)}}"#.utf8)
    }

    private func built(
        permissions: Bool = true
    ) throws -> ModelModeCatalog {
        let models = try JSONDecoder().decode(
            ModelCatalog.self, from: Data(Self.catalogJSON.utf8)
        )
        let roster = try JSONDecoder().decode(
            AgentPresetRoster.self, from: Data(Self.rosterJSON.utf8)
        )
        let perms = permissions
            ? try JSONDecoder().decode(PermissionCatalog.self, from: Data(Self.permissionsJSON.utf8))
            : nil
        return ModelModeCatalog(models, presets: roster, permissions: perms)
    }

    // MARK: - What the user sees versus what goes on the wire

    @Test("the default preset reads as Standard mode while its roster id stays on the wire")
    func defaultPresetLabel() throws {
        let catalog = try built()
        let standard = try #require(catalog.defaultMode)
        // SPEC §6: display "Standard mode", send the roster id.
        #expect(standard.label == "Standard mode")
        #expect(standard.id == "standard")
        #expect(standard.isSelectable)
    }

    @Test("a named non-default preset shows its host name, and an unnamed one its id")
    func otherPresetLabels() throws {
        let catalog = try built()
        let careful = try #require(catalog.modes.first { $0.id == "careful" })
        #expect(careful.label == "Careful")
    }

    @Test("a broken preset is unavailable and carries the host's explanation")
    func brokenPreset() throws {
        let catalog = try built()
        let broken = try #require(catalog.modes.first { $0.id == "broken-one" })
        #expect(broken.isSelectable == false)
        #expect(broken.broken == "missing dependency")
    }

    // MARK: - Providers

    @Test("a failed provider is reported without hiding the providers that work")
    func failuresDoNotHideUsableGroups() throws {
        let catalog = try built()
        #expect(catalog.failures.map(\.id) == ["p2"])
        #expect(catalog.failures.first?.message == "unreachable")
        // The usable group survives alongside the failure report.
        #expect(catalog.providers.map(\.id) == ["p1"])
        #expect(catalog.providers.first?.models.count == 2)
    }

    @Test("reasoning choices are exposed only for models that advertise them")
    func reasoningIsNotInvented() throws {
        let catalog = try built()
        let one = try #require(catalog.option(for: ModelSelection(provider: "p1", model: "m1")))
        let two = try #require(catalog.option(for: ModelSelection(provider: "p1", model: "m2")))

        #expect(one.offersReasoningChoice)
        #expect(one.efforts.map(\.id) == ["low"])
        #expect(one.defaultEffort == "low")
        // SPEC §6: do not offer unsupported reasoning efforts.
        #expect(two.offersReasoningChoice == false)
        #expect(two.efforts.isEmpty)
    }

    @Test("the selected model resolves to the host's own label, and to nothing when absent")
    func selectionResolvesToTheHostLabel() throws {
        let catalog = try built()
        #expect(catalog.option(for: catalog.defaultSelection)?.name == "Model One")
        // A model the catalog does not list, which is what a currently unreachable
        // provider looks like. Inventing a label here is what SPEC §6 forbids.
        #expect(catalog.option(for: ModelSelection(provider: "p1", model: "gone")) == nil)
        #expect(catalog.option(for: ModelSelection(provider: "px", model: "m1")) == nil)
    }

    @Test("permission presets are read-only labels")
    func permissionPresetsAreReadOnly() throws {
        let catalog = try built()
        #expect(catalog.permissionPresets.map(\.id) == ["workspace-write"])
        #expect(catalog.defaultPermissionPreset == "workspace-write")
    }

    // MARK: - Refusals

    private func business(_ code: String) -> DshRPCError {
        .business(RPCError(code: code, message: "host said \(code)"))
    }

    @Test("a locked mode is its own refusal, not a transport problem")
    func lockedModeIsClassified() {
        let refusal = SelectionRefusal.classify(business(SelectionRefusal.modeLockedCode))
        #expect(refusal == .modeLocked)
        // The previous selection stays on screen: the host decided, and decided no.
        #expect(refusal.confirmsPreviousSelection)
    }

    @Test("an unresolvable model is its own refusal")
    func unavailableModelIsClassified() {
        let refusal = SelectionRefusal.classify(business(SelectionRefusal.modelUnavailableCode))
        guard case .modelUnavailable = refusal else {
            Issue.record("expected modelUnavailable, got \(refusal)")
            return
        }
        #expect(refusal.confirmsPreviousSelection)
    }

    @Test("another business refusal keeps its code")
    func otherBusinessRefusal() {
        #expect(
            SelectionRefusal.classify(business("session/not-found"))
                == .refused(code: "session/not-found", message: "host said session/not-found")
        )
    }

    @Test("a transport failure decided nothing, so the old selection is not confirmed", arguments: [
        DshRPCError.transportInterruption(detail: "dropped"),
        DshRPCError.harnessUnavailable(attempts: 2),
        DshRPCError.rateLimited(retryAfterSeconds: 5, attempts: 1),
        DshRPCError.cancelled,
        DshRPCError.capabilityUnavailable(endpoint: "session/modelCatalog"),
    ])
    func transportFailuresDoNotConfirm(_ error: DshRPCError) {
        // SPEC §6: on uncertainty, refresh projections before enabling Send. Treating a
        // dropped connection as a confirmed selection would enable Send on a stale model.
        let refusal = SelectionRefusal.classify(error)
        guard case .transport = refusal else {
            Issue.record("expected a transport refusal, got \(refusal)")
            return
        }
        #expect(refusal.confirmsPreviousSelection == false)
    }

    @Test("a blank session is the only one whose mode may be edited")
    func modeEditabilityFollowsBlank() {
        #expect(ModelModeCatalog.modeIsEditable(sessionIsBlank: true))
        #expect(ModelModeCatalog.modeIsEditable(sessionIsBlank: false) == false)
    }

    // MARK: - The calls

    @Test("refresh reads the three catalogs and tolerates a missing permission catalog")
    func refreshToleratesMissingPermissions() async throws {
        let transport = StubRelayTransport(responses: [
            .json(status: 200, envelope(Self.catalogJSON)),
            .json(status: 200, envelope(Self.rosterJSON)),
            // A host without permissionPresets/catalog answers 404. That is a missing
            // optional section, not a reason to fail the picker.
            .json(status: 404, Data("{}".utf8)),
        ])
        let store = catalog(clients: transport)
        let built = try await store.refresh()

        #expect(built.providers.count == 1)
        #expect(built.modes.count == 3)
        #expect(built.permissionPresets.isEmpty)
        #expect(await store.catalog != nil)

        let paths = await transport.recordedRequests.map(\.url.path)
        #expect(paths == [
            "/api/session/modelCatalog",
            "/api/agentPresets/list",
            "/api/permissionPresets/catalog",
        ])
    }

    @Test("selecting a model sends the exact wire args and returns the host's answer")
    func selectModelRoundTrip() async throws {
        let transport = StubRelayTransport(responses: [
            .json(status: 200, envelope(#"{"selected":{"provider":"p1","model":"m1","reasoningEffort":"low"}}"#)),
        ])
        let store = catalog(clients: transport)

        let selection = try await store.selectModel(
            sessionId: "s1", provider: "p1", model: "m1", reasoningEffort: "low"
        )
        // The host's normalized answer, not the request echoed back.
        #expect(selection == ModelSelection(provider: "p1", model: "m1", reasoningEffort: "low"))

        let request = try #require(await transport.recordedRequests.first)
        #expect(request.url.path == "/api/session/selectModel")
        let args = try #require(
            try JSONDecoder().decode(JSONValue.self, from: #require(request.body))
        )["payload"]?["args"]
        // `session/selectModel` names its argument object `request`.
        #expect(args?["request"]?["sessionId"]?.stringValue == "s1")
        #expect(args?["request"]?["provider"]?.stringValue == "p1")
        #expect(args?["request"]?["model"]?.stringValue == "m1")
        #expect(args?["request"]?["reasoningEffort"]?.stringValue == "low")
    }

    @Test("a locked mode surfaces as a refusal rather than a transport failure")
    func selectModeLocked() async throws {
        let failure = Data(
            #"{"type":"server-response","rpcId":"r","result":{"ok":false,"error":{"code":"agent-preset/locked","message":"the session has started"}}}"#.utf8
        )
        let transport = StubRelayTransport(responses: [.json(status: 200, failure)])
        let store = catalog(clients: transport)

        await #expect(throws: SelectionRefusal.modeLocked) {
            try await store.selectMode(agentId: "s1", preset: "careful")
        }
    }

    @Test("a selection is a write, so it is never retried")
    func selectionIsNotRetried() async throws {
        // SPEC §3: an uncertain mutation is reconciled, never replayed. A 429 must produce
        // one attempt, not the read path's bounded retries.
        let transport = StubRelayTransport(responses: Array(
            repeating: .json(status: 429, Data(), headers: ["Retry-After": "5"]), count: 3
        ))
        let store = catalog(clients: transport)

        _ = try? await store.selectModel(sessionId: "s1", provider: "p1", model: "m1")

        #expect(await transport.recordedRequests.count == 1)
    }
}
