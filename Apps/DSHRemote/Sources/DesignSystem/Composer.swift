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
    /// Non-nil only when images can actually be sent: a photo control with nowhere to go is
    /// absent, not greyed.
    var onAddImage: (() -> Void)?
    /// The file entry's title in the attachment menu. A noun, because that is what a menu of
    /// sources is — "Add a file" next to "Photo" reads like a sentence someone cut in half.
    var fileMenuTitle = "File"
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
    /// Told when the field takes or gives up focus.
    ///
    /// A caller that puts the composer inside a scrolling page needs this to bring it above the
    /// keyboard: the keyboard's own inset does not move content that is not already at the bottom
    /// of the screen, which is how the chat box ended up behind the keyboard on the phone.
    ///
    /// Declared beside `onSend` so the initialiser's order stays the order call sites read in —
    /// memberwise initialisers follow declaration order, and a callback parked in the middle of
    /// the layout options has to be passed in the middle of them.
    var onFocusChange: ((Bool) -> Void)?

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
            // Centred rather than bottom-aligned: the controls beside the field are 44 points
            // tall and a line of text is about 22, so aligning their bottoms dropped the text
            // roughly 9 points below the buttons it sits between — visible as text hugging the
            // bottom of the box in a single-line draft.
            HStack(alignment: .center, spacing: DSHMetrics.space) {
                // One attachment button rather than two icons competing for the same strip. The
                // choices are the same either way; a menu states them instead of making the row
                // carry a symbol per destination, and it is where a third source would go.
                if onAttach != nil || onAddImage != nil {
                    Menu {
                        if let onAddImage {
                            Button { onAddImage() } label: { Label("Photo", systemImage: "photo") }
                        }
                        if let onAttach {
                            Button { onAttach() } label: { Label(fileMenuTitle, systemImage: "doc") }
                        }
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.body)
                            // `paperclip` fills its em box where `plus` and `photo` do not, so at the
                            // same font size it drew about half again as large as the buttons it
                            // replaced — "huge and ridiculous" on the phone. Small image scale puts
                            // its ink back alongside the text.
                            .imageScale(.small)
                            .foregroundStyle(DSHPalette.secondaryText)
                            .frame(minWidth: DSHMetrics.minimumHitTarget, minHeight: DSHMetrics.minimumHitTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Add an attachment")
                }
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.body)
                    // A field at its line limit scrolls instead of growing, so this is the case
                    // where the keyboard had no way off: the drag below never reached the field,
                    // and scrolling it did nothing.
                    .scrollDismissesKeyboard(.immediately)
                    .foregroundStyle(DSHPalette.primaryText)
                    // Five lines then scroll: the box should look like a message field, not a
                    // document.
                    .lineLimit(1...5)
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
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(sendEnabled ? DSHPalette.onPrimaryAction : DSHPalette.secondaryText)
                            // Drawn smaller than it is tappable: the target stays 44 points, the
                            // circle does not dominate the row.
                            .frame(width: 34, height: 34)
                            .background(sendEnabled ? DSHPalette.primaryAction : DSHPalette.elevatedSurface)
                            .clipShape(Circle())
                            .frame(minWidth: DSHMetrics.minimumHitTarget, minHeight: DSHMetrics.minimumHitTarget)
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
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
        // Tighter vertically than horizontally: the row's own controls already carry 44 points
        // of height, so card padding on both axes made the composer a slab.
        .padding(.horizontal, DSHMetrics.spaceCard)
        .padding(.vertical, DSHMetrics.spaceSmall)
        .dismissesKeyboardOnDownwardDrag()
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
