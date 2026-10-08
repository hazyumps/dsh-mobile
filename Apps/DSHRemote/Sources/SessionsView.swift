import DSHRemoteKit
import SwiftUI

/// SPEC §3.3: sessions grouped by the host's workspace, with running state and
/// last activity when the host supplies them.
struct SessionsView: View {
    let host: SavedHost
    @Environment(AppModel.self) private var model
    @State private var hasLoaded = false
    @State private var autoOpened: String?

    var body: some View {
        List {
            if model.isLoadingSessions {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading sessions…").foregroundStyle(.secondary)
                }
            }

            if let error = model.sessionListError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            ForEach(model.sessionGroups, id: \.key) { group in
                Section(group.key) {
                    ForEach(group.sessions, id: \.sessionId) { session in
                        NavigationLink {
                            ChatView(sessionId: session.sessionId)
                        } label: {
                            SessionRow(session: session, updated: model.lastActivity(session))
                        }
                    }
                }
            }
        }
        .navigationTitle(host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                StatusBadge(status: model.status)
            }
        }
        .overlay {
            if !model.isLoadingSessions && model.sessionGroups.isEmpty && model.sessionListError == nil && hasLoaded {
                ContentUnavailableView {
                    Label("No sessions", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a conversation on the computer and it will appear here.")
                }
            }
        }
        .refreshable { await model.loadSessions(for: host) }
        .navigationDestination(item: $autoOpened) { sessionId in
            ChatView(sessionId: sessionId)
        }
        .task {
            // Verification affordance: open the first session once the list has
            // loaded, so the chat screen can be reached without a tap. Inert
            // unless DSH_OPEN_SESSION is set.
            guard model.shouldOpenFirstSessionOnLaunch else { return }
            for _ in 0..<40 {
                if let first = model.sessionGroups.first?.sessions.first?.sessionId {
                    autoOpened = first
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await model.loadSessions(for: host)
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let updated: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if session.running == true {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Running")
                }
                Text(session.title ?? "Untitled session")
                    .font(.body)
                    .lineLimit(2)
            }
            if let updated {
                Text(updated, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
