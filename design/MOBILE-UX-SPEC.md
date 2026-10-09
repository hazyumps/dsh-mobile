# DeepSeek Harness iPhone experience specification

Date: 2026-10-09  
Status: implementation direction based on Patrick’s feedback and the third visual pass  
Platform: native SwiftUI, iOS 18 and later, iPhone

The app should feel like the DeepSeek Harness web app Patrick already uses, adapted for a phone. Keep its identity, workspace organization, dark surfaces, and conversation flow. Use the rounded cards, readable spacing, and reachable controls from the mobile concepts.

Opening the app should return Patrick to his work. A saved host reconnects automatically, the conversation catches up, and an unfinished draft remains available. Reconnecting to an already trusted host never requires an approval.

This specification replaces the original Hosts → Sessions → Chat navigation in [SPEC.md](../SPEC.md) and expands the product direction to include starting sessions. The original specification remains the protocol and security baseline where this document does not explicitly change a product requirement. Generated protocol models establish available shapes; they do not establish that a feature has been integrated or tested on the phone.

The companion [engineering wiring specification](MOBILE-IMPLEMENTATION-SPEC.md) defines exact requests and subscriptions, state ownership, creation/send transactions, approval/question routes, attachment handling, and integration acceptance tests. Its host-source findings clarify the behavior described here; they do not mean the native features are already implemented.

## Visual references

| Reference | Use |
| --- | --- |
| Patrick’s supplied desktop screenshot | Primary identity reference: DeepSeek whale and wordmark, HARNESS tag, dark canvas, sidebar, workspace names, and new-session composition |
| [Home and workspace drawer](mockups/2026-10-09/01-home-and-workspaces.png) | Main navigation, home composition, session cards, and workspace hierarchy |
| [Conversation and recovery](mockups/2026-10-09/02-conversation-and-recovery.png) | Conversation density, tool cards, decision cards, composer, and retained context during recovery |
| [Earlier mobile pass](mockups/2026-10-08/pass-02/README.md) | Secondary reference for mobile readability and restrained presentation |

The images establish direction rather than exact pixel measurements. The sizes and colors below are implementation starting values. Illustrative session names, model labels, statuses, and text in the images are not hardcoded application data.

**Correction to the approval mockup:** “Apply the recovery changes?” illustrates an agent requesting permission to edit code. It is not a reconnect permission. Future screenshots should use an unambiguous example such as “Run this command?” with the actual command supplied by the host.

**Correction to the recovery mockup:** its composer is captioned “Send when reconnected”, which promises that a send will be queued and delivered on reconnect. This design does not do that — a phone disconnect never queues a send, and Send is disabled while offline because delivery could not be confirmed. The label should read as a disabled state with its reason (“Offline — reconnect to send”), not as a promise of later delivery. Reconciling an uncertain send is a deliberate user action, never an automatic replay.

## Product priorities

1. Resume the same work reliably after locking the phone or switching apps.
2. Make the app immediately recognizable as DeepSeek Harness.
3. Make reading, typing, switching sessions, and answering requests comfortable with one hand.
4. Preserve workspace, conversation, and draft context across navigation and interruptions.
5. Expose host features progressively as their native integration becomes dependable.

The phone is a companion to the host. Models, tools, workspaces, session execution, and configured Gaia capabilities remain on the harness host. A phone disconnect does not imply that execution stopped.

## Scope and implementation status

