import Foundation
import SwiftUI

/// The app's entry point. V1 navigation is Hosts → Sessions → Chat, so the app
/// opens on the host list; a host is unreachable until it is paired.
@main
struct DSHRemoteApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            // The design-system gallery, for reviewing the visual foundation.
            // Inert unless `DSH_DESIGN_GALLERY` is set on a debug build, so the
            // normal landing screen below is exactly what shipped before.
            if model.shouldShowDesignGalleryOnLaunch {
                ComponentGalleryView()
                    .environment(model)
            } else {
                HostsView()
                    .environment(model)
                    .onChange(of: scenePhase, initial: true) { _, phase in
                        switch phase {
                        case .active: model.setForeground(true)
                        case .background: model.setForeground(false)
                        case .inactive: break
                        @unknown default: break
                        }
                    }
                    .task(id: model.connectionID) {
                        await model.refreshSessions()
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
                    }
            }
        }
    }
}
