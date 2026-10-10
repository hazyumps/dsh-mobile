import SwiftUI

/// A pending decision from the host, in the two shapes the spec defines.
///
/// UX spec "Approvals and structured questions": an approval shows the host's
/// reason, action, and scope, with "Allow once" and "Reject"; a question
/// supports multiple items, single or multiple selection, an optional custom
/// answer, and a deliberate Submit. Both are one component because both are the
/// same thing on screen — the agent stopped and is waiting for this phone — and
/// both need the same stale handling below.
///
/// The component owns nothing about transport. Answers go out through the
/// closures the caller passes; the caller decides what a submission means and
/// when the card is history.
struct DecisionCard: View {
    enum Content {
        case approval(Approval)
        case question(Question)
    }

    /// An action the agent wants to perform. The fields come from the host, so
    /// an absent scope renders as nothing rather than as a guess.
    struct Approval {
        var reason: String?
        var action: String
        var scope: String?
        /// Exact detail behind a disclosure: the spec keeps details available
        /// before submission rather than asking for trust in a one-line summary.
        var details: String?
    }

    /// One or more questions asked together, matching the host's structure.
    struct Question {
        var header: String?
        var items: [Item]
    }

    struct Item: Identifiable {
        var id: String
        var prompt: String
        var options: [String]
        var allowsMultipleSelection: Bool
        var allowsCustomAnswer: Bool
        var customAnswerPlaceholder: String?
    }

    /// One item's answer, as the caller will send it. `selected` keeps the
    /// option's own text: the host asked in words, so words are the answer.
    struct Answer: Equatable {
        var itemId: String
        var selected: [String]
        var custom: String?
    }

    let content: Content
    /// A card whose request is no longer confirmed open. The spec keeps
    /// historical cards visible but disables their controls until the host says
    /// otherwise, so this is a first-class input rather than a caller trick.
    var isStale = false
    /// Raised while a submission is in flight, so the same decision cannot be
    /// tapped twice.
    var isSubmitting = false
    /// The sentence that explains a disabled card, and the uncertain state after
    /// a submission whose outcome is unknown.
    var footnote: String?
    var onAllowOnce: (() -> Void)?
    var onReject: (() -> Void)?
    var onSubmit: (([Answer]) -> Void)?
    /// Stops the turn instead of answering it. Not a rejection: nothing is sent about the
    /// question, the work behind it is ended.
    var declineTitle: String?
    var onDecline: (() -> Void)?

    /// Options marked chosen before the first tap. A transcript never passes it;
    /// the gallery does, because this machine has no Simulator GUI and nothing can
    /// be tapped, so the selected styling would otherwise never be seen. Seeded
    /// into state the card owns, so a later tap still replaces it.
    var initiallySelected: [String: [String]] = [:]

    @State private var selections: [String: Set<String>]
    @State private var customAnswers: [String: String] = [:]
    @State private var showsDetails = false
    @Environment(\.dynamicTypeSize) private var typeSize

