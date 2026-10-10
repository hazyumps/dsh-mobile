import DSHRemoteKit
import SwiftUI

/// The workspace drawer: global destinations, the workspace tree, and the host row.
///
/// UX spec "Workspace drawer and session browser" fixes the order — brand and close,
/// new session, secondary destinations, workspaces with search, sessions nested under
/// the expanded workspace, then the host row and Settings. Two parts of that list are
/// absent rather than decorative: **Plugins, Scheduled tasks, MCP and Usage** need the
/// capability-gated reads of SPEC §10, and **New session** needs the create transaction
/// of SPEC §5. Until each lands, the drawer says so instead of showing a control that
/// would not work.
struct DrawerView: View {
    @Environment(AppModel.self) private var model

    let close: () -> Void
    let openSession: (String) -> Void
    let openWorkspace: (String) -> Void
    let openSettings: () -> Void
    let openPlugins: () -> Void
    let openSchedules: () -> Void
    let openUsage: () -> Void
    /// Closes the drawer and puts the cursor in Home's prompt field.
    let openNewSession: () -> Void

    @State private var query = ""
    @FocusState private var filterFocused: Bool
    @State private var expandedWorkspaceId: String?
    /// Whether the harness destinations are unfolded.
    @State private var showsDestinations = true

    private var browse: BrowseState { model.browse }

