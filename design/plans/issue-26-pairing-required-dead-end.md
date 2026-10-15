# Issue #26: a parked connection is not a dead end

**Status:** verified
**Branch:** `issue-26-pairing-required-dead-end`
**Version impact:** PATCH — a fix to existing behaviour. No API change, no persisted format, no
generated model. No bump in this PR; a line under `## [Unreleased]`.

## Context

`ForegroundConnection.setForeground(true)` returns early when the last failure was non-retryable
(`ForegroundConnection.swift:50-53`), and `run()` breaks out of its loop on the same condition
(`:90-93`). Because `error` is only cleared by a *success* (`:72`), a single non-retryable failure
permanently blocks every later attempt: each return to the foreground repaints the parked status and
never dials again.

The relay makes this reachable in normal use. On a WebSocket upgrade the relay answers a bare **403
for every Host-fence rejection**, and the fence runs before authentication by design, so the status
code says nothing about the credential. The client maps 403 → `.credentialRejected` → sticky
`.pairingRequired` (`Network/RelayTransport.swift:230`, `State/ConnectionCoordinator.swift:191`,
`:984-988`). Observed on the phone 2026-10-14: a parked `pairingRequired` while the token was valid
until 11-06 and the relay's certificate had not rotated since 10-07.

The two halves are separate. The relay's mislabelling is filed as **#79** and cannot be fixed here
(`AGENTS.md`, "Boundaries"). This plan fixes the half that is ours: **the app must not be
unrecoverable**. A terminal failure should end the *backoff loop* — which is what SPEC §6.4/§6.9
"stop retrying" protects — not the app's ability to try again when the world changes.

The cure today is a relaunch. Relaunching is exactly what "wake listeners armed, one fresh attempt"
replaces, and it is the design the OpenChamber client proves in the field.

## Acceptance criteria

- **AC1** — after a non-retryable failure has parked the connection, the **next foreground
  transition makes exactly one fresh attempt**. Today it makes none.
- **AC2** — the backoff loop still stops. A non-retryable failure never sleeps and never retries
  while the app stays foregrounded; each wake earns one attempt, not a loop.
- **AC3** — if the revived attempt succeeds the connection reports `.connected`, the published
  connection id changes, and the stored error is cleared. If it fails the same way, the same parked
  status returns.
- **AC4** — a *retryable* failure still retries with the existing backoff, unchanged.
- **AC5** — a host with no credential never dials, across any number of wakes (the local refusal in
  `connect()` is not turned into a network attempt by this change).

## Test list

| AC | Suite / file | Test name | Fails today because |
|---|---|---|---|
| AC1, AC3 | `ForegroundConnectionTests.swift` | `"a wake earns one fresh attempt after a parked credential rejection"` | the early return in `setForeground` means `openedSocketRequests` stays 1 and the status never leaves `.pairingRequired` |
| AC3 | `ForegroundConnectionTests.swift` | `"a wake after a changed certificate parks again when the mismatch persists"` | same early return; the old test asserted the dead end as intended (`count == 1`) |
| AC2 | `ForegroundConnectionTests.swift` | `"a parked failure never sleeps and never loops"` | passes today; a guard that the fix does not introduce a backoff loop |
| AC4 | `ForegroundConnectionTests.swift` | `"an unavailable network retries automatically while foregrounded"` | passes today; unchanged guard |
| AC5 | `ForegroundConnectionTests.swift` | `"an unpaired host never dials, across wakes"` | passes today; guard that revival does not dial without a credential |

Two existing tests **encode the defect as the contract** and are rewritten in the `Tests:` commit,
deliberately and visibly — not weakened:

| Existing test | Was | Becomes |
|---|---|---|
| `changedIdentityStops` | "a changed certificate stops retries, including after app switching", asserting `openedSocketRequests.count == 1` after a wake | renamed and re-asserted: it parks, and a wake earns exactly one more attempt |
| `revokedCredentialStops` | "credential rejection stops automatic retries", asserting `count == 1` after a wake | renamed and re-asserted: it parks, and a wake earns exactly one more attempt |

Both keep the part that is still true — **no automatic retry without a wake** — by asserting the
sleeper was never asked to wait and that the count does not grow while the app stays foregrounded.

*Fakes: `StubRelayTransport` (with `enqueue(socket:)`), `StubRelaySocket`, `RecordingRelaySleeper`.
No new stub is needed and no `Sources/` addition is required to make the tests compile.*

## Slices

| Slice | ACs | Files | Notes |
|---|---|---|---|
| A | AC1–AC5 | `Sources/DSHRemoteKit/State/ForegroundConnection.swift` | the whole change is one guard in `setForeground` plus its comment |
| A | — | `Tests/DSHRemoteKitTests/ForegroundConnectionTests.swift` | rewrites + new cases |

## Risk flags

