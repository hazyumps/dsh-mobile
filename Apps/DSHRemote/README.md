# DSH Remote — iOS app target

The app is generated from [project.yml](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen), so the project file is not
in git. `DSHRemote` depends on the `DSHRemoteKit` package at the repository
root by local path, which is where the wire models, the transport layer, and
their tests live.

```sh
brew install xcodegen          # once
cd Apps/DSHRemote
xcodegen generate              # writes DSHRemote.xcodeproj
open DSHRemote.xcodeproj
```

Building for a simulator needs no Apple identity:

```sh
xcodebuild -project DSHRemote.xcodeproj -scheme DSHRemote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build-app \
  CODE_SIGNING_ALLOWED=NO build
```

## Installing on a phone

This machine has a valid Apple Development identity, and its team matches the one
already committed to [project.yml](project.yml):

```sh
security find-identity -v -p codesigning
#  1) … "Apple Development: ph@dontbuck.com (7JS22WHNBB)"   1 valid identities found
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
#  … OU=U6LC736TBG …
grep DEVELOPMENT_TEAM project.yml
#  DEVELOPMENT_TEAM: "U6LC736TBG"
```

Read the **OU** for the team. The parenthesised value in the certificate's common
name is the certificate ID, not the team, and the two look alike enough to be
mistaken for a mismatch on a certificate that is in fact fine.

So the remaining step is choosing the destination, not creating an identity:

1. Open the project in Xcode and select the `DSHRemote` target.
2. Signing & Capabilities should already show the team from `project.yml`.
3. Select your iPhone and Run.

Verified 2026-10-09: the identity exists and its team matches `project.yml`. A
device install has **not** been re-run since, so that path is unblocked on paper
rather than proven.

Xcode writes the team into the project when you pick it, but since the project
is generated, put it in `project.yml` instead (`DEVELOPMENT_TEAM`) so a
regenerate does not lose it.

Once you are signed in (Xcode → Settings → Accounts), the whole remaining step is
two commands:

```sh
# the team id appears beside your Apple ID in Xcode → Settings → Accounts,
# or as IDEProvisioningTeamByIdentifier in the Xcode defaults
perl -pi -e 's/^(\s*DEVELOPMENT_TEAM:).*$/$1 "YOURTEAMID"/' project.yml
xcodegen generate

# build and install straight to a connected phone; -allowProvisioningUpdates
# lets Xcode create the development certificate and profile for you
xcodebuild -project DSHRemote.xcodeproj -scheme DSHRemote \
  -destination 'platform=iOS,name=YOUR_IPHONE' \
  -allowProvisioningUpdates build
```

`xcodebuild -showdestinations -project DSHRemote.xcodeproj -scheme DSHRemote`
lists the exact device names to pass to `-destination` if you would rather not
type one from memory. Without `-allowProvisioningUpdates` the first device build
fails on the missing profile, which reads like a code error and is not one.

Verified on 2026-10-08: `xcodebuild -destination 'generic/platform=iOS'
CODE_SIGNING_ALLOWED=NO build` **succeeds**, so the app compiles for a device
architecture and signing is the only thing standing between it and the phone —
not a code or platform problem. Xcode also carries a team record already
(`IDEProvisioningTeamByIdentifier` in its defaults) from a previous sign-in, so
picking a team again may be quicker than first-time setup.

## What the app does today

`HostsView` is the v1 landing screen. Pairing works end to end: paste the
relay's pairing JSON, see the host and key it pins, claim the one-time code,
and the device token goes into the keychain while the host's nonsensitive
metadata goes to `hosts.json` in Application Support. Forgetting a host
deletes its credential and says plainly that it does not revoke the device at
the relay.

The app connects to saved hosts, lists sessions, follows conversations, sends
prompts, and answers questions. The status badge carries text and a symbol.

The root is now the selected host's work, not the host list: **Home** (status row,
workspace control, "Continue a session") with the **drawer** for switching
workspace or conversation, and **Settings** for host selection, pairing, and the
device name. `HostsView` remains the pairing introduction for a phone with no
saved host. Grouping comes from the host's own workspace registry through
`HostSessionStore`; the session list is read and refreshed by that store rather
than by the connection, so a list failure never relabels a healthy connection.

**Home's composer starts sessions.** Send is the first moment the host hears
anything: the identity is persisted, `session/create` is sent once with it, the new
session is followed, and the first prompt reuses the submission identity already on
disk.

Above the composer are the **mode and model** the session will start on (SPEC §6),
read from the host's own catalog: the agent preset, and the provider/model with an
effort submenu where the host advertises one. Both are staged rather than applied —
the preset rides on `session/create`, and the model is set through
`session/selectModel` before the prompt, so a selection the host refuses stops the
first message instead of sending it on a different model. A `session/workspace-attach-failed` is reconciled as the partial success it is
rather than retried as a fresh create, and an uncertain outcome keeps the draft and
says so. The drawer's New session just opens that composer.

