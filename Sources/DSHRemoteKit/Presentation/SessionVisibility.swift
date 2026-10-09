import Foundation

/// Which sessions a browse list may show.
///
/// SPEC §4 gives the workspace registry an `archivedSessionIds` baseline field and an
/// `archived` delta, and the host's own app keeps those sessions out of its list. A client that
/// ignores the field shows them again — which is exactly the difference the phone showed
/// against the desktop.
///
/// A tiny type rather than a filter written inline at the call site, so the rule is stated
/// once and can be tested: membership is still the registry's job, and this only removes what
/// the host has taken out of the list.
public enum SessionVisibility {
    /// The ids in `sessionIds`, in order, minus the archived ones.
    public static func visible(sessionIds: [String], archivedSessionIds: [String]) -> [String] {
        guard !archivedSessionIds.isEmpty else { return sessionIds }
        let archived = Set(archivedSessionIds)
        return sessionIds.filter { !archived.contains($0) }
    }

    /// Whether a session is hidden because it is archived.
    public static func isArchived(_ sessionId: String, archivedSessionIds: [String]) -> Bool {
        archivedSessionIds.contains(sessionId)
    }
}