    init(
        content: Content,
        isStale: Bool = false,
        isSubmitting: Bool = false,
        footnote: String? = nil,
        onAllowOnce: (() -> Void)? = nil,
        onReject: (() -> Void)? = nil,
        onSubmit: (([Answer]) -> Void)? = nil,
        declineTitle: String? = nil,
        onDecline: (() -> Void)? = nil,
        initiallySelected: [String: [String]] = [:]
    ) {
        self.content = content
        self.isStale = isStale
        self.isSubmitting = isSubmitting
        self.footnote = footnote
        self.onAllowOnce = onAllowOnce
        self.onReject = onReject
        self.onSubmit = onSubmit
        self.declineTitle = declineTitle
        self.onDecline = onDecline
        self.initiallySelected = initiallySelected
        _selections = State(initialValue: initiallySelected.mapValues(Set.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceCard) {
            switch content {
            case .approval(let approval): approvalBody(approval)
            case .question(let question): questionBody(question)
            }
            if let footnote {
                Text(footnote)
                    .font(.dshMetadata)
                    .foregroundStyle(isStale ? DSHPalette.secondaryText : DSHPalette.error)
            }
        }
        .padding(DSHMetrics.spaceCard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dshCard()
        .opacity(isStale ? 0.7 : 1)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Approval

    @ViewBuilder
    private func approvalBody(_ approval: Approval) -> some View {
        Label(isStale ? "Approval · no longer pending" : "Your approval", systemImage: "hand.raised")
            .font(.dshMetadata)
            .foregroundStyle(DSHPalette.attention)
            .accessibilityLabel(isStale ? "This approval is no longer pending" : "The agent is asking your approval")

        Text(approval.action.isEmpty ? "The agent wants to take an action." : approval.action)
            .font(.title3.weight(.medium))
            .foregroundStyle(DSHPalette.primaryText)
            .fixedSize(horizontal: false, vertical: true)

        if let reason = approval.reason, !reason.isEmpty {
            Text(reason)
                .font(.dshSupporting)
                .foregroundStyle(DSHPalette.secondaryText)
        }
        if let scope = approval.scope, !scope.isEmpty {
            field(label: "Scope", value: scope)
        }
        if let details = approval.details, !details.isEmpty {
            Button {
                showsDetails.toggle()
            } label: {
                HStack(spacing: DSHMetrics.space) {
                    Text("View action details")
                    Spacer(minLength: DSHMetrics.space)
                    Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                        .accessibilityHidden(true)
                }
                .font(.dshSupporting)
                .foregroundStyle(DSHPalette.primaryText)
                .padding(DSHMetrics.space)
                .background(DSHPalette.elevatedSurface.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsDetails {
                Text(details)
                    .font(.dshCode)
                    .foregroundStyle(DSHPalette.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        decisionButtons {
            control(title: "Allow once", prominent: true, action: onAllowOnce)
            control(title: "Reject", prominent: false, action: onReject)
        }
    }

    // MARK: - Question

    @ViewBuilder
    private func questionBody(_ question: Question) -> some View {
        if let header = question.header, !header.isEmpty {
            Text(header)
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.attention)
                .accessibilityLabel("Question from the agent: \(header)")
        }
        ForEach(question.items) { item in
            questionItem(item)
        }
        decisionButtons {
            control(title: "Submit", prominent: true, isEnabled: canSubmit, action: submit)
            if let declineTitle, let onDecline {
                control(title: declineTitle, prominent: false, action: onDecline)
            }
        }
        if declineTitle != nil {
            // The consequence, next to the control that causes it: the question is not refused,
            // the agent's turn is stopped.
            Text("Stops the agent's turn. The question goes unanswered.")
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func questionItem(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: DSHMetrics.space) {
            Text(item.prompt)
                .font(.body)
                .foregroundStyle(DSHPalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(item.options, id: \.self) { option in
                optionRow(item, option)
            }
            if item.allowsCustomAnswer {
                TextField(
                    item.customAnswerPlaceholder ?? "Your answer",
                    text: binding(forCustom: item.id),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(isStale)
                .accessibilityLabel(item.customAnswerPlaceholder ?? "Your own answer to \(item.prompt)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func optionRow(_ item: Item, _ option: String) -> some View {
        Button {
            choose(option, for: item)
        } label: {
            HStack(spacing: DSHMetrics.space) {
                Image(systemName: symbol(for: item, option: option))
                    .foregroundStyle(isChosen(item, option) ? DSHPalette.primaryActionText : DSHPalette.secondaryText)
                    .accessibilityHidden(true)
                Text(option)
                    .font(.body)
                    .foregroundStyle(DSHPalette.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Selector rows stack their label and marker at
                    // accessibility sizes rather than clipping (UX spec
                    // "Accessibility and layout acceptance").
                    .multilineTextAlignment(typeSize.dshNeedsStackedControls ? .center : .leading)
            }
            .padding(.horizontal, DSHMetrics.spaceCard)
            .padding(.vertical, DSHMetrics.space + 2)
            .frame(maxWidth: .infinity)
            .background(isChosen(item, option) ? DSHPalette.elevatedSurface : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous)
                    .strokeBorder(
                        isChosen(item, option) ? DSHPalette.primaryAction : DSHPalette.divider,
                        lineWidth: isChosen(item, option) ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isStale)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isChosen(item, option) ? .isSelected : [])
        .accessibilityHint(item.allowsMultipleSelection ? "Multiple answers allowed" : "Choose one answer")
    }

    private func decisionButtons<Content: View>(@ViewBuilder _ build: () -> Content) -> some View {
        Group {
            if typeSize.dshNeedsStackedControls {
                VStack(spacing: DSHMetrics.space) { build() }
            } else {
                HStack(spacing: DSHMetrics.space) { build() }
            }
        }
    }

    @ViewBuilder
    private func control(
        title: String,
        prominent: Bool,
        isEnabled: Bool = true,
        action: (() -> Void)?
    ) -> some View {
        // Two branches rather than a ternary: `.bordered` and `.borderedProminent` are
        // distinct types, so a ternary has no common type and Swift falls back to
        // `ButtonStyle`, which has neither member.
        Group {
            if prominent {
                Button(title) { action?() }.buttonStyle(.borderedProminent)
            } else {
                Button(title) { action?() }.buttonStyle(.bordered)
            }
        }
            .tint(prominent ? DSHPalette.primaryAction : DSHPalette.elevatedSurface)
            .foregroundStyle(prominent ? DSHPalette.onPrimaryAction : DSHPalette.primaryText)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .frame(minHeight: DSHMetrics.minimumHitTarget)
            .disabled(isStale || isSubmitting || isEnabled == false || action == nil)
    }

    private func field(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
            Text(label)
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
            Text(value)
                .font(.dshSupporting)
                .foregroundStyle(DSHPalette.primaryText)
                .textSelection(.enabled)
        }
    }

    // MARK: - Selection

    private func isChosen(_ item: Item, _ option: String) -> Bool {
        selections[item.id]?.contains(option) ?? false
    }

    private func symbol(for item: Item, option: String) -> String {
        if item.allowsMultipleSelection {
            return isChosen(item, option) ? "checkmark.square.fill" : "square"
        }
        return isChosen(item, option) ? "largecircle.fill.circle" : "circle"
    }

    /// Single selection replaces; multiple selection toggles. Both drop an empty
    /// key so `canSubmit` does not treat a cleared item as answered.
    private func choose(_ option: String, for item: Item) {
        var chosen = selections[item.id] ?? []
        if item.allowsMultipleSelection {
            if chosen.contains(option) { chosen.remove(option) } else { chosen.insert(option) }
        } else {
            chosen = chosen == [option] ? [] : [option]
        }
        selections[item.id] = chosen.isEmpty ? nil : chosen
    }

    private func binding(forCustom id: String) -> Binding<String> {
        Binding(
            get: { customAnswers[id] ?? "" },
            set: { customAnswers[id] = $0 }
        )
    }

    /// An item is answered by a choice or by custom text, since the host may
    /// allow both and either one is a real answer.
    private var canSubmit: Bool {
        guard case .question(let question) = content, !question.items.isEmpty else { return false }
        return question.items.allSatisfy { item in
            !(selections[item.id]?.isEmpty ?? true)
                || !(customAnswers[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    private func submit() {
        guard case .question(let question) = content else { return }
        let answers = question.items.map { item -> Answer in
            let custom = customAnswers[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Answer(
                itemId: item.id,
                selected: (selections[item.id] ?? []).sorted(),
                custom: (custom?.isEmpty ?? true) ? nil : custom
            )
        }
        onSubmit?(answers)
    }
}
