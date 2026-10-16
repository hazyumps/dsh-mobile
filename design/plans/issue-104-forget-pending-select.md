# Issue #104: a host forgotten while its selection is in flight is still connected

**Status:** approved (Dan, 2026-10-16, "Plan approved" on #104); tests red
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
    public mutating func forget(_ hostId: UUID) -> Bool    // ends the current ticket iff it is for hostId,
                                                           // and marks hostId as being forgotten
    public mutating func finishForgetting(_ hostId: UUID)  // clears the mark (added after review, below)
}
```

`forget` returns true when it ended the current selection, which tells the caller to tear that
selection down. The app's `forget` becomes `if selections.forget(host.id) { disconnect() }`,
**before** `await registry.forget`. That one rule covers a pending selection and a published one
alike, replacing the post-await `selectedHost?.id == host.id` check.

**Added after the security review (Dan, 2026-10-16).** Ending the selection before the first
`await` leaves a gap. A `select(B)` that *begins* while `forget(B)` is awaiting the registry gets a
fresh ticket, and nothing ends it. Its token read yields nil, so it throws `missingCredential`, and
its `catch` path publishes `selectedHost = B` (`AppModel.swift` `:406–414`). The old post-await
`selectedHost` check used to tear that down. The fix stays in the gate. `forget(_:)` also marks B
as being forgotten, and `begin(B)` while B is marked returns a ticket that is already not current.
`finishForgetting(_:)` clears the mark. `AppModel.forget` calls it from a `defer` placed right
after `selections.forget`, so the mark is cleared on every exit, including `listNotSaved`, and a
host whose forget failed can be selected again:

```swift
if selections.forget(host.id) { disconnect() }
defer { selections.finishForgetting(host.id) }
```

The mark is per host, so it never blocks a selection of another host. In Python terms, `defer` is
a `finally:` block for the rest of the function.

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
  selection through the gate before its first `await`, and `selectionID` is gone. `forget`
  finishes forgetting (`selections.finishForgetting`) on every path out, including `listNotSaved`
  and the partial-failure path.
- **AC7.** A selection of B begun while B is being forgotten is not current, so it neither
  publishes nor connects B, and its failure path publishes nothing either.
- **AC8.** Once forgetting B finishes, whether it succeeded or the list save failed, a new
  selection of B is current.
- **AC9.** Forgetting B does not affect a selection of another host C begun meanwhile.
- **AC10.** The mark is kept per host when two forgets overlap. If B and C are both being
  forgotten and C's forget finishes, B is still marked, and it is unmarked only by its own finish.
  (This is separate from AC9, which is about selecting C. AC10 is about finishing C.)

## Test list

Controllable store: `HeldReadSecretStore`, a private actor in the test file, is new. `secret(for:)`
captures the stored value (as a Keychain read that had already returned would have), yields on an
`AsyncStream` that the read has started, and then suspends on a continuation until `release()`.
Deletes and writes are never held. The test awaits the stream's first element, never
`Task.sleep`. Each test builds its own store.

| AC | Suite / file | Test name | Fails today because |
|---|---|---|---|
| AC1 | `HostRegistryTests.swift` | `"#104 AC1: a token read that a forget overtakes yields no token"` | the held read returns the captured value: `"token-B" == nil` fails |
| AC1 | `HostRegistryTests.swift` (it needs the suite's `Disk`) | `"#104 AC1: forgetting B while its token read is held leaves no current selection and no token"`. Mirrors `AppModel`'s order: `begin(B)`, held read, `gate.forget(B)`, `registry.forget(B)`, release | stub `forget` returns false, and the read yields `"token-B"` |
| AC1 | `HostSelectionGateTests.swift` | `"AC1: forgetting B ends a pending selection of B"` | stub `forget(B)` returns false |
| AC2 | `HostSelectionGateTests.swift` | `"AC2: forgetting C leaves a pending selection of B current"` | stub `isCurrent` returns false |
| AC2 | `HostRegistryTests.swift` | `"#104 AC2: forgetting another host leaves a held token read intact"` | guard: passes today and must keep passing (it catches a fix that drops every in-flight read) |
| AC2 | `HostSelectionGateTests.swift` | `"AC2: forgetting a host whose selection was superseded leaves the newer one current"` | stub `isCurrent(newer)` returns false |
| AC3 | `HostSelectionGateTests.swift` | `"AC3: a newer selection supersedes an older one"` | stub `isCurrent(newer)` returns false |
| AC3 | `HostSelectionGateTests.swift` | `"AC3: ending the selection makes its ticket stale"` | stub `isCurrent` is false before `end()` as well (the test asserts it is current first) |
| AC3 | `HostSelectionGateTests.swift` | `"AC3: selecting a forgotten host again does not revive the old ticket"` | stub `isCurrent(fresh)` returns false |
| AC7 | `HostSelectionGateTests.swift`, suite "a host being forgotten" | `"AC7: a selection begun while B is being forgotten is not current"` | `begin` makes every ticket current: `!gate.isCurrent(during)` fails |
| AC8 | same | `"AC8: once forgetting B finishes, a new selection of B is current (the failed-save case)"` | fails on its precondition `!gate.isCurrent(during)`. The post-finish assertion passes today, because nothing is ever marked, so the precondition is what makes the test bite |
| AC9 | same | `"AC9: forgetting B does not affect a selection of C begun meanwhile"` | fails on its precondition `!gate.isCurrent(ofB)`, for the same reason. The assertion about C proves nothing unless B's mark is in effect |
| AC10 | same | `"AC10: when two forgets overlap, finishing one keeps the other host marked"` | guard: passes against the implementation at `689848f`. It is shown to guard by mutation; see Red evidence |
| AC4 | `HostRegistryTests.swift` | `"#104 AC4: no token is handed out for a host that is not saved"` | returns the stored token: `"token-X" == nil` fails |
| AC5 | `HostRegistryTests.swift` | `"#104 AC5: a selection naming a host that is not saved is not recorded"` | `registry.selection?.hostId` is the unsaved id |

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
- And in `forget`: `selections.forget` comes before the first `await`, and
  `defer { selections.finishForgetting(host.id) }` sits right after it. No `return` and no `throw`
  can leave the function with the mark still set.
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
- `seedForGallery` publishes `selectedHost` without a ticket. Correction, from the verifier: this
  *is* a change. Before #104 the post-await `selectedHost?.id == host.id` check disconnected a
  gallery-seeded host when it was forgotten. Now it does not, because the gate holds no ticket for
  it. The gallery is Debug only and is not fixed here.
- `apply(status:selection:)` checks its ticket on entry only, then awaits (verifier finding 1).
  That predates #104, and it is filed as #106 in the host-lifecycle cluster.
- A `select(B)` refused by AC7 returns at its first check, after `resetHostScopedState` has set
  `idleStatus = .connecting`. Nothing then moves the status on until the next selection or
  disconnect. That is the existing behaviour of any refused selection, not new to AC7, and it
  belongs to the lifecycle review (#94, #96).
- Two leftovers are filed as #108 for the design review. Neither one reads a token or connects:
  1. A `select(B)` from an out-of-date `SavedHost`, after `forget` has returned, is not refused
     by the gate, because B is no longer marked. Its token read yields nil (AC4), so it can show B
     in a failure state.
  2. Two forgets of the same host at once share one mark in the set. The first to finish clears
     it while the second is still awaiting the registry.

## Red evidence

`Tools/check.sh --red`, 2026-10-16: `red: ok it compiles and fails on assertions (kit: fail, app:
pass)`, `check: ok — red for the right reason`. Kit: 604 tests, 12 issues, all in the tests below.
The app tests are unchanged and pass. Every failure matches its prediction.

```
HostSelectionGateTests
AC1: forgetting B ends a pending selection of B                         Expectation failed: ended
AC2: forgetting C leaves a pending selection of B current               Expectation failed: gate.isCurrent(ticket)
AC2: forgetting a host whose selection was superseded ... newer current  Expectation failed: gate.isCurrent(newer)
AC3: a newer selection supersedes an older one                          Expectation failed: gate.isCurrent(newer)
AC3: ending the selection makes its ticket stale                        Expectation failed: gate.isCurrent(ticket)  (before end)
AC3: selecting a forgotten host again does not revive the old ticket    Expectation failed: gate.isCurrent(fresh)
HostRegistryTests
#104 AC1: a token read that a forget overtakes yields no token          Expectation failed: try await read.value == nil
#104 AC1: forgetting B while its token read is held ...                 Expectation failed: ended; Expectation failed: token == nil
#104 AC2: forgetting another host leaves a held token read intact       passed (guard, as predicted)
#104 AC4: no token is handed out for a host that is not saved           Expectation failed: try await registry.relayDeviceToken(for: stray.id) == nil
#104 AC5: a selection naming a host that is not saved is not recorded   Expectation failed: await registry.selection == nil;
                                                                        Expectation failed: disk.hostStore.loadSelection() == nil
