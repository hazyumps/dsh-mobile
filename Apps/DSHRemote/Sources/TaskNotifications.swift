import DSHRemoteKit
import Foundation
import Observation
import UserNotifications

// The phone's own reminders for scheduled tasks.
//
// This file is the only place in the app that touches `UserNotifications`, and it holds no
// decisions: which tasks earn a reminder, what it says, and where a tap goes are all
// ``TaskNotificationPlan`` in the kit, which is testable offline. What is left here is the
// translation into `UNNotificationRequest`s and the reading back of the system's
// authorization state — neither of which a unit test can exercise, because
// `UNUserNotificationCenter.current()` is a process-wide singleton with no seam.
//
// The one rule worth stating twice: applying a plan always clears the reminders this app
// owns that the plan no longer contains, and it does that even when notifications are not
// authorized. Turning notifications off in iOS Settings must not leave a plan pending that
// starts firing the moment they are turned back on.

/// The phone's own reminders for scheduled tasks, and their authorization state.
@MainActor
@Observable
final class TaskNotificationScheduler {
    /// Every pending request this app owns starts with this, so clearing its own stale
    /// reminders can never touch a notification somebody else scheduled.
    static let identifierPrefix = "task."

    /// What the user has allowed. `.notDetermined` until the system is asked.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// How many reminders the plan currently has pending, once a plan has been applied.
    private(set) var pendingCount = 0
    /// Why the last apply could not schedule, when it could not.
    private(set) var lastError: String?

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Reads the current authorization without prompting.
    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Asks for permission. Called from Settings, never on launch: a prompt with no context
    /// is the one people decline.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
            return granted
        } catch {
            lastError = error.localizedDescription
            await refreshAuthorization()
            return false
        }
    }

    /// Makes the pending reminders exactly the plan's.
    ///
    /// Replace-by-identifier rather than remove-everything-then-add: a reminder for a task
    /// whose next occurrence has not moved keeps its place in the queue, so re-planning on
    /// every foreground does not churn the order iOS will deliver them in.
    func apply(plan: [TaskNotification]) async {
        await refreshAuthorization()
        lastError = nil

        let wanted = Set(plan.map(\.id))
        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) && !wanted.contains($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        guard authorization.allowsDelivery else {
            // Deliberately after the clear: a denied app must end up with no pending plan,
            // not with a frozen one.
            pendingCount = await center.pendingNotificationRequests()
                .filter { $0.identifier.hasPrefix(Self.identifierPrefix) }.count
            return
        }

        for reminder in plan {
            try? await center.add(request(for: reminder))
        }
        pendingCount = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(Self.identifierPrefix) }.count
    }

    /// Removes every reminder this app owns. Used when the selected host is forgotten, so a
    /// task list the phone can no longer read cannot keep firing.
    func cancelAll() async {
        let owned = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        if !owned.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: owned)
        }
        pendingCount = 0
    }

    /// One reminder, as the system wants it.
    private func request(for reminder: TaskNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        // Only the two keys a tap needs. `TaskNotificationPayload` ignores anything else, so
        // a payload from a future build does nothing rather than surprising this one.
        content.userInfo = TaskNotificationPayload(
            taskId: reminder.taskId,
            sessionId: reminder.sessionId
        ).userInfo

        // Calendar components rather than a time interval: a reminder is for a wall-clock
        // occurrence, and the host stores it in an IANA zone precisely so that DST does not
        // move it. An interval computed now would be right until the clocks changed.
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: reminder.fireAt
        )
        return UNNotificationRequest(
            identifier: reminder.id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
    }
}

/// Routes a notification the user interacted with back into the app.
///
/// `UNUserNotificationCenter.delegate` is set once, at launch, which is *before* a host is
/// selected — so the tap is handed to ``AppModel``, which knows whether it can route it yet
/// or has to hold it until a host exists.
///
/// Deliberately **not** `@MainActor`. The protocol's methods take non-Sendable `UNNotification`
/// values, so a main-actor-isolated conformance cannot be called from the system at all. This
/// stays nonisolated, extracts the two `String`s it needs, and hops with only those.
final class TaskNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// The tap handler.
    ///
    /// `@MainActor @Sendable` so the value itself may cross to the main actor. The storage is
    /// `nonisolated(unsafe)` for the one reason it is safe: it is written once at launch,
    /// before the app can be delivered a notification, and only ever read afterwards.
    nonisolated(unsafe) var onTap: (@MainActor @Sendable (TaskNotificationPayload) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let payload = TaskNotificationPayload(userInfo: Self.strings(response.notification.request.content.userInfo))
        let onTap = self.onTap
        await MainActor.run { onTap?(payload) }
    }

    /// A reminder that arrives while the app is open still shows.
    ///
    /// The default is to swallow it, which would make the app look broken exactly when the
    /// user is watching — and there is no in-app banner to replace it with.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// `userInfo` is `[AnyHashable: Any]`; only string keys with string values are ours.
    private static func strings(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, let value = value as? String else { continue }
            result[key] = value
        }
        return result
    }
}

extension UNAuthorizationStatus {
    /// Whether a planned reminder can actually be delivered in this state.
    ///
    /// `.provisional` is a delivery state — quiet notifications, no prompt — and treating it
    /// as "not authorized" would silently drop every reminder for a user who chose it.
    /// `.ephemeral` is the App Clip state and behaves the same way for this purpose.
    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        case .denied, .notDetermined: false
        @unknown default: false
        }
    }

    /// The sentence Settings shows for this state.
    var dshDescription: String {
        switch self {
        case .authorized: "On."
        case .provisional: "On, delivered quietly."
        case .ephemeral: "On for this session."
        case .denied: "Off. Turn them on in iOS Settings."
        case .notDetermined: "Not asked yet."
        @unknown default: "Unknown."
        }
    }
}
