import SwiftUI

/// The text-entry composer: growing field, attachment button, optional model
/// control, and Send (UX spec "Composer, commands, and attachments").
///
/// Two rules shape it. Send is disabled for reasons the field itself cannot
/// show — offline, waiting for a baseline, an upload in flight — so the reason
/// goes in a line beside it rather than being implied by a grey button. And an
/// attachment control or a model control that has nowhere to go is absent, not
/// greyed: the spec forbids presenting decorative controls as working features.
///
/// The field grows to six lines and then scrolls internally, which is what
/// `lineLimit(1...6)` on a vertical axis does; beyond that the composer keeps
/// its height and the conversation above it does not get pushed off screen.
struct Composer: View {
    @Binding var text: String
    /// Disabled whenever the caller says so; `sendBlockedReason` tells the user
    /// why. Pass `nil` for the reason when Send is blocked by something obvious,
    /// such as an empty draft.
    var canSend = true
    var sendBlockedReason: String?
    var isSending = false
    /// Non-nil only when a real attachment action exists.
    var onAttach: (() -> Void)?
    var attachmentLabel = "Add an attachment"
    /// Non-nil only when the host's model catalog actually backs the control.
    /// A read-only `modelName` renders as a label, which the spec requires to be
    /// visibly identified as such rather than looking like a menu.
    var modelSelection: ModelSelection?
    var placeholder = "Message"
    /// Bumped by the caller to focus the field — the drawer's New session uses it so the
    /// prompt field is ready without a second tap. The composer owns the focus state; the
    /// caller only asks.
    var focusRequest = 0
    /// Called with the trimmed draft. Clearing it stays the caller's decision,
    /// because the draft is cleared only after the host accepts the prompt
    /// (UX spec "Composer, commands, and attachments").
    var onSend: ((String) -> Void)?

    @FocusState private var isFocused

    /// The model control's two shapes: a chooser with real options, or a label
    /// that says the selection lives somewhere else.
    struct ModelSelection {
        var name: String
        /// Empty means read-only: nothing to choose, so nothing to tap.
        var options: [String] = []
        var select: ((String) -> Void)?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.space) {
            HStack(alignment: .bottom, spacing: DSHMetrics.space) {
                if let onAttach {
                    DSHIconAction(label: attachmentLabel, symbol: "plus", action: onAttach)
                }
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(DSHPalette.primaryText)
                    .lineLimit(1...6)
                    .focused($isFocused)
                    .accessibilityLabel(placeholder)
                Button {
                    send()
                } label: {
                    if isSending {
                        ProgressView()
                            .frame(minWidth: DSHMetrics.minimumHitTarget, minHeight: DSHMetrics.minimumHitTarget)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(sendEnabled ? DSHPalette.onPrimaryAction : DSHPalette.secondaryText)
                            .frame(minWidth: DSHMetrics.minimumHitTarget, minHeight: DSHMetrics.minimumHitTarget)
                            .background(sendEnabled ? DSHPalette.primaryAction : DSHPalette.elevatedSurface)
                            .clipShape(Circle())
                            .contentShape(Circle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send")
                // Disabled, but still the button in place: a user who cannot see
                // the grey still has the explanation line below.
                .disabled(!sendEnabled)
            }

            if let modelSelection {
                modelControl(modelSelection)
            }

            if sendEnabled == false, let sendBlockedReason, !sendBlockedReason.isEmpty {
                Label(sendBlockedReason, systemImage: "info.circle")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: focusRequest) { _, _ in
            guard focusRequest > 0 else { return }
            isFocused = true
        }
        .padding(DSHMetrics.spaceCard)
        .background(DSHPalette.card)
        .overlay(
            RoundedRectangle(cornerRadius: DSHMetrics.composerCornerRadius, style: .continuous)
                .strokeBorder(DSHPalette.cardEdge, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.composerCornerRadius, style: .continuous))
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasDraft: Bool {
        !trimmedText.isEmpty
    }

    private var sendEnabled: Bool {
        hasDraft && canSend && !isSending
    }

    private func send() {
        guard sendEnabled else { return }
        onSend?(trimmedText)
    }

    @ViewBuilder
    private func modelControl(_ selection: ModelSelection) -> some View {
        if selection.options.isEmpty || selection.select == nil {
            Label(selection.name, systemImage: "cpu")
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
                .accessibilityLabel("Model \(selection.name). Selection is not available here.")
        } else {
            Menu {
                ForEach(selection.options, id: \.self) { option in
                    Button(option) { selection.select?(option) }
                }
            } label: {
                HStack(spacing: DSHMetrics.spaceSmall) {
                    Text(selection.name)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .accessibilityHidden(true)
                }
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.primaryText)
                .padding(.horizontal, DSHMetrics.spaceCard)
                .frame(minHeight: DSHMetrics.minimumHitTarget)
                .background(DSHPalette.elevatedSurface)
                .clipShape(Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model. \(selection.name). Change")
        }
    }
}
