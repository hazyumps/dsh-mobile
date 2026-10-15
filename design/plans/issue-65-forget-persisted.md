# Issue #65: forgetting a host is not persisted

**Status:** approved (Dan, 2026-10-15; all seven design deviations accepted)
**Branch:** `issue-65-forget-persisted`
**Version impact:** PATCH. This is a bug fix. `HostRegistry` is a new kit type; nothing public is
removed or changed, and `hosts.json`, `selection.json` and the drafts files keep their formats. No
bump in this PR, just a line under `## [Unreleased]`.

## Context

`AppModel.forget(_:)` (`Apps/DSHRemote/Sources/AppModel.swift:1686-1698`) removes the host from the
in-memory `hosts`. It deletes the Keychain token in a fire-and-forget `Task` (`try?`), and removes
drafts in another `Task`. It never calls `store.save(hosts)`; the only save is in `claim` (`:1672`).
After a relaunch the "forgotten" host comes back from `hosts.json` with no credential, and selecting
it ends in `missingCredential`. `DraftStore.remove(hostId:)` only schedules a debounced write
(`DraftStore.swift:407-411`), so the drafts may survive the relaunch too.
`HostStoreTests.forgettingIsScoped` could not catch this, because it drives `HostStore` directly and
not the app's path. Separately, `disconnect()` (`:1700`) skips resets that `select()` does
(`:320-352`): `commandStore`, `attachmentUploader`, `attachmentReader`, `stagedAttachments`,
`attachmentError`, `stagedImages`, `imageError`, `hostSnapshot`, `sessionProjections`, `commands`
and `commandMessage`. So forgetting the selected host leaves its staged files and commands behind.

The fix moves the host lifecycle into a kit actor, `HostRegistry`, and gives the app one door into
it. Disk is the source of truth: a forget whose list save fails leaves the host in place and says so.

## Acceptance criteria

- **AC1 (the reproduction).** Two hosts are paired and on disk, and the selection points at one of
  them. Forget the selected one, then build a fresh `HostStore` and `HostRegistry` on the same
  directory and secret store. Only the other host remains, and its token is untouched. The forgotten
  host's token is `nil`, and no selection is saved.
- **AC2.** When `forget` returns, the forgotten host's drafts and navigation are gone from disk: a
  fresh `DraftStore` on the same directory, read without waiting, has none of them. The other host's
  draft is intact.
- **AC3.** Forgetting a host that is not selected leaves the saved selection alone.
- **AC4.** If the list cannot be saved, `forget` throws `.listNotSaved` and changes nothing: the host
  is still in `registry.hosts` and on disk, and its token and drafts are still there.
- **AC5.** If the token cannot be deleted, `forget` throws `.credentialNotRemoved`. The host is still
  gone from disk and its drafts are still removed. The failure is reported, not retried.
- **AC6.** `add(_:token:)` persists both halves. A fresh registry lists the host and reads its token
  back through `relayDeviceToken(for:)`.
- **AC7.** If the list cannot be saved, `add` throws `.listNotSaved` and leaves no orphaned token:
  the host is not listed, and its token is `nil`.