```

The second AC1 test does not report `!gate.isCurrent(ticket)` because the stub's `isCurrent` is
already false. That assertion begins to bite once the builder makes `isCurrent` real, and the
`ended` assertion pins the same behaviour from the other side.

**Second `Tests:` commit (AC7–AC9, after the security review).** `Tools/check.sh --red`,
2026-10-16: `red: ok it compiles and fails on assertions (kit: fail, app: pass)`, `check: ok — red
for the right reason`. Kit: 607 tests, 3 issues. The AC1–AC6 tests are green on the builder's implementation. The only
failures are the new ones, and each matches its prediction:

```
HostSelectionGateForgettingTests ("Host selection gate: a host being forgotten")
AC7: a selection begun while B is being forgotten is not current     Expectation failed: !gate.isCurrent(during)
AC8: once forgetting B finishes, a new selection of B is current ... Expectation failed: !gate.isCurrent(during)   (precondition)
AC9: forgetting B does not affect a selection of C begun meanwhile   Expectation failed: !gate.isCurrent(ofB)      (precondition)
```

One planner line was added to an existing test. `"AC3: selecting a forgotten host again does not
revive the old ticket"` now calls `gate.finishForgetting(b)` before re-selecting, because under
AC7 a selection begun mid-forget is rightly not current. The added line goes into this `Tests:`
commit, and no line of the earlier commit changed. The stub is `finishForgetting` as a no-op,
with `forget` not yet marking.

