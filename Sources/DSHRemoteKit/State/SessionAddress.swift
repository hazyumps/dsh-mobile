import Foundation

/// Where a conversation is read from.
///
/// `session/follow` and `session/page` take the same address union, and the two members are not
/// interchangeable. Probed against the live relay, 2026-10-15:
///
/// ```
/// POST /api/session/page  {"address":{"kind":"session","sessionId":"9b8e505c-…"}}
///   → ok: false, code "session/agent-busy",
///     message "subagent Sessions require their durable parent address"
/// ```
///
/// So a child cannot be read by session id, however much of one its id looks like: the durable
/// parent address — parent, child and mode together — is what the host routes on. Making the
/// address the caller's value rather than something a session id is silently turned into is what
/// keeps that from being rediscovered at a call site.
///
/// The two wire forms are written out separately because one is built as raw JSON (the mux `open`
/// frame) and the other as the generated ``SessionPageRequestAddress``. Both are exercised by a
/// test, so neither can quietly drift back to the session member.
public enum SessionAddress: Sendable, Hashable {
    /// An ordinary session.
    case session(String)
    /// A subagent conversation, which needs its parent and the mode it was delegated with.
    case subagent(parentSessionId: String, childSessionId: String, mode: SubagentMode)

    /// The session a reader orbits: the child for a subagent, the session itself otherwise.
    ///
    /// Used where only an id fits — the cancel call, a diagnostics line — never to build an
    /// address, which is the mistake the probe above is about.
    public var sessionId: String {
        switch self {
        case .session(let sessionId): sessionId
        case .subagent(_, let childSessionId, _): childSessionId
        }
    }

    /// The parent this conversation belongs to, for a subagent.
    public var parentSessionId: String? {
        switch self {
        case .session: nil
        case .subagent(let parentSessionId, _, _): parentSessionId
        }
    }

    public var isSubagent: Bool {
        switch self {
        case .session: false
        case .subagent: true
        }
    }

    /// The address object as `session/follow`'s `args.request.address` carries it.
    ///
    /// Written out rather than derived from the generated union, because the follow's args are
    /// built as raw ``JSONValue`` (`ChatSession.start`). ``pageAddress`` is the generated form of
    /// the same object and a test asserts both, so the two cannot drift apart.
    var wire: JSONValue {
        switch self {
        case .session(let sessionId):
            .object([
                "kind": .string("session"),
                "sessionId": .string(sessionId),
            ])
        case .subagent(let parentSessionId, let childSessionId, let mode):
            .object([
                "kind": .string("subagent"),
                "parentSessionId": .string(parentSessionId),
                "childSessionId": .string(childSessionId),
                "mode": .string(mode.rawValue),
            ])
        }
    }

    /// The same address, as `session/page`'s generated request types it.
    var pageAddress: SessionPageRequestAddress {
        switch self {
        case .session(let sessionId):
            .session(.init(kind: "session", sessionId: sessionId))
        case .subagent(let parentSessionId, let childSessionId, let mode):
            .subagent(.init(
                kind: "subagent",
                parentSessionId: parentSessionId,
                childSessionId: childSessionId,
                mode: .init(rawValue: mode.rawValue)
            ))
        }
    }
}
