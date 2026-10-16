# Issue #104: a host forgotten while its selection is in flight is still connected

**Status:** draft
**Branch:** `issue-104-forget-pending-select`
**Version impact:** PATCH. A behaviour fix: no persisted format change, no generated model. The
kit gains a small public type, which is additive. No bump in this PR, and one line under
`## [Unreleased]`.

## Context

Patrick's agent review of PR #92 (comment on #92, 2026-10-15) found this interleaving in
`Apps/DSHRemote/Sources/AppModel.swift`. `select(B)` captures `selectionID` (`:326`), then
suspends twice: on `previous?.stop()` (`:330`) and on `registry.relayDeviceToken(for:)` (`:334`).
If `forget(B)` runs during either suspension, it calls `disconnect()`, which bumps `selectionID`,
only when `selectedHost?.id == host.id` (`:1701`). While B is pending, `selectedHost` still names A
(or nil), so the pending selection stays current. It resumes, publishes `selectedHost = B` (`:391`)
and connects. If the token is already deleted, the failure path (`:404–414`) publishes B anyway.
`HostRegistry.relayDeviceToken(for:)` (`HostRegistry.swift:133`) returns a token for any id, saved
or not. This is static analysis; the red test below is the first reproduction.

## Root cause

A selection's validity is tracked only as a generation counter (`selectionID`) that nothing ties
to a host. So `forget` can end a selection only once it has been *published*
(`selectedHost?.id == host.id`), never one still in flight. Separately, the registry hands out a
token, and records a selection, for an id it no longer holds.

- **Origin:** `origin/pre-existing`. Before #92 `forget` was synchronous, with the same
  `selectedHost` check, so a suspended `select` survived it then too.
- **Priority:** `priority/P2`. It is a short race window, and the host stays reconnected only
  until the next relaunch (`HostRegistry.init` reconciles the selection away).
- **Cluster:** host lifecycle, with #65 (closed), #94 and #96, all labelled `needs-design-review`.
  This fix is shaped as one piece of that design: the current selection is owned by one value
  that knows which host it is for. It does not add a special case.
- **Go-ahead:** Dan, 2026-10-16, to fix now as a kit design.

## Design, and where it departs from the agreed approach

The agreed approach put the ticket in `HostRegistry`, with `beginSelection(of:)` and
`isCurrent(_:)`. **This plan puts it in a small value type the app holds on the main actor**,
`HostSelectionGate`, for these reasons:

1. **The invalidation has to happen before `forget`'s first suspension, on the main actor.**
   `HostRegistry` is an actor. If `registry.forget` invalidated the ticket, the invalidation would
   run only once the actor got to it. A `select(B)` continuation already queued on the main actor
   could check `await registry.isCurrent(ticket)`, see `true`, and publish B before `forget`'s
   synchronous part ran. Then `forget`'s tail would still need its `selectedHost` check to tear B
   down, which is the special case this fix is meant to remove.
2. **Every check of an actor's state is an `await`**, which is itself a suspension. The answer can
   be stale by the time the main actor publishes. A main-actor value is checked synchronously, so
   nothing can happen between the check and the publish.
3. **Some checks are synchronous today.** `disconnect()` and `apply(snapshot:selection:)`
   (`:1342`) are not `async`. With a registry ticket, `disconnect` would have to spawn a `Task`
   to invalidate, and its ordering against the next `select` would be a bet on the scheduler.
4. **One mechanism.** The gate replaces `selectionID` outright. `select` begins a ticket,
   `disconnect` ends it, and `forget` ends it when it is for that host. Nothing coexists.

The registry keeps the part that belongs to it: it refuses to act for a host it no longer holds.
`relayDeviceToken(for:)` returns nil for an unsaved host, and so does a read that a `forget`
overtook. `setSelection(_:)` does nothing for an unsaved host. That is defence in depth: no other
caller can get a forgotten host's token either.

In Python terms, the gate is a small object that holds "the current request id and the host it is
for". It is not shared across threads: only the main actor touches it, like a value that only the
asyncio event-loop thread ever reads.

```swift
public struct HostSelectionGate: Sendable {
    public struct Ticket: Sendable, Equatable { public let hostId: UUID }  // plus a private id
    public init()
    public mutating func begin(_ hostId: UUID) -> Ticket   // supersedes any earlier ticket
    public func isCurrent(_ ticket: Ticket) -> Bool
    public mutating func end()                             // disconnect
    @discardableResult
    public mutating func forget(_ hostId: UUID) -> Bool    // ends the current ticket iff it is for hostId
}
```

