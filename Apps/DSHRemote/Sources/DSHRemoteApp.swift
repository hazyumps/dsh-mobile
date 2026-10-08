import Foundation
import SwiftUI

/// The app's entry point. V1 navigation is Hosts → Sessions → Chat, so the app
/// opens on the host list; a host is unreachable until it is paired.
@main
struct DSHRemoteApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HostsView()
                .environment(model)
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