- [x] **C3 — concurrency.** The change is inside the `setForeground` `Task` and alters what runs on a
      revision bump. The `revision`/cancellation protocol is untouched: the wake still cancels the
      previous task and awaits it before running. Tests observe signals (recorded requests, sleeper
      calls), never `Task.sleep`.
- [x] **C5 — the relay.** The full defect needs the relay change in **#79**; this is the client half
      and does not pretend the 403 is now correctly classified. The app recovers *despite* the
      misclassification rather than because it was fixed.
- [ ] S1–S10 — none. Justification for the two closest: **S2** is not ticked because the pin decision
      itself is untouched — a mismatch still fails, still never falls back to CA validation, and never
      takes a different code path; only *when a renewed attempt may happen* changes. **S1** is not
      ticked because a connect opens `$events` and reads; it changes no host state.
- [ ] C1, C2, C4, C6 — none.

## Out of scope

- **The relay's 403.** #79 — the fence needs its own signal (421) so a wrong `Host` stops looking
  like a bad credential. Until then this change makes the app recover anyway.
- **A "Try again" affordance on the parked screen.** `ConversationView.unavailable` (`:226-232`) is a
  `ContentUnavailableView` with no actions, and `setForeground` is idempotent-guarded
  (`:32`), so a user staring at a parked screen has no button to press. Adding one needs a new kit
  entry point (`retry()`), and a test for API that does not exist cannot be committed red-first
  (`Tools/check.sh --red` requires the tests to compile). Filed as a follow-up rather than smuggled
  in here. **AC1 alone restores recovery**: the lifecycle is wired (`.active` → `setForeground(true)`,
  `DSHRemoteApp.swift:38`), so the natural "switch away and back" now retries.
- **Recording why a connection ended** — #27.
- Any change to `RelayTransport`, `SPKIPin`, or `RelayPinningPolicy`.

## Red evidence

`Tools/check.sh --red` on `2b61e2c` (the `Tests:` commit), before any implementation:

```
red: ok it compiles and fails on assertions (kit: fail, app: pass; logs in .build/check).
check: ok — red for the right reason (48s)
```

Kit: 504 tests in 36 suites, 6 issues, every one an assertion failure — no compile error.

| Test | Message |
|---|---|
| `a wake earns one fresh attempt after a parked credential rejection` | `recovery.status == .connected` → not evaluated; `recovery.error == nil` → `credentialRejected(relayError: nil, status: 403)`; `transport.openedSocketRequests.count == 2` → not evaluated |
| `a changed certificate parks, and a wake earns exactly one fresh attempt` | `eventually { transport.openedSocketRequests.count == 2 }` → not evaluated |
| `a credential rejected mid-connection parks, and a wake earns exactly one fresh attempt` | `eventually { transport.openedSocketRequests.count == 2 }` → not evaluated |

The count staying at **1** *is* the defect. `parkedFailureDoesNotLoop` and `unpairedNeverDials`
passed before the change and after it, as intended: they are guards, not red tests.

The first run was a **false red**: the app-tests step could not reach SwiftPM's manifest cache
(`cannot open file '…/Library/Caches/org.swift.swiftpm/manifests/…' for diagnostics emission`), which
is a property of the agent's file sandbox rather than of the change. Re-running with a wider sandbox
gave the honest result above.

## Verification

The fix was undone on the finished tree — `git revert --no-commit cabf1ec`, so the implementation is
gone and the tests remain — and the suite re-run:

| AC | Undone how | Test failure with it undone |
|---|---|---|
| AC1, AC3 | `git revert --no-commit cabf1ec` | `eventually { transport.openedSocketRequests.count == 2 }` not evaluated; the count stays 1; `recovery.error` still `credentialRejected(relayError: nil, status: 403)` |
| AC3 (pin) | same | `eventually { transport.openedSocketRequests.count == 2 }` not evaluated |
| AC2, AC4, AC5 | same | guards still pass — no sleep, no loop, and no dial without a credential |

- `Tools/check.sh`: **green** (full, 61 s) — 504 tests in 36 suites; coverage 86.83%, and the baseline
  raised from 86.70 to 86.83 in the same PR as the coverage rule requires; Debug **and** Release
  build; app tests pass; `guard-tests` clean.
- Risk checklist: **C3** and **C5** answered in the PR; no S-flag ticked, with the S1 and S2
  reasoning given there.

## Notes for the next person

- The parked state is reached from **two** paths: a connect failure (`ConnectError.rpc
  (.credentialRejected)`) and a failure thrown *through* a live connection
  (`applyCallFailure`, `:1004-1009`). Both end in `run()`'s `guard failure.isRetryable else { … break }`,
  so one fix covers both.
- `refreshStatus` (`:984-988`) is *not* the dead end, though it reads like one: it only suppresses
  repainting when the new failure is also `credentialRejected` while already parked. Any other
  failure repaints, and a success still sets `.connected`. The dead end is entirely in
  `ForegroundConnection`.
- Revival is deliberately **not** rate-limited by a timer. `setForeground` only fires on a genuine
  phase change, which is the app's own throttle.
