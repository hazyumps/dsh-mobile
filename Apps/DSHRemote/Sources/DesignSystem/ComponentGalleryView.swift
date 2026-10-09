import DSHRemoteKit
import SwiftUI

/// The design-system gallery: every component, in each of its states, on the
/// real tokens.
///
/// It exists so this work can be looked at rather than read. It reaches the
/// running app only through an explicit opt-in (`DSH_DESIGN_GALLERY`, debug
/// builds only), and its data is demonstration data, which UX spec "Scope and
/// implementation status" allows exactly there: "Demonstration data stays in
/// previews and tests."
///
/// The two controls at the top are the spec's own acceptance checks — every
/// surface must hold its hierarchy in System, Light, and Dark, and rows must
/// stack rather than clip at accessibility text sizes — so they are switched
/// here rather than assumed.
struct ComponentGalleryView: View {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: Self { self }
        var scheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    @State private var appearance: Appearance
    @State private var largeType = false
    @State private var draft = "Reconnect should keep the draft and the reading position."
    @State private var expandedWorkspace = true
    @State private var log = "Nothing has been tapped yet."

    /// Defaults to following the system, not to forcing dark.
    ///
    /// A review screen should start in whatever appearance the device is actually in --
    /// otherwise the gallery can only ever show dark on launch, and the one appearance
    /// nobody has looked at is Light, which is also the one whose values were adjusted for
    /// contrast. Following the system also makes the Light and Dark variants checkable from
    /// a simulator or a device appearance switch rather than only by tapping the picker.
    init(appearance: Appearance = .system) {
        _appearance = State(initialValue: appearance)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSHMetrics.spaceGroup) {
                controls
                brandSection
                statusSection
                sessionSection
                workspaceSection
                toolSection
                decisionSection
                composerSection
            }
            .padding(.horizontal, DSHMetrics.pageMargin)
            .padding(.bottom, DSHMetrics.spaceGroup)
        }
        .background(DSHPalette.canvas)
        .preferredColorScheme(appearance.scheme)
        .environment(\.dynamicTypeSize, largeType ? .accessibility3 : .large)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.space) {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { option in
                    Text(option.rawValue.capitalized).tag(option)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Accessibility text size", isOn: $largeType)
                .font(.dshSupporting)
            Text(log)
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, DSHMetrics.space)
    }

    private var brandSection: some View {
        section("Brand") {
            HStack {
                DSHBrandLockup()
                Spacer()
            }
            .padding(DSHMetrics.spaceCard)
            .dshCard()
            // Marked as the open item it is, so nobody mistakes the placeholder
            // for the finished identity.
            Text("Placeholder wordmark. Needs a licensed DeepSeek asset — see DSHBrandLockup.")
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.attention)
        }
    }

    private var statusSection: some View {
        section("Host and status") {
            VStack(spacing: 0) {
                HostStatusRow(hostName: "Patrick's Mac", state: .connected)
                HostStatusRow(hostName: "Patrick's Mac", state: .reconnecting)
                HostStatusRow(hostName: "Patrick's Mac", state: .needsInput)
                HostStatusRow(hostName: "Patrick's Mac", state: .pairingRequired)
                HostStatusRow(
                    hostName: "A host with a name long enough to test truncation behaviour",
                    state: DSHHostState(ConnectionStatus.hostUnavailable)
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DSHMetrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(DSHPalette.cardEdge, lineWidth: 1)
            )

            HStack {
                DSHStatusChip("Draft saved", tone: .neutral)
                DSHStatusChip("Working", tone: .action, symbol: "ellipsis.circle")
                DSHStatusChip("Failed", tone: .error, symbol: "exclamationmark.circle")
            }
        }
    }

    private var sessionSection: some View {
        section("Session cards") {
            VStack(spacing: DSHMetrics.space) {
                SessionCard(
                    title: "Reconnect handling",
                    supportingLine: "Checking the recovery flow",
                    state: .running,
                    open: note("Opened a running session")
                )
                SessionCard(
                    title: "Polish the mobile UI",
                    supportingLine: "Your draft is saved",
                    state: .draftSaved,
                    open: note("Opened a session with a draft")
                )
                SessionCard(
                    title: "A conversation whose title runs long enough to need two lines on a phone",
                    lastActivity: "3 hours ago",
                    open: note("Opened a cached session")
                )
                // No data at all: still a row, still tappable, still readable.
                SessionCard(title: "", open: note("Opened an empty session"))
            }
            Button("View all sessions", action: note("View all sessions"))
                .font(.dshSupporting)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DSHMetrics.spaceCard)
                .dshCard()
        }
    }

    private var workspaceSection: some View {
        section("Drawer rows") {
            VStack(spacing: DSHMetrics.spaceSmall) {
                WorkspaceRow(name: "chats", toggle: note("Selected chats"))
                WorkspaceRow(
                    name: "dsh-mobile",
                    isSelected: true,
                    isExpanded: expandedWorkspace,
                    sessionCount: 2,
                    toggle: {
                        expandedWorkspace.toggle()
                        note("Toggled dsh-mobile")()
                    }
                )
                if expandedWorkspace {
                    DrawerSessionRow(title: "Reconnect handling", state: .running, open: note("Opened Reconnect handling"))
                    DrawerSessionRow(title: "Polish the mobile UI", open: note("Opened Polish the mobile UI"))
                }
                WorkspaceRow(name: "A workspace with a name long enough to test the row", sessionCount: 12, toggle: note("Selected the long workspace"))
            }
            .padding(DSHMetrics.spaceSmall)
            .background(DSHPalette.navigationSurface)
            .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.cardCornerRadius, style: .continuous))
        }
    }

    private var toolSection: some View {
        section("Tool cards") {
            ToolCard(
                title: "Inspect reconnect flow",
                symbol: "terminal",
                collapsedSummary: "2 files checked",
                state: .succeeded
            )
            ToolCard(
                title: "Inspect reconnect flow",
                symbol: "terminal",
                collapsedSummary: "2 files checked",
                state: .succeeded,
                arguments: [
                    ToolCard.ToolField(label: "Command", value: "grep -rn reconnect Apps/DSHRemote/Sources", isCode: true)
                ],
                results: [
                    ToolCard.ToolField(label: "Output", value: Self.longOutput, isCode: true)
                ],
                initiallyExpanded: true
            )
            ToolCard(
                title: "Waiting on a tool that has not returned",
                symbol: "wrench.and.screwdriver",
                state: .working,
                arguments: [ToolCard.ToolField(label: "Path", value: "Sources/DSHRemoteKit/Network", isCode: true)]
            )
            // Unknown tools keep a card instead of disappearing.
            ToolCard(title: "an_unfamiliar_tool", symbol: "questionmark.circle", state: .unknown)
        }
    }

    private var decisionSection: some View {
        section("Decisions") {
            DecisionCard(
                content: .approval(
                    DecisionCard.Approval(
                        reason: "Reconnect the session and preserve your draft.",
                        action: "Run this command?",
                        scope: "Apps/DSHRemote/Sources",
                        details: "git stash && xcodebuild -scheme DSHRemote build"
                    )
                ),
                onAllowOnce: note("Allow once — a wired screen sends the approval here"),
                onReject: note("Reject — a wired screen sends the rejection here")
            )
            DecisionCard(
                content: .question(
                    DecisionCard.Question(
                        header: "Which recovery should the phone take?",
                        items: [
                            DecisionCard.Item(
                                id: "policy",
                                prompt: "Choose what happens when the socket drops.",
                                options: ["Hold the draft and reconnect", "Show the last confirmed state", "Both"],
                                allowsMultipleSelection: false,
                                allowsCustomAnswer: false,
                                customAnswerPlaceholder: nil
                            ),
                            DecisionCard.Item(
                                id: "checks",
                                prompt: "Which checks should the run include?",
                                options: ["Reconnect", "Cold launch", "Lock and unlock"],
                                allowsMultipleSelection: true,
                                allowsCustomAnswer: true,
                                customAnswerPlaceholder: "Anything else to check"
                            ),
                        ]
                    )
                ),
                onSubmit: { answers in
                    note("Submit \(answers.count) answer(s) — a wired screen sends these")()
                },
                initiallySelected: ["policy": ["Hold the draft and reconnect"]]
            )
            // The same card after the request went stale: kept as history, with
            // its controls disabled and the reason said out loud.
            DecisionCard(
                content: .approval(
                    DecisionCard.Approval(reason: "This request is not confirmed open any more.", action: "Apply the recovery changes?")
                ),
                isStale: true,
                footnote: "Reconnect and refresh this conversation to see whether the host is still asking.",
                onAllowOnce: {},
                onReject: {}
            )
        }
    }

    private var composerSection: some View {
        section("Composer") {
            Composer(
                text: $draft,
                onAttach: note("A wired screen opens the attachment picker here"),
                modelSelection: Composer.ModelSelection(name: "DeepSeek", options: ["DeepSeek", "Ember"], select: { note($0)() }),
                onSend: { note("Send “\($0)”")() }
            )
            Composer(
                text: $draft,
                canSend: false,
                sendBlockedReason: "Reconnecting. Your draft is kept and will not be sent until the connection is back.",
                onAttach: note("A wired screen opens the attachment picker here"),
                modelSelection: Composer.ModelSelection(name: "DeepSeek"),
                onSend: { note("Send “\($0)”")() }
            )
            Composer(text: .constant(""))
        }
    }

    // MARK: - Helpers

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DSHMetrics.space) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DSHPalette.primaryText)
            content()
        }
    }

    /// Gallery actions report themselves instead of pretending to do something.
    private func note(_ message: String) -> () -> Void {
        { log = message }
    }

    private static let longOutput = """
    Sources/DSHRemoteKit/State/ConnectionCoordinator.swift:212: /// Reconnect is the next slice and owns that decision.
    Sources/DSHRemoteKit/State/ConnectionCoordinator.swift:318: func reportReconnecting() {
    Sources/DSHRemoteKit/State/ForegroundConnection.swift:44: scheduleRetry(after: delay)
    Sources/DSHRemoteKit/State/ForegroundConnection.swift:61: guard status.isRecoverableWithoutUserAction else { return }
    Sources/DSHRemoteKit/State/ForegroundConnection.swift:88: // A replaced connection closes the old socket first.
    """ + "\n" + "Repeated so the bounded preview and its own expansion control are exercised.\n"
}

#Preview("Gallery — dark") {
    ComponentGalleryView()
}

#Preview("Gallery — light") {
    ComponentGalleryView(appearance: .light)
}

#Preview("Gallery — accessibility text") {
    ComponentGalleryView()
        .environment(\.dynamicTypeSize, .accessibility3)
}