| Area | Required direction | State at this specification |
| --- | --- | --- |
| Branding and navigation | DeepSeek identity, workspace drawer, home, recent sessions | Mockups only; app still uses the original host-first navigation |
| Pairing and saved hosts | Pair once; remember credentials and chosen host | Existing paste-pairing and saved-host code; QR and polished management still needed |
| Foreground recovery | Automatic reconnect and subscription refresh | Implemented in the working tree; package tests and iOS build pass; physical-phone validation pending |
| Existing sessions | Group, search, open, and follow sessions | Basic list and chat exist; workspace registry, richer cards, and search still needed |
| New session | Start work within a selected existing workspace | Protocol descriptor and generated request exist; app flow and live round-trip still needed |
| Conversation | Readable Markdown, streaming, quiet tool cards, accessible history | Basic text rendering exists; full presentation and history UX still needed |
| Questions and approvals | Host-backed requests, clear scope, no duplicate submissions | Basic question answering exists; full question forms and permission integration still needed |
| Drafts | Persist per host and session, including a new-session draft | Current recovery retains the open view’s draft in memory; durable draft storage still needed |
| Model and mode selection | Host-derived choices with verified meaning | Installed source confirms mode is an agent preset; native integration and host round-trip tests remain |
| Attachments and commands | Native pickers and host-advertised commands | Required product capabilities; not claimed complete by the mockups |
| Plugins, schedules, MCP, usage | Familiar drawer entry points with useful native details | Capability-gated follow-up work; no assumption of desktop feature parity |
| Remote access | Stable address, retained pairing, automatic recovery | Architecture work remains; no tunnel or host identity change deployed |

A release must not present decorative controls as working features. An unavailable section is omitted, or clearly explains the required host capability when that explanation helps the user. Demonstration data stays in previews and tests.

## Visual system

### Identity and color

Use an existing, appropriately licensed DeepSeek whale/wordmark asset if the repository or upstream provides one. Verify the asset source before shipping. Do not recreate a production logo by cropping the generated mockup.

The compact brand lockup combines the whale, “deepseek,” and the small HARNESS tag. Show it on Home and the drawer. A conversation uses its title and workspace instead, giving the content more room.

| Token | Initial dark value | Purpose |
| --- | --- | --- |
| Canvas | `#141416` | Main page and conversation background |
| Navigation surface | `#1D1D1F` | Drawer and secondary panels |
| Card and composer | `#2A2A2D` | Session, tool, and decision cards; text entry |
| Elevated surface | `#323237` | Selected row or an expanded card area |
| Primary text | `#F5F5F7` | Titles, messages, primary labels |
| Secondary text | `#B0B2BB` | Workspace, timestamps, supporting copy |
| Divider | `#3B3D43` | Subtle separation and card edges |
| Primary action | `#526B96` | Send, selected choices, primary buttons |
| Success | `#41C86A` | Confirmed connected/running state, with a text label |
| Attention | `#E8A23A` | Waiting for input or recovering |
| Error | `#F07878` | Actionable failure text/icon, used sparingly |

Surfaces are mostly flat. Use a thin edge to distinguish cards rather than large shadows, glowing borders, or gradients. Let blue identify actions; avoid coloring every message or card blue.

Dark mode is the primary visual reference. Retain System, Light, and Dark appearance choices. Implement semantic colors so light mode has the same hierarchy rather than a literal inversion. Validate text contrast in both appearances.

### Type and spacing

| Element | Starting style | Behavior |
| --- | --- | --- |
| Home title | System title, approximately 26–28 pt, medium | “Into the Unknown”; may wrap on small screens |
| Conversation title | System headline, approximately 17 pt | One line normally; accessible full label |
| Message body | System body, approximately 17 pt | Natural line breaks, selectable text, comfortable line spacing |
| Card title | Approximately 16 pt, medium | Up to two lines in compact lists |
| Supporting text | Approximately 14 pt | Avoid low-contrast gray for actionable information |
| Metadata | Approximately 12–13 pt | Timestamps and status; never the only source of essential context |
| Code and paths | System monospaced text | Horizontal scrolling for code, selectable values |

Use Dynamic Type text styles instead of fixed-size text boxes. Default page margins are 16 pt. Use an 8 pt spacing rhythm, with 12–16 pt inside compact cards and 20–24 pt between major groups.

Cards use approximately 16 pt corner radii; the composer uses approximately 20 pt. Small chips use 8–12 pt or a capsule. Controls have at least a 44 × 44 pt hit area even when their symbol is smaller.

### Density and motion

Show enough of a conversation to read several paragraphs before scrolling. Assistant prose sits directly on the canvas. Cards are reserved for sessions, tools, attachments, decisions, and errors requiring action.

Use brief native transitions when opening the drawer, expanding a card, or changing focus. Respect Reduce Motion. Streaming updates should change text without animating the entire layout. Avoid unsolicited haptics for individual tokens or reconnect attempts.

## Navigation and returning to work

