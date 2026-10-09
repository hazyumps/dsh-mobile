import Foundation

// SPEC §6: the model and mode pickers.
//
// The generated types (`ModelCatalog`, `AgentPresetRoster`, `PermissionCatalog`) are the
// wire contract, and this file does not restate them. It wraps them in rows a picker can
// render and adds the two things the spec is actually emphatic about: what the *user* sees
// versus what goes on the wire, and which refusals mean what.

/// One model selection, in the same terms the wire uses for both the catalog default and
/// the result of choosing one.
public struct ModelSelection: Sendable, Hashable {
    public var provider: String
    public var model: String
    public var reasoningEffort: String?

    public init(provider: String, model: String, reasoningEffort: String? = nil) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    public init(_ value: ModelCatalogDefault) {
        self.init(
            provider: value.provider,
            model: value.model,
            reasoningEffort: value.reasoningEffort
        )
    }

    public init(_ value: SessionSelectModelValueSelected) {
        self.init(
            provider: value.provider,
            model: value.model,
            reasoningEffort: value.reasoningEffort
        )
    }
}

/// One reasoning effort the selected model advertises.
public struct EffortOption: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
}

/// One selectable model.
public struct ModelOption: Sendable, Hashable, Identifiable {
    /// The model's own id. Preserved exactly — SPEC §6: "Preserve provider/model IDs
    /// exactly".
    public var id: String
    public var provider: String
    /// The host's display name, which is the only label the picker may show. Hardcoding
    /// "DeepSeek" or any other backend is explicitly forbidden.
    public var name: String
    public var description: String?
    public var efforts: [EffortOption]
    public var defaultEffort: String?

    /// Whether this model offers a reasoning choice at all. SPEC §6: "Do not offer
    /// unsupported reasoning efforts."
    public var offersReasoningChoice: Bool { !efforts.isEmpty }
}

/// One provider, with its models. The group's `id` is the provider id.
public struct ProviderSection: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var models: [ModelOption]
}

/// A provider the host could not reach. SPEC §6: "Show provider failures without hiding
/// the usable groups."
public struct ProviderFailure: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var message: String
}

/// One agent preset — "Standard mode" in the web app's vocabulary.
public struct ModeOption: Sendable, Hashable, Identifiable {
    /// The roster id. This is what goes on the wire.
    public var id: String
    public var isDefault: Bool
    public var name: String?
    public var description: String?
    /// Non-nil when the host marks the preset broken. SPEC §6: "A broken preset is
    /// unavailable with its explanation."
    public var broken: String?

    public var isSelectable: Bool { broken == nil }

    /// The web app's own label for the default preset.
    ///
    /// SPEC §6 asks for the label to read as "Standard mode" while the roster id goes on
    /// the wire, so the two are deliberately different strings. A named non-default preset
    /// shows its host name; an unnamed one falls back to its id rather than to an invented
    /// label.
    public var label: String {
        isDefault ? Self.standardModeLabel : (name ?? id)
    }

    public static let standardModeLabel = "Standard mode"
}

/// One permission preset, read-only.
public struct PermissionOption: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
}

/// Everything a model/mode picker renders.
public struct ModelModeCatalog: Sendable, Hashable {
    public var providers: [ProviderSection]
    public var failures: [ProviderFailure]
    /// What the host says is selected now, before any local staging.
    public var defaultSelection: ModelSelection
    public var modes: [ModeOption]
    /// Read-only in this design: SPEC §6 gives permission presets "no permission-preset
    /// mutation in this initial design".
    public var permissionPresets: [PermissionOption]
    public var defaultPermissionPreset: String?

    public init(
        providers: [ProviderSection],
        failures: [ProviderFailure],
        defaultSelection: ModelSelection,
        modes: [ModeOption],
        permissionPresets: [PermissionOption] = [],
        defaultPermissionPreset: String? = nil
    ) {
        self.providers = providers
        self.failures = failures
        self.defaultSelection = defaultSelection
        self.modes = modes
        self.permissionPresets = permissionPresets
        self.defaultPermissionPreset = defaultPermissionPreset
    }

