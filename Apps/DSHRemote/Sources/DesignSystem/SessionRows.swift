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

/// A project row on Home: folder, name, what is in it, and where it goes.
///
/// A row rather than a card, so the list of projects stays visually quieter than the
/// sessions above it: cards are things you talk to, rows are places they live. The count
/// comes from the same value the project's own screen lists, so the two cannot disagree.
struct ProjectRow: View {
    let title: String
    let sessionCount: Int
    var activeCount = 0
    let open: () -> Void

    private var supporting: String {
        let sessions = sessionCount == 1 ? "1 session" : "\(sessionCount) sessions"
        // "0 active" is a measurement of nothing; it is left out rather than drawn.
        return activeCount > 0 ? "\(sessions) · \(activeCount) active" : sessions
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: DSHMetrics.space) {
                Image(systemName: "folder")
                    .foregroundStyle(DSHPalette.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.isEmpty ? "Untitled project" : title)
                        .font(.dshCardTitle)
                        .foregroundStyle(DSHPalette.primaryText)
                        .lineLimit(1)
                    Text(supporting)
                        .font(.dshMetadata)
                        .foregroundStyle(DSHPalette.secondaryText)
                }
                Spacer(minLength: DSHMetrics.space)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, DSHMetrics.space + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this project")
    }
}
