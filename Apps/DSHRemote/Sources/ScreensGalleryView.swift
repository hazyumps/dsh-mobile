import DSHRemoteKit
import SwiftUI

/// Home and the drawer, rendered from fixture data.
///
/// The same reason the component gallery exists: the visual work has to be *looked at*
/// to be reviewed, and this machine has no Simulator GUI. Home only exists once a host
/// has been paired and has answered, so without this there is no way to see the layout
/// at all — and a screenshot is the whole review.
///
/// It renders the **real** ``HomeView`` and ``DrawerView`` against an ``AppModel`` seeded
/// with fixture state, rather than a lookalike screen: the thing being reviewed is the
/// shipping view, and a duplicate would be able to disagree with it. Inert unless
/// `DSH_SCREEN_GALLERY` is set, which no release build can read.
struct ScreensGalleryView: View {
    @Environment(AppModel.self) private var model

    /// Which screen to draw. `simctl` cannot tap, so the choice is made at launch:
    /// `DSH_SCREEN_GALLERY=drawer` draws the drawer, anything else draws Home.
    private var screen: String {
        ProcessInfo.processInfo.environment["DSH_SCREEN_GALLERY"] ?? "home"
    }

    var body: some View {
        Group {
            if screen == "drawer" {
                drawer
            } else {
                HomeView()
            }
        }
        .task { model.seedForScreensGallery() }
    }

    /// The drawer stands alone here because that is how it is presented: Home's own
    /// overlay adds the dimmed backdrop, which is a two-line wrapper around this panel.
    private var drawer: some View {
        ZStack(alignment: .leading) {
            DSHPalette.canvas.ignoresSafeArea()
            DrawerView(
                close: {},
                openSession: { _ in },
                openWorkspace: { _ in },
                openSettings: {}
            )
            .frame(maxWidth: 340)
        }
    }
}

extension AppModel {
    /// Puts the app in the state Home and the drawer render from.
    ///
    /// Fixture values only — no connection, no credential, no store. The screen it
    /// produces is real; the data behind it is not, and nothing here claims otherwise.
    /// Reachable only through ``shouldShowScreenGalleryOnLaunch``.
    func seedForScreensGallery() {
        let workspaces = [
            BrowseWorkspace(
                id: "workspace-dsh-mobile",
                title: "dsh-mobile",
                path: "/Users/patrick/repo/dsh-mobile",
                sessions: [
                    BrowseSession(
                        id: "session-example-1",
                        title: "Wire the workspace registry into Home",
                        running: true,
                        updatedAt: Date().addingTimeInterval(-90),
                        isSubagent: false
                    ),
                    BrowseSession(
                        id: "session-example-2",
                        title: "Conversation reducer: live deltas and the cursor seed",
                        running: false,
                        updatedAt: Date().addingTimeInterval(-3_600),
                        isSubagent: false
                    ),
                    BrowseSession(
                        id: "session-example-subagent",
                        title: "Subagent: fixture coverage sweep",
                        running: true,
                        updatedAt: Date().addingTimeInterval(-600),
                        isSubagent: true
                    ),
                ]
            ),
            BrowseWorkspace(
                id: "workspace-gaia",
                title: "gaia",
                path: "/Users/patrick/repo/gaia",
                sessions: [
                    BrowseSession(
                        id: "session-example-3",
                        title: "sync-dsh: render the home patch from models.yml",
                        running: false,
                        updatedAt: Date().addingTimeInterval(-86_400),
                        isSubagent: false
                    )
                ]
            ),
            BrowseWorkspace(
                id: "workspace-cortex",
                title: "cortex",
                path: nil,
                sessions: []
            ),
        ]
        let host = SavedHost(
            displayName: "patrick-mac",
            origin: URL(string: "https://10.1.0.138:3443")!,
            pinnedFingerprint: "7pcXvn2Kosz4qWgFpUmIao9YQ05bXYTLbfP0IskaeN4="
        )
        seedForGallery(
            host: host,
            status: .connected,
            browse: BrowseState(
                workspaces: workspaces,
                workspacesState: .current,
                sessionsState: .current
            ),
            workspaceId: workspaces.first?.id
        )
    }
}
