import DSHRemoteKit
import SwiftUI

/// Home: the current host's work, with a drawer for switching context.
///
/// UX spec "Home and starting a session" orders the page — toolbar, host row,
/// workspace context, the heading, workspace control, composer, recent sessions —
/// and this follows that order. The composer is present and honest about the one
/// thing it cannot do yet: creating a session is SPEC §5's transaction, which is a
/// later slice. Send is disabled with its reason rather than enabled and broken.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    /// What a tap in this stack can lead to.
    enum Route: Hashable {
        case session(String)
        /// `nil` lists every session the host reported.
        case sessions(String?)
        /// The capability-gated drawer destinations (SPEC §10).
        case plugins
        case schedules
    }

    @State private var path: [Route] = []
    @State private var isDrawerOpen = false
    @State private var isWorkspacePickerOpen = false
    @State private var isSettingsOpen = false
    @State private var draft = ""

    private var browse: BrowseState { model.browse }

    private var workspace: BrowseWorkspace? {
        browse.workspace(id: model.selectedWorkspaceId) ?? browse.workspaces.first
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .leading) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DSHMetrics.spaceGroup) {
                        hostRow
                        heading
                        workspaceControl
                        composer
                        continueSection
                    }
                    .padding(.horizontal, DSHMetrics.pageMargin)
                    .padding(.vertical, DSHMetrics.spaceCard)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(DSHPalette.canvas)
                .scrollDismissesKeyboard(.interactively)

                if isDrawerOpen {
                    drawerLayer
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .session(let sessionId):
                    ConversationView(sessionId: sessionId)
                case .sessions(let workspaceId):
                    SessionBrowserView(workspaceId: workspaceId)
                case .plugins:
                    PluginsView()
                case .schedules:
                    SchedulesView()
                }
            }
        }
        .sheet(isPresented: $isWorkspacePickerOpen) {
            WorkspacePickerView(
                workspaces: browse.workspaces,
                selectedId: model.selectedWorkspaceId,
                select: { workspaceId in
                    model.selectWorkspace(workspaceId)
                    isWorkspacePickerOpen = false
                },
                cancel: { isWorkspacePickerOpen = false }
            )
        }
        .sheet(isPresented: $isSettingsOpen) {
            SettingsView()
        }
        .task(id: model.selectedSessionId) {
            // Navigation is restored from the same value the store persists, so a cold
            // launch reopens the last conversation instead of the workspace list.
            // An explicit launch destination wins over the restored conversation: it is the
            // only way to reach a drawer screen on a machine that cannot tap, and the
            // restored session would otherwise always get there first.
            if let route = Self.launchRoute(for: model.launchDestination) {
                path = [route]
                return
            }
            guard let sessionId = model.selectedSessionId else {
                path.removeAll()
                return
            }
            if path.last != .session(sessionId) { path = [.session(sessionId)] }
        }
        .onChange(of: path) { _, next in
            // Leaving the conversation is what clears the stored destination; the
            // workspace stays selected, which is where the user lands.
            if next.isEmpty, model.selectedSessionId != nil { model.closeSession() }
        }
        .onChange(of: isDrawerOpen) { _, open in
            if open { Task { await model.refreshSessions() } }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            DSHIconAction(label: "Open navigation", symbol: "sidebar.left") {
                withAnimation(.snappy) { isDrawerOpen = true }
            }
        }
        ToolbarItem(placement: .principal) {
            DSHBrandLockup()
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("View all sessions", systemImage: "list.bullet") {
                    path.append(.sessions(model.selectedWorkspaceId))
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshSessions() }
                }
                Divider()
                Button("Settings", systemImage: "gearshape") { isSettingsOpen = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    // MARK: - Sections

    private var hostRow: some View {
        HostStatusRow(
            hostName: model.selectedHost?.displayName ?? "No host",
            state: DSHHostState(model.status)
        )
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.space) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DSHPalette.primaryActionText)
                .accessibilityHidden(true)
            Text("Into the Unknown")
                .font(.dshHomeTitle)
                .foregroundStyle(DSHPalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DSHMetrics.space)
    }

    @ViewBuilder
    private var workspaceControl: some View {
        if let workspace {
            Button {
                isWorkspacePickerOpen = true
            } label: {
                HStack(spacing: DSHMetrics.space) {
                    Image(systemName: "folder")
                        .foregroundStyle(DSHPalette.secondaryText)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.title)
                            .font(.dshCardTitle)
                            .foregroundStyle(DSHPalette.primaryText)
                            .lineLimit(1)
                        if let path = workspace.path, !path.isEmpty {
                            Text(path)
                                .font(.dshMetadata)
                                .foregroundStyle(DSHPalette.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: DSHMetrics.space)
                    Text("\(workspace.sessionCount)")
                        .font(.dshMetadata)
                        .foregroundStyle(DSHPalette.secondaryText)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(DSHPalette.secondaryText)
                        .accessibilityHidden(true)
                }
                .padding(DSHMetrics.spaceCard)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dshCard()
                .contentShape(RoundedRectangle(cornerRadius: DSHMetrics.cardCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Chooses the workspace to work in")
        }
    }

    private var composer: some View {
        Composer(
            text: $draft,
            canSend: false,
            sendBlockedReason: "Start a new session on your computer for now — the phone can follow and answer existing ones.",
            isSending: false,
            placeholder: "Ask your harness…"
        )
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceCard) {
            HStack {
                Text("Continue a session")
                    .font(.dshCardTitle)
                    .foregroundStyle(DSHPalette.primaryText)
                Spacer()
                Button("View all") {
                    path.append(.sessions(model.selectedWorkspaceId))
                }
                .font(.dshSupporting)
                .foregroundStyle(DSHPalette.primaryActionText)
            }
            recentBody
        }
    }

    @ViewBuilder
    private var recentBody: some View {
        let recent = browse.recent()

        // The session index failing is said out loud even when rows are on screen. The
        // workspace registry names sessions the index may never deliver — this host
        // fails `session/list` outright over one corrupt session log — and a screen that
        // showed those rows without the failure would present them as loaded sessions.
        if let reason = browse.sessionIndexFailure {
            VStack(alignment: .leading, spacing: DSHMetrics.space) {
                Label("Couldn’t load sessions", systemImage: "exclamationmark.triangle")
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.error)
                // The host's reason is kept, but behind a disclosure: it quotes full
                // private paths, and the UX spec asks for "Retry the list; inspect error
                // details" — details on request, not a wall of them over the sessions.
                ErrorDetails(reason: reason)
                Button("Try again") { Task { await model.refreshSessions() } }
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.primaryActionText)
            }
            .padding(DSHMetrics.spaceCard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dshCard()
        }

        if browse.isLoadingFirstTime {
            HStack(spacing: DSHMetrics.space) {
                ProgressView()
                Text("Reading sessions…").foregroundStyle(DSHPalette.secondaryText)
            }
            .font(.dshSupporting)
        } else if recent.isEmpty, let reason = browse.workspaceFailure {
            VStack(alignment: .leading, spacing: DSHMetrics.space) {
                Label("Couldn’t load workspaces", systemImage: "exclamationmark.triangle")
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.error)
                Text(reason)
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await model.refreshSessions() } }
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.primaryActionText)
            }
            .padding(DSHMetrics.spaceCard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dshCard()
        } else if recent.isEmpty {
            Text("No sessions yet. Start one on your computer and it will appear here.")
                .font(.dshSupporting)
                .foregroundStyle(DSHPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: DSHMetrics.space) {
                ForEach(recent) { session in
                    SessionCard(
                        title: session.title,
                        supportingLine: session.isLoaded ? nil : "Details didn’t load",
                        state: session.running ? .running : nil,
                        lastActivity: session.running || !session.isLoaded ? nil : session.lastActivity
                    ) {
                        open(session.id)
                    }
                }
            }
        }
    }

    // MARK: - Drawer

    private var drawerLayer: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.snappy) { isDrawerOpen = false } }
                .accessibilityLabel("Close navigation")
                .accessibilityAddTraits(.isButton)

            DrawerView(
                close: { withAnimation(.snappy) { isDrawerOpen = false } },
                openSession: { sessionId in
                    withAnimation(.snappy) { isDrawerOpen = false }
                    open(sessionId)
                },
                openWorkspace: { workspaceId in
                    withAnimation(.snappy) { isDrawerOpen = false }
                    model.selectWorkspace(workspaceId)
                },
                openSettings: {
                    withAnimation(.snappy) { isDrawerOpen = false }
                    isSettingsOpen = true
                },
                openPlugins: {
                    withAnimation(.snappy) { isDrawerOpen = false }
                    path.append(.plugins)
                },
                openSchedules: {
                    withAnimation(.snappy) { isDrawerOpen = false }
                    path.append(.schedules)
                }
            )
            .transition(.move(edge: .leading))
            .frame(maxWidth: 340)
        }
    }

    /// A launch destination, in the drawer's own terms.
    private static func launchRoute(for destination: String?) -> Route? {
        switch destination {
        case "plugins": .plugins
        case "schedules": .schedules
        default: nil
        }
    }

    private func open(_ sessionId: String) {
        model.openSession(sessionId)
        if path.last != .session(sessionId) { path.append(.session(sessionId)) }
    }
}

