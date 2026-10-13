import DSHRemoteKit
import SwiftUI

/// Home: the work, newest first, with the harness behind the drawer.
///
/// The page is two lists and a composer. Recents is the last few sessions across every
/// project, because "return to work" does not care which project the work was in; projects
/// are the hierarchy, as a destination rather than a disclosure, so a workspace with thirty
/// sessions has the whole screen to list them on. The composer is an inset at the bottom
/// rather than a section in the scroll, so it is never the thing that scrolled away.
///
/// The host row that used to head this page is gone: it said "Connected — Mac.fernlabs.net"
/// on every launch, which is a fact you need once and not forty times a day. The unhealthy
/// case still gets the top of the page, as a banner.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    /// What a tap in this stack can lead to.
    ///
    /// The harness destinations are here rather than in the drawer's own stack: the drawer
    /// closes as it navigates, so the screen it opens belongs to Home's path and inherits
    /// the same back button and the same restoration rules.
    enum Route: Hashable {
        case session(String)
        case project(String)
        case newSession
        case modelDefaults
        case usage
        case plugins
        case schedules
        case hosts
        case thisPhone
        case reminders
        case diagnostics
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Route] = []
    @State private var isDrawerOpen = false

    private var browse: BrowseState { model.browse }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .leading) {
                page
                if isDrawerOpen { drawerLayer }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(for: Route.self) { route in
                destination(route)
            }
        }
        .task {
            // The catalog labels the composer's model chip and backs the new-session
            // screen, and it does not stream.
            if model.catalog == nil { await model.loadModelCatalog() }
            #if DEBUG
            // Debug builds only: a screen whose only door is a tap needs a way in on a
            // machine that cannot tap. `DSH_NEW_SESSION` replaces the old `DSH_FOCUS` and
            // `DSH_DRAFT`, which pointed at the composer that has moved.
            if ProcessInfo.processInfo.environment["DSH_NEW_SESSION"] != nil {
                path = [.newSession]
            }
            if ProcessInfo.processInfo.environment["DSH_DRAWER"] != nil {
                try? await Task.sleep(for: .seconds(2))
                isDrawerOpen = true
            }
            #endif
        }
        .task(id: model.selectedSessionId) {
            // Navigation is restored from the same value the store persists, so a cold
            // launch reopens the last conversation instead of the workspace list.
            // A notification tap wins over both: the user asked for that screen, and the
            // restored conversation is only ever a convenience.
            if let route = Self.launchRoute(for: model.consumeDrawerDestination()) {
                path = [route]
                return
            }
            if let route = Self.launchRoute(for: model.launchDestination) {
                #if DEBUG
                // A destination like Usage needs a session to report on, and selecting one
                // is a separate action from navigating to a conversation.
                if let named = model.launchSessionId, model.selectedSessionId != named {
                    model.openSession(named)
                }
                #endif
                path = [route]
                return
            }
            guard let sessionId = model.selectedSessionId else {
                // Back on Home closes the session, which is what the drawer's absence of a
                // session list means: leaving a conversation is leaving it.
                if !path.contains(where: { if case .session = $0 { true } else { false } }) {
                    path.removeAll()
                }
                return
            }
            if path.last != .session(sessionId) { path = [.session(sessionId)] }
        }
        .task(id: model.selectedHost?.id) {
            // SPEC §4: refresh `session/list` on foreground, opening the drawer,
            // pull-to-refresh, and at most every 15 seconds while the recent list is
            // visible. The recent list is *this* screen.
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
        .onChange(of: model.pendingDrawerDestination) { _, next in
            // The tap that arrives while this screen is already up: `selectedSessionId` has
            // not changed, so the navigation task above does not re-run for it.
            guard let route = Self.launchRoute(for: model.consumeDrawerDestination() ?? next) else { return }
            path = [route]
        }
        .onChange(of: isDrawerOpen) { _, open in
            if open {
                // The drawer covers the screen, and whatever had first responder keeps it —
                // so the keyboard stayed up over the drawer's own content.
                DSHKeyboard.dismiss()
                Task { await model.refreshSessions() }
            }
        }
        .onChange(of: path) { _, _ in
            // Pushing a screen leaves any field behind it focused, which is how a keyboard
            // ends up on top of a screen nobody is typing into.
            DSHKeyboard.dismiss()
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .session(let sessionId):
            ConversationView(sessionId: sessionId)
        case .project(let workspaceId):
            ProjectSessionsView(workspaceId: workspaceId, startSession: { path.append(.newSession) })
        case .newSession:
            NewSessionView(onCreated: { sessionId in path = [.session(sessionId)] })
        case .modelDefaults:
            ModelModeDefaultsView()
        case .usage:
            UsageView(sessionId: model.selectedSessionId, title: "Usage")
        case .plugins:
            PluginsView()
        case .schedules:
            SchedulesView()
        case .hosts:
            HostsPairingView()
        case .thisPhone:
            ThisPhoneView()
        case .reminders:
            RemindersView()
        case .diagnostics:
            DiagnosticsView()
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
    }

    // MARK: - The page

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSHMetrics.spaceGroup) {
                if !model.status.isUsable { offlineBanner }
                failureCards
                content
            }
            .padding(.horizontal, DSHMetrics.pageMargin)
            .padding(.top, DSHMetrics.spaceCard)
            // Room for the composer inset, which sits outside this scroll view.
            .padding(.bottom, DSHMetrics.space)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DSHPalette.canvas)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await model.refreshSessions() }
        .safeAreaInset(edge: .bottom, spacing: 0) { composerBar }
    }

    @ViewBuilder
    private var content: some View {
        if browse.isLoadingFirstTime {
            HStack(spacing: DSHMetrics.space) {
                ProgressView()
                Text("Reading sessions…").foregroundStyle(DSHPalette.secondaryText)
            }
            .font(.dshSupporting)
        } else if browse.sessionCount == 0 {
            emptyState
        } else {
            recents
            projects
        }
    }

    /// Shown when the state is not connected, and only then.
    private var offlineBanner: some View {
        Label {
            Text("\(DSHHostState(model.status).text) — showing what this phone last loaded.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "bolt.horizontal.circle")
        }
        .font(.dshSupporting)
        .foregroundStyle(DSHPalette.attention)
        .padding(DSHMetrics.spaceCard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dshCard()
    }

    /// The whale, where it introduces the product instead of pushing work off the screen.
    ///
    /// UX spec "Home" item 4 puts the heading on Home unconditionally; the revised layout
    /// keeps it for the state where there is nothing else to say. Recorded in the spec.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.space) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DSHPalette.primaryActionText)
                .accessibilityHidden(true)
            Text("Into the Unknown")
                .font(.dshHomeTitle)
                .foregroundStyle(DSHPalette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("No sessions yet. Start one on your computer and it will appear here.")
                .font(.dshSupporting)
                .foregroundStyle(DSHPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DSHMetrics.space)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.space) {
            DSHGroupHeader(title: "Recents")
            ForEach(browse.recent(limit: Self.recentLimit)) { session in
                SessionCard(
                    title: session.title,
                    supportingLine: supportingLine(for: session),
                    state: session.needsInput ? .needsInput : (session.running ? .running : nil),
                    lastActivity: nil,
                    open: { open(session.id) }
                )
            }
        }
    }

    /// Four: enough to fill the first screen at this density, and the rest are one tap away
    /// under the project they belong to.
    private static let recentLimit = 4

    /// Where the session came from, and when it last moved.
    private func supportingLine(for session: BrowseSession) -> String? {
        var parts: [String] = []
        if let project = projectTitle(for: session.id) { parts.append(project) }
        if let activity = session.lastActivity { parts.append(activity) }
        if !session.isLoaded { parts.append("Details didn’t load") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func projectTitle(for sessionId: String) -> String? {
        browse.workspaces.first { $0.sessions.contains { $0.id == sessionId } }?.title
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSHGroupHeader(
                title: "Projects",
                trailing: browse.projects.count == 1 ? "1" : "\(browse.projects.count)"
            )
            .padding(.bottom, DSHMetrics.spaceSmall)
            ForEach(Array(browse.projects.enumerated()), id: \.element.id) { index, workspace in
                if index > 0 { Divider().overlay(DSHPalette.divider) }
                ProjectRow(
                    title: workspace.title,
                    sessionCount: workspace.visibleSessionCount,
                    activeCount: workspace.activeCount
                ) {
                    path.append(.project(workspace.id))
                }
            }
        }
    }

    /// The failures that leave rows on screen unexplained, said out loud.
    ///
    /// A failed session index still leaves the registry standing, and this host has failed
    /// the index outright over one corrupt session log — presenting registry ids as loaded
    /// sessions is exactly what this prevents.
    @ViewBuilder
    private var failureCards: some View {
        if let reason = browse.sessionIndexFailure {
            VStack(alignment: .leading, spacing: DSHMetrics.space) {
                Label("Couldn’t load sessions", systemImage: "exclamationmark.triangle")
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.error)
                // The host's reason is kept verbatim but behind a disclosure: it quotes full
                // private paths, and the UX spec asks for details on request.
                ErrorDetails(reason: reason)
                Button("Try again") { Task { await model.refreshSessions() } }
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.primaryActionText)
            }
            .padding(DSHMetrics.spaceCard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dshCard()
        } else if browse.workspaceFailure != nil {
            VStack(alignment: .leading, spacing: DSHMetrics.space) {
                Label("Couldn’t load projects", systemImage: "exclamationmark.triangle")
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.error)
                Button("Try again") { Task { await model.refreshSessions() } }
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.primaryActionText)
            }
            .padding(DSHMetrics.spaceCard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dshCard()
        }
    }

    // MARK: - Composer

    /// The composer, as a control rather than a field.
    ///
    /// Tapping opens the new-session screen, where the host, project, preset and model are
    /// read before the text is written. Keeping a live text field here would mean the
    /// keyboard covers the recents the screen exists to show, and it would put the same
    /// draft in two places.
    private var composerBar: some View {
        Button {
            path.append(.newSession)
        } label: {
            HStack(spacing: DSHMetrics.space) {
                Image(systemName: "plus")
                    .font(.body)
                    .foregroundStyle(DSHPalette.primaryText)
                    .frame(width: 34, height: 34)
                    .background(DSHPalette.card)
                    .clipShape(Circle())
                Text("Ask DeepSeek…")
                    .font(.dshMessageBody)
                    .foregroundStyle(DSHPalette.secondaryText)
                Spacer(minLength: DSHMetrics.space)
                if let name = model.effectiveModel?.name {
                    Text(name)
                        .font(.dshMetadata)
                        .foregroundStyle(DSHPalette.secondaryText)
                        .lineLimit(1)
                        .padding(.horizontal, DSHMetrics.spaceCard)
                        .padding(.vertical, DSHMetrics.spaceSmall)
                        .background(DSHPalette.card)
                        .clipShape(Capsule())
                }
            }
            .padding(DSHMetrics.spaceSmall + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSHPalette.elevatedSurface)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(DSHPalette.cardEdge, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask DeepSeek")
        .accessibilityHint("Opens a new session, where the project and model are chosen")
        .padding(.horizontal, DSHMetrics.pageMargin)
        .padding(.vertical, DSHMetrics.space)
        .background(DSHPalette.canvas)
        .overlay(alignment: .top) { Divider().overlay(DSHPalette.divider) }
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
                open: { destination in
                    withAnimation(.snappy) { isDrawerOpen = false }
                    path.append(Self.route(for: destination))
                }
            )
            .transition(.move(edge: .leading))
            // Full height, not content height. Without this the panel is only as tall as its
            // list, so the panel ends part-way down the screen and everything below it reads
            // as a drawer that is somehow both too big and too empty.
            .frame(maxWidth: 340, maxHeight: .infinity, alignment: .top)
            .dismissesKeyboardOnDownwardDrag()
            // Swipe the panel away to close it, the mirror of the edge drag that opens it.
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        guard abs(value.translation.width) > 44 else { return }
                        withAnimation(.snappy) { isDrawerOpen = false }
                    }
            )
        }
    }

    private static func route(for destination: DrawerView.Destination) -> Route {
        switch destination {
        case .modelDefaults: .modelDefaults
        case .plugins: .plugins
        case .usage: .usage
        case .schedules: .schedules
        case .hosts: .hosts
        case .thisPhone: .thisPhone
        case .reminders: .reminders
        case .diagnostics: .diagnostics
        }
    }

    /// A launch destination, in Home's own terms.
    private static func launchRoute(for destination: String?) -> Route? {
        switch destination {
        case "usage": .usage
        case "plugins": .plugins
        case "schedules": .schedules
        case "hosts": .hosts
        case "diagnostics": .diagnostics
        case "new": .newSession
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