The root is the current host’s work, with a drawer for switching context. Host administration moves into Settings and the host row; it is not the normal landing screen after pairing.

| Situation | Destination |
| --- | --- |
| No saved host | Pairing introduction |
| First successful pairing | Home, with workspace selection |
| Return from background | Existing screen, cached content, same draft and scroll context; automatic refresh |
| Cold launch with a valid saved selection | Last session on the selected host; load fresh history without showing fabricated cached messages |
| Last session no longer accessible | Explain that state, preserve its draft, and offer the workspace’s sessions |
| No previous session | Home in the last selected workspace |
| Previously selected host unavailable | Preserve that host and context; recover automatically rather than silently switching hosts |

Persist host, workspace, and last-session identifiers separately. An address change must not create a new logical host or move drafts into a different account. Switching hosts is an explicit action and closes the previous host’s connection.

Use standard navigation and sheets for details. There is no required bottom tab bar. The drawer contains global destinations, workspaces, and recent sessions; the composer remains the dominant bottom control while chatting.

## Home and starting a session

### Layout

From top to bottom:

1. Compact toolbar: drawer control, DeepSeek Harness identity, contextual menu.
2. Host/status row showing the selected host and a text state.
3. Selected workspace context, where it adds useful orientation.
4. Whale and “Into the Unknown” heading, with generous but responsive spacing.
5. Workspace and mode controls.
6. Large rounded composer.
7. “Continue a session” with recent-session cards and “View all sessions.”

The “Preview” badge in the reference is optional release metadata. Show it only when it describes the actual app release. Do not reserve a permanent badge solely to match the image.

With the keyboard open, reduce the decorative heading area and prioritize the composer. On smaller phones, allow the page to scroll rather than squeezing controls. Stack workspace and mode selectors if they do not fit at accessible text sizes.

### Workspace and mode

The workspace selector opens a searchable native sheet of host workspaces. Use the host’s workspace identifier and canonical directory; do not infer a writable workspace from a display name or the phone’s filesystem.

The installed web source confirms that “Standard mode” selects an agent preset. Use the host roster and its actual preset identity; permission presets are a separate setting. The host locks agent-preset changes after the session's first turn starts, so the picker is primarily part of the new-session flow. A read-only, broken, or unsupported selection is visibly identified as such. The exact mapping and refusal handling are defined in the [engineering spec](MOBILE-IMPLEMENTATION-SPEC.md#6-model-and-mode-pickers).

The model control uses the host’s model catalog and current selection. Show the actual configured model label; “DeepSeek” in the image is illustrative. Never select a different backend because the mobile app prefers it.

### Sending the first prompt

The drawer’s New session action opens a new-session draft within the current workspace. It does not immediately create an empty host session. Create the session when the user submits the first prompt, subject to verified host behavior.

Capture the workspace, host, mode, model, text, and attachments at submission time. Once the host returns a session ID, bind the draft and screen to that ID before submitting the prompt. Reopening or retrying the UI must not create another session after creation was acknowledged.

If creation or delivery has an unknown outcome, preserve the draft and reconcile with the host before offering another submission. Installed host source now confirms explicit-session-ID adoption and prompt deduplication for this build. Use the persisted identities and transaction rules in the engineering spec; native round-trip tests remain required, and reconnect must never automatically replay a write.

If session creation is unsupported by the connected host, keep the existing-session experience usable and show “Start this session on your computer.” Do not show an enabled Send that cannot work.

## Workspace drawer and session browser

The drawer follows the web app’s organization:

- Brand lockup and a clearly reachable close control.
- Prominent New session button.
- Plugins, Scheduled tasks, MCP, and Usage when supported by the delivered app and connected host.
- Workspaces heading with search.
- Folder rows, with the selected workspace highlighted and expanded.
- Session rows nested under the expanded workspace.
- Host/status row and Settings at the bottom.

Use a leading overlay approximately 85–90% of the screen width, bounded to a sensible maximum on larger layouts. Keep a visible dismiss area and support tapping outside. At accessibility sizes, use a full-width presentation if the overlay would clip content. The drawer’s content scrolls; its footer must never cover the final workspace row.