- **AC8.** At launch the registry drops a saved selection that names a host no longer on disk
  (today's `AppModel.init` reconcile). A selection set through the registry is what the next launch
  reads.
- **AC9 (app).** `AppModel` does not construct `HostStore` or `KeychainSecretStore` and holds
  neither. It does not save the list or write a token itself; everything goes through `registry`.
  `hosts` is `private(set)` and mirrors the registry after every call. `forget` is `async`: a
  `.listNotSaved` keeps the host and shows the error, and any other error is shown after the host
  is gone. **Guarded by a new `Tools/lint.sh` rule, which prevents the class.**
- **AC10 (app).** `disconnect()` clears every piece of host-scoped state that `select()` clears,
  because both call one `resetHostScopedState()`. **No test guards this.** It is structural; see
  "Unguarded" below.

## Test list

All tests are in `Tests/DSHRemoteKitTests/HostRegistryTests.swift`. Each test gets its own temporary
directory and its own `InMemorySecretStore`, with no shared state. AC1 seeds the disk directly
(`HostStore.save` plus `setRelayDeviceToken`), so it reads as "paired in an earlier launch". That way
it fails on `forget` alone and not on `add`. A save failure is forced by making the host directory
read-only (`0o555`, restored in `defer`). A token-delete failure uses a test-local
`FailingDeleteSecretStore`.

| AC | Test name | Fails today because |
|---|---|---|
| AC1 | `"AC1: a forgotten host stays forgotten after a relaunch"` | the stub `forget` only edits memory: the reloaded list still has both hosts, the forgotten token is still set, and the selection file still names it |
| AC2 | `"AC2: a forgotten host's drafts and navigation are gone from disk when forget returns"` | the stub never touches drafts: the fresh `DraftStore` still has the draft |
| AC3 | `"AC3: forgetting an unselected host keeps the selection"` | guard. It passes against the stub, and fails if `forget` clears the selection every time |
| AC4 | `"AC4: a forget whose list cannot be saved throws and changes nothing"` | the stub does not throw, and it has already dropped the host from memory |
| AC5 | `"AC5: a token that cannot be deleted is reported, and the host is still gone from disk"` | the stub does not throw, and the reloaded list still has the host |
| AC6 | `"AC6: an added host and its token survive a relaunch"` | the stub `add` only edits memory: the reloaded list is empty and the token is `nil` |
| AC7 | `"AC7: an add whose list cannot be saved throws and leaves no token"` | the stub does not throw |
| AC8 | `"AC8: a selection naming a host no longer saved is cleared at launch"` | the stub `init` does not reconcile: `selection` is still set |
| AC8 | `"AC8: a selection set through the registry is read by the next launch"` | the stub `setSelection` writes nothing: `selection` is `nil` |

**Stubs** in `Sources/DSHRemoteKit/Persistence/HostRegistry.swift`, compiling and never crashing:

```swift
public enum HostRegistryError: Error, Equatable, Sendable {
    case listNotSaved(reason: String)
    case credentialNotSaved(reason: String)
    case credentialNotRemoved(reason: String)
    case draftsNotRemoved(reason: String)
}
public actor HostRegistry {
    public nonisolated let initialHosts: [SavedHost]   // what init loaded, for AppModel's sync init
    public private(set) var hosts: [SavedHost]
    public var selection: HostSelection?
    public init(store: HostStore = HostStore(), secrets: any SecretStore = KeychainSecretStore(),
                drafts: DraftStore)
    public func add(_ host: SavedHost, token: String) async throws
    public func forget(_ id: UUID) async throws
    public func setSelection(_ id: UUID?) throws
    public func relayDeviceToken(for id: UUID) async throws -> String?
}
```

The stubs load the list, edit `hosts` in memory, and return `nil` or do nothing for the rest. So
`forget` reproduces today's bug exactly, and every test except the AC3 guard fails on an assertion.

## Design decisions (for gate 1)

- **Order in `forget`:** (1) save the list without the host. A failure throws `.listNotSaved`, and
  memory, the selection, the token and the drafts are all left alone. (2) Reconcile the selection.
  (3) Delete the token. (4) `drafts.remove(hostId:)`, then `flush()`. Steps 2 to 4 all run even if
  one of them fails, and the first failure is thrown (`.credentialNotRemoved` / `.draftsNotRemoved`).
  A failed token delete is not a reason to leave drafts behind. Nothing is retried.
- **Order in `add`:** token, then append and save. A failed token write throws
  `.credentialNotSaved` and changes nothing. A failed save rolls back the append, deletes the token,
  and throws `.listNotSaved`.
- **Selection goes through the registry.** I chose this over leaving it on `HostStore`.
  `restoreLastHost` reads `registry.selection`, and `select` calls `registry.setSelection`. That
  leaves the app holding no `HostStore` at all.
- **No construction site in `Apps/`.** I changed this from the agreed approach. The registry's
  `store` and `secrets` parameters default to `HostStore()` and `KeychainSecretStore()`, so the app
  writes `HostRegistry(drafts: drafts)`. That gives the lint rule zero hits in `Apps/` and needs no
  allowlist entry. The allowlist holds *tracked violations* with exact counts, and a permanent
  construction site is not a violation.
- **`initialHosts` is `nonisolated let`.** `AppModel.init` is synchronous and sets `idleStatus` from
  the list. If it awaited the actor first, the pairing intro would flash on every launch.
- **The error strings** carry an `OSStatus` or a file error, never a token (S9).

## Slices

| Slice | ACs | Files | Notes |
|---|---|---|---|
| A (kit) | AC1–AC8 | `Sources/DSHRemoteKit/Persistence/HostRegistry.swift`, `Tools/must-test.txt` (`Persistence/HostRegistry.swift 90`), `Sources/DSHRemoteKit/README.md` (test table row) | builds against the planner's tests only |
| B (app) | AC9, AC10 | `Apps/DSHRemote/Sources/AppModel.swift`, `HostsView.swift:48`, `SettingsScreens.swift:152`, `Tools/lint.sh`, `CHANGELOG.md` | compiles against the stub signatures, so it can run beside A. Its lint rule goes green only when its own AppModel edit lands |

Slice B in detail:

- `private let store` and `private let secrets` are replaced by `private let registry`, and
  `hosts = registry.initialHosts`.
- `select` reads its token through `registry.relayDeviceToken(for:)`.
- In `claim`, the three lines at `:1670-1672` become `try await registry.add(host, token:
  claim.token)` followed by `hosts = await registry.hosts`. **`PairingClient(transport:)` and
  `client.claim(...)` are left exactly as written** (see Coordination).
- `forget` becomes `async` and publishes `private(set) var hostError: String?`, rendered next to
  `claimError` in `HostsView` and in the Settings host list.
- The two call sites become `Task { await model.forget(host) }`.
- `resetHostScopedState()` holds the shared resets: the eleven listed in Context, plus the ones both
  paths already share. Each caller keeps its own extras: `select` keeps `await previous?.stop()` and
  `idleStatus = .connecting`, and `disconnect` keeps `releaseTimedClaim`, `origin`, `selectedHost`
  and the workspace and session ids.

**The lint rule `host-lifecycle`** fails on `\bHostStore\(`, `KeychainSecretStore\(`,
`\.save\(hosts` or `(set|delete)RelayDeviceToken\(` anywhere under `Apps/`. The reason it gives is
#65: the list and the token change together, in the registry, or they drift apart.

## Coordination

`AppModel.swift` is shared with the **#63** session (`issue-63-…`). Its only `AppModel` edit is
around `:522` (`submitEventResult`), and it has said it will not touch the claim block. #63 is
changing `PairingClient` in the kit, so this branch leaves those two lines alone and expects a
textual merge at most. #63 also removes the `retry-none` entry from `Tools/lint-allowlist.txt`,
which this branch does not touch. Whichever branch merges second rebases.

## Risk flags

- [x] **S4 secrets and the host lifecycle.** This changes pair, forget and disconnect. AC1 and AC6
  reload from disk after the operation. No token goes into `hosts.json`, an error string or a log.
- [x] **C3 concurrency.** `HostRegistry` is a new `actor` and has no `@unchecked` or `unsafe`. The
  app's two fire-and-forget `Task`s are removed. The tests await `forget` and never sleep.
- [x] **C6 UI with no kit test.** AC10 (see below). AC9 is guarded by lint and the app build.
- [x] **S3 pairing** (ticked after security review). The claim block's persistence moved to
  `registry.add`; `PairingClient(transport:)`, `client.claim(...)` and the trust policy are
  unchanged. Pre-existing and out of scope: the stored pin falls back to `claim.fingerprint` when
  the payload has none, a pin learned from the network (SPEC §3.2) — filed as its own issue.
- [x] **S9 what leaves the sandbox** (ticked after security review). The new `hostError` text holds
  the host's display name and a Keychain OSStatus or file-error reason; no token, account value or
  session content can reach it (security review on the PR).
- [ ] C1 persisted formats is **not ticked**. The same files are written in the same encoding.

## Unguarded

AC10 has no test. `AppModel` builds a real `HostStore()` and Keychain in the hosted app, so the app
test target (`Tests/DSHRemoteTests`) would touch the simulator's real state. Seeding staged
attachments also needs a selected, connected host. The guard is structural: `disconnect` and
`select` call one function, so a reset added to one path is added to both. The verifier should
confirm by reading that `resetHostScopedState()` covers every property `select` used to clear. The
real fix is the per-host state object in the AppModel extraction, which is outside this issue.

## Out of scope

- **`imageCache` is never cleared per host.** It is in memory only and byte-bounded (an LRU), so
  nothing persists and nothing survives a relaunch. It is keyed by session id plus attachment id,
  with no host in the key. Two hosts could share a session id, so a per-host key (or a clear in
  `resetHostScopedState`) is worth its own small issue. It is a hygiene item, not the persistence
  bug this issue is about.
- **Revoking the device at the relay.** SPEC §6.3 keeps forget and revoke separate, and the
  confirmation text already says so.
- **Moving the rest of `select`/`disconnect` into the kit.** That is the AppModel extraction. This
  issue moves only the host lifecycle.

## Red evidence

`Tools/check.sh --red` with the tests and the stub, nothing else:

```
red: ok it compiles and fails on assertions (kit: fail, app: pass; logs in .build/check).
check: ok — red for the right reason (78s)
```

Kit: 514 tests in 37 suites, **16 issues**, all in `Host registry`. They are all assertion
failures, with no compile error or crash. App tests: 4 pass. Every failure matches the prediction.

| Test | Failure (`HostRegistryTests.swift`) |
|---|---|
| AC1 forgotten host stays forgotten | `:80` `relaunched.hosts == [keep]`; `:81` `hostStore.load() == [keep]`; `:83` forgotten token `== nil`; `:84` `loadSelection() == nil`; `:85` `relaunched.selection == nil` |
| AC2 drafts gone from disk | `:109` draft text `== ""`; `:110` `draftCount == 0`; `:111` `navigation == DraftNavigation()` |
| AC3 unselected forget keeps selection | **passes**. This is the guard, as predicted |
| AC4 unsavable list changes nothing | `:155` expected `.listNotSaved`, got `nil` (no throw) |
| AC5 undeletable token reported | `:185` expected `.credentialNotRemoved`, got `nil` (no throw) |
| AC6 add survives relaunch | `:206` `relaunched.hosts == [paired]`; `:207` token `== "fresh-token"` |
| AC7 unsavable add leaves no token | `:229` expected `.listNotSaved`, got `nil` (no throw) |
| AC8 stale selection cleared at launch | `:249` `registry.selection == nil`; `:250` `loadSelection() == nil` |
| AC8 selection survives relaunch | `:263` `selection?.hostId == keep.id` |

AC4 and AC7 stop at the throw check, so their "nothing changed" assertions have not run yet. They
run once `forget` and `add` throw. The read-only trick (`0o555` on the host directory) is not yet
proven to make `HostStore.save` fail, because the stub never saves. If AC4 or AC7 later reports
"got nil" against a real implementation, the trick is the suspect and not the builder.

## Verification

Verified 2026-10-15 on `e0a3dcd` by an agent that did not build the branch. Each row undoes one
behaviour in `Sources/DSHRemoteKit/Persistence/HostRegistry.swift` (or `AppModel.swift` for AC9)
and runs `swift test --disable-sandbox --filter HostRegistryTests`. After each one the file was
restored with `git checkout -- <file>` and the full kit suite was green again (514 tests).

| AC | Undone how | Test failure with it undone |
|---|---|---|
| AC1 | `forget` skips `store.save(remaining)` | `:80` `relaunched.hosts == [keep]`; `:81` `hostStore.load() == [keep]` (AC4 and AC5 fail too) |
| AC1 | `forget` skips `deleteRelayDeviceToken` | `:83` `relayDeviceToken(forHostUUID: drop.id) == nil` (AC5 fails too) |
| AC1 | `forget` skips `reconcileSelection` | **passes.** See finding 1 |
| AC2 | `forget` calls `drafts.remove` but not `flush()` | `:109` draft text `== ""`; `:110` `draftCount == 0`; `:111` `navigation == DraftNavigation()` (AC5 `:190` fails too) |
| AC3 | `forget` always clears the selection (`saveSelection(nil)`) | `:127` `loadSelection()?.hostId == keep.id`; `:128` relaunched `selection?.hostId == keep.id` |
| AC4 | `hosts = remaining` before the save | `:158` `registry.hosts == [keep, drop]` |
| AC4 | token deleted before the save | `:161` token `== "token-drop.local"` |
| AC4 | drafts removed and flushed before the save | `:162` draft text `== "half a thought"` |
| AC4 | selection reconciled before the save | **passes.** See finding 2 |
| AC5 | a failed token delete is not recorded | `:185` `expected .credentialNotRemoved, got nil` |
| AC5 | a failed token delete throws at once, skipping drafts | `:190` `draftCount(hostId: drop.id) == 0` |
| AC5 | a failed token delete is retried once | `:191` `deleteAttempts == 1` |
| AC6 | `add` skips `store.save(updated)` | `:206` `relaunched.hosts == [paired]` (AC7 `:229` fails too) |
| AC6 | `add` skips `setRelayDeviceToken` | `:207` `relayDeviceToken(for:) == "fresh-token"` |
| AC7 | `add` skips the token rollback | `:234` `relayDeviceToken(forHostUUID: paired.id) == nil` |
| AC7 | `hosts = updated` before the save | `:232` `registry.hosts == [existing]` |
| AC8 | `init` reads `loadSelection()` instead of reconciling | `:249` `registry.selection == nil`; `:250` `loadSelection() == nil` |
| AC8 | `setSelection` sets memory only | `:263` relaunched `selection?.hostId == keep.id` |
| AC9 | added to `AppModel`, one at a time: `HostStore()`, `KeychainSecretStore()`, `store.save(hosts)`, `setRelayDeviceToken(`, `deleteRelayDeviceToken(` | `Tools/lint.sh` exits 1 with `host-lifecycle Apps/DSHRemote/Sources/AppModel.swift:122: …` each time |
| AC9 | `try store.save(list)` on an injected `HostStore`, or `setSecret(_, for: RelayDeviceCredential.account(...))` | lint passes. The pattern is textual, so these slip through, but each one needs a `HostStore` or a `SecretStore` in hand, and building one is caught. Acceptable |
| AC10 | not testable (see "Unguarded"); read instead | see below |

**AC10, by reading.** On `main`, `select()` cleared 32 things (`AppModel.swift:319-352`): four task
cancels, then `recovery`, `coordinator`, `hostStore`, `secondaryStore`, `plugins`, `pluginsReport`,
`scheduledTasks`, `scheduledTasksReport`, `modelModeStore`, `commandStore`, `attachmentUploader`,
`attachmentReader`, `stagedAttachments`, `attachmentError`, `stagedImages`, `imageError`,
`hostSnapshot`, `sessionProjections`, `commands`, `commandMessage`, `catalog`, `catalogState`,
`stagedMode`, `stagedModel`, `interactionStore`, `interactions`, `browse` and `selectionID`.
`resetHostScopedState()` clears all of them, in the same order. `select()` and `disconnect()` both
call it. `disconnect()` keeps its own extras: `releaseTimedClaim`, `origin`, `selectedHost`, the
workspace and session ids, and `idleStatus`. `recovery?.setForeground(false)` now runs before the
task cancels and not after them. That makes no difference. `ForegroundConnection` is
`@MainActor`, and `disconnect()` runs from start to end on the main actor with no `await`. A
`cancel()` only sets a flag, and the shutdown `Task` that `setForeground` starts cannot run until
`disconnect()` returns. So nothing can see the steps in between.

- `Tools/check.sh` (full): **green**, 135 s. That is lint, models, version 0.2.0 (238), planner
  tests untouched, 514 kit tests, coverage 86.83% against a baseline of 86.83%
  (`Persistence/HostRegistry.swift` at 95.95%, floor 90), the Debug and Release builds, and 4 app
  tests. The first run, on a cold tree, failed only at `coverage`, and printed nothing. At that
  moment the test binary was newer than `default.profdata`, so `llvm-cov` said "no coverage data
  found". Under `set -euo pipefail`, `Tools/coverage.sh` then exits 1 inside the `table=`
  assignment, before it reaches its own error message. Re-running `swift test
  --enable-code-coverage` and then `Tools/coverage.sh` was green, and so was the second full run.
  This is a tooling flake, not something this branch caused. See finding 3.
- Version impact **PATCH**. This agrees with `RELEASING.md` ("a bug fix"). `project.yml` and
  `Info.plist` are not touched. The formats of `hosts.json`, `selection.json`, the drafts and the
  Keychain are unchanged. `HostRegistry` adds to the public API and changes nothing that exists.
  The new `hostError` label only reports a failure of the fix, so it is not a new feature. The
  `CHANGELOG.md` line is under `## [Unreleased]` → `### Fixed` and cites #65.
- Risk checklist. **S4**: forget + relaunch removes the host, the token, the selection and the
  drafts (AC1 and AC2 reload from fresh stores). The token reaches only `SecretStore`, and the error
  reasons are `String(describing:)` of a file or Keychain error, never a token. S4 is a security
  flag, so the security reviewer still has to sign it off before the PR. **C3**: one new `actor`,
  with no `@unchecked` or `unsafe`. The app's two fire-and-forget `Task`s are gone, and the tests
  await and never sleep. **C6**: AC10 was checked by reading (above). AC9 is held by lint and the
  app build.

**Findings for the human:**

1. **AC1's selection clause is not guarded on its own.** Remove the
   `selection = store.reconcileSelection(with: remaining)` in `forget`, and AC1 still passes.
   `relaunched` is built at `:79`, before the selection asserts at `:84-85`. Its `init` reconcile
   (AC8) clears the stale file first, so the launch-time reconcile masks the one at forget time.
   For the user nothing changes, because the next launch reconciles anyway. In memory, though,
   `registry.selection` keeps naming a forgotten host until relaunch, and no test sees that.
   Asserting `disk.hostStore.loadSelection() == nil` and `await registry.selection == nil` before
   relaunching would guard it. That is the planner's call.
2. **AC4's "selection unchanged" assert cannot fail under its fixture.** Mutation: reconcile the
   selection before the list save. The test still passes, because the `0o555` host directory also
   stops `removeItem` of `selection.json`. In real life a save can fail while an unlink succeeds
   (disk full, for example), so the ordering is untested. The implementation itself is in the right
   order. This is minor.
3. **`Tools/coverage.sh` fails silently** when `llvm-cov report` errors. The `set -e` exit fires
   inside the `table=$(…)` pipeline, before the "could not read a TOTAL line" message. It caused
   one unexplained red `check: RED … - coverage` here. It is unrelated to #65, but worth its own
   `process` issue.
4. Minor, UX: `hostError` is cleared only when the next `forget` starts. A "forgotten, but not
   completely" message stays up across later pairing and selection.
5. The `.draftsNotRemoved` path has no test (no AC asks for one). It accounts for some of the 3
   lines `HostRegistry.swift` leaves uncovered.

**Findings 1, 2 and 5, answered in a second `Tests:` commit.** These tests ran against the built
`HostRegistry.swift`, and the suite is green (516 tests). Each mutation was undone with
`git checkout --`.

| Change | Mutation that now fails it |
|---|---|
| AC1 now asserts `loadSelection() == nil` and `registry.selection == nil` *before* the relaunch (`:93-94`) | `forget` without `reconcileSelection` fails `:93` and `:94` |
| New test, `"AC4: a forget whose list cannot be saved leaves the selection alone"`. It replaces `hosts.json` with a directory, so only the list write fails | reconcile before the save fails `:204` (`loadSelection()?.hostId == drop.id`) and `:205` (`registry.selection`) |
| New test, `"AC5: drafts that cannot be written away are reported, and the host and token are still gone"`. It uses an injected failing `DraftStore` write | swallowing the flush error fails `:255` (`expected .draftsNotRemoved, got nil`) |

## Notes for the next person

`HostStoreTests.forgettingIsScoped` passed throughout the bug, because it tested the store and not
the path the app takes. Any rule about two things changing together (the list and the token) needs
one owner and a test that goes through that owner.