**Third `Tests:` commit (AC10, at `689848f`).** This is a guard test, so `Tools/check.sh --red`
does not apply: it passes against the current implementation, and every other test is green too.
To show that it guards something, `HostSelectionGate.swift` was mutated twice and restored with
`git checkout --` each time. With either mutant, AC10 was the only failing gate test (10 tests,
1 issue):

```
today                                          ✔ AC10 passed
finishForgetting does forgetting.removeAll()   ✘ AC10: Expectation failed: !gate.isCurrent(whileBIsForgotten)
mark held in one slot (UUID?, not Set<UUID>)   ✘ AC10: Expectation failed: !gate.isCurrent(whileBIsForgotten)
restored (git checkout --)                     ✔ AC10 passed
```

## Verification

Verifier, 2026-10-16, at `f486d1a`. Each mutation was applied alone to the kit source, run with
`swift test --disable-sandbox --filter 'HostSelectionGateTests|HostRegistryTests'`, and restored
with `git checkout -- <file>`. Afterwards the whole suite was green again and the tree was clean.

| AC | Undone how | Test failure with it undone |
|---|---|---|
| AC1 | `gate.forget` returns true but no longer clears `current` | `AC1: forgetting B ends a pending selection of B`: `!gate.isCurrent(ticket)`; `#104 AC1: forgetting B while its token read is held …`: `!gate.isCurrent(ticket)` |
| AC1 | `gate.forget` always returns false | both AC1 tests: `ended`, `!gate.isCurrent(ticket)` |
| AC1 | `relayDeviceToken` checks membership **before** the read, not after | `#104 AC1: a token read that a forget overtakes yields no token`: `try await read.value == nil`; `#104 AC1: forgetting B while …`: `token == nil` |
| AC2 | `gate.forget` ends the current ticket whatever host it is for | `AC2: forgetting C leaves a pending selection of B current`: `!ended`, `gate.isCurrent(ticket)`; `AC2: forgetting a host whose selection was superseded …`: `!ended`, `gate.isCurrent(newer)` |
| AC2 | `gate.forget` clears any ticket (`defer { current = nil }`) but reports by host | the same two AC2 tests: `gate.isCurrent(ticket)`, `gate.isCurrent(newer)` |
| AC3 | `begin` stores the ticket only when none is current (no supersede) | `AC3: a newer selection supersedes an older one`: `!gate.isCurrent(older)`, `gate.isCurrent(newer)`; superseded-forget AC2 test: `!ended`, `gate.isCurrent(newer)` |
| AC3 | `end()` is a no-op | `AC3: ending the selection makes its ticket stale`: `!gate.isCurrent(ticket)` |
| AC3 | `isCurrent` compares the host only, not the ticket id | `AC3: selecting a forgotten host again does not revive the old ticket`: `!gate.isCurrent(old)` |
| AC4 | `relayDeviceToken` returns the store's token with no membership check | `#104 AC4: no token is handed out for a host that is not saved`: `try await registry.relayDeviceToken(for: stray.id) == nil` (and both AC1 registry tests) |
| AC5 | the saved-host guard removed from `setSelection` | `#104 AC5: a selection naming a host that is not saved is not recorded`: `await registry.selection == nil`, `disk.hostStore.loadSelection() == nil` |
| AC1-5 | `git revert --no-commit 2532ef7` (the whole kit commit), then `--abort` | 604 tests, 12 issues: the same set as the Red evidence |
| AC6 | no automated test, as planned; checked by reading `AppModel.swift` | see below |

