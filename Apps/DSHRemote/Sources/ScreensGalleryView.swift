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
    /// `DSH_SCREEN_GALLERY=drawer|project|new` draws one of those, anything else draws Home.
    private var screen: String {
        ProcessInfo.processInfo.environment["DSH_SCREEN_GALLERY"] ?? "home"
    }

    var body: some View {
        Group {
            switch screen {
            case "drawer": drawer
            case "conversation": conversation
            // The two screens the redesign added, reachable by tap in the app and by
            // environment variable here, because a simulator cannot tap.
            // Both of these are pushed screens in the app, so they are wrapped in the
            // stack that gives them their bar — reviewed without it they draw no title at
            // all, which is a fact about the harness rather than about the screen.
            case "project":
                NavigationStack {
                    ProjectSessionsView(
                        workspaceId: "workspace-dsh-mobile",
                        startSession: {}
                    )
                }
            case "new":
                NavigationStack {
                    NewSessionView(onCreated: { _ in })
                }
            case "subagents":
                // #13's screen. The roster is seeded because the real one needs a host that has
                // delegated something, and the shapes here are the captured ones: a running child
                // whose turn is open, one whose last turn completed, one whose last turn did not,
                // and one the session index has not reported at all.
                NavigationStack {
                    SubagentsView(
                        parentSessionId: "session-example-1",
                        seededRoster: Self.subagentFixture(now: SystemEpochClock().epochMillis())
                    )
                }
            case "home-cert-changed":
                // #89's banner, reviewed the same way: Home seeded into host-unavailable
                // with the certificate-changed error, so the Re-pair door is reachable
                // on a machine that cannot tap it.
                HomeView()
            default: HomeView()
            }
        }
        .task { model.seedForScreensGallery(screen: screen) }
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
                // An earlier reply with a straight-edged glyph in both left corners: the "T"
                // that opens it and the "n" that opens its last line, which a rounded clip
                // shaves (#74). Both lines are far wider than 2 × cardCornerRadius, because
                // SwiftUI shrinks the radius of a narrower box and a clip there cuts nothing.
                // It sits first so it is on screen without scrolling.
                ConversationMessage(
                    id: "seq:9",
                    role: .assistant,
                    text: "The step ended before its durable record landed.\n\nno more frames arrived after that one.",
                    isProvisional: false,
                    reasoning: nil
                ),
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

    /// A roster with the four states the real one can show, in the shapes the host sends.
    ///
    /// The values are invented relative to `now`; the *shapes* are the captured ones. Rendering
    /// from the capture itself would show a three-month duration on a child whose turn closed the
    /// same afternoon, because `settledMs` is a duration and `active` is absolute.
    private static func subagentFixture(now: Int64) -> SubagentRoster {
        let catalog: [JSONValue] = [
            .object(["mode": .string("continuable"), "label": .string("Map the relay's fence"), "id": .string("subagent-1"), "createdAt": .int(now - 3_600_000)]),
            .object(["mode": .string("continuable"), "label": .string("Review the mux frame bound"), "id": .string("subagent-2"), "createdAt": .int(now - 7_200_000)]),
            .object(["mode": .string("continuable"), "label": .string("Sweep fixture coverage"), "id": .string("subagent-3"), "createdAt": .int(now - 9_000_000)]),
            // An unlabelled one-shot row: the descriptor makes `label` optional there, so the row
            // falls back to its session id.
            .object(["mode": .string("one-shot"), "id": .string("subagent-4"), "createdAt": .int(now - 10_800_000)]),
            // And one the session index has not reported at all, which gets a row and nothing else.
            .object(["mode": .string("continuable"), "label": .string("Not in the index yet"), "id": .string("subagent-5"), "createdAt": .int(now - 11_400_000)]),
        ]
        return SubagentRoster(catalog: catalog, facts: [
            "subagent-1": SubagentFacts(
                projections: [
                    "subagentTiming": .object([
                        "settledMs": .int(412_000),
                        "active": .object(["since": .int(now - 96_000), "through": .int(now - 1_000)]),
                    ]),
                    "tokenUsage": .object([
                        "uncachedInputTokens": .int(48_120),
                        "outputTokens": .int(9_840),
                        "cacheReadTokens": .int(1_204_880),
                        "cacheWriteTokens": .int(0),
                    ]),
                ],
                title: "Trace a fence refusal through the relay",
                isRunning: true
            ),
            "subagent-2": SubagentFacts(
                projections: [
                    "subagentTiming": .object(["settledMs": .int(2_760_000), "lastTurnCompleted": .bool(true)]),
                    "tokenUsage": .object([
                        "uncachedInputTokens": .int(120_400),
                        "outputTokens": .int(31_220),
                        "cacheReadTokens": .int(8_402_000),
                        "cacheWriteTokens": .int(0),
                    ]),
                ],
                title: "Read the mux framing rules",
                isRunning: false
            ),
            // An interrupted turn: `active` with no `turn/end`, and a last turn that did not
            // complete. The duration is bounded by `through`, so it stopped where the work did.
            "subagent-3": SubagentFacts(
                projections: [
                    "subagentTiming": .object([
                        "settledMs": .int(64_500),
                        "active": .object(["since": .int(now - 900_000), "through": .int(now - 640_000)]),
                        "lastTurnCompleted": .bool(false),
                    ]),
                    "tokenUsage": .object([
                        "uncachedInputTokens": .int(6_100),
                        "outputTokens": .int(820),
                        "cacheReadTokens": .int(0),
                        "cacheWriteTokens": .int(0),
                    ]),
                ],
                title: "Pin the polymorphic surfaceOp shape",
                isRunning: false
            ),
            // The unlabelled one-shot from the catalog: it has a real state, and its row is still
            // named by its session id because the catalog gave it no label.
            "subagent-4": SubagentFacts(
                projections: [
                    "subagentTiming": .object(["settledMs": .int(154_000), "lastTurnCompleted": .bool(true)]),
                    "tokenUsage": .object([
                        "uncachedInputTokens": .int(9_400),
                        "outputTokens": .int(1_260),
                        "cacheReadTokens": .int(88_000),
                        "cacheWriteTokens": .int(0),
                    ]),
                ],
                title: "One-shot: pin the JSONValue shape",
                isRunning: false
            ),
            // No facts at all: the session index has not reported this child. It still lists — the
            // catalog is membership — with no activity, no duration and no token total rather than
            // with zeroes.
            "subagent-5": SubagentFacts(projections: [:], title: nil, isRunning: nil),
        ])
    }

    /// The drawer stands alone here because that is how it is presented: Home's own
    /// overlay adds the dimmed backdrop, which is a two-line wrapper around this panel.
    private var drawer: some View {
        ZStack(alignment: .leading) {
            DSHPalette.canvas.ignoresSafeArea()
            DrawerView(
                close: {},
                open: { _ in }
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
    func seedForScreensGallery(screen: String = "home") {
        let workspaces = [
            BrowseWorkspace(
                id: "workspace-dsh-mobile",
                title: "dsh-mobile",
                path: "/Users/example/repo/dsh-mobile",
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
                path: "/Users/example/repo/gaia",
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
        // #89's banner state seeds the status and the carried error together, because
        // the notice is the pair (SPEC §3.1's status has no certificate word); every
        // other screen renders the connected fixture.
        let certificateChanged = screen == "home-cert-changed"
        seedForGallery(
            host: host,
            status: certificateChanged ? .hostUnavailable : .connected,
            browse: BrowseState(
                workspaces: workspaces,
                workspacesState: .current,
                sessionsState: .current
            ),
            workspaceId: workspaces.first?.id,
            lastError: certificateChanged
                ? .certificateChanged(detail: "the relay's certificate no longer matches the pin this phone trusts")
                : nil
        )
    }
}
