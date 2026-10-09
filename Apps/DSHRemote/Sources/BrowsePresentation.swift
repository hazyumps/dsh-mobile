import DSHRemoteKit
import Foundation

/// One session, as the browse screens render it.
///
/// Plain values on purpose: the views take this and a closure, never the store or a
/// wire type. That is the same contract the design-system gallery already relies on,
/// and it is what lets the debug screen render Home and the drawer with no host.
struct BrowseSession: Identifiable, Hashable {
    let id: String
    /// The host's title, or the one the app falls back to. Never empty: the row's
    /// untitled case is already decided here so two screens cannot disagree about it.
    let title: String
    let running: Bool
    let updatedAt: Date?
    /// Set for a session the host reports under another session, which is not an
    /// ordinary session to open from the drawer's workspace tree.
    let isSubagent: Bool
    /// Whether the host says this session is waiting on the user *now* (SPEC §4).
    ///
    /// Two signals, and neither is the transcript: the session's own `inbox`/`userQuestions`
    /// projections, and a live actionable `$events` request the interaction store holds for it.
    let needsInput: Bool
    /// Whether `session/list` supplied a record for this id.
    ///
    /// The workspace registry names sessions the index may not have delivered — and the
    /// index can fail outright, which this host currently does for a corrupt session log.
    /// A registry-only row is a real session whose details are unknown, which is a
    /// different thing from a session that has no title, and the two must not look alike.
    let isLoaded: Bool

    var lastActivity: String? {
        guard let updatedAt else { return nil }
        // `Date.RelativeFormatStyle` rather than a cached `RelativeDateTimeFormatter`:
        // the formatter is not `Sendable`, and a static one would be shared mutable
        // state across actors for the sake of a few list rows.
        return updatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// One workspace, with the sessions the host's registry says belong to it.
struct BrowseWorkspace: Identifiable, Hashable {
    /// The host's workspace id, or the ungrouped sentinel. Opaque: never derived from
    /// the title (SPEC §4).
    let id: String
    let title: String
    let path: String?
    let sessions: [BrowseSession]

    var isUngrouped: Bool { id == Self.ungroupedId }
    var sessionCount: Int { sessions.count }

    static let ungroupedId = "ungrouped"
}

/// Everything the browse screens show, and what is known about it.
///
/// The two resource states stay separate because they are two different failures: a
/// session list that failed is not an empty set of workspaces, and neither is proof
/// that the connection is down (SPEC §3).
struct BrowseState: Hashable {
    var workspaces: [BrowseWorkspace] = []
    var workspacesState: ResourceState = .loading
    var sessionsState: ResourceState = .loading

    /// Before a host's snapshot exists at all.
    static let idle = BrowseState()

    /// The sessions shown under “Continue a session”, newest first.
    ///
    /// Subagents are excluded: they are real sessions, but they are not what somebody
    /// means by "continue", and opening one from a recent list is a surprise.
    func recent(limit: Int = 5) -> [BrowseSession] {
        workspaces
            .flatMap(\.sessions)
            .filter { !$0.isSubagent }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    func workspace(id: String?) -> BrowseWorkspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// One session by id, wherever the host filed it. Used for a conversation's title.
    func session(id: String) -> BrowseSession? {
        for workspace in workspaces {
            if let match = workspace.sessions.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    var sessionCount: Int { workspaces.reduce(0) { $0 + $1.sessions.count } }

    /// A reason to show beside the list, when a load failed.
    var failureReason: String? {
        sessionIndexFailure ?? workspaceFailure
    }

    /// Why `session/list` failed, if it did.
    ///
    /// Its own accessor because the two failures look nothing alike on screen: a failed
    /// session index still leaves the workspace tree standing, and this host currently
    /// fails the index outright over one corrupt session log. Showing the hierarchy
    /// without mentioning that would present registry ids as if they were loaded sessions.
    var sessionIndexFailure: String? {
        switch sessionsState {
        case .failed(let reason): reason
        case .stale(let reason): reason
        case .empty, .loading, .current: nil
        }
    }

    /// Why `workspace/follow` failed, if it did.
    var workspaceFailure: String? {
        switch workspacesState {
        case .failed(let reason): reason
        case .stale(let reason): reason
        case .empty, .loading, .current: nil
        }
    }

    /// Whether a refresh is in flight with nothing to show yet.
    var isLoadingFirstTime: Bool {
        workspaces.isEmpty && (workspacesState == .loading || sessionsState == .loading)
    }

    /// Maps the store's snapshot into the values the screens render.
    ///
    /// Membership comes from `snapshot.sections`, which the store derives from the
    /// workspace registry alone — not from `cwd`, and not from a title.
    /// - Parameter liveWaiters: session ids with an actionable delivery in the interaction
    ///   store — the third signal, which the projections cannot carry because a live request
    ///   is not a projection.
    static func from(_ snapshot: HostSessionStore.Snapshot, liveWaiters: Set<String> = []) -> BrowseState {
        let workspaces = snapshot.sections.map { section in
            BrowseWorkspace(
                id: section.workspaceId ?? BrowseWorkspace.ungroupedId,
                title: section.title,
                path: section.workspaceId.flatMap { id in
                    snapshot.workspaces.first { $0.workspaceId == id }?.path
                },
                sessions: section.sessionIds.map { id in
                    Self.session(
                        id: id,
                        record: snapshot.sessions[id],
                        projections: snapshot.projections[id],
                        hasLiveRequest: liveWaiters.contains(id)
                    )
                }
            )
        }
        return BrowseState(
            workspaces: workspaces,
            workspacesState: snapshot.workspacesState,
            sessionsState: snapshot.sessionsState
        )
    }

    /// A session id the registry knows but the index has not delivered is still listed,
    /// with the untitled fallback, rather than dropped: the registry is the authority on
    /// membership and the record may simply not have arrived yet.
    private static func session(
        id: String,
        record: HostSessionStore.SessionRecord?,
        projections: [String: HostSessionStore.Projection]? = nil,
        hasLiveRequest: Bool = false
    ) -> BrowseSession {
        BrowseSession(
            id: id,
            title: record?.title ?? "Untitled session",
            running: record?.running ?? false,
            updatedAt: record?.updatedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            isSubagent: record?.parentSessionId != nil,
            needsInput: hasLiveRequest || SessionInputSignal.isWaiting(
                projections: projections?.mapValues(\.value)
            ),
            isLoaded: record != nil
        )
    }
}