`forget` returns true when it ended the current selection, which tells the caller to tear that
selection down. The app's `forget` becomes `if selections.forget(host.id) { disconnect() }`,
**before** `await registry.forget`. That one rule covers a pending selection and a published one
alike, replacing the post-await `selectedHost?.id == host.id` check.

**One behaviour change to approve.** Forgetting the host you are connected to now disconnects
before the list is saved. If the save then fails (`listNotSaved`), the host is still listed, you
are disconnected, and the error says it was not forgotten. Today you would stay connected. The
alternative, invalidating first and disconnecting afterwards only on success, leaves a pending
`select` with nothing to finish it: `resetHostScopedState` has already torn A down and
`idleStatus` reads `.connecting` forever. Disconnecting is the honest end state.

## Acceptance criteria

- **AC1.** Forgetting B while B's selection is pending ends that selection. When the held token
  read resumes, it yields no token and the selection is no longer current, so nothing is published
  or connected for B.
- **AC2.** Forgetting an unrelated host C while B's selection is pending leaves B's selection
  current, and its token read still yields B's token.
- **AC3.** A newer selection supersedes an older one, and `end()` (disconnect) ends the current
  one. A ticket from before a forget is not revived when the same host is selected again.
- **AC4.** The registry does not hand out a token for a host that is not saved.
- **AC5.** The registry does not record a selection for a host that is not saved.
- **AC6 (app, guarded by build and reading).** `AppModel.select` checks its ticket after every
  suspension, before publishing anything, on both the success and failure paths. `forget` ends the
  selection through the gate before its first `await`, and `selectionID` is gone.

## Test list

Controllable store: `HeldReadSecretStore`, a private actor in the test file, is new. `secret(for:)`
captures the stored value (as a Keychain read that had already returned would have), yields on an
`AsyncStream` that the read has started, and then suspends on a continuation until `release()`.
Deletes and writes are never held. The test awaits the stream's first element, never
`Task.sleep`. Each test builds its own store.

| AC | Suite / file | Test name | Fails today because |
|---|---|---|---|
| AC1 | `HostRegistryTests.swift` | `"AC1: a token read that a forget overtakes yields no token"` | the held read returns the captured value: `"token-B" == nil` fails |
| AC1 | `HostSelectionGateTests.swift` (new) | `"AC1: forgetting B while its token read is held leaves no current selection and no token"`. Mirrors `AppModel`'s order: `begin(B)`, held read, `gate.forget(B)`, `registry.forget(B)`, release | stub `forget` returns false, and the read yields `"token-B"` |
| AC1 | `HostSelectionGateTests.swift` | `"AC1: forgetting B ends a pending selection of B"` | stub `forget(B)` returns false |
| AC2 | `HostSelectionGateTests.swift` | `"AC2: forgetting C leaves a pending selection of B current"` | stub `isCurrent` returns false |
| AC2 | `HostRegistryTests.swift` | `"AC2: forgetting another host leaves a held token read intact"` | guard: passes today and must keep passing (it catches a fix that drops every in-flight read) |
| AC3 | `HostSelectionGateTests.swift` | `"AC3: a newer selection supersedes an older one"` | stub `isCurrent(newer)` returns false |
| AC3 | `HostSelectionGateTests.swift` | `"AC3: ending the selection makes its ticket stale"` | stub `isCurrent` is false before `end()` as well (the test asserts it is current first) |
| AC3 | `HostSelectionGateTests.swift` | `"AC3: selecting a forgotten host again does not revive the old ticket"` | stub `isCurrent(fresh)` returns false |
| AC4 | `HostRegistryTests.swift` | `"AC4: no token is handed out for a host that is not saved"` | returns the stored token: `"token-X" == nil` fails |
| AC5 | `HostRegistryTests.swift` | `"AC5: a selection naming a host that is not saved is not recorded"` | `registry.selection?.hostId` is the unsaved id |

AC numbers in `HostRegistryTests.swift` already run AC1–AC8 for #65. The new tests go under
`// MARK: - Selection in flight (#104)`, and their names say `#104` so they read unambiguously:
`"#104 AC1: …"`.

**Stubs in `Sources/`** (`Sources/DSHRemoteKit/State/HostSelectionGate.swift`): the type and
signatures above. `begin` returns a ticket without storing it, `isCurrent` returns false, `forget`
returns false and `end` does nothing. They give wrong values and never crash. The registry needs
no stub: its tests fail against today's behaviour.

**AC6 has no automated test, and the plan says so.** `AppModel` builds its own Keychain-backed
registry and is reachable only from the app target. Driving `select` against a held store would
mean an injection seam in `AppModel` plus a simulator test, which is wider than this fix. The
guard is the following:

