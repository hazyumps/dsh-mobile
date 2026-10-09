import DSHRemoteKit
import SwiftUI

/// One workspace's sessions, in full.
///
/// UX spec "Workspace drawer and session browser": "View all sessions" opens the
/// selected workspace's complete available list. The host's `session/list` is not
/// paginated in this build — the reply is the whole index — so this is the whole list
/// rather than a first page, and no next-page control is offered that the host could
/// not answer.
struct SessionBrowserView: View {
    @Environment(AppModel.self) private var model

    /// `nil` shows every session the host reported, ungrouped sections included.
    let workspaceId: String?

    private var workspace: BrowseWorkspace? {
        model.browse.workspace(id: workspaceId)
    }

    private var sessions: [BrowseSession] {
        let source = workspace?.sessions ?? model.browse.workspaces.flatMap(\.sessions)
        return source.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    var body: some View {
        List {
            if let reason = model.browse.failureReason {
                Section {
                    VStack(alignment: .leading, spacing: DSHMetrics.space) {
                        Label("Couldn’t refresh sessions", systemImage: "exclamationmark.triangle")
                            .font(.dshSupporting)
                            .foregroundStyle(DSHPalette.error)
                        Text(reason)
                            .font(.dshMetadata)
                            .foregroundStyle(DSHPalette.secondaryText)
                        Button("Try again") { Task { await model.refreshSessions() } }
                            .font(.dshSupporting)
                            .foregroundStyle(DSHPalette.primaryActionText)
                    }
                }
            }

            ForEach(sessions) { session in
                Button {
                    model.openSession(session.id)
                } label: {
                    SessionCard(
                        title: session.title,
                        supportingLine: session.isSubagent ? "Subagent session" : nil,
                        state: session.running ? .running : nil,
                        lastActivity: session.running ? nil : session.lastActivity
                    ) { model.openSession(session.id) }
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .background(DSHPalette.canvas)
        .navigationTitle(workspace?.title ?? "All sessions")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refreshSessions() }
        .overlay {
            if sessions.isEmpty {
                if model.browse.isLoadingFirstTime {
                    ProgressView("Reading sessions…")
                } else {
                    ContentUnavailableView {
                        Label("No sessions", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Start a conversation on your computer and it will appear here.")
                    }
                }
            }
        }
    }
}
