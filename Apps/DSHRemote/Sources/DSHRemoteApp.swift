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
        }
    }
}
