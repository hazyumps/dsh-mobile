import DSHRemoteKit
import Foundation
import SwiftUI
import UserNotifications

/// The app's entry point.
///
/// UX spec "Navigation and returning to work" replaces v1's Hosts → Sessions → Chat:
/// the root is the current host's work, with the drawer for switching context, and host
/// administration moves into Settings. So the shell has exactly two shapes — the pairing
/// introduction when nothing is selected, and Home once something is.
@main
struct DSHRemoteApp: App {
    @State private var model = AppModel()
    @State private var notifications = TaskNotificationDelegate()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                // The design-system gallery, for reviewing the visual foundation.
                // Inert unless `DSH_DESIGN_GALLERY` is set on a debug build, so the
                // normal landing screen below is exactly what shipped before.
                if model.shouldShowDesignGalleryOnLaunch {
                    ComponentGalleryView()
                } else if model.shouldShowScreenGalleryOnLaunch {
                    // The screens above the components, from fixture data. Same reason:
                    // this machine has no Simulator GUI, and Home only exists once a
                    // host has answered.
                    ScreensGalleryView()
                } else {
                    RootView()
                }
            }
            .environment(model)
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active: model.setForeground(true)
                case .background: model.setForeground(false)
                case .inactive: break
                @unknown default: break
                }
            }
            .task {
                // The delegate must be installed before the app finishes launching, or a tap
                // that launched it is dropped on the floor with no error anywhere.
                notifications.onTap = { [model] payload in model.handleTaskNotification(payload) }
                UNUserNotificationCenter.current().delegate = notifications
                await model.taskNotifications.refreshAuthorization()

                // Verification affordance, debug builds only: a harness can
                // seed pairing by passing `DSH_PAIRING_PAYLOAD`, so the whole
                // flow can be exercised on a simulator with no keyboard and no
                // GUI. It runs the ordinary `claim` path — the same code the
                // paste field calls — rather than a parallel one.
                #if DEBUG
                if let pasted = ProcessInfo.processInfo.environment["DSH_PAIRING_PAYLOAD"],
                   !pasted.isEmpty {
                    await model.claim(pasted: pasted)
                }
                #endif
                // The galleries are review modes, not the app: restoring a host there
                // would let a live snapshot overwrite the seeded fixtures mid-review,
                // which is exactly what happened the first time the drawer was shot.
                guard !model.shouldShowScreenGalleryOnLaunch,
                      !model.shouldShowDesignGalleryOnLaunch
                else { return }
                #if DEBUG
                // `simctl` cannot tap a notification, so the tap is injected as the payload
                // the delegate would have handed over — `DSH_NOTIFICATION=task:<id>` or
                // `session:<id>`. Injected *before* the host is restored on purpose: that is
                // the cold-launch case, where the tap has to be held until there is somewhere
                // to route it.
                if let probe = ProcessInfo.processInfo.environment["DSH_NOTIFICATION"] {
                    let parts = probe.split(separator: ":", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        switch parts[0] {
                        case "task": model.handleTaskNotification(TaskNotificationPayload(taskId: parts[1], sessionId: nil))
                        case "session": model.handleTaskNotification(TaskNotificationPayload(taskId: nil, sessionId: parts[1]))
                        default: break
                        }
                    }
                }
                #endif
                await model.restoreLastHost()
            }
        }
    }
}

/// The two shapes of the app: nothing chosen, or a host's work.
private struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.selectedHost == nil {
            HostsView()
        } else {
            HomeView()
        }
    }
}