The drawer's **Plugins** and **Scheduled tasks** destinations read through
`SecondaryReadStore` and are capability-gated. On the installed host the plugin
inventory answers (212 entries) while **every `schedule/*` endpoint 404s**, so the
schedule screen says "not available on this harness" with no retry — an absence
established by the host is not a failed read. Both are read-only: management
controls are absent rather than greyed. **MCP and Usage** stay omitted, because
this build exposes no MCP inventory endpoint and no verified host-wide usage
source (SPEC §10).

A conversation renders from `ChatSession`'s snapshot stream (messages, reasoning,
fenced code with Copy, non-message activity cards, older-history paging) and
batches pending questions by `callId`. The follow and the pager ask for a bounded
page — `ChatSession.pageMessages`, measured against the socket's inbound limit,
because an unbounded baseline destroys the connection (see that constant).

Approvals and live questions are answered through the `$events` router:
`AppModel` composes one `InteractionStore` per selected host, mounts one router
subscription per ready generation, and publishes the decisions a screen renders.
A question with a current delivery goes through `$events/result`; only one with no
live channel uses `userQuestions/answer`. The timed question's foreground claim is
attached, paused and released by the conversation screen, which is where SPEC §8
puts its lifetime.

**Slash commands** are read per session and suggested once a draft starts with `/`,
with the host's own description and hint. A registered command goes to
`commands/execute`; an unknown `/word` stays ordinary prompt text, and matching is on
the exact name so `/nameplate` is not `/plan`. A refusal keeps the draft and refreshes
the list.

**Attachments** go up the raw `session/uploadFileBinary` route, streaming from disk, with
the bounded base64 `fileUploads/upload` fallback reserved for a 404 that says the route is
absent — never around an auth, size or admission refusal. Staged files appear as chips in
the composer, and the next prompt cites them as `{type:"file",receiptId}`; the transcript
shows the files a message carried, from the durable part the host stores once the receipt
is retired. The importer is the system one, which a simulator cannot drive, so that one
control is unverified here.

**Images** go inline, in the prompt, inside the host's own `imageLimits` — read from the
session's `imageLimits` projection, never assumed. An image the host already accepts is
passed through byte-for-byte; anything else is shrunk to both the longest-edge and the
pixel caps and re-encoded as JPEG until it fits, with a refusal that names the limit that
stopped it. The transcript shows the pictures a message carried, resolved by the host into
the same durable shape a file gets.

**Live questions work end to end.** A harness session that uses `ask_user_question` parks its
turn, the phone receives the `user-questions/request` waterfall, shows the card, and answering
it through `$events/result` resumes the turn — verified against the installed host, whose
durable tool result read `{"answers":[{"id":"colour","selected":["Blue"]}]}` with
`isError: false`.

**Approvals and the timed claim are still offline-only.** Nothing on this host produces
either: an unanswered question's waterfall carries **no** `wait`, and a write outside the
workspace is refused by the sandbox outright rather than escalated to an approval. So SPEC
§8's timed-claim path is implemented and unit-tested but has no live coverage here.

**Attachments read back.** An image a message carried is drawn in the transcript from the
host (`session/attachment` → `SessionImageCache`), with a placeholder at the attachment's own
aspect ratio while it loads. Nothing is kept on the device: the phone may have been
reinstalled since the message was sent, and the host is the only copy certain to exist.

**Session cards** carry SPEC §4's "Needs your input" state, from the host's *current* channels
— the `inbox`/`userQuestions.active` projections and a live `$events` delivery — never from a
historical `ask_user_question` tool call. The recent list refreshes on foreground, on opening
the drawer, on pull-to-refresh, and every 15 seconds while it is visible.

**`DSH_TRACE=1`** prints a one-line decisions trace (subscription, waterfall, live waiters) to
stdout, readable with `xcrun simctl launch --console-pty`. It exists because a missing badge
looks like nothing at all, and nothing else shows whether the `$events` subscription was
established. Debug builds only.

**Usage** is a drawer destination, scoped to the selected session and read entirely from the
harness's own projections (`tokenUsage`, `sessionStats`, `contextBreakdown`, `contextPressure`)
— no host-wide totals, no estimates from the transcript. A field the harness did not report is
absent rather than zero, and a rate with no denominator to divide by is absent too.

