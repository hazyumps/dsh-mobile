import Foundation
import Testing
@testable import DSHRemoteKit

// Turning a task list into local notifications, and a notification tap back into a
// destination, without `UserNotifications` anywhere near the test.
//
// Two rules are the reason this is a plan and not a delivery record, and both are asserted
// here rather than left to the wording of a notification body:
//
//   * a due task is *due*, so the notification says so and never claims a run happened;
//   * a `scheduledAt` in the past is a task that has stopped, not one that is late — the
//     host keeps the last next-occurrence on a disabled or finished task.

@Suite("Task notification plan")
struct TaskNotificationPlanTests {
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)  // 2025-10-07T…Z

    /// Build one task at a fixed distance from `now`.
    private func task(
        id: String,
        enabled: Bool = true,
        secondsFromNow: Double?,
        scheduledAt: String? = nil,
        kind: String = "every",
        everySeconds: Int = 3600,
        title: String = "Morning brief"
    ) throws -> ScheduledTask {
        let stamp: String
        if let scheduledAt {
            stamp = scheduledAt
        } else if let secondsFromNow {
            stamp = Self.iso(Self.now.addingTimeInterval(secondsFromNow))
        } else {
            stamp = ""
        }
        let timing = kind == "every" ? #""everySeconds":\#(everySeconds),"# : ""
        let json = """
        {"id":"\(id)","title":"\(title)","enabled":\(enabled),"workspaceId":"","createdAt":"2026-01-01T00:00:00Z",
         "updatedAt":"2026-01-01T00:00:00Z",
         "schedule":{"id":"\(id)","kind":"\(kind)","title":"\(title)","prompt":"p",\(timing)"scheduledAt":"\(stamp)"},
         "target":{"provider":"p","model":"m","effort":"","preset":""}}
        """
        return try JSONDecoder().decode(ScheduledTask.self, from: Data(json.utf8))
    }

    private static func iso(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: false).format(date)
    }

    // MARK: - Which tasks earn a notification

    @Test("an armed task due in the future earns one notification that says it is due, not that it ran")
    func armedTaskIsPlanned() throws {
        let plan = try TaskNotificationPlan.build(
            tasks: [task(id: "a", secondsFromNow: 3600)],
            now: Self.now
        )

        #expect(plan.count == 1)
        let notification = try #require(plan.first)
        #expect(notification.taskId == "a")
        #expect(notification.title == "Morning brief")
        #expect(notification.body == TaskNotificationPlan.dueBody)
        #expect(notification.fireAt == Self.now.addingTimeInterval(3600))
        // A task that has not run yet has no session, so a tap cannot land in one.
        #expect(notification.sessionId == nil)
    }

    @Test("a disabled task earns nothing, whatever its next occurrence says")
    func disabledTaskIsSkipped() throws {
        let plan = try TaskNotificationPlan.build(
            tasks: [task(id: "a", enabled: false, secondsFromNow: 3600)],
            now: Self.now
        )
        #expect(plan.isEmpty)
    }

    /// The trap: the host leaves the previous occurrence on a task that has ended or been
    /// switched off, so a past instant means "nothing is armed". Firing it now would be a
    /// notification for something that will not happen.
    @Test("a scheduledAt in the past earns nothing rather than firing immediately")
    func pastOccurrenceIsSkipped() throws {
        let plan = try TaskNotificationPlan.build(
            tasks: [task(id: "a", secondsFromNow: -60)],
            now: Self.now
        )
        #expect(plan.isEmpty)
    }

    @Test("an absent or unparseable scheduledAt earns nothing rather than a guess")
    func unreadableOccurrenceIsSkipped() throws {
        let absent = try task(id: "a", secondsFromNow: nil)
        let nonsense = try task(id: "b", secondsFromNow: nil, scheduledAt: "tomorrow morning")
        let blank = try task(id: "c", secondsFromNow: nil, scheduledAt: "")

        let plan = TaskNotificationPlan.build(tasks: [absent, nonsense, blank], now: Self.now)
        #expect(plan.isEmpty)
    }

    // MARK: - Ordering and the ceiling

    @Test("notifications are ordered soonest first")
    func orderedSoonestFirst() throws {
        let plan = try TaskNotificationPlan.build(
            tasks: [
                task(id: "late", secondsFromNow: 7200),
                task(id: "soon", secondsFromNow: 600),
                task(id: "middle", secondsFromNow: 3600),
            ],
            now: Self.now
        )
        #expect(plan.map(\.taskId) == ["soon", "middle", "late"])
    }

    /// iOS keeps 64 pending local notifications per app and drops the rest without saying so,
    /// so exceeding the budget is not a bigger plan — it is a plan that silently loses its
    /// tail.
    @Test("more tasks than the budget keeps the soonest ones")
    func budgetKeepsTheSoonest() throws {
        let tasks = try (0..<100).map { index in
            try task(id: "t\(index)", secondsFromNow: Double(index + 1) * 60)
        }

        let plan = TaskNotificationPlan.build(tasks: tasks, now: Self.now, budget: 60)
        #expect(plan.count == 60)
        #expect(plan.first?.taskId == "t0")
        #expect(plan.last?.taskId == "t59")

        let none = TaskNotificationPlan.build(tasks: tasks, now: Self.now, budget: 0)
        #expect(none.isEmpty)
    }

    // MARK: - Identity, so a re-plan replaces rather than duplicates

    @Test("one task's one occurrence has one identifier, and a second occurrence has another")
    func identifiersAreStablePerOccurrence() throws {
        let first = try task(id: "a", secondsFromNow: 3600)
        let replanned = try task(id: "a", secondsFromNow: 3600)
        let nextOccurrence = try task(id: "a", secondsFromNow: 7200)

        let before = try #require(TaskNotificationPlan.build(tasks: [first], now: Self.now).first)
        let after = try #require(TaskNotificationPlan.build(tasks: [replanned], now: Self.now).first)
        let later = try #require(TaskNotificationPlan.build(tasks: [nextOccurrence], now: Self.now).first)

        #expect(before.id == after.id)
        #expect(before.id != later.id)
        // The identifier names the task, so a stale pending request is attributable.
        #expect(before.id.hasPrefix("task.a."))
    }

    // MARK: - Where a tap goes

    @Test("a payload with a session opens the conversation, even when it also names the task")
    func sessionWinsTheRoute() {
        let payload = TaskNotificationPayload(taskId: "a", sessionId: "session-9")
        #expect(payload.destination == .conversation(sessionId: "session-9"))
        #expect(payload.userInfo == ["taskId": "a", "sessionId": "session-9"])
    }

    @Test("a payload with only a task opens the task list")
    func taskOnlyRoutesToTheList() {
        let payload = TaskNotificationPayload(userInfo: ["taskId": "a"])
        #expect(payload.destination == .taskList(taskId: "a"))
    }

    /// A notification this build cannot place must do nothing. Crashing or opening an
    /// arbitrary screen is worse than the tap being ignored.
    @Test("an empty or unrecognised payload routes nowhere")
    func unrecognisedPayloadRoutesNowhere() {
        #expect(TaskNotificationPayload(userInfo: [:]).destination == nil)
        #expect(TaskNotificationPayload(userInfo: ["somethingElse": "x"]).destination == nil)
        // A blank value is not an id.
        #expect(TaskNotificationPayload(userInfo: ["sessionId": "   "]).destination == nil)
    }

    @Test("a payload survives the round trip through userInfo")
    func payloadRoundTrips() {
        let original = TaskNotificationPayload(taskId: "a", sessionId: "session-9")
        let restored = TaskNotificationPayload(userInfo: original.userInfo)
        #expect(restored == original)
    }
}
