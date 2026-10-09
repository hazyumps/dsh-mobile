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
