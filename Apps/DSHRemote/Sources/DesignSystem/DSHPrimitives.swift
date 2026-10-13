import SwiftUI

/// The four state colors, named by what they mean rather than by a hue, so a
/// component can say "this needs input" without picking a hex.
///
/// UX spec "Visual system" requires state to be carried by text as well as
/// colour, so nothing here renders a colour alone — every consumer pairs a tone
/// with a word.
enum DSHTone: Equatable, Hashable {
    case neutral
    case success
    case attention
    case error
    case action

    var color: Color {
        switch self {
        case .neutral: DSHPalette.secondaryText
        case .success: DSHPalette.success
        case .attention: DSHPalette.attention
        case .error: DSHPalette.error
        case .action: DSHPalette.primaryActionText
        }
    }
}

/// The card surface every card in the app shares: one flat fill, one hairline
/// edge, one radius.
///
/// Kept as a background modifier rather than a view, because the cards differ
/// in layout and would otherwise each wrap this in a stack that fights their
/// own sizing.
struct DSHCardBackground: ViewModifier {
    var isHighlighted = false
    var cornerRadius: CGFloat = DSHMetrics.cardCornerRadius

    func body(content: Content) -> some View {
        content
            .background(isHighlighted ? DSHPalette.elevatedSurface : DSHPalette.card)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DSHPalette.cardEdge, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func dshCard(isHighlighted: Bool = false, cornerRadius: CGFloat = DSHMetrics.cardCornerRadius) -> some View {
        modifier(DSHCardBackground(isHighlighted: isHighlighted, cornerRadius: cornerRadius))
    }
}

/// A short status word with its state colour, and a dot so the state is not
/// carried by colour alone. Used in lists, cards, and the host row.
///
/// The text comes from the caller: UX spec "Workspace drawer and session
/// browser" fixes the words ("Running", "Needs your input", "Draft saved"), and
/// a component that invented its own would drift from them.
struct DSHStatusChip: View {
    let text: String
    var tone: DSHTone = .neutral
    /// A dot is enough for a list row; a symbol suits a card header where the
    /// state changes (an arrow for reconnecting reads as motion).
    var symbol: String?

    init(_ text: String, tone: DSHTone = .neutral, symbol: String? = nil) {
        self.text = text
        self.tone = tone
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: DSHMetrics.spaceSmall + 2) {
            if let symbol {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(tone.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(.dshMetadata)
        .foregroundStyle(tone.color)
        .padding(.horizontal, DSHMetrics.space)
        .padding(.vertical, DSHMetrics.spaceSmall)
        .background(tone == .neutral ? Color.clear : DSHPalette.elevatedSurface.opacity(0.5))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A labelled button that must stay tappable at 44 × 44 pt even when its label
/// is a single symbol.
///
/// The spec's floor ("Controls have at least a 44 × 44 pt hit area even when
/// their symbol is smaller") is easy to lose when a symbol is placed in a list
/// row, so it lives here instead of at each call site.
struct DSHIconAction: View {
    let label: String
    let symbol: String
    var tone: DSHTone = .neutral
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tone.color)
                .frame(minWidth: DSHMetrics.minimumHitTarget, minHeight: DSHMetrics.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A titled group on a scrolling page: "Recents", "Projects", "Today".
///
/// The heading is metadata-weight rather than a heading font because these are labels
/// inside a list, not sections of a document — and Home has several of them stacked,
/// which a hierarchy of headline sizes would turn into a ladder.
struct DSHGroupHeader: View {
    let title: String
    /// A count or a secondary action's label, on the trailing edge.
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSHMetrics.space) {
            Text(title)
                .font(.dshMetadata.weight(.semibold))
                .foregroundStyle(DSHPalette.secondaryText)
            Spacer(minLength: DSHMetrics.space)
            if let trailing {
                Text(trailing)
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.secondaryText)
            }
        }
    }
}

/// The visual line a context row draws: what is being decided, and what it is set to.
///
/// Split from ``DSHContextRow`` so a decision that is a *menu* and one that needs a
/// searchable sheet — the project list, which can run to dozens — render identically while
/// presenting differently. The shape is the component; the presentation is the caller's.
struct DSHContextLabel: View {
    let title: String
    let symbol: String
    let value: String
    var isStaged = false

    var body: some View {
        HStack(spacing: DSHMetrics.space) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(DSHPalette.secondaryText)
                .frame(width: 26, alignment: .leading)
                .accessibilityHidden(true)
            Text(title)
                .font(.dshMessageBody)
                .foregroundStyle(DSHPalette.secondaryText)
            Spacer(minLength: DSHMetrics.space)
            HStack(spacing: DSHMetrics.spaceSmall + 2) {
                Text(value)
                    .font(.dshMessageBody)
                    .foregroundStyle(DSHPalette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isStaged {
                    Circle()
                        .fill(DSHPalette.primaryActionText)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: DSHMetrics.minimumHitTarget)
        .contentShape(Rectangle())
    }
}

/// One line of the new-session context: what is being decided, and what it is set to.
///
/// A row rather than a chip, because the four decisions are read as a list before typing
/// and a strip of capsules cannot carry the label that says which is which. The whole row
/// is the control, so the target is the row rather than the chevron.
///
/// The label is a `Menu` with custom content. On iOS 26 a `Menu` draws Liquid Glass chrome
/// around a custom label, which is why `Composer` moved its icon-only attachment button to
/// a plain button and a sheet; a full-width row label is a different shape and has not been
/// seen on the phone yet. If the phone draws a capsule around these rows, this is the place
/// to change — not the call sites.
struct DSHContextRow<MenuContent: View>: View {
    let title: String
    let symbol: String
    let value: String
    /// Whether the choice differs from the host's default, marked as it is elsewhere.
    var isStaged = false
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        Menu {
            menu()
        } label: {
            DSHContextLabel(title: title, symbol: symbol, value: value, isStaged: isStaged)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(value).")
        .accessibilityHint("Change \(title.lowercased())")
    }
}

/// The compact brand lockup: whale placeholder, "deepseek", and the HARNESS
/// tag. Shown on Home and in the drawer (UX spec "Identity and color").
///
/// OPEN ITEM — the logo is a placeholder. The spec says to use an existing,
/// appropriately licensed DeepSeek whale/wordmark asset and to verify its
/// source before shipping, and explicitly not to recreate the production logo
/// by cropping the mockup. No such asset exists in this repository, so this
/// renders an SF Symbol and a text wordmark and nothing claims to be the real
/// mark. Replace `placeholderSymbol` and the wordmark styling once a licensed
/// asset is added to the app bundle, and keep the accessibility label.
struct DSHBrandLockup: View {
    private var placeholderSymbol: String { "sparkles" }

    var body: some View {
        HStack(spacing: DSHMetrics.space) {
            Image(systemName: placeholderSymbol)
                .accessibilityHidden(true)
            Text("deepseek")
                .font(.body.weight(.semibold))
                .accessibilityHidden(true)
            Text("HARNESS")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, DSHMetrics.spaceSmall + 2)
                .padding(.vertical, 2)
                .background(DSHPalette.elevatedSurface)
                .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceSmall))
                .accessibilityHidden(true)
        }
        .foregroundStyle(DSHPalette.primaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("DeepSeek Harness")
    }
}