`#104 AC2: forgetting another host leaves a held token read intact` passes under every mutation
above, as planned: it guards against a fix that drops every in-flight read, and none of these
mutations does that.

**AC6, by reading `AppModel.swift` at `f486d1a`.** It holds.
- `selectionID` is gone (`grep` finds nothing). `selections.begin(host.id)` runs after
  `resetHostScopedState()`, whose `end()` would otherwise clear the new ticket.
- Every suspension in `select` is followed by `guard selections.isCurrent(selection)` before
  anything is published: `previous?.stop()` (:331), `relayDeviceToken` (:335), the `catch` entry
  (:406), `setSelection` (:396, new), and `drafts.navigation` inside `restoreNavigation` (:1460,
  new), plus a check after `restoreNavigation` returns (:398).
- `apply(snapshot:)` and the `observeDecisions` loop check synchronously before they publish.
  `apply(status:)` checks on entry only (see the findings).
- `forget` calls `selections.forget(host.id)` and `disconnect()` before its first `await`. The
  post-await `selectedHost` check is gone.
- **Where the last check moved.** It now runs right after `restoreNavigation`, before
  `applyLaunchSessionOverride()` and `replayDeferredNotification()`, where it used to run just
  before `recovery.setForeground`. That is correct. Both calls are synchronous, so nothing can
  suspend between the new check and `setForeground`. A current selection behaves exactly as
  before. Only a stale selection behaves differently: it no longer sets `selectedSessionId` from
  `DSH_SESSION`/`DSH_DESTINATION` (Debug only), and it no longer consumes `deferredNotification`.
  Before this change a stale replay either deferred the tap again (`selectedHost == nil`) or sent
  it to whichever host had replaced it. Now the tap stays held for the current selection's own
  replay, or for the next `select`. No tap is lost. I found no other user-visible difference.
- **The approved behaviour.** Forgetting the connected host disconnects even if the list save
  fails. The published selection's ticket is never ended while it is connected (the re-select
  path does not begin a new one), so `selections.forget` returns true and `disconnect()` runs
  before `registry.forget`. The `listNotSaved` branch then reloads `hosts`, sets `hostError` and
  returns without reconnecting. `idleStatus` is `.offline`, because `hosts` is still non-empty.

**Version and size.** PATCH is right under RELEASING.md: a bug fix, and the new public type is
additive. The CHANGELOG line is under `## [Unreleased]` / `### Fixed` and covers the approved
behaviour change. Production Swift from `e87023e` to `HEAD` is +44/−29 (`AppModel` 24/19,
`HostRegistry` 8/3, `HostSelectionGate` 12/7), under the 50-line threshold. `Tools/must-test.txt`
gains `State/HostSelectionGate.swift 95`.

- `Tools/check.sh` (full): green in 136 s. 604 kit tests passed, coverage was 88.53% against an
  88.50% baseline, Debug and Release built, and 4 app tests passed. The guard-tests check was ok.
  Coverage rose by 0.03 points; the baseline was not raised (WORKFLOW step 6), and that is left to
  the orchestrator.
- Risk checklist: in the PR.

**Findings, none blocking.**
1. `apply(status:selection:)` checks the ticket on entry only, then awaits
   (`coordinator?.remoteEvents()`, `hostStore.start()`, `refreshSessions()`,
   `subscribeToDecisions`) and reads the *current* `self.hostStore`/`self.coordinator`. A newer
   selection that publishes during those awaits could have a stale status apply start its store,
   and `subscribeToDecisions` could build its `interactionStore` with the stale ticket. Then
   `observeDecisions` would refuse every snapshot, and that host's decision cards would never
   show. This predates #104: `selectionID` had the same single entry check. It is outside the
   plan's AC6 list. A forget alone cannot trigger it, because `disconnect` nils `hostStore`. It
   needs a follow-up issue in the host-lifecycle cluster.
2. The plan's Out of scope says the gallery case is "unchanged". It is not, strictly. Before #104
   the post-await `selectedHost?.id == host.id` check disconnected a gallery-seeded host when it
   was forgotten. Now `seedForGallery` takes no ticket, so forgetting it does not disconnect. The
   impact is Debug only.
