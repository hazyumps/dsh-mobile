import DSHRemoteKit
import SwiftUI

/// One session's subagents, and how long each has been working (#13).
///
/// The desktop's catalog in the phone's shape. Membership and order are the parent's own
/// `subagentCatalog`; the figure under each row is the child's `subagentTiming`, which the host
/// folds out of its own turn boundaries. Nothing here is derived from the transcript and nothing is
/// estimated: a value the host did not report is absent rather than zero, and a child the session
/// index has not heard of is drawn without an activity rather than with a confident idle dot.
///
/// A row opens the child's conversation **read-only**. The desktop elects a composer for a
/// continuable child whose exact parent is unavailable, and that is `subagents/prompt` — a write
/// path with its own once-only test, deliberately not this change.
struct SubagentsView: View {
    /// The session whose children are listed.
    let parentSessionId: String
    /// A roster to draw instead of the host's, for the screen gallery.
    ///
    /// `nil` in the app, where the roster comes from the store. The gallery needs a value because a
    /// screen that cannot be rendered without a host is a screen that cannot be reviewed, and the
    /// machine that reviews these layouts has no Simulator GUI.
    var seededRoster: SubagentRoster?

    @Environment(AppModel.self) private var model

    /// The instant the durations are measured to.
    ///
    /// Advanced once a second, and only while something is running — see ``tick``. A frozen figure
    /// does not need redrawing, which is the other half of why `needsTick` exists.
    @State private var now: Int64 = SystemEpochClock().epochMillis()

    private var roster: SubagentRoster {
        seededRoster ?? model.roster(for: parentSessionId)
    }

    var body: some View {
        List {
            if !roster.isReported {
                // "Not reported" and "none" are different statements, and only one of them is the
                // host saying anything at all.
                notice("This harness has not reported subagents for this session.")
            } else if roster.entries.isEmpty {
                notice("This session has not delegated to any subagents.")
            } else {
                Section {
                    ForEach(roster.entries) { entry in
                        NavigationLink(value: entry) { row(entry) }
                    }
                } header: {
                    Text(countLabel)
                } footer: {
                    Text("Reported by the harness for this session. A subagent's conversation opens read-only.")
                }
            }
        }
        .navigationTitle("Subagents")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: SubagentRoster.Entry.self) { entry in
            ConversationView(address: address(for: entry), isReadOnly: true)
        }
        .task(id: roster.needsTick) { await tick() }
    }

    /// The clock, while there is something for it to move.
    ///
    /// Cancelled by `.task(id:)` the moment nothing is running. The `sleep` *is* the clock here
    /// rather than a bet on the scheduler: nothing is being waited for, one second is the
    /// resolution being drawn at, and the value read afterwards is the wall clock.
    private func tick() async {
        guard roster.needsTick else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            now = SystemEpochClock().epochMillis()
        }
    }

    // MARK: - Rows

    private func notice(_ text: String) -> some View {
        Section {
            Text(text)
                .font(.dshSupporting)
                .foregroundStyle(DSHPalette.secondaryText)
        }
    }

    private var countLabel: String {
        switch roster.runningCount {
        case 0: "\(roster.count) subagents"
        case 1: "1 running of \(roster.count)"
        default: "\(roster.runningCount) running of \(roster.count)"
        }
    }

    private func row(_ entry: SubagentRoster.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSHMetrics.spaceCard) {
            // A fixed column, so the labels line up whatever the activity is — the desktop
            // reserves the same width for the same reason.
            activityGlyph(entry.activity)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayLabel)
                    .font(.dshCardTitle)
                    .lineLimit(2)
                if let secondary = secondary(entry) {
                    Text(secondary)
                        .font(.dshMetadata)
                        .foregroundStyle(DSHPalette.secondaryText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: DSHMetrics.space)

            VStack(alignment: .trailing, spacing: 2) {
                if let duration = entry.durationMs(now: now) {
                    Text(Self.duration(duration))
                        .font(.dshMetadata)
                        .monospacedDigit()
                }
                if let tokens = entry.tokenTotal {
                    Text(Self.count(tokens))
                        .font(.dshMetadata)
                        .foregroundStyle(DSHPalette.secondaryText)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, DSHMetrics.spaceSmall)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func activityGlyph(_ activity: SubagentRoster.Activity?) -> some View {
        switch activity {
        case .running:
            Image(systemName: "circle.dotted").foregroundStyle(DSHPalette.primaryActionText)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DSHPalette.success)
        case .inactive:
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(DSHPalette.secondaryText)
        // Nothing said. An idle dot would be a claim the host never made.
        case nil:
            Image(systemName: "circle.dotted")
                .foregroundStyle(DSHPalette.secondaryText)
                .hidden()
        }
    }

    /// The row's second line: the child's own title, its mode, and what it is doing.
    private func secondary(_ entry: SubagentRoster.Entry) -> String? {
        let parts = [entry.title, Self.modeLabel(entry.mode), entry.activity.map(Self.activityLabel)]
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }

    private static func modeLabel(_ mode: SubagentMode) -> String {
        switch mode {
        case .oneShot: "One-shot"
        case .continuable: "Continuable"
        case .unknown: "Mode unknown"
        case .unrecognized(let value): value
        }
    }

    private static func activityLabel(_ activity: SubagentRoster.Activity) -> String {
        switch activity {
        case .running: "Running"
        case .completed: "Completed"
        case .inactive: "Inactive"
        }
    }

    /// Where a row's conversation is read from.
    ///
    /// A mode the client does not recognise is sent as `unknown` — the union's own member for "not
    /// established" — which is how the desktop opens an unknown-mode row. Sending the raw string
    /// would be inventing a member the host's union does not have.
    private func address(for entry: SubagentRoster.Entry) -> SessionAddress {
        let mode: SubagentMode = switch entry.mode {
        case .oneShot, .continuable, .unknown: entry.mode
        case .unrecognized: .unknown
        }
        return .subagent(parentSessionId: parentSessionId, childSessionId: entry.id, mode: mode)
    }

    // MARK: - Formatting

    /// Grouped digits: a token count is read for its magnitude, and 110456576 is not.
    static func count(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// A duration at decreasing precision as it grows, which is what makes a two-hour child and a
    /// two-second one both readable. The desktop formats the same way from the same milliseconds.
    static func duration(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds) / 1000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