/// The host's own failure text, on request.
///
/// It is kept verbatim — a paraphrase of a host error is a guess — but folded away,
/// because the text quotes full private paths and belongs behind the "inspect error
/// details" step of the UX spec's session-list row.
struct ErrorDetails: View {
    let reason: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: DSHMetrics.spaceSmall + 2) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text("Details")
                        .font(.dshMetadata)
                }
                .foregroundStyle(DSHPalette.secondaryText)
                .frame(minHeight: DSHMetrics.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the host's error" : "Shows the host's error")

            if isExpanded {
                Text(reason)
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The workspace selector: a searchable list of the host's registry.
///
/// A sheet rather than a menu because the registry can be long, and because the
/// identifier it returns is the host's own — never one derived from a title or a
/// phone-side directory (SPEC §4).
struct WorkspacePickerView: View {
    let workspaces: [BrowseWorkspace]
    let selectedId: String?
    let select: (String) -> Void
    let cancel: () -> Void

    @State private var query = ""

    private var matches: [BrowseWorkspace] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return workspaces }
        return workspaces.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(matches) { workspace in
                    Button {
                        select(workspace.id)
                    } label: {
                        HStack(spacing: DSHMetrics.space) {
                            Image(systemName: "folder")
                                .foregroundStyle(DSHPalette.secondaryText)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workspace.title)
                                    .foregroundStyle(DSHPalette.primaryText)
                                if let path = workspace.path, !path.isEmpty {
                                    Text(path)
                                        .font(.dshMetadata)
                                        .foregroundStyle(DSHPalette.secondaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: DSHMetrics.space)
                            if workspace.id == selectedId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DSHPalette.primaryActionText)
                                    .accessibilityLabel("Selected")
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Filter workspaces")
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
            }
            .overlay {
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }
}