**Diagnostics** live under Settings → Support. The kit's `DiagnosticLog` had a previewable
export and nothing recorded to it; the app now records connection state changes (with the
generation and the attempt's duration) and each resource's state change, and the preview *is*
the export — the same string, so there is no "what will be sent" question. No prompts, answers,
credentials, signed URLs, or paths, structurally: the record type has no free-text field.

**Still to come:** physical-device validation (slice F), which is the only way to check the
two pickers, background recovery, and the timed claim under a real lock.

Returning from the background automatically opens a new connection with the
stored credential and refreshes the session list and open conversation. Temporary
failures retry while foregrounded with backoff; there is no reconnect approval.
Backgrounding cancels retries and closes the socket. A revoked credential or
changed certificate stops recovery and shows the reason.

The open screen keeps its messages and draft during reconnection and waits for
a fresh snapshot before enabling sends. It does not replay prompts or answers.
This is in-memory retention, not draft/history restoration after iOS terminates
the app; the selected host, workspace, and session *are* persisted, so a cold
launch returns to the last conversation. Session-list errors preserve the cached
list and do not relabel a healthy connection as unavailable.

Recovery is covered by offline transport tests and an iOS simulator build.
Physical-phone validation is still needed: open a conversation, type a draft,
lock/unlock or switch apps, then confirm that new host output appears and the
draft remains. Repeat with a temporarily unavailable network. The independently
diagnosed host session-log inconsistency can still prevent session listing;
reconnection does not repair host files or provide a stable remote hostname.

## Environment state

Both blockers this section used to list are gone, verified 2026-10-09:

- **A code-signing identity exists**, and its team (OU `U6LC736TBG`) matches
  `DEVELOPMENT_TEAM` in `project.yml` — see *Installing on a phone* above.
- **An iOS simulator runtime is installed.** `xcrun simctl runtime list`
  reports `iOS 27.0 (24A434) — Ready`. The simulator can therefore *run*, not
  only build, so `-destination 'platform=iOS Simulator,name=…'` is usable and
  a screen can be looked at rather than merely compiled.

`xcodebuild -showdestinations -project DSHRemote.xcodeproj -scheme DSHRemote`
lists the concrete destinations on this machine, which is the honest answer to
"what can I run" and is cheaper than reading this paragraph.

Still outstanding, and not an environment problem: physical-phone validation of
the recovery behaviour described above. An installed runtime is not a phone.


## Debug affordances

These environment variables change what a **debug** build does. Every one is
compiled out of a release build, and none does anything unless it is set, so the
shipping app's normal flow is what runs by default.

| variable | effect |
| --- | --- |
| `DSH_PAIRING_PAYLOAD` | Seeds pairing at launch with a relay pairing payload, running the ordinary `claim` path rather than a parallel one. For exercising the whole flow on a simulator with no keyboard. |
| `DSH_OPEN_HOST` | Selects the first saved host at launch. Home, the drawer, and the session list are otherwise unreachable on a simulator, which cannot be tapped. |
| `DSH_OPEN_SESSION` | Opens a session once the list has loaded. Pair it with `DSH_SESSION_ID` to open a specific conversation rather than the newest. |
| `DSH_SESSION_ID` | Names the session `DSH_OPEN_SESSION` should open. |
| `DSH_DESTINATION` | Opens a drawer destination at launch: `plugins` or `schedules`. It wins over the restored conversation, which would otherwise always get there first. |
| `DSH_NEW_SESSION_MESSAGE` | Starts a **new** session once a workspace is known, with this text as the first prompt. It creates a real session and runs one real turn, so point it at a scratch workspace. |
| `DSH_MODE` | Stages an agent preset for a launch-created session, by roster id (`minimal`, `ptc`, `cordis`). |
| `DSH_MODEL` | Stages a model for a launch-created session, as `provider/model` or `provider/model/effort`. |
| `DSH_DESTINATION=home` | Shows Home rather than the restored conversation, which the app otherwise correctly reopens. |
| `DSH_SETTINGS` | Opens Settings on launch — its only other door is a drawer row. |
| `DSH_DIAGNOSTICS` | Opens Settings straight to the diagnostics preview. |
| `DSH_DRAFT` | Prefills the conversation composer, so the `/` command suggestions can be seen on a machine that cannot type. |
| `DSH_ATTACH` | Uploads this local path into the open conversation and stages its receipt, so the upload path can be exercised without a file importer. |
| `DSH_IMAGE` | Stages this local image into the open conversation, so the inline-image path can be exercised without a photo picker. |
| `DSH_ANSWER` | Answers the first live request with this value — a question's option label, or `allow`/`deny` for an approval — so the `$events/result` path can be exercised without a tap. |
| `DSH_SEND_MESSAGE` | Sends one message once a conversation is open. **Point it at a scratch session**: a duplicate or stray prompt costs real work, and this client never resends on its own. |
| `DSH_DESIGN_GALLERY` | Shows the component gallery instead of the app: every design-system component in each of its states, on the real tokens. |
| `DSH_SCREEN_GALLERY` | Shows the screens above the components from fixture data — `drawer` draws the drawer, `conversation` the conversation transcript, anything else Home. It renders the **real** screens against a seeded model, so the layout can be reviewed without a host. |

A simulator launch passes them through `simctl`'s `SIMCTL_CHILD_` prefix, and the
bundle identifier is generated from `bundleIdPrefix` in [project.yml](project.yml):

```sh
SIMCTL_CHILD_DSH_SCREEN_GALLERY=conversation \
  xcrun simctl launch booted net.fernlabs.dshremote
xcrun simctl io booted screenshot conversation.png
```

`simctl` cannot inject touches, so anything that would normally need a tap has a
variable above; the galleries exist because the visual work has to be *looked at*
to be reviewed, and this machine has no Simulator GUI. Both are debug screens, not
shipping destinations.

A **signed** simulator build is required for the Keychain.
`CODE_SIGNING_ALLOWED=NO` builds install and run, but every credential read fails
with `OSStatus -34018`, so a saved host cannot be reached from one — build with a
concrete `-destination 'platform=iOS Simulator,id=<udid>'` instead.