    /// Wraps the generated wire types.
    ///
    /// - Parameter permissions: optional because a host that does not implement
    ///   `permissionPresets/catalog` must not stop the model picker from working. The
    ///   capability state decides whether the section is shown at all; this type only
    ///   refuses to invent presets it was not given.
    public init(
        _ catalog: ModelCatalog,
        presets: AgentPresetRoster,
        permissions: PermissionCatalog? = nil
    ) {
        self.providers = catalog.groups.map { group in
            ProviderSection(
                id: group.id,
                name: group.name,
                models: group.models.map { model in
                    ModelOption(
                        id: model.id,
                        provider: group.id,
                        name: model.name,
                        description: model.description,
                        efforts: (model.reasoning?.efforts ?? []).map {
                            EffortOption(id: $0.id, name: $0.name, description: $0.description)
                        },
                        defaultEffort: model.reasoning?.defaultEffort
                    )
                }
            )
        }
        self.failures = catalog.failures.map {
            ProviderFailure(id: $0.id, name: $0.name, message: $0.message)
        }
        self.defaultSelection = ModelSelection(catalog.default)
        self.modes = presets.presets.map {
            ModeOption(
                id: $0.id,
                isDefault: $0.isDefault,
                name: $0.name,
                description: $0.description,
                broken: $0.broken
            )
        }
        self.permissionPresets = (permissions?.options ?? []).map {
            PermissionOption(id: $0.value, name: $0.name, description: $0.description)
        }
        self.defaultPermissionPreset = permissions?.defaultPreset
    }

    /// The row for the selection the host reports, so the picker shows the host's real
    /// label rather than a guessed one.
    ///
    /// Nil when the selected model is not in the catalog — which happens when a provider
    /// is currently unreachable, and is exactly the case where inventing a label would
    /// mislead.
    public func option(for selection: ModelSelection) -> ModelOption? {
        providers
            .first { $0.id == selection.provider }?
            .models
            .first { $0.id == selection.model }
    }

    /// The mode row the host marks as default.
    public var defaultMode: ModeOption? {
        modes.first { $0.isDefault }
    }

    /// Whether the given preset is locked out of selection right now.
    ///
    /// SPEC §6 says a blank session may have its agent preset changed and a started one may
    /// not, and warns that a stale `blank` flag can suggest otherwise. So this is only a
    /// hint for enabling a control; the authoritative answer is the host's, and it arrives
    /// as ``SelectionRefusal/modeLocked``.
    public static func modeIsEditable(sessionIsBlank: Bool) -> Bool {
        sessionIsBlank
    }
}

// MARK: - Refusals

/// Why changing a selection did not take effect.
///
/// Separated from `DshRPCError` because the picker's response differs: a locked mode is
/// not a failure to retry, an unavailable model is not a network problem, and a transport
/// error is neither.
public enum SelectionRefusal: Error, Sendable, Hashable {
    /// The session has started its first turn, so the host refuses to change the preset.
    case modeLocked
    /// The host could not resolve the requested model.
    case modelUnavailable(message: String)
    /// A business refusal with its own code.
    case refused(code: String, message: String)
    /// Something transport-shaped: the selection was never judged.
    case transport(reason: String)

    /// The host's codes, read from the installed registry and session controller.
    public static let modeLockedCode = "agent-preset/locked"
    public static let modelUnavailableCode = "session/model-unavailable"

    /// Classifies a failed selection call.
    ///
    /// The distinction matters more than it looks: a locked mode must leave the confirmed
    /// selection displayed and stop offering the control, whereas a transport failure
    /// means the answer is still unknown and the picker must refresh before enabling Send
    /// (SPEC §6: "On uncertainty, refresh projections before enabling Send").
    public static func classify(_ error: DshRPCError) -> SelectionRefusal {
        if case .business(let rpcError) = error {
            switch rpcError.code {
            case modeLockedCode: return .modeLocked
            case modelUnavailableCode: return .modelUnavailable(message: rpcError.message)
            default: return .refused(code: rpcError.code, message: rpcError.message)
            }
        }
        switch error {
        case .credentialRejected:
            return .transport(reason: "the device credential was refused")
        case .relayedAuthenticationFailure:
            return .transport(reason: "the relay could not authenticate to the harness")
        case .rateLimited:
            return .transport(reason: "the host is rate limiting")
        case .harnessUnavailable:
            return .transport(reason: "the harness is unavailable behind the relay")
        case .capabilityUnavailable(let endpoint):
            return .transport(reason: "the host does not implement \(endpoint)")
        case .certificateChanged:
            return .transport(reason: "the host certificate changed")
        case .transportInterruption:
            return .transport(reason: "the connection was interrupted")
        case .protocolIncompatible:
            return .transport(reason: "the response did not match the protocol")
        case .unexpectedStatus(let status, _):
            return .transport(reason: "the host returned an unexpected status \(status)")
        case .cancelled:
            return .transport(reason: "the request was cancelled")
        case .business:
            // Handled above; kept so this switch stays exhaustive if a case is added.
            return .transport(reason: "the refusal could not be classified")
        }
    }

