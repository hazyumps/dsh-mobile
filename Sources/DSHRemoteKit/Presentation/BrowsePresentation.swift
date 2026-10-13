import Foundation

/// One session, as the browse screens render it.
///
/// Plain values on purpose: the views take this and a closure, never the store or a
/// wire type. That is the same contract the design-system gallery already relies on,
/// and it is what lets the debug screen render Home and the drawer with no host.
///
/// It lives in the kit rather than the app target because none of it needs a screen —
/// the ordering and filtering rules below are exactly the kind of thing that has to be
/// tested, and behind the app target they were not (issue #61).
public struct BrowseSession: Identifiable, Hashable, Sendable {
    public let id: String
    /// The host's title, or the one the app falls back to. Never empty: the row's
    /// untitled case is already decided here so two screens cannot disagree about it.
    public let title: String
    public let running: Bool
    public let updatedAt: Date?
    /// Set for a session the host reports under another session, which is not an
    /// ordinary session to open from the browse lists.
    public let isSubagent: Bool
    /// Whether the host says this session is waiting on the user *now* (SPEC §4).
    ///
    /// Two signals, and neither is the transcript: the session's own `inbox`/`userQuestions`
    /// projections, and a live actionable `$events` request the interaction store holds for it.
    public let needsInput: Bool
    /// Whether `session/list` supplied a record for this id.
    ///
    /// The workspace registry names sessions the index may not have delivered — and the
    /// index can fail outright, which this host has done for a corrupt session log.
    /// A registry-only row is a real session whose details are unknown, which is a
    /// different thing from a session that has no title, and the two must not look alike.
    public let isLoaded: Bool

    public init(
        id: String,
        title: String,
        running: Bool,
        updatedAt: Date?,
        isSubagent: Bool,
        needsInput: Bool,
        isLoaded: Bool
    ) {
        self.id = id
        self.title = title
        self.running = running
        self.updatedAt = updatedAt
        self.isSubagent = isSubagent
        self.needsInput = needsInput
        self.isLoaded = isLoaded
    }

