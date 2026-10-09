import DSHRemoteKit
import SwiftUI

/// The mode and model a new session will start in, as two menus (SPEC §6).
///
/// Plain data and closures, like every other design-system component: the gallery renders
/// this without a host, and Home renders it from the catalog the store loaded.
///
/// Nothing here invents a choice. Every row comes from the host's own catalog, the current
/// label is the host's own name for what is selected, and a model the host cannot resolve is
/// refused by the host rather than filtered out here. The mode is staged rather than applied,
/// because SPEC §6 gives `agentPresets/select` to a *blank* session and a new session has no
/// identity until the first send — so the preset rides along on `session/create` instead.
struct ModelModeControls: View {
    let catalog: ModelModeCatalog?
    let isLoading: Bool
    let failure: String?
    let selectedMode: ModeOption?
    let selectedModel: ModelOption?
    /// Whether the choice differs from the host's default, which is what the mark means.
    var isModeStaged = false
    var isModelStaged = false
    var onSelectMode: (String) -> Void
    var onSelectModel: (ModelSelection) -> Void
    var onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.space) {
            if let catalog {
                HStack(alignment: .top, spacing: DSHMetrics.space) {
                    modeControl(catalog)
                    modelControl(catalog)
                }
                if !catalog.failures.isEmpty {
                    // SPEC §6: show provider failures without hiding the groups that work.
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(catalog.failures) { failure in
                            Text("\(failure.name): \(failure.message)")
                                .font(.dshMetadata)
                                .foregroundStyle(DSHPalette.attention)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else if isLoading {
                HStack(spacing: DSHMetrics.space) {
                    ProgressView()
                    Text("Reading models…").foregroundStyle(DSHPalette.secondaryText)
                }
                .font(.dshMetadata)
            } else if let failure {
                VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
                    Text(failure)
                        .font(.dshMetadata)
                        .foregroundStyle(DSHPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again", action: onRefresh)
                        .font(.dshMetadata)
                        .foregroundStyle(DSHPalette.primaryActionText)
                }
            }
        }
    }

    // MARK: - Mode

    private func modeControl(_ catalog: ModelModeCatalog) -> some View {
        Menu {
            ForEach(catalog.modes) { mode in
                Button {
                    onSelectMode(mode.id)
                } label: {
                    // A broken preset is listed with the host's own explanation and cannot be
                    // chosen; hiding it would leave the roster's gap unexplained.
                    mode.broken == nil ? Text(mode.label) : Text("\(mode.label) — \(mode.broken ?? "")")
                }
                .disabled(!mode.isSelectable)
            }
        } label: {
            chip(
                title: selectedMode?.label ?? "Mode",
                symbol: "slider.horizontal.3",
                isStaged: isModeStaged
            )
        }
        .accessibilityLabel("Mode. \(selectedMode?.label ?? "not selected"). Change")
    }

    // MARK: - Model

    private func modelControl(_ catalog: ModelModeCatalog) -> some View {
        Menu {
            ForEach(catalog.providers) { provider in
                Menu(provider.name) {
                    ForEach(provider.models) { model in
                        if model.offersReasoningChoice {
                            // Effort is part of the selection, not a separate setting: the
                            // host normalizes the pair together.
                            Menu(model.name) {
                                ForEach(model.efforts) { effort in
                                    Button(effortLabel(effort, for: model)) {
                                        onSelectModel(selection(for: model, effort: effort.id))
                                    }
                                }
                            }
                        } else {
                            Button(modelLabel(model)) {
                                onSelectModel(selection(for: model, effort: nil))
                            }
                        }
                    }
                }
            }
        } label: {
            chip(
                title: selectedModel.map(modelLabel) ?? "Model",
                symbol: "cpu",
                isStaged: isModelStaged
            )
        }
        .accessibilityLabel("Model. \(selectedModel.map(modelLabel) ?? "not selected"). Change")
    }

    private func modelLabel(_ model: ModelOption) -> String {
        // The host's own display name, with the provider beside it so two providers offering
        // a similarly-named model stay distinguishable.
        model.name
    }

    private func effortLabel(_ effort: EffortOption, for model: ModelOption) -> String {
        let isDefault = effort.id == model.defaultEffort
        return isDefault ? "\(effort.name) (default)" : effort.name
    }

    private func selection(for model: ModelOption, effort: String?) -> ModelSelection {
        ModelSelection(
            provider: model.provider,
            model: model.id,
            reasoningEffort: effort ?? model.defaultEffort
        )
    }

    /// One control's chip: the host's label, a symbol, and a mark when it is not the default.
    private func chip(title: String, symbol: String, isStaged: Bool) -> some View {
        HStack(spacing: DSHMetrics.spaceSmall) {
            Image(systemName: symbol)
                .font(.caption)
                .accessibilityHidden(true)
            Text(title)
                .font(.dshMetadata)
                .lineLimit(1)
            if isStaged {
                Circle()
                    .fill(DSHPalette.primaryActionText)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.down")
                .font(.caption2)
                .accessibilityHidden(true)
        }
        .foregroundStyle(DSHPalette.primaryText)
        .padding(.horizontal, DSHMetrics.spaceCard)
        .frame(minHeight: DSHMetrics.minimumHitTarget)
        .background(DSHPalette.card)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(DSHPalette.cardEdge, lineWidth: 1))
        .contentShape(Capsule())
    }
}