3. Forgetting the *previously published* host A while `select(B)` is pending no longer
   disconnects, which is right because B carries on. `selectedHost` still names the forgotten A
   until B publishes or fails. That is a short, visible window, not a lasting state.

### Re-verification after the security review (AC7–AC9), at `f711824`

The same method as above. Each change was made alone to `HostSelectionGate.swift` and restored
with `git checkout --`. Afterwards all 607 tests were green and the tree was clean.

| AC | Undone how | Test failure with it undone |
|---|---|---|
| AC7 | `forget` does not insert the mark | AC7: `!gate.isCurrent(during)`; AC8: `!gate.isCurrent(during)` (precondition); AC9: `!gate.isCurrent(ofB)` (precondition) |
| AC7 | `begin` ignores the mark (`current = ticket`) | the same three failures |
| AC8 | `finishForgetting` does nothing | AC8: `gate.isCurrent(after)`; AC3 "does not revive": `gate.isCurrent(fresh)` |
| AC9 | the mark is global (`!forgetting.isEmpty`) | AC9: `gate.isCurrent(ofC)` |
| AC7-9 | `git revert --no-commit e32d9dd` (slice B's kit commit), then `--abort` | 607 tests, 3 issues: the same set as the second red run |
| — | `begin` during a forget keeps the previous ticket current (`if !forgetting.contains(hostId) { current = ticket }`) | **passes**: not pinned, see below |
| — | a single-slot mark (`forgetting = [hostId]`), so a second forget replaces the first | **passes**: not pinned |
| — | `finishForgetting` clears every host (`removeAll()`) | **passes**: not pinned |

- `Tools/check.sh` (full): green in 124 s. 607 kit tests passed, coverage was 88.54% against an
  88.50% baseline, Debug and Release built, 4 app tests passed, and the guard-tests check was ok.
  The added line in the AC3 revive test belongs to the second `Tests:` commit, and guard-tests
  accepts it.
- **AC6, `forget`, by reading.** `defer { selections.finishForgetting(host.id) }` is the statement
  right after `if selections.forget(host.id) { disconnect() }` (which is synchronous and cannot
  throw), and it comes before the first `await` (`registry.forget`). A Swift `defer` runs on every
  way out of the scope it was registered in, so it runs on the `listNotSaved` `return`, on the
  partial-failure `catch`, and on success. In each case it runs after the final
  `hosts = await registry.hosts`, so the mark is held until the list on screen has been updated.
  This holds.
- **`begin(B)` during B's forget also ends the previous ticket: correct.** In the app, nothing
  observable depends on it. `select` calls `resetHostScopedState()` immediately before `begin`,
  that reset calls `end()`, and so `current` is already nil when `begin` runs. The previous host's
  streams and stores are torn down by then too. As a rule of the gate on its own terms it is also
  the right choice: every `begin` supersedes (AC3). Keeping the previous ticket current would let
  an older pending selection resume and publish into state that a newer `select` has already
  reset, after the user asked for a different host. It is untested: the mutation that keeps the
  previous ticket passes all 25 gate and registry tests. Given the reset, that gap is harmless
  today.
- **Size.** Production Swift from the plan commit to `HEAD` is +92/−22: `HostSelectionGate` +58
  (31 of them code, the rest doc comment), `AppModel` +26/−19 and `HostRegistry` +8/−3. Slice B
  added +11/−7 (gate +8/−6, `AppModel` +3/−1).

**Finding, not blocking.** Nothing tests that the mark is per host when two forgets overlap. A
single-slot mark, or a `finishForgetting` that clears every host, passes every test. In the app,
`forget(B)` and then `forget(C)` can overlap, because each runs in its own `Task` from the hosts
list. With either of those mutations, C finishing would clear B's mark while B's registry forget
is still awaiting, and that reopens the AC7 gap for B. The code is right today (`Set.insert` and
`Set.remove`). One more gate test would pin it: `forget(b)`, `forget(c)`, `finishForgetting(c)`,
then a `begin(b)` must not be current. The same counting limit applies to forgetting the same host
twice at once: the first `finishForgetting` clears the mark while the second forget is still in
flight. In practice that is hard to reach, because the host has already left the list by then.

## Notes for the next person

- An actor-owned "is this still current?" check is one `await` stale by the time you act on it.
  When the actor's caller is the one that publishes, keep the generation in the caller's isolation
  domain, and keep the actor's own guard for what it hands out.
