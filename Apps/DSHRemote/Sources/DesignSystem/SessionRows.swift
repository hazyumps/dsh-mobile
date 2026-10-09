import SwiftUI

/// A recent-session card for Home and the session browser.
///
/// UX spec "Workspace drawer and session browser": "A session card shows title,
/// a short supporting line when available, and a meaningful status or last
/// activity." Both optional parts are optional here — a session with no title
/// and no supporting line still renders as a tappable row rather than empty
/// space.
///
/// The whole card is the control, so the tap target is the card and not the
/// chevron: the spec forbids a primary action that depends on a precisely
/// targeted small symbol.
struct SessionCard: View {
    let title: String
    var supportingLine: String?
    var state: DSHSessionState?
    var lastActivity: String?
    var isHighlighted = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: DSHMetrics.space) {
                VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall + 2) {
                    Text(title.isEmpty ? "Untitled session" : title)
                        .font(.dshCardTitle)
                        .foregroundStyle(DSHPalette.primaryText)
                        .lineLimit(2)
                    if let supportingLine, !supportingLine.isEmpty {
                        Text(supportingLine)
                            .font(.dshSupporting)
                            .foregroundStyle(DSHPalette.secondaryText)
                            .lineLimit(2)
                    }
                    // The spec lets a card show a status *or* last activity.
                    // Only one is passed in practice, and drawing a second line
                    // of metadata for its own sake costs the row its airiness.
                    if let lastActivity {
                        Text(lastActivity)
                            .font(.dshMetadata)
                            .foregroundStyle(DSHPalette.secondaryText)
                    }
                }
                Spacer(minLength: DSHMetrics.space)
                if let state {
                    DSHStatusChip(state.text, tone: state.tone, symbol: state.symbol)
                        .fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(DSHMetrics.spaceCard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dshCard(isHighlighted: isHighlighted)
            .contentShape(RoundedRectangle(cornerRadius: DSHMetrics.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The session states the spec tabulates, with the exact words it uses.
///
/// "Connection stale" deliberately carries no indicator: the spec says a stale
/// list is a "neutral cached presentation" that must not keep asserting a live
/// running status.
enum DSHSessionState: Equatable {
    case running
    case needsInput
    case draftSaved
    case cached

    var text: String {
        switch self {
        case .running: "Running"
        case .needsInput: "Needs your input"
        case .draftSaved: "Draft saved"
        case .cached: "Cached"
        }
    }

    var tone: DSHTone {
        switch self {
        case .running: .success
        case .needsInput: .attention
        case .draftSaved: .neutral
        case .cached: .neutral
        }
    }

    var symbol: String? { nil }
}

/// A workspace row in the drawer: folder, name, and an expansion control
/// (UX spec "Workspace drawer and session browser").
///
/// Selection and expansion are one action here, because that is what the
/// drawer's rows do — expand the workspace and make it current. Splitting them
/// would put two small targets in one row.
struct WorkspaceRow: View {
    let name: String
    var isSelected = false
    var isExpanded = false
    var sessionCount: Int?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: DSHMetrics.space) {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .foregroundStyle(isSelected ? DSHPalette.primaryActionText : DSHPalette.secondaryText)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.primaryText)
                    .lineLimit(1)
                if let sessionCount {
                    Text("\(sessionCount)")
                        .font(.dshMetadata)
                        .foregroundStyle(DSHPalette.secondaryText)
                        .accessibilityLabel("\(sessionCount) sessions")
                }
                Spacer(minLength: DSHMetrics.space)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.footnote)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DSHMetrics.spaceCard)
            .padding(.vertical, DSHMetrics.space + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A selected row is the elevated surface, per the token table.
            .background(isSelected ? DSHPalette.elevatedSurface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isExpanded ? "Collapses this workspace" : "Expands this workspace")
    }
}

/// A session row nested under its workspace: conversation icon and title,
/// indented with one guide line rather than a deep tree.
struct DrawerSessionRow: View {
    let title: String
    var state: DSHSessionState?
    var isSelected = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: DSHMetrics.space) {
                // The guide line carries the hierarchy; the indent is the
                // spec's "modest indent", not a nested disclosure.
                Rectangle()
                    .fill(DSHPalette.divider)
                    .frame(width: 1)
                    .frame(height: 28)
                    .accessibilityHidden(true)
                Image(systemName: "text.bubble")
                    .font(.footnote)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .accessibilityHidden(true)
                Text(title.isEmpty ? "Untitled session" : title)
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.primaryText)
                    .lineLimit(2)
                Spacer(minLength: DSHMetrics.space)
                if let state {
                    DSHStatusChip(state.text, tone: state.tone, symbol: state.symbol)
                        .fixedSize()
                }
            }
            .padding(.horizontal, DSHMetrics.spaceCard)
            .padding(.vertical, DSHMetrics.space)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? DSHPalette.elevatedSurface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
