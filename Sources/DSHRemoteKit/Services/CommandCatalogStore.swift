import Foundation

/// One command the host advertises for a session.
///
/// SPEC §9: `commands/list` returns a **bare array**, so this is the row a client has to read
/// out of it; `description` is required, `definitionId` and `input` are not.
public struct CommandEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var description: String
    public var definitionId: String?
    /// The host's own hint for what the command takes, when it declared any.
    public var hint: String?
    /// Whether the command accepts attachments. Absent means the host said nothing, which is
    /// not the same as "yes": SPEC §9 says to respect each command's advertised rule.
    public var acceptsAttachments: Bool

    public var id: String { name }

    public init(
        name: String,
        description: String,
        definitionId: String? = nil,
        hint: String? = nil,
        acceptsAttachments: Bool = false
    ) {
        self.name = name
        self.description = description
        self.definitionId = definitionId
        self.hint = hint
        self.acceptsAttachments = acceptsAttachments
    }

    init(_ wire: CommandsListResultItem) {
        self.name = wire.name
        self.description = wire.description
        self.definitionId = wire.definitionId
        self.hint = wire.input?.hint
        self.acceptsAttachments = wire.input?.attachments == true
    }

    /// Whether a draft line names this command: `/name` followed by nothing or a space.
    ///
    /// Matched here rather than by a `hasPrefix("/name")` at the call site, which would also
    /// match `/nameplate` and send it as this command.
    public func matches(line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return false }
        let rest = trimmed.dropFirst()
        guard let boundary = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return rest == name
        }
        return rest[rest.startIndex..<boundary] == name
    }
}

/// What running a command produced.
///
/// SPEC §9 names three different "nothing to show" cases, and they are not interchangeable:
/// a success may carry no text, an error always carries text, and the whole result is
/// optional because the descriptor models it as `_undefined()`-optional. Folding them into
/// one type would make "the host ran it silently" indistinguishable from "the host refused".
public enum CommandOutcome: Sendable, Hashable {
    /// The host ran it. `text` is optional — the schema does not require one — and
    /// `sourceEventSeq` names a durable event the transcript will already show.
    case ran(text: String?, sourceEventSeq: Int64?)
    /// The host refused it, in its own words.
    case refused(text: String)
    /// The command completed with no result at all, which the descriptor permits.
    case completed

    /// The text to show beside the composer, if any.
    public var text: String? {
        switch self {
        case .ran(let text, _): text
        case .refused(let text): text
        case .completed: nil
        }
    }

    /// Whether the transcript will render this itself, so a local echo would duplicate it.
    public var hasDurableSource: Bool {
        if case .ran(_, let seq) = self { return seq != nil }
        return false
    }
}

/// Reads a session's commands and runs them.
///
/// An actor because the list is cached per session and invalidated by the session changing —
/// SPEC §9: "Refresh when the session/preset changes and on a command-refused refresh path.
/// Cache only within the appropriate host/session scope."
public actor CommandCatalogStore {
    /// `namespace/method`, straight from `Protocol/endpoints.json`.
    public static let listMethod = "commands/list"
    public static let executeMethod = "commands/execute"

    private let makeClient: @Sendable () -> DshRpcClient
    /// Keyed by session, so a second session cannot read the first one's commands.
    private var cache: [String: [CommandEntry]] = [:]

    public init(makeClient: @escaping @Sendable () -> DshRpcClient) {
        self.makeClient = makeClient
    }

    /// The commands the host advertises for a session.
    ///
    /// The reply is a **bare array**: a client that assumed `session/list`'s `{items: […]}}`
    /// envelope finds nothing here, which is why the decode is written against the array
    /// rather than through a wrapper that would swallow the difference.
    @discardableResult
    public func commands(for agentId: String) async throws -> [CommandEntry] {
        let response = try await makeClient().call(
            Self.listMethod,
            args: CommandsListAgentArguments(agentId: agentId),
            returning: [CommandsListResultItem].self
        )
        // A missing value after `ok: true` is a host with no commands, not a decode failure.
        let entries = (response.result.value ?? []).map(CommandEntry.init)
        cache[agentId] = entries
        return entries
    }

    /// The last list read for a session, without a round trip.
    public func cached(for agentId: String) -> [CommandEntry] {
        cache[agentId] ?? []
    }

    /// Forgets a session's cache — a refusal is a refresh path, not a reason to trust it.
    public func invalidate(_ agentId: String) {
        cache[agentId] = nil
    }

    /// Runs a command line.
    ///
    /// A write, so it is never retried (SPEC §3.4), and the submitted-attachment list is sent
    /// explicitly empty: the descriptor requires the field, and the host distinguishes an
    /// empty list from an absent one.
    public func execute(agentId: String, line: String) async throws -> CommandOutcome {
        let response = try await makeClient().mutate(
            Self.executeMethod,
            args: CommandsExecuteArguments(
                agentId: agentId,
                line: line,
                submittedAttachments: []
            ),
            returning: CommandsExecuteResult.self
        )
        guard let value = response.result.value else {
            // The permitted absent result. Not an error, and not something to invent text for.
            return .completed
        }
        switch value.result {
        case .success(let success):
            return .ran(text: success.text, sourceEventSeq: success.sourceEventSeq)
        case .error(let failure):
            return .refused(text: failure.text)
        case .unrecognized:
            // A variant this build does not know is still an answer; inventing a meaning for
            // it would be worse than saying nothing.
            return .completed
        }
    }
}

/// `commands/list` takes `agentId` directly rather than inside a `request` object.
///
/// Spelled out here because the descriptor differs per endpoint and guessing costs a
/// `gateway/arguments-invalid` rather than a compile error.
struct CommandsListAgentArguments: Codable, Sendable {
    var agentId: String
}