- The compiler: removing `selectionID` forces every guard site to change type to `Ticket`.
- The reviewer and verifier check this list of suspensions in `select` (line numbers as of
  `bc967f0`). Each one must be followed by `guard selections.isCurrent(ticket) else { return }`
  before any assignment to published state:
  1. `await previous?.stop()` (`:330`, check exists)
  2. `try await registry.relayDeviceToken` (`:334`, check exists)
  3. the `catch` entry (`:405`, check exists)
  4. `try? await registry.setSelection` (`:395`, **check missing today**)
  5. `await drafts.navigation(for:)` inside `restoreNavigation` (`:1458`, **check missing**, and
     it publishes `selectedWorkspaceId` and `selectedSessionId`)
- A lint rule was considered and rejected. "A check follows every `await`" cannot be expressed in
  `grep` without false positives. A rule banning `selectionID` would only restate what the
  compiler already enforces once the property is deleted.

## Slices

One slice. The kit and app changes are small and depend on each other's names.

| Slice | ACs | Files | Notes |
|---|---|---|---|
| A | AC1–AC5 | `Sources/DSHRemoteKit/State/HostSelectionGate.swift` (new), `Sources/DSHRemoteKit/Persistence/HostRegistry.swift` | gate about 20 lines of code plus its doc comment. Registry: a membership check after the read in `relayDeviceToken`, and a guard in `setSelection` |
| A | AC6 | `Apps/DSHRemote/Sources/AppModel.swift` | the hunks below |

**`AppModel.swift` hunks**, for sessions editing it in parallel:
- `:145` `private var selectionID = UUID()` becomes `private var selections = HostSelectionGate()`.
- `select(_:)`, `:315–415`: ticket capture, the existing checks, and the two new ones after
  `setSelection` and inside `restoreNavigation`.
- The parameter types `selection: UUID` become `HostSelectionGate.Ticket` in
  `observeStatus` (`:434`), `apply(status:selection:)` (`:454`), `subscribeToDecisions`
  (`:475`), `observeDecisions` (`:531`), `observeSnapshots` (`:1227`) and
  `apply(snapshot:selection:)` (`:1342`).
- `restoreNavigation(for:)`, `:1457`: takes the ticket.
- `forget(_:)`, `:1691–1704`: `selections.forget` moves before `await registry.forget`, and the
  post-await `selectedHost` check goes.
- `resetHostScopedState()`, `:1765`: `selectionID = UUID()` becomes `selections.end()`.

**Size:** about 30 to 40 production lines added, net of the removed ones. That is under the 50-line
threshold.

`Tools/must-test.txt`: `Persistence/HostRegistry.swift` keeps its 90% floor. Add
`State/HostSelectionGate.swift  95`, since it is the lifecycle rule. Raise the coverage baseline
if the measured total rises.

## Risk flags

- [x] **S4 secrets and the host lifecycle.** `forget` and `select` change, and the registry stops
  returning a token for an unsaved host. The persisted forget stays covered by the existing #65
  relaunch tests (`HostRegistryTests` AC1, AC2, AC8). The new AC5 test reads the selection back
  through a fresh `HostStore`. No token goes into any error string: the new paths return nil and
  never throw a token.
- [x] **C3 concurrency.** No new actor, no `Task {}`, no `@unchecked` and no `nonisolated(unsafe)`.
  The gate is a plain `Sendable` struct mutated only on the main actor. The held-read tests observe
  an `AsyncStream` signal. They rely on actor reentrancy (`registry.forget` runs while
  `relayDeviceToken` is suspended in the store), and the test comment says so.
- [ ] S1, S2, S3, S5 to S10, C1, C2 and C4 to C6: not touched. C6 is close: AC6 is app-only. The
  rule itself, which selection is current and what forgetting ends, moved into the kit. What stays
  in the app is calling it after each `await`.

## Out of scope

- The wider host-lifecycle design under `needs-design-review` (#94, #96). This settles only "which
  selection is current".
- An `AppModel` injection seam for a secret store, which would make AC6 testable. If the design
  review wants one, it is its own issue.
- `seedForGallery` publishes `selectedHost` without a ticket, so forgetting the gallery's host
  does not disconnect it. It is a debug-only screen, so this is unchanged and noted here only.

## Red evidence

*Filled in with the `Tests:` commit.*

```
```

## Verification

*Filled in by the verifier.*

| AC | Undone how | Test failure with it undone |
|---|---|---|

- `Tools/check.sh`: …
- Risk checklist: in the PR

## Notes for the next person

- An actor-owned "is this still current?" check is one `await` stale by the time you act on it.
  When the actor's caller is the one that publishes, keep the generation in the caller's isolation
  domain, and keep the actor's own guard for what it hands out.