Workspace rows have a folder icon, name, and expansion control. Session rows have a conversation icon and title. Keep the hierarchy clear with a modest indent and one optional guide line, not a deeply nested tree.

Search initially filters loaded workspace names and session titles. Label the scope; do not imply full-history server search. An empty search shows the query and a clear reset action.

“View all sessions” opens the selected workspace’s complete available list, with pagination if the host supplies it. Preserve list scroll position when returning from a conversation. A session card shows title, a short supporting line when available, and a meaningful status or last activity. Do not invent summaries from unread content.

| Session state | Presentation |
| --- | --- |
| Running, confirmed by host | Small green indicator and “Running” |
| Waiting for a decision | Amber indicator and “Needs your input” |
| Draft stored locally | “Draft saved” only after persistence succeeds |
| Inactive | Relative last activity, if supplied |
| Connection stale | Neutral cached presentation; do not keep asserting live running status |

Use the workspace registry as the source of organization. Grouping solely by session `cwd`, as the current app does, is a fallback and can miss empty workspaces or renamed labels.

## Conversation screen

### Header and transcript

The toolbar shows the drawer control, session title, workspace subtitle, and a menu. The menu opens session details and context actions that are actually supported. Keep model, mode, goal, plan, and usage details out of the main transcript unless relevant to the current action.

User messages use compact graphite bubbles aligned toward the trailing side, up to roughly 85% of content width. Assistant responses are leading-aligned text on the canvas. Both support selection and copying.

Render paragraphs, lists, headings, links, and fenced code. Code blocks have an explicit Copy action and horizontal scrolling. External links open only on a user tap. Preserve the existing rule against automatically fetching arbitrary remote images from message Markdown.

Reasoning is collapsed under a disclosure when the host provides it. It is separate from the final answer. Do not add ratings buttons or a permanent toolbar beneath every paragraph.

### Live output and history

Update existing message text as chunks arrive, even when the number of messages stays the same. A provisional assistant message becomes its durable counterpart without duplication.

Follow the live tail only when the user is already near the bottom. If the user is reading older text, retain the visible message anchor and show a “New activity” control. Loading older history must also preserve the anchor.

A reconnect keeps the current transcript visible until a fresh baseline arrives. Replace the baseline rather than merging unrelated generations. Do not clear the transcript simply because a network call failed. A missing or rejected baseline shows an explanation and a retry action, not an endless blank spinner.

### Tool cards

A collapsed tool card shows a familiar symbol, useful title, concise result summary, and state. The example “Inspect reconnect flow · 2 files checked” is appropriate only if the host supplied the action and enough result data to support that summary.

Expansion shows readable arguments and results, including exact commands or paths when relevant. Large output starts with a bounded preview and an explicit expansion control. Keep the full underlying event intact. Unknown tools receive a generic card instead of disappearing.

## Composer, commands, and attachments

The conversation composer stays above the keyboard and home indicator. It contains multiline text, an attachment button, the current model control when supported, and Send. Workspace/mode context can appear in a compact row above it; avoid repeating the same workspace label in multiple adjacent rows.

The text field grows to approximately six lines before scrolling internally. Draft text remains editable during a disconnect. Disable Send while offline, while waiting for the refreshed conversation baseline, while attachments are uploading, or while a send awaits acknowledgement. Explain the disabled state nearby when it is not obvious.

Do not replace an existing draft when a stream refresh arrives. Clear it only after confirmed prompt acceptance. If acceptance is uncertain, show “Delivery unconfirmed” and retain the draft; never automatically resend.

The attachment menu uses PhotosPicker and the system file importer. Each attachment chip shows name, preparation/upload state, and Remove. Use the limits, staging, and receipt rules in the protocol specification. An attachment belongs to the host/session draft that selected it, even if navigation changes during upload.

Typing `/` opens host-advertised command suggestions. Selecting one inserts or invokes it according to the verified command contract. Unknown slash text can be sent as ordinary prompt text, preserving the host’s skill behavior.

The host decides how a prompt behaves during active work. Show queued, refused, or accepted only when the response establishes that state. Do not label a normal prompt as an interrupt or steer action without verified support.

## Approvals and structured questions