    private var matches: [BrowseWorkspace] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return browse.workspaces }
        return browse.workspaces.compactMap { workspace in
            if workspace.title.localizedCaseInsensitiveContains(needle) { return workspace }
            let sessions = workspace.sessions.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
            }
            guard !sessions.isEmpty else { return nil }
            return BrowseWorkspace(
                id: workspace.id,
                title: workspace.title,
                path: workspace.path,
                sessions: sessions
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            newSessionRow
            destinations
            Divider().overlay(DSHPalette.divider)
            workspaceSearch
            workspaceList
            Divider().overlay(DSHPalette.divider)
            footer
        }
        // The keyboard overlays the drawer rather than shrinking it. Without this the layout gave
        // up the keyboard's height while typing in the filter, which pushed the host row and
        // Settings up and left a dead strip below them.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(DSHPalette.navigationSurface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DSHPalette.divider)
                .frame(width: 1)
                .ignoresSafeArea(edges: .vertical)
        }
        .onAppear {
            #if DEBUG
            // Debug builds only: focus the filter, so the drawer can be reviewed with the
            // keyboard up — the state that exposed the footer's dead strip on the phone.
            if ProcessInfo.processInfo.environment["DSH_FILTER"] != nil { filterFocused = true }
            #endif
            // The selected workspace is the expanded one, so the drawer opens where the
            // user already is rather than collapsed.
            if expandedWorkspaceId == nil { expandedWorkspaceId = model.selectedWorkspaceId }
        }
        .onChange(of: model.selectedWorkspaceId) { _, workspaceId in
            // The registry arrives after the first render, so a drawer that opened
            // before it did would otherwise start with everything collapsed.
            if expandedWorkspaceId == nil { expandedWorkspaceId = workspaceId }
        }
    }

    private var header: some View {
        HStack(spacing: DSHMetrics.space) {
            DSHBrandLockup()
            Spacer(minLength: DSHMetrics.space)
            DSHIconAction(label: "Close navigation", symbol: "xmark", action: close)
        }
        .padding(.horizontal, DSHMetrics.spaceCard)
        .padding(.top, DSHMetrics.spaceCard)
        .padding(.bottom, DSHMetrics.space)
    }

    /// New session opens the composer rather than creating anything.
    ///
    /// SPEC §5: "Opening New session changes local UI only. Do not create a host session
    /// until the first Send." Home *is* the new-session surface, so this closes the drawer
    /// and puts the cursor in the field — the host hears nothing until something is sent.
    private var newSessionRow: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
            Button(action: openNewSession) {
                HStack(spacing: DSHMetrics.space) {
                    Image(systemName: "square.and.pencil")
                        .accessibilityHidden(true)
                    Text("New session")
                        .font(.dshSupporting)
                    Spacer(minLength: DSHMetrics.space)
                }
                .foregroundStyle(DSHPalette.primaryText)
                .padding(.horizontal, DSHMetrics.spaceCard)
                .padding(.vertical, DSHMetrics.space + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DSHPalette.card)
                .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the prompt field in the selected workspace")

            Text("Creates the session when you send the first message, in \(selectedWorkspaceTitle).")
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DSHMetrics.spaceSmall)
        }
        .padding(.horizontal, DSHMetrics.spaceCard)
        .padding(.bottom, DSHMetrics.spaceCard)
    }

    private var selectedWorkspaceTitle: String {
        model.browse.workspace(id: model.selectedWorkspaceId)?.title
            ?? model.browse.workspaces.first?.title
            ?? "the selected workspace"
    }

    /// The drawer's global destinations.
    ///
    /// MCP and Usage are deliberately absent: SPEC §10 establishes no MCP inventory endpoint
    /// for this build at all, and there is no verified host-wide usage source. Plugins and
    /// Scheduled tasks have endpoints, so they get rows — and the screens themselves say when
    /// the connected host does not answer them.
    private var destinations: some View {
        VStack(spacing: 0) {
            // A folding header: these are places to go, not the point of the drawer, and the
            // workspace list should not start below three rows of navigation on a small screen.
            Button {
                withAnimation(.snappy) { showsDestinations.toggle() }
            } label: {
                HStack(spacing: DSHMetrics.spaceSmall) {
                    Text("Harness")
                        .font(.dshMetadata.weight(.semibold))
                        .foregroundStyle(DSHPalette.secondaryText)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DSHPalette.secondaryText)
                        .rotationEffect(.degrees(showsDestinations ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DSHMetrics.spaceCard)
                .frame(minHeight: DSHMetrics.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsDestinations ? "Hide harness destinations" : "Show harness destinations")

            if showsDestinations {
                destinationRow("Usage", symbol: "chart.bar", action: openUsage)
                destinationRow("Plugins", symbol: "puzzlepiece.extension", action: openPlugins)
                destinationRow("Scheduled tasks", symbol: "calendar.badge.clock", action: openSchedules)
            }
        }
        .padding(.horizontal, DSHMetrics.spaceSmall + 2)
        .padding(.bottom, DSHMetrics.spaceSmall)
    }

    private func destinationRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DSHMetrics.space) {
                Image(systemName: symbol)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.primaryText)
                Spacer(minLength: DSHMetrics.space)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DSHMetrics.spaceCard)
            .frame(minHeight: DSHMetrics.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var workspaceSearch: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.space) {
            Text("Workspaces")
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
            HStack(spacing: DSHMetrics.spaceSmall + 2) {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .accessibilityHidden(true)
                TextField("Filter workspaces and sessions", text: $query)
                    .focused($filterFocused)
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.primaryText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(DSHPalette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the filter")
                }
            }
            .padding(.horizontal, DSHMetrics.spaceCard)
            .padding(.vertical, DSHMetrics.space + 2)
            .background(DSHPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
            // The scope is stated rather than implied: this is a local filter over what
            // the phone has already loaded, not a host-side search (SPEC §4).
            Text("Filters sessions and workspaces already loaded on this phone.")
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DSHMetrics.spaceCard)
        // Top spacing, because the divider that closes the Harness block sits immediately above
        // this label: with only bottom padding, "Workspaces" read as if it belonged to the
        // section above it rather than starting its own.
        .padding(.top, DSHMetrics.spaceCard)
        .padding(.bottom, DSHMetrics.space)
    }

    private var workspaceList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
                if browse.isLoadingFirstTime {
                    HStack(spacing: DSHMetrics.space) {
                        ProgressView()
                        Text("Reading workspaces…")
                            .font(.dshSupporting)
                            .foregroundStyle(DSHPalette.secondaryText)
                    }
                    .padding(.horizontal, DSHMetrics.spaceCard)
                } else if browse.sessionIndexFailure != nil {
                    // The tree below is the registry's membership, which is still true;
                    // the session records behind it are not, and the drawer says so rather
                    // than showing every row as an untitled session.
                    Label("Session details didn’t load", systemImage: "exclamationmark.triangle")
                        .font(.dshMetadata)
                        .foregroundStyle(DSHPalette.attention)
                        .padding(.horizontal, DSHMetrics.spaceCard)
                } else if matches.isEmpty, !query.isEmpty {
                    Text("Nothing loaded matches “\(query)”.")
                        .font(.dshSupporting)
                        .foregroundStyle(DSHPalette.secondaryText)
                        .padding(.horizontal, DSHMetrics.spaceCard)
                } else if matches.isEmpty {
                    Text("This host has not reported any workspaces yet.")
                        .font(.dshSupporting)
                        .foregroundStyle(DSHPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DSHMetrics.spaceCard)
                }

                ForEach(matches) { workspace in
                    let isExpanded = expandedWorkspaceId == workspace.id
                    WorkspaceRow(
                        name: workspace.title,
                        isSelected: workspace.id == model.selectedWorkspaceId,
                        isExpanded: isExpanded,
                        sessionCount: workspace.sessionCount
                    ) {
                        expandedWorkspaceId = isExpanded ? nil : workspace.id
                        openWorkspace(workspace.id)
                    }
                    if isExpanded {
                        ForEach(workspace.sessions) { session in
                            DrawerSessionRow(
                                title: session.title,
                                state: session.needsInput ? .needsInput : (session.running ? .running : nil),
                                isSelected: session.id == model.selectedSessionId
                            ) {
                                openSession(session.id)
                            }
                            .padding(.leading, DSHMetrics.spaceCard)
                        }
                        if workspace.sessions.isEmpty {
                            Text("No sessions in this workspace.")
                                .font(.dshMetadata)
                                .foregroundStyle(DSHPalette.secondaryText)
                                .padding(.leading, DSHMetrics.spaceCard * 2)
                        }
                    }
                }
            }
            .padding(.horizontal, DSHMetrics.spaceSmall + 2)
            .padding(.bottom, DSHMetrics.spaceCard)
        }
        // The footer is outside the scroll view, so the last workspace row can always be
        // scrolled clear of it (UX spec: "its footer must never cover the final row").
        .frame(maxHeight: .infinity)
                // Sliding the list, or flicking the drawer away, puts the filter's keyboard away.
            .scrollDismissesKeyboard(.immediately)
        }
    private var footer: some View {
        VStack(spacing: DSHMetrics.space) {
            HostStatusRow(
                hostName: model.selectedHost?.displayName ?? "No host",
                state: DSHHostState(model.status)
            )
            Button(action: openSettings) {
                HStack(spacing: DSHMetrics.space) {
                    Image(systemName: "gearshape")
                        .accessibilityHidden(true)
                    Text("Settings")
                        .font(.dshSupporting)
                    Spacer(minLength: DSHMetrics.space)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(DSHPalette.primaryText)
                .frame(minHeight: DSHMetrics.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DSHMetrics.spaceCard)
        .padding(.vertical, DSHMetrics.spaceCard)
    }
}
