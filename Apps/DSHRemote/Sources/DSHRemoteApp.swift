import Foundation
import SwiftUI

/// The app's entry point.
///
/// UX spec "Navigation and returning to work" replaces v1's Hosts → Sessions → Chat:
/// the root is the current host's work, with the drawer for switching context, and host
/// administration moves into Settings. So the shell has exactly two shapes — the pairing
/// introduction when nothing is selected, and Home once something is.
@main
struct DSHRemoteApp: App {
    @State private var model = AppModel()
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
