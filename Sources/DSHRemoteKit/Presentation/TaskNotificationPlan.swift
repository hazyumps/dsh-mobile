import Foundation

// Turning `scheduledTasks/list` into local notifications, and turning a notification tap
// back into a destination.
//
// Deliberately pure and free of `UserNotifications`: `UNUserNotificationCenter` is a system
// singleton with no protocol seam, so anything that touches it can only be exercised on a
// device or a simulator. Everything that can be *wrong* — which tasks earn a notification,
// how many, what they say, and where a tap goes — is decided here and tested offline. The
// app's job is then to translate this plan into `UNNotificationRequest`s, which is the part
// with no decisions left in it.
//
// What a local notification can honestly claim is the whole reason this is a *plan* rather
// than a delivery record: it fires whether or not the host was awake to run the task. So the
// wording says the task is due, never that it ran. Reporting what actually happened needs the
// task's `lastRun` after the fact, which is the background-refresh slice.

/// One notification to post.
public struct TaskNotification: Sendable, Hashable, Identifiable {
    /// Stable per (task, occurrence).
    ///
    /// Re-planning replaces a task's pending notification instead of adding a second one,
    /// because `UNUserNotificationCenter` keys pending requests by identifier. Epoch seconds
    /// rather than the host's own string, so the same occurrence written with or without
    /// fractional seconds is still the same identifier.
    public let id: String
    public let taskId: String
    public let title: String
    public let body: String
    /// When it should fire.
    public let fireAt: Date
    /// The run's session, when one is already known.
    ///
    /// Never set by ``TaskNotificationPlan/build(tasks:now:budget:)`` — a task that has not
    /// run yet has no session — but a delivery report does know one, so a tap can go
    /// straight to the conversation.
    public let sessionId: String?

    public init(id: String, taskId: String, title: String, body: String, fireAt: Date, sessionId: String? = nil) {
        self.id = id
        self.taskId = taskId
        self.title = title
        self.body = body
        self.fireAt = fireAt
        self.sessionId = sessionId
    }
}

/// Builds the pending-notification plan from a task list.
public enum TaskNotificationPlan {
    /// How many notifications to keep pending.
    ///
    /// iOS keeps at most 64 pending local notifications per app and silently drops the rest,
    /// so a plan that exceeds the ceiling is not a plan. Sixty leaves room for the
    /// "needs your input" notifications that share the same budget.
    public static let defaultBudget = 60

    /// The body for a task that is due now.
    ///
    /// "Scheduled to run", not "running" or "ran": this fires on the wall clock, and the host
    /// may be asleep, offline, or never have started the task at all.
    public static let dueBody = "Scheduled to run now"

    /// The soonest `budget` notifications for the tasks that are due in the future.
    ///
    /// A task is skipped — not defaulted — when it is disabled, when it reports no
    /// `scheduledAt`, when that value will not parse, or when it names an instant that has
    /// already passed. The last two matter: the host keeps the *last* next-occurrence on a
    /// task that has ended or been disabled, so a past `scheduledAt` means "nothing is armed",
    /// never "fire it now".
    public static func build(
        tasks: [ScheduledTask],
        now: Date,
        budget: Int = defaultBudget
    ) -> [TaskNotification] {
        guard budget > 0 else { return [] }
        var planned: [TaskNotification] = []
        for task in tasks {
            guard task.enabled, let fireAt = WireTimestamp.date(from: task.schedule.scheduledAt) else { continue }
            guard fireAt > now else { continue }
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            planned.append(TaskNotification(
                id: identifier(taskId: task.id, fireAt: fireAt),
                taskId: task.id,
                title: title.isEmpty ? "Scheduled task" : title,
                body: dueBody,
                fireAt: fireAt
            ))
        }
        // Soonest first, so truncation to the budget drops the furthest-out tasks rather
        // than an arbitrary prefix of the host's ordering. Ties broken by id so the plan is
        // deterministic rather than dependent on the host's list order.
        planned.sort { left, right in
            left.fireAt == right.fireAt ? left.id < right.id : left.fireAt < right.fireAt
        }
        return Array(planned.prefix(budget))
    }

    /// The pending-request identifier for one task's one occurrence.
    public static func identifier(taskId: String, fireAt: Date) -> String {
        "task.\(taskId).\(Int(fireAt.timeIntervalSince1970))"
    }
}

/// Where a notification tap should land.
public enum TaskNotificationDestination: Sendable, Hashable {
    /// A run whose session is known — the conversation.
    case conversation(sessionId: String)
    /// A task that has not run yet, or a run that never got a session: the task itself.
    case taskList(taskId: String)
}

/// The payload carried in a notification's `userInfo`, read back on tap.
///
/// Decoded from `[String: String]` rather than `[AnyHashable: Any]` so the mapping is
/// testable and so a payload the host or a future build adds a key to is ignored rather than
/// fatal — an unrecognised notification must do nothing, not crash.
public struct TaskNotificationPayload: Sendable, Hashable {
    public static let taskKey = "taskId"
    public static let sessionKey = "sessionId"

    public let taskId: String?
    public let sessionId: String?

    public init(taskId: String?, sessionId: String?) {
        self.taskId = taskId
        self.sessionId = sessionId
    }

    /// Reads the two keys out of a `userInfo` dictionary, ignoring everything else.
    public init(userInfo: [String: String]) {
        let task = userInfo[Self.taskKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = userInfo[Self.sessionKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.taskId = (task?.isEmpty ?? true) ? nil : task
        self.sessionId = (session?.isEmpty ?? true) ? nil : session
    }

    /// Where a tap goes, or nil when the payload names nothing this build can open.
    public var destination: TaskNotificationDestination? {
        if let sessionId { return .conversation(sessionId: sessionId) }
        if let taskId { return .taskList(taskId: taskId) }
        return nil
    }

    /// The `userInfo` for a planned notification.
    public var userInfo: [String: String] {
        var info: [String: String] = [:]
        if let taskId { info[Self.taskKey] = taskId }
        if let sessionId { info[Self.sessionKey] = sessionId }
        return info
    }
}