Approvals concern an action the agent wants to perform. Reconnection, reading session state, and restoring a saved draft do not produce approval cards.

A pending approval shows the host’s reason, action, and scope. Use “Allow once” and “Reject” when those map to the actual request. Keep exact details available before submission. Do not add an “Always allow” control to this design.

Represent a pending request inline near its relevant activity. For a long conversation, use a compact “Needs your input” shortcut to bring it into view. Do not render two active copies of the same decision.

Question cards support the host’s full structure: multiple items, single or multiple selections, optional custom answers, and a deliberate Submit action. Use the request’s permitted responses rather than inferring options from prose.

On reconnect, keep historical decision cards as history but disable old pending controls until current host state confirms the request is still open. Reconcile active, answered, and withdrawn requests. Never replay an approval or question answer automatically. An uncertain answer is visibly uncertain, not silently treated as rejected or submitted again.

## Connection and loading behavior

Model transport state and screen data state separately. A ready authenticated socket can coexist with a session-loading error. Session-list failure must not reset pairing or turn “Connected” into “Host unavailable.”

| Condition | What the user sees | Automatic behavior | Available actions |
| --- | --- | --- | --- |
| First connection to saved host | “Connecting to Patrick’s Mac…” | Use saved credential and existing trust policy | Read cached context; type a draft |
| Socket ready, data pending | “Connected” plus “Updating conversation…” or “Reading sessions…” | Fetch baseline/list | Keep cached content; hold sends until required data is current |
| Ready with current data | Compact “Connected” state | Follow live changes | Normal supported actions |
| Returning after background | Existing screen with “Reconnecting…” | Open fresh connection and subscriptions without approval | Read cached context and edit draft |
| Temporary network loss | “Reconnecting…”; last confirmed update if known | Retry with jitter and backoff while active | Read and type; no queued sends or approvals |
| Prolonged interruption | One recovery card with connection details | Continue eligible retries while foregrounded | Inspect details or choose another saved host |
| Session-list error | “Connected” and “Couldn’t load sessions” | Keep existing connection and cached list | Retry the list; inspect error details |
| Follow-stream error | Cached transcript and “Couldn’t refresh this conversation” | Recover the connection if it failed; otherwise allow a data retry | Keep draft; retry follow |
| Credential rejected | “Pairing required” with the reason | Stop automatic retries | Pair again |
| Host key changed | Specific identity-change explanation | Stop; retain saved trust until deliberately replaced | Verify host identity and re-pair |
| Session removed/inaccessible | A session-specific explanation | Keep host connection usable | Return to sessions; recover the local draft |

Use one compact status row. Brief reconnects should not replace the whole conversation with an error screen. Show the larger recovery card only for a sustained failure, initially after approximately three seconds, or when user action is required. This removes the duplicate persistent warnings suggested by the illustrative recovery image.

### Recovery contract

- Entering the background preserves local state, cancels retries, and releases the phone’s connection. The host keeps working independently.
- Returning to active immediately schedules recovery if a host was selected. A brief inactive state, such as a system sheet, does not need to tear down the connection.
- Use one active host coordinator. Serialize old teardown with a replacement connection so rapid app switching cannot close the new socket.
- Wait for protocol readiness before claiming connected. Wait for a snapshot before claiming a conversation is current.
- Reconnect attempts begin around 0.5 seconds apart after failure, increase with jitter, and cap around ten seconds. Honor a longer server Retry-After value.
- Treat socket failures and ended event streams as lost connections. Discard late frames from abandoned subscriptions.
- Never automatically repeat session creation, prompts, answers, approvals, or other writes merely because recovery succeeded.
- Add foreground liveness checking and network-path-change handling as remaining work; immediate loss detection on a silently dead socket is not yet established by the current implementation.
- Do not promise a permanent background socket or include a misleading “Keep connected” switch. Background notifications require separate host and APNs support.

### Host identity and remote address

The saved host represents a trusted machine, not just an IP string. A future stable endpoint must preserve that relationship and all local drafts. A phone changing networks should not require pairing again if the same authenticated endpoint remains reachable.

The current saved private address does not provide cellular access. The intended no-phone-VPN experience needs a stable HTTPS/WSS hostname and an authenticated remote route. The [connection investigation](mockups/2026-10-09/CONNECTION-REVIEW.md) describes an outbound-tunnel option and its trust requirements.