    public var lastActivity: String? {
        guard let updatedAt else { return nil }
        // `Date.RelativeFormatStyle` rather than a cached `RelativeDateTimeFormatter`:
        // the formatter is not `Sendable`, and a static one would be shared mutable
        // state across actors for the sake of a few list rows.
        return updatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// One workspace, with the sessions the host's registry says belong to it.
public struct BrowseWorkspace: Identifiable, Hashable, Sendable {
    /// The host's workspace id, or the ungrouped sentinel. Opaque: never derived from
    /// the title (SPEC §4).
    public let id: String
    public let title: String
    public let path: String?
    public let sessions: [BrowseSession]

    public init(id: String, title: String, path: String?, sessions: [BrowseSession]) {
        self.id = id
        self.title = title
        self.path = path
        self.sessions = sessions
    }

    public var isUngrouped: Bool { id == Self.ungroupedId }
    public var sessionCount: Int { sessions.count }

    /// What the project row reports, and what its screen then shows.
    ///
    /// Subagents are excluded from both. A row saying "3 sessions" that opens a list of
    /// two is how the count and the list stop agreeing.
    public var visibleSessionCount: Int { sessions.count { !$0.isSubagent } }

    /// How many of the visible sessions are running, for the row's "· 2 active".
    public var activeCount: Int { sessions.count { !$0.isSubagent && $0.running } }

    /// The most recent activity in this workspace, or `nil` when nothing here is dated.
    ///
    /// Subagents count: they are the workspace being worked in, even though they are not
    /// rows anyone opens.
    public var latestActivity: Date? {
        sessions.compactMap(\.updatedAt).max()
    }

    public static let ungroupedId = "ungrouped"
}

/// A project's sessions under one date heading.
///
/// The span, not the title, is the identity: two groups can never share a heading, and
/// the heading text is copy that may change without changing what the group means.
public struct SessionDateGroup: Identifiable, Hashable, Sendable {
    public enum Span: String, CaseIterable, Hashable, Sendable {
        case today, yesterday, earlier, undated

        public var title: String {
            switch self {
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .earlier: "Earlier"
            // Not "Earlier": the host never said when this session ran, and the registry
            // listing a session whose record has not arrived is a real state on this host.
            case .undated: "No date reported"
            }
        }
    }

    public let span: Span
    public let sessions: [BrowseSession]

    public init(span: Span, sessions: [BrowseSession]) {
        self.span = span
        self.sessions = sessions
    }

    public var id: String { span.rawValue }
    public var title: String { span.title }
}

/// Everything the browse screens show, and what is known about it.
///
/// The two resource states stay separate because they are two different failures: a
/// session list that failed is not an empty set of workspaces, and neither is proof
/// that the connection is down (SPEC §3).
public struct BrowseState: Hashable, Sendable {
    public var workspaces: [BrowseWorkspace]
    public var workspacesState: ResourceState
    public var sessionsState: ResourceState

    public init(
        workspaces: [BrowseWorkspace] = [],
        workspacesState: ResourceState = .loading,
        sessionsState: ResourceState = .loading
    ) {
        self.workspaces = workspaces
        self.workspacesState = workspacesState
        self.sessionsState = sessionsState
    }

    /// Before a host's snapshot exists at all.
    public static let idle = BrowseState()

    /// The sessions Home shows as recents, newest first.
    ///
    /// Subagents are excluded: they are real sessions, but they are not what somebody
    /// means by "continue", and opening one from a recent list is a surprise. Ties break
    /// on id, so a list that re-renders with equal timestamps cannot reorder itself.
    public func recent(limit: Int = 5) -> [BrowseSession] {
        workspaces
            .flatMap(\.sessions)
            .filter { !$0.isSubagent }
            .sorted(by: Self.newestFirst)
            .prefix(limit)
            .map { $0 }
    }

    /// The workspaces Home lists as projects: most recently worked in, first.
    ///
    /// A workspace nothing is dated in keeps its registry position behind the dated ones —
    /// an empty workspace is not *old*, it is unknown, and it must not displace a workspace
    /// we can actually date. The ungrouped sentinel sorts last regardless: sessions the
    /// registry filed under no workspace are still reachable, but "Ungrouped" is not a
    /// project and does not head the list.
    public var projects: [BrowseWorkspace] {
        workspaces
            .enumerated()
            .sorted { left, right in
                let leftWorkspace = left.element
                let rightWorkspace = right.element
                if leftWorkspace.isUngrouped != rightWorkspace.isUngrouped {
                    return !leftWorkspace.isUngrouped
                }
                switch (leftWorkspace.latestActivity, rightWorkspace.latestActivity) {
                case let (leftDate?, rightDate?):
                    if leftDate != rightDate { return leftDate > rightDate }
                    return left.offset < right.offset
                case (nil, .some): return false
                case (.some, nil): return true
                default: return left.offset < right.offset
                }
            }
            .map(\.element)
    }

    /// One workspace's sessions as its screen lists them: newest first, no subagents.
    public func sessions(in workspaceId: String?) -> [BrowseSession] {
        guard let workspace = workspace(id: workspaceId) else { return [] }
        return workspace.sessions
            .filter { !$0.isSubagent }
            .sorted(by: Self.newestFirst)
    }

    /// The same list, bucketed by when it last ran.
    ///
    /// A span with nothing in it is omitted rather than rendered as an empty heading, and
    /// the groups come out in calendar order — today, yesterday, earlier, undated.
    public func groupedSessions(
        in workspaceId: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [SessionDateGroup] {
        let sessions = sessions(in: workspaceId)
        guard !sessions.isEmpty else { return [] }

        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        var buckets: [SessionDateGroup.Span: [BrowseSession]] = [:]
        for session in sessions {
            let span: SessionDateGroup.Span
            if let updated = session.updatedAt {
                if calendar.isDate(updated, inSameDayAs: now) {
                    span = .today
                } else if let yesterday, calendar.isDate(updated, inSameDayAs: yesterday) {
                    span = .yesterday
                } else {
                    span = .earlier
                }
            } else {
                span = .undated
            }
            buckets[span, default: []].append(session)
        }

        return SessionDateGroup.Span.allCases.compactMap { span in
            guard let sessions = buckets[span], !sessions.isEmpty else { return nil }
            return SessionDateGroup(span: span, sessions: sessions)
        }
    }

    /// Newest first, then by id so equal timestamps have one order and keep it.
    private static func newestFirst(_ left: BrowseSession, _ right: BrowseSession) -> Bool {
        let leftDate = left.updatedAt ?? .distantPast
        let rightDate = right.updatedAt ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return left.id < right.id
    }

    public func workspace(id: String?) -> BrowseWorkspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// One session by id, wherever the host filed it. Used for a conversation's title.
    public func session(id: String) -> BrowseSession? {
        for workspace in workspaces {
            if let match = workspace.sessions.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    public var sessionCount: Int { workspaces.reduce(0) { $0 + $1.sessions.count } }

    /// A reason to show beside the list, when a load failed.
    public var failureReason: String? {
        sessionIndexFailure ?? workspaceFailure
    }

    /// Why `session/list` failed, if it did.
    ///
    /// Its own accessor because the two failures look nothing alike on screen: a failed
    /// session index still leaves the workspace registry standing, and this host has failed
    /// the index outright over one corrupt session log. Showing the hierarchy without
    /// mentioning that would present registry ids as if they were loaded sessions.
    public var sessionIndexFailure: String? {
        switch sessionsState {
        case .failed(let reason): reason
        case .stale(let reason): reason
        case .empty, .loading, .current: nil
        }
    }

    /// Why `workspace/follow` failed, if it did.
    public var workspaceFailure: String? {
        switch workspacesState {
        case .failed(let reason): reason
        case .stale(let reason): reason
        case .empty, .loading, .current: nil
        }
    }

    /// Whether a refresh is in flight with nothing to show yet.
    public var isLoadingFirstTime: Bool {
        workspaces.isEmpty && (workspacesState == .loading || sessionsState == .loading)
    }

    /// Maps the store's snapshot into the values the screens render.
    ///
    /// Membership comes from `snapshot.sections`, which the store derives from the
    /// workspace registry alone — not from `cwd`, and not from a title.
    /// - Parameter liveWaiters: session ids with an actionable delivery in the interaction
    ///   store — the third signal, which the projections cannot carry because a live request
    ///   is not a projection.
    public static func from(_ snapshot: HostSessionStore.Snapshot, liveWaiters: Set<String> = []) -> BrowseState {
        // SPEC §4 gives the registry an `archived` delta and `archivedSessionIds` in its
        // baseline, and the host's own app hides those sessions. Listing them here was the
        // difference the phone showed against the desktop: archived sessions came back as
        // ordinary recent cards. Membership is still the registry's — this only removes the
        // ones the host has taken out of the list.
        let archived = snapshot.archivedSessionIds
        let workspaces = snapshot.sections.map { section in
            BrowseWorkspace(
                id: section.workspaceId ?? BrowseWorkspace.ungroupedId,
                title: section.title,
                path: section.workspaceId.flatMap { id in
                    snapshot.workspaces.first { $0.workspaceId == id }?.path
                },
                sessions: SessionVisibility.visible(
                    sessionIds: section.sessionIds,
                    archivedSessionIds: archived
                ).map { id in
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
