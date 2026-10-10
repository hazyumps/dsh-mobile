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
        case usage
        case plugins
        case schedules
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Route] = []
    @State private var isDrawerOpen = false
    @State private var isWorkspacePickerOpen = false
    @State private var isSettingsOpen = false
    @State private var draft = ""
    /// Bumped by the drawer's New session, so the field is focused without a second tap.
    @State private var focusRequest = 0

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
                        modelModeControls
                        composer
                        continueSection
                    }
                    .padding(.horizontal, DSHMetrics.pageMargin)
                    .padding(.vertical, DSHMetrics.spaceCard)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A downward drag anywhere on Home puts the keyboard away, the same motion the
                // drawer and the transcript accept.
                .dismissesKeyboardOnDownwardDrag()
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
                case .usage:
                    UsageView(sessionId: model.selectedSessionId, title: "Usage")
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
            // Debug builds can open straight to the diagnostics preview, which is otherwise
            // two taps away and unreachable on a machine that cannot tap.
            SettingsView(startsAtDiagnostics: ProcessInfo.processInfo.environment["DSH_DIAGNOSTICS"] != nil)
        }
        .task {
            // The catalog is what the mode and model controls render, and it does not stream.
            if model.catalog == nil { await model.loadModelCatalog() }
            #if DEBUG
            // Debug builds only: open Settings on launch, so a screen whose only door is a row
            // in the drawer can be reviewed on a machine that cannot tap.
            if ProcessInfo.processInfo.environment["DSH_SETTINGS"] != nil { isSettingsOpen = true }
            // Focus the composer, and open the drawer, so the keyboard-vs-drawer interaction can
            // be reproduced on a machine that cannot tap either one. Debug only.
            if ProcessInfo.processInfo.environment["DSH_FOCUS"] != nil {
                try? await Task.sleep(for: .seconds(1.5))
                focusRequest += 1
            }
            if ProcessInfo.processInfo.environment["DSH_DRAWER"] != nil {
                try? await Task.sleep(for: .seconds(3))
                isDrawerOpen = true
            }
            #endif
        }
        .task(id: model.selectedSessionId) {
            // Navigation is restored from the same value the store persists, so a cold
            // launch reopens the last conversation instead of the workspace list.
            // An explicit launch destination wins over the restored conversation: it is the
            // only way to reach a drawer screen on a machine that cannot tap, and the
            // restored session would otherwise always get there first.
            if let route = Self.launchRoute(for: model.launchDestination) {
                #if DEBUG
                // A destination like Usage needs a session to report on, and selecting one is a
                // separate action from navigating to a conversation. A launch that names both
                // gets both, which is how a screen behind two taps gets reviewed here.
                if let named = model.launchSessionId, model.selectedSessionId != named {
                    model.openSession(named)
                }
                #endif
                path = [route]
                return
            }
            guard let sessionId = model.selectedSessionId else {
                path.removeAll()
                return
            }
            if path.last != .session(sessionId) { path = [.session(sessionId)] }
        }
        .task(id: model.selectedHost?.id) {
            // SPEC §4: "refresh `session/list` on foreground, opening the drawer,
            // pull-to-refresh, and at most every 15 seconds while the recent list is
            // visible." The recent list is *this* screen, so the timer lives here — the drawer
            // already refreshes when it opens, and the open/highlighted fields are the only
            // other reasons to re-read the index.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await model.refreshSessions()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Foreground is the trigger that matters after a phone has been in a pocket: the
            // list may be hours stale and the timer did not run while the app was suspended.
            if phase == .active { Task { await model.refreshSessions() } }
        }
        .onChange(of: path) { _, next in
            // Leaving the conversation is what clears the stored destination; the
            // workspace stays selected, which is where the user lands.
            if next.isEmpty, model.selectedSessionId != nil { model.closeSession() }
        }
        // Swiping right from the leading edge opens the drawer; swiping left on it closes it.
        // Two targeted gestures rather than one on the root: a horizontal drag across the
        // transcript would compete with the scroll views, and edge-drag is the platform's own
        // answer to exactly this.
        .overlay(alignment: .leading) {
            if !isDrawerOpen {
                Color.clear
                    .frame(width: 22)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onEnded { value in
                                guard value.translation.width > 44 else { return }
                                withAnimation(.snappy) { isDrawerOpen = true }
                            }
                    )
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: isDrawerOpen) { _, open in
            if open {
                // The drawer covers the screen, and the field it was opened over keeps first
                // responder — so the keyboard stayed up over the drawer's own content.
                DSHKeyboard.dismiss()
                Task { await model.refreshSessions() }
            }
        }
        .onChange(of: path) { _, _ in
            // Pushing a screen leaves the field behind it focused, which is how a keyboard ends
            // up on top of a conversation nobody is typing into.
            DSHKeyboard.dismiss()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // A toggle, not just an opener: the same button that opens the drawer closes it.
            DSHIconAction(
                label: isDrawerOpen ? "Close navigation" : "Open navigation",
                symbol: "sidebar.left"
            ) {
                withAnimation(.snappy) { isDrawerOpen.toggle() }
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

    /// The mode and model a new session will start in (SPEC §6).
    private var modelModeControls: some View {
        ModelModeControls(
            catalog: model.catalog,
            isLoading: model.catalogState == .loading,
            failure: {
                if case .failed(let reason) = model.catalogState { return reason }
                return nil
            }(),
            selectedMode: model.effectiveMode,
            selectedModel: model.effectiveModel,
            // The mark means "not the host's default", so a default selection carries none.
            isModeStaged: model.stagedMode != nil,
            isModelStaged: model.stagedModel != nil,
            onSelectMode: { model.stageMode($0) },
            onSelectModel: { model.stageModel($0) },
            onRefresh: { Task { await model.loadModelCatalog() } }
        )
    }

    /// Why Send is not available, or `nil` when it is.
    private var sendBlockedReason: String? {
        if !model.status.isUsable { return "Offline — reconnect to send." }
        if model.selectedWorkspaceId == nil { return "Choose a workspace first." }
        return nil
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
            if let error = model.newSessionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Composer(
                text: $draft,
                canSend: sendBlockedReason == nil,
                sendBlockedReason: sendBlockedReason,
                isSending: model.isStartingSession,
                placeholder: "Start something new…",
                focusRequest: focusRequest,
                onSend: { text in Task { await startSession(text) } }
            )
        }
    }

    /// Starts a session with the first prompt, and clears the field only if the prompt was
    /// accepted — the transaction owns the rest (SPEC §5).
    private func startSession(_ text: String) async {
        guard let workspaceId = model.selectedWorkspaceId else { return }
        let started = await model.startSession(workspaceId: workspaceId, text: text)
        if started != nil, model.newSessionError == nil { draft = "" }
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
                        state: session.needsInput ? .needsInput : (session.running ? .running : nil),
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
                },
                openUsage: {
                    withAnimation(.snappy) { isDrawerOpen = false }
                    path.append(.usage)
                },
                openNewSession: {
                    withAnimation(.snappy) { isDrawerOpen = false }
                    focusRequest += 1
                }
            )
            .transition(.move(edge: .leading))
            .frame(maxWidth: 340)
            .dismissesKeyboardOnDownwardDrag()
            // Swipe the panel away to close it, the mirror of the edge drag that opens it.
            // Either direction: a panel that only leaves one way is a panel you have to learn,
            // and the gesture people reach for first is the one that pushes it back where it
            // came from.
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        guard abs(value.translation.width) > 44 else { return }
                        withAnimation(.snappy) { isDrawerOpen = false }
                    }
            )
        }
    }

    /// A launch destination, in the drawer's own terms.
    private static func launchRoute(for destination: String?) -> Route? {
        switch destination {
        case "usage": .usage
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