Treat that as a separate infrastructure deliverable. A TLS-terminating endpoint needs explicit platform-certificate trust behavior; it cannot reuse a direct relay key pin blindly. Discovery must never replace a trusted key merely because an address advertises a new one. The Mac must remain awake for work hosted on that Mac.

## Persistence and privacy

| Local state | Identity and storage | Restore behavior |
| --- | --- | --- |
| Device credential | Keychain, keyed by stable saved-host UUID | Reuse automatically; never include in diagnostics |
| Host metadata | Protected app support file | Restore chosen host and endpoint/trust mode |
| Existing-session draft | Host UUID plus session ID | Restore text and local attachment selections after navigation and relaunch |
| New-session draft | Host UUID plus workspace ID | Restore independently of other workspaces |
| Last selected context | Host, workspace, session identifiers | Return to context without treating stored status as live |
| Scroll anchor and expanded cards | Host/session plus stable message or event IDs | Restore when those items exist in the refreshed history |
| Transcript | Memory for this release | Survive ordinary reconnection; after process termination show loading until host data arrives |
| Freshness timestamp | Last successful data update for that screen | Say “Last updated…” only when the app actually recorded it |

Save draft changes atomically after a short debounce, with a flush when navigating or entering the background. “Draft saved on this iPhone” is shown only after a successful write. If saving fails, retain the in-memory draft and say so.

Never include credentials, pairing codes, draft text, messages, or tool arguments/results in routine diagnostics. Forgetting a host removes its local credentials and drafts only after the existing explicit confirmation; device revocation at the relay is a separate action.

## Settings and secondary sections

| Destination | First useful implementation | Later expansion |
| --- | --- | --- |
| Settings | Appearance, host selection/pairing, display name, version, connection details, redacted diagnostics | Additional preferences justified by actual use |
| Plugins | Read installed plugin names and available status through a verified endpoint | Enable/disable/install only after supported write behavior and consequences are designed |
| Scheduled tasks | Read schedules, next-run data, and history when returned by the host | Create/edit/pause after the scheduling contract is exercised |
| MCP | Read host-reported server/tool status when an appropriate API is verified | Configuration management as a separate scoped feature |
| Usage | Host-reported values with clear units, period, and scope | Richer history if the host exposes it |
| Session details | Workspace, current model/mode, goal, plan, todos, and context data when available | Editing only where the host exposes supported actions |

Do not substitute device statistics for model usage or show guessed token counts. Do not assume that plugin inventory is the same thing as MCP connection health. A descriptor for a related operation is not proof of the required UI data source.

## Accessibility and layout acceptance

Support compact phones, larger phones, portrait, landscape, the keyboard, and safe-area insets. No primary action depends on hover, swipe alone, or a precisely targeted small symbol.

Use text and symbols with state colors. Target at least 4.5:1 contrast for body text and 3:1 for large text and essential interface boundaries. Validate the chosen semantic colors rather than assuming the starting palette satisfies every combination.

VoiceOver announces control purpose, current selections, loading failures, and pending questions. Streaming should not announce every token. Move focus into a presented sheet and return it to the invoking control when dismissed.

At large Dynamic Type sizes, allow selector rows to stack, card buttons to become full-width vertical controls, and titles to wrap. Code can scroll horizontally; primary forms and navigation must remain usable without horizontal scrolling.

## Implementation map