    /// Whether the picker should keep showing the previous selection as confirmed.
    ///
    /// True for everything except a transport failure, where nothing was decided.
    public var confirmsPreviousSelection: Bool {
        if case .transport = self { return false }
        return true
    }
}

// MARK: - Reading and changing

/// Reads the model and mode catalogs and performs the two selection mutations.
///
/// An actor because the catalog is shared state that several screens read and a selection
/// change invalidates.
///
/// The client is injected rather than reached through `ConnectionCoordinator`, so this
/// type has no opinion about connection ownership and can be exercised offline.
public actor ModelModeCatalogStore {
    /// `namespace/method`, straight from `Protocol/endpoints.json`.
    public static let modelCatalogMethod = "session/modelCatalog"
    public static let presetListMethod = "agentPresets/list"
    public static let selectModelMethod = "session/selectModel"
    public static let selectPresetMethod = "agentPresets/select"
    public static let permissionCatalogMethod = "permissionPresets/catalog"

    private let makeClient: @Sendable () -> DshRpcClient
    public private(set) var catalog: ModelModeCatalog?

    public init(makeClient: @escaping @Sendable () -> DshRpcClient) {
        self.makeClient = makeClient
    }

    /// Reads all three catalogs. The permission catalog is best-effort.
    ///
    /// A host without `permissionPresets/catalog` gets a 404, which is a missing optional
    /// section and not a reason to fail the picker the user is actually opening.
    @discardableResult
    public func refresh() async throws -> ModelModeCatalog {
        let client = makeClient()
        let models = try await client.call(
            Self.modelCatalogMethod, args: RPCEmptyRequest(), returning: ModelCatalog.self
        )
        let presets = try await client.call(
            Self.presetListMethod, args: RPCEmptyRequest(), returning: AgentPresetRoster.self
        )
        let permissions = try? await client.call(
            Self.permissionCatalogMethod, args: RPCEmptyRequest(), returning: PermissionCatalog.self
        )
        guard let modelCatalog = models.result.value, let roster = presets.result.value else {
            throw SelectionRefusal.transport(reason: "the host returned no catalog")
        }
        let built = ModelModeCatalog(
            modelCatalog,
            presets: roster,
            permissions: permissions?.result.value
        )
        catalog = built
        return built
    }

    /// Applies a model selection and returns the host's *normalized* answer.
    ///
    /// The returned value is the host's, not the request echoed back: SPEC §6 notes the
    /// host resolves the request through its own call-config path, so only its answer says
    /// what is now selected. A write, so it is never retried.
    public func selectModel(
        sessionId: String,
        provider: String,
        model: String,
        reasoningEffort: String? = nil
    ) async throws -> ModelSelection {
        let client = makeClient()
        do {
            let response = try await client.mutate(
                Self.selectModelMethod,
                args: SessionSelectModelArguments(request: SessionSelectModelRequest(
                    sessionId: sessionId,
                    provider: provider,
                    model: model,
                    reasoningEffort: reasoningEffort
                )),
                returning: SessionSelectModelValue.self
            )
            guard let selected = response.result.value?.selected else {
                throw SelectionRefusal.transport(reason: "the host returned no selection")
            }
            return ModelSelection(selected)
        } catch let error as DshRPCError {
            throw SelectionRefusal.classify(error)
        }
    }

    /// Applies an agent preset to a blank session, returning the preset the host accepted.
    public func selectMode(agentId: String, preset: String) async throws -> String {
        let client = makeClient()
        do {
            let response = try await client.mutate(
                Self.selectPresetMethod,
                args: AgentPresetsSelectArguments(agentId: agentId, agentPreset: preset),
                returning: AgentPresetsSelectResult.self
            )
            guard let accepted = response.result.value else {
                throw SelectionRefusal.transport(reason: "the host returned no preset")
            }
            return accepted
        } catch let error as DshRPCError {
            throw SelectionRefusal.classify(error)
        }
    }
}
