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
            } else if screen == "conversation" {
                conversation
            } else {
                HomeView()
            }
        }
        .task { model.seedForScreensGallery() }
    }

    /// A conversation with the constructs a real one carries: prose, a fenced block,
    /// collapsed reasoning, an activity card, a gap, older history, and a batch of
    /// questions. The values are invented; the *shapes* are the ones the client folds
    /// out of the wire.
    private var conversation: some View {
        ScrollView {
            ConversationTranscript(snapshot: Self.conversationFixture)
                .padding(.horizontal, DSHMetrics.pageMargin)
                .padding(.vertical, DSHMetrics.cardCornerRadius)
        }
        .background(DSHPalette.canvas)
    }

    private static var conversationFixture: ConversationSnapshot {
        ConversationSnapshot(
            generation: 1,
            messages: [
                ConversationMessage(
                    id: "seq:10",
                    role: .user,
                    text: "Why did the feed stop mid-turn?",
                    isProvisional: false,
                    reasoning: nil
                ),
                ConversationMessage(
                    id: "seq:11",
                    role: .assistant,
                    text: """
                    ## Why it stopped

                    The step ended without a matching durable record, so the window kept \
                    the preview until it could prove what happened.

                    - **The preview is provisional** until a durable record lands.
                    - The cursor only advances on committed sequence numbers.
                      - A nested note, to check indentation.
                    1. Check the expectation first.
                    2. Then the frame that follows.

                    | Source | Effect |
                    | --- | --- |
                    | `$events` | carries the committed sequence |
                    | `session/follow` | replaces the baseline |

                    > A late frame from a retired generation must not answer.

                    ```sh
                    swift test --disable-sandbox --filter ChatSessionTests
                    ```

                    Then the next `$events` frame carried the committed sequence.

                    ---
                    """,
                    isProvisional: false,
                    reasoning: "Check the sequence expectation first: cursor + 1, not one past the highest record."
                ),
                ConversationMessage(
                    id: "attempt:live",
                    role: .assistant,
                    text: "Checking whether the settlement arrived out of order…",
                    isProvisional: true,
                    reasoning: nil
                ),
            ],
            unmodelledEvents: [
                DurableEventEnvelope(
                    type: "agent/inbox/spliced",
                    seq: 12,
                    time: 1,
                    data: .object(["name": .string("inbox")]),
                    surfaceOp: nil
                )
            ],
            hasSnapshot: true,
            hasGap: true,
            isStreaming: true,
            followError: nil,
            pendingQuestions: [
                PendingQuestion(
                    id: "q-1",
                    callId: "call-1",
                    header: "Recovery",
                    question: "Re-run the suite against the captured frames?",
                    options: [
                        .init(label: "Re-run the tests", detail: "swift test, offline"),
                        .init(label: "Skip for now", detail: nil),
                    ],
                    allowsMultiple: false
                ),
                PendingQuestion(
                    id: "q-2",
                    callId: "call-1",
                    header: "Recovery",
                    question: "Which baseline should the next check use?",
                    options: [
                        .init(label: "The captured snapshot", detail: nil),
                        .init(label: "A scratch session", detail: nil),
                    ],
                    allowsMultiple: true
                ),
            ],
            cursor: 31,
            canLoadOlder: true,
            isLoadingOlder: false,
            pageError: nil
        )
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
                openSettings: {},
                openPlugins: {},
                openSchedules: {},
                openUsage: {},
                openNewSession: {}
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
                        isSubagent: false,
                        needsInput: false,
                        isLoaded: true
                    ),
                    BrowseSession(
                        id: "session-example-2",
                        title: "Conversation reducer: live deltas and the cursor seed",
                        running: false,
                        updatedAt: Date().addingTimeInterval(-3_600),
                        isSubagent: false,
                        needsInput: true,
                        isLoaded: true
                    ),
                    BrowseSession(
                        id: "session-example-subagent",
                        title: "Subagent: fixture coverage sweep",
                        running: true,
                        updatedAt: Date().addingTimeInterval(-600),
                        isSubagent: true,
                        needsInput: true,
                        isLoaded: true
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
                        isSubagent: false,
                        needsInput: false,
                        isLoaded: true
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