| Area | Existing seam | Required work |
| --- | --- | --- |
| App shell and selection | `DSHRemoteApp`, `AppModel`, `HostsView`, `SessionsView` | Introduce Home and drawer; keep host management accessible; persist context |
| Recovery | `ForegroundConnection`, `ConnectionCoordinator`, `MuxClient` | Retain current recovery behavior; validate on device; add liveness/path handling |
| Chat | `ChatView`, `ChatSession`, `ConversationBuilder` | Implement transcript/card system, history behavior, stable scroll anchors, and active-request reconciliation |
| Workspaces | Descriptor `workspace/follow` and generated workspace models | Drive workspace tree from the registry and maintain a live snapshot |
| New sessions | Descriptor `session/create`, `SessionCreateRequest`, `SessionCreateValue` | Verify a live create/follow/prompt round-trip; preserve draft and handle uncertain outcomes |
| Models | `session/modelCatalog`, `session/selectModel` descriptors | Verify catalog/selection behavior and render actual choices |
| Modes | Agent preset roster/select plus verified web/host source | Implement staged selection for a new or blank session; respect the first-turn lock |
| Questions and decisions | `$events`, session control state, question models and answer path | Distinguish active requests from historical tool records; implement full forms and stale-request protection |
| Durable drafts | Existing host/secret persistence patterns | Add an atomically written draft store scoped by host and session/workspace |
| Secondary sections | Plugin/schedule descriptors; other data sources require verification | Start with useful read-only views; gate unsupported features |

Keep generated models generated. Add captured fixtures or verified examples when extending behavior. Networking and transcript folding remain outside the main actor; the UI observes state that belongs to the selected host and conversation.

## Delivery sequence

| Step | Deliverable | Completion condition |
| --- | --- | --- |
| 1 | Device validation of recovery and separate repair of the host’s misfiled session stubs | App returns from lock with fresh data; session listing is no longer blocked by host storage validation |
| 2 | Visual foundation, Home, workspace drawer, and session cards | Recognizable DeepSeek identity; reliable selection and navigation on small and large phones |
| 3 | Conversation, tool cards, decision forms, and persistent drafts | Real data renders correctly; reading position and typed work survive navigation and interruptions |
| 4 | New-session flow, model/mode controls, attachments, and commands | Each control performs a verified host operation and handles refusal or uncertain delivery |
| 5 | Secondary views and remote access | Useful capability-gated pages; separately validated stable remote route and trust behavior |

Host data repair and remote access change the live environment and require explicit authorization. This document specifies their desired outcome; writing it does not perform or authorize those changes.

## Acceptance scenarios

| Scenario | Required result |
| --- | --- |
| Home compared with the desktop screenshot | Same recognizable brand, dark surfaces, workspace vocabulary, and prompt hierarchy |
| First launch without pairing | Clear pairing entry; no fake sessions or enabled remote actions |
| Return after 30 seconds in another app | Same screen and draft; automatic reconnect; current transcript arrives; no permission sheet |
| Lock/unlock after several minutes | Same behavior, even if the old socket died during suspension |
| Rapid background/foreground changes | One usable connection and follow subscription; no late teardown closes the current socket |
| Network temporarily unavailable | Cached transcript stays readable; draft editable; Send disabled; eligible retries continue while active |
| Wi-Fi to cellular on the eventual remote route | Same host and pairing retained; conversation refreshes when reachable |
| Relay restart with unchanged identity | Automatic recovery and fresh baseline without duplicate messages |
| Changed host key or revoked device token | Specific error; no endless authentication retries or automatic trust replacement |
| Connected host returns a corrupt-session error | Connected stays visible; cached sessions survive; loading error has Retry and Details |
| Follow never supplies a snapshot | Bounded loading with an explanatory error; existing content is not replaced by a blank transcript |
| Stream updates an existing message | Text changes even though message count does not |
| Read older history while new output arrives | Reading position stays fixed; New activity becomes available |
| Approval answered on the computer while phone reconnects | Phone reconciles the request and offers no stale active button |
| Connection drops after a send or answer | Delivery uncertainty is shown; no automatic replay |
| Switch between two hosts with identically named workspaces | Sessions, credentials, and drafts remain isolated |
| Session creation succeeds but first prompt fails | One session remains selected; draft retained; retry does not create another session |
| Navigate away and relaunch after typing | Persisted draft returns in the correct host/session or workspace; transcript is refreshed from the host |
| Unsupported secondary capability | No deceptive working control; unrelated core flows remain usable |
| Largest accessibility text with keyboard open | Composer, submit buttons, drawer, and request details remain reachable |

Use state/transport tests for reconnect, late frames, duplicate prevention, and persistence boundaries. Use rendered SwiftUI screens and physical-device checks for layout, keyboard handling, text scaling, app suspension, and real networking. An iOS build and passing package tests alone do not establish the complete phone experience.
