import DSHRemoteKit
import SwiftUI

/// One project, in full: every session it holds, newest first, under date headings.
///
/// This is what the drawer's workspace tree becomes. The tree could only ever show the
/// sessions that fitted under an expanded row, and its expansion was lost every time the
/// drawer closed; a screen has room for all of them and remembers nothing, because there is
/// nothing to remember. The host's `session/list` is not paginated in this build — the reply
/// is the whole index — so this is the whole list rather than a first page.
struct ProjectSessionsView: View {
    @Environment(AppModel.self) private var model

    let workspaceId: String
    /// Home owns the stack and the new-session screen, so the action is handed in.
    let startSession: () -> Void

    @State private var query = ""

    private var workspace: BrowseWorkspace? {
        model.browse.workspace(id: workspaceId)
    }

    /// The same grouping Home's counts come from, filtered by the local search.
    ///
    /// The filter is local on purpose: this list is what the phone has already loaded, and
    /// the screen says so rather than implying a host-side search (SPEC §4).
    private var groups: [SessionDateGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = model.browse.groupedSessions(in: workspaceId)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let matches = group.sessions.filter { $0.title.localizedCaseInsensitiveContains(needle) }
            guard !matches.isEmpty else { return nil }
            return SessionDateGroup(span: group.span, sessions: matches)
        }
    }

    private var isEmpty: Bool {
        model.browse.sessions(in: workspaceId).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                filter
                newSession
                sessionList
            }
            .padding(.horizontal, DSHMetrics.pageMargin)
            .padding(.bottom, DSHMetrics.spaceGroup)
        }
        .background(DSHPalette.canvas)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(workspace?.title ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refreshSessions() }
    }

    private var header: some View {
        HStack(spacing: DSHMetrics.spaceSmall + 2) {
            Image(systemName: "folder")
                .font(.footnote)
                .foregroundStyle(DSHPalette.secondaryText)
                .accessibilityHidden(true)
            if let path = workspace?.path, !path.isEmpty {
                Text(path)
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DSHMetrics.space)
            Text(workspace.map { $0.visibleSessionCount == 1 ? "1 session" : "\($0.visibleSessionCount) sessions" } ?? "")
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
        }
        .padding(.vertical, DSHMetrics.spaceCard)
    }

    private var filter: some View {
        HStack(spacing: DSHMetrics.spaceSmall + 2) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(DSHPalette.secondaryText)
                .accessibilityHidden(true)
            TextField("Filter sessions", text: $query)
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
        .frame(minHeight: DSHMetrics.minimumHitTarget)
        .background(DSHPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
    }

    private var newSession: some View {
        Button(action: startSession) {
            HStack(spacing: DSHMetrics.space) {
                Image(systemName: "square.and.pencil")
                    .accessibilityHidden(true)
                Text("New session in \(workspace?.title ?? "this project")")
                    .font(.dshCardTitle)
                    .lineLimit(1)
                Spacer(minLength: DSHMetrics.space)
            }
            .foregroundStyle(DSHPalette.primaryText)
            .padding(DSHMetrics.spaceCard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSHPalette.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, DSHMetrics.spaceCard)
    }

    @ViewBuilder
    private var sessionList: some View {
        if let reason = model.browse.sessionIndexFailure {
            VStack(alignment: .leading, spacing: DSHMetrics.space) {
                Label("Couldn’t load sessions", systemImage: "exclamationmark.triangle")
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.error)
                ErrorDetails(reason: reason)
                Button("Try again") { Task { await model.refreshSessions() } }
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.primaryActionText)
            }
            .padding(DSHMetrics.spaceCard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dshCard()
            .padding(.top, DSHMetrics.spaceGroup)
        } else if isEmpty {
            Text(model.browse.isLoadingFirstTime
                 ? "Reading sessions…"
                 : "No sessions in this project yet. Start one above.")
                .font(.dshSupporting)
                .foregroundStyle(DSHPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DSHMetrics.spaceGroup)
        } else if groups.isEmpty {
            Text("Nothing in this project matches “\(query)”.")
                .font(.dshSupporting)
                .foregroundStyle(DSHPalette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DSHMetrics.spaceGroup)
        } else {
            ForEach(groups) { group in
                DSHGroupHeader(title: group.title)
                    .padding(.top, DSHMetrics.spaceGroup)
                    .padding(.bottom, DSHMetrics.space)
                VStack(spacing: DSHMetrics.space) {
                    ForEach(group.sessions) { session in
                        SessionCard(
                            title: session.title,
                            supportingLine: session.lastActivity,
                            state: session.needsInput ? .needsInput : (session.running ? .running : nil),
                            lastActivity: nil,
                            open: { model.openSession(session.id) }
                        )
                    }
                }
            }
        }
    }
}
