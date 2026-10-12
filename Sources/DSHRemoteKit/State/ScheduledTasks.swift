import Foundation

// `dsh-plugin-scheduled-tasks` — the scheduled-tasks feature the desktop profile actually
// loads, reached as the `scheduledTasks` Remote namespace.
//
// This is a **peer** of `@deepseek-ai/dsh-schedule`, not the same service, and the two do
// not substitute for each other:
//
// * the shipped `schedule/*` service delivers a due occurrence as a follow-up in the
//   *original* session (``ScheduleEntry``'s `sessionId`/`lastDelivery` half), and is
//   registered only by `@deepseek-ai/dsh-experimental-schedule-bundle`, which is not in the
//   desktop profile's bundle list — so on this host every `schedule/*` call 404s;
// * this plugin starts a **new session per run**, named `<task> — <date>`, and records the
//   run on the task.
//
// Captured from the running relay on 2026-10-12, with the task text redacted
// (`Fixtures/scheduled-tasks-list.json`).
//
// Two properties decide how much the client has to do, and both were read off the live
// answer rather than inferred from the schema:
//
// * `schedule.scheduledAt` is the **next occurrence**, not the time the task was created —
//   the host advances it after every run. So a client can build a reminder from it without
//   reimplementing cron, DST or IANA zones.
// * `lastRun` is the receipt. `sessionId` is written only once the run's session exists, so
//   a run that failed to start carries `sessionId: null` and the reason in `error`.

/// One run of a scheduled task: `list`'s `lastRun`.
public struct ScheduledTaskRun: Sendable, Hashable, Codable {
    /// The occurrence this run was for, ISO 8601.
    public var occurrenceAt: String
    /// The session the run started.
    ///
    /// Optional in Swift so that both a `null` and an absent key decode to nil — the host
    /// sends `null` for a run that never got a session, and "not reported" is not something
    /// a caller may read as a session id either.
    public var sessionId: String?
    /// When the host finished starting the run, ISO 8601. Not when the agent finished
    /// answering: this plugin does not wait for the turn.
    public var finishedAt: String
    /// Whether the run started. False carries the reason in ``error``.
    public var ok: Bool
    public var error: String?

    public init(
        occurrenceAt: String,
        sessionId: String? = nil,
        finishedAt: String,
        ok: Bool,
        error: String? = nil
    ) {
        self.occurrenceAt = occurrenceAt
        self.sessionId = sessionId
        self.finishedAt = finishedAt
        self.ok = ok
        self.error = error
    }
}

/// Which model, thinking level and agent preset a run starts with.
public struct ScheduledTaskTarget: Sendable, Hashable, Codable {
    public var provider: String
    public var model: String
    /// The model's reasoning effort; empty for a model without one.
    public var effort: String
    /// The agent preset id; empty means the plugin's default.
    public var preset: String

    public init(provider: String, model: String, effort: String, preset: String) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.preset = preset
    }
}

/// One task from `scheduledTasks/list`.
///
/// `schedule` is a ``ScheduleEntry`` because the plugin's schedule record is the **same**
/// six-arm union with the same timing keys, minus the catalog intersection: reusing that
/// decode keeps one reader of ``ScheduleKind``'s trap — read `kind` first, then only that
/// arm's parameters — instead of a second one that can disagree.
///
/// The host also sends `runs`, its last twenty run records. It is deliberately not modelled:
/// `lastRun` is the newest of them, which is all a notification or a screen needs, and
/// carrying the rest would put a task's whole run history in every list response the phone
/// decodes on foreground.
public struct ScheduledTask: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var title: String
    /// Whether the task is armed. A disabled task keeps its history and stops firing.
    public var enabled: Bool
    /// The workspace a run joins; empty means the plugin's own setting.
    public var workspaceId: String
    public var createdAt: String
    public var updatedAt: String
    public var schedule: ScheduleEntry
    public var target: ScheduledTaskTarget
    /// The most recent run, or nil when the task has never run.
    public var lastRun: ScheduledTaskRun?

    public init(
        id: String,
        title: String,
        enabled: Bool,
        workspaceId: String,
        createdAt: String,
        updatedAt: String,
        schedule: ScheduleEntry,
        target: ScheduledTaskTarget,
        lastRun: ScheduledTaskRun? = nil
    ) {
        self.id = id
        self.title = title
        self.enabled = enabled
        self.workspaceId = workspaceId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schedule = schedule
        self.target = target
        self.lastRun = lastRun
    }
}

/// `scheduledTasks/list`'s result: `{ tasks: [...] }`.
///
/// An object with a `tasks` key — unlike `schedule/catalog`, which is a bare array. The two
/// list shapes on these two namespaces really are different, which is why each gets its own
/// decode rather than a guess at the other's envelope.
public struct ScheduledTaskList: Sendable, Hashable, Codable {
    public var tasks: [ScheduledTask]

    public init(tasks: [ScheduledTask]) {
        self.tasks = tasks
    }
}

/// ISO 8601 as the host writes it.
///
/// `scheduledAt` carries fractional seconds (`2026-10-13T12:00:00.000Z`) and a hand-edited
/// or older record may not, so both forms parse. `Date.ISO8601FormatStyle` rather than a
/// shared `ISO8601DateFormatter`: the formatter is a mutable class, and a static one would
/// be shared mutable state across the actors that read schedules.
public enum WireTimestamp {
    public static func date(from text: String) -> Date? {
        if let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return parsed
        }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(text)
    }
}
