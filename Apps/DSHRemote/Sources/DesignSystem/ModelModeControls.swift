import DSHRemoteKit
import SwiftUI

/// The mode and model a new session will start in (SPEC §6).
///
/// Plain data and closures, like every other design-system component: the gallery renders
/// this without a host, and the new-session screen renders it from the catalog the store
/// loaded.
///
/// Nothing here invents a choice. Every row comes from the host's own catalog, the current
/// label is the host's own name for what is selected, and a model the host cannot resolve is
/// refused by the host rather than filtered out here. The mode is staged rather than applied,
/// because SPEC §6 gives `agentPresets/select` to a *blank* session and a new session has no
/// identity until the first send — so the preset rides along on `session/create` instead.
///
/// Two styles, one set of options: `chips` is the pair of capsules the design system has
/// always drawn, and `rows` is the labelled context line the new-session screen reads
/// top-to-bottom. They share the option lists so a choice can never exist in one and not
/// the other.
struct ModelModeControls: View {
    enum Style {
        case chips
        case rows
    }

    var style: Style = .chips
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
        VStack(alignment: .leading, spacing: style == .chips ? DSHMetrics.space : 0) {
            if let catalog {
                controls(catalog)
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
                    .padding(.top, style == .rows ? DSHMetrics.spaceSmall : 0)
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
            } else {
                // Neither a catalog nor a failure: the read is in flight, or it has not been
                // made. A control that renders *nothing* in this state is how two of the four
                // context rows on the new-session screen silently disappeared — found by
                // looking at the screen, not by a test.
                VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
                    HStack(spacing: DSHMetrics.space) {
                        if isLoading { ProgressView() }
                        Text(isLoading ? "Reading presets and models…" : "Presets and models not read yet")
                    }
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.secondaryText)
                    if !isLoading {
                        Button("Load them", action: onRefresh)
                            .font(.dshMetadata)
                            .foregroundStyle(DSHPalette.primaryActionText)
                    }
                }
                .frame(minHeight: DSHMetrics.minimumHitTarget, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func controls(_ catalog: ModelModeCatalog) -> some View {
        switch style {
        case .chips:
            HStack(alignment: .top, spacing: DSHMetrics.space) {
                Menu {
                    modeOptions(catalog)
                } label: {
                    chip(
                        title: selectedMode?.label ?? "Mode",
                        symbol: "slider.horizontal.3",
                        isStaged: isModeStaged
                    )
                }
                .accessibilityLabel("Mode. \(selectedMode?.label ?? "not selected"). Change")

                Menu {
                    modelOptions(catalog)
                } label: {
                    chip(
                        title: selectedModel.map(modelLabel) ?? "Model",
                        symbol: "cpu",
                        isStaged: isModelStaged
                    )
                }
                .accessibilityLabel("Model. \(selectedModel.map(modelLabel) ?? "not selected"). Change")
            }
        case .rows:
            VStack(spacing: 0) {
                DSHContextRow(
                    title: "Preset",
                    symbol: "slider.horizontal.3",
                    value: selectedMode?.label ?? "Reading presets…",
                    isStaged: isModeStaged
                ) {
                    modeOptions(catalog)
                }
                DSHContextRow(
                    title: "Model",
                    symbol: "cpu",
                    value: selectedModel.map(modelLabel) ?? "Reading models…",
                    isStaged: isModelStaged
                ) {
                    modelOptions(catalog)
                }
            }
        }
    }

    // MARK: - Options

    @ViewBuilder
    private func modeOptions(_ catalog: ModelModeCatalog) -> some View {
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
    }

    @ViewBuilder
    private func modelOptions(_ catalog: ModelModeCatalog) -> some View {
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
