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
- [ ] S3 pairing is **not ticked**. The claim call and the trust policy are unchanged. Only where the
  result is stored moves.
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

*Filled in by the verifier.*

| AC | Undone how | Test failure with it undone |
|---|---|---|

- `Tools/check.sh`: …
- Risk checklist: …

## Notes for the next person

`HostStoreTests.forgettingIsScoped` passed throughout the bug, because it tested the store and not
the path the app takes. Any rule about two things changing together (the list and the token) needs
one owner and a test that goes through that owner.
