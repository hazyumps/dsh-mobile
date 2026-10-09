import Foundation

/// Whether a session is *currently* waiting on the user.
///
/// SPEC §4 is unusually specific about this, because the obvious implementation is wrong:
/// "'Needs input' comes from current interaction channels/projections. A historical
/// `ask_user_question` tool call does not produce this badge by itself."
///
/// So this reads the two places the host says "now" — the session's `inbox` projection
/// (`next-turn` / `next-step`) and its `userQuestions.active` — and nothing else. A transcript
/// full of answered questions says nothing about whether one is open, and a badge driven by
/// history would stick on a session nobody is waiting for.
///
/// A live, actionable `$events` request is the third signal, and it belongs to the caller: the
/// interaction store knows it, this does not.
public enum SessionInputSignal {
    /// Whether the host's projections say this session has something waiting.
    ///
    /// Tolerant by construction: a missing or malformed projection says **no**, because a
    /// badge that cannot be justified from the host's own data is worse than a missing one.
    public static func isWaiting(inbox: JSONValue?, userQuestions: JSONValue?) -> Bool {
        if let inbox {
            for key in ["next-turn", "next-step"] where !(inbox[key]?.arrayValue ?? []).isEmpty {
                return true
            }
        }
        if let active = userQuestions?["active"]?.arrayValue, !active.isEmpty {
            return true
        }
        return false
    }

    /// The same question, asked of a snapshot's projection map.
    public static func isWaiting(projections: [String: JSONValue]?) -> Bool {
        guard let projections else { return false }
        return isWaiting(
            inbox: projections["inbox"],
            userQuestions: projections["userQuestions"]
        )
    }
}
