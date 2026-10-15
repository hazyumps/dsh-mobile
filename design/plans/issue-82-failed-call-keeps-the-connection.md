# Issue #82: a failed request must not tear down the connection

**Status:** verified
**Branch:** `issue-82-failed-call-keeps-the-connection`
**Version impact:** PATCH — a behaviour fix. No API change, no persisted format, no generated model.
No bump in this PR; a line under `## [Unreleased]`.

## Context

A **per-request** failure is promoted to a **connection-level** failure. Every RPC path ends
`lastError = failure; applyCallFailure(failure)` (`ConnectionCoordinator.swift:546-547`, plus `:612,
:643, :694, :772, :829, :878`), and `applyCallFailure` applies the failure's status for `.offline`
and `.pairingRequired` (`:1004-1009`). A request timeout is classified `.offline`
(`RelayTransport.swift:209-212` → `offline(detail)` → `.transportInterruption`, `:1063-1065`).
`ForegroundConnection.run()` reads any non-usable status as "the socket has gone"
(`ForegroundConnection.swift:76-85`) and rebuilds the connection.

So one slow reply destroys a healthy connection. With `HomeView` refreshing `session/list` every 15
seconds (`HomeView.swift:106-110`), the status chip flips Connected → Reconnecting → Connected while
every screen looks fine, because the stores swallow their own errors
(`HostSessionStore.swift:568-572`).

This was found chasing the flickering chip on the phone (2026-10-14) and is a defect either way. It
has **not** been reproduced — see "Reproduction status".

## Acceptance criteria

- **AC1** — a call that fails with a transport-shaped failure (a timeout, an interrupted request)
  leaves the connection alone: the coordinator's status stays `.connected`. Because the teardown is
  *caused* by a non-usable status, that also means no new socket is opened — the test notes the
  implication rather than trying to assert "nothing happened" over a window of time.
- **AC2** — a call the host refuses with `.pairingRequired` still repaints the status, so a revoked
  credential is still surfaced and still parks. Unchanged, and guarded by an existing test.
- **AC3** — a genuine socket death still tears down and rebuilds, driven by `$events` ending
  (`streamEnded`, `:902-917`). Unchanged, and guarded by an existing test.

## Test list

| AC | Suite / file | Test name | Fails today because |
|---|---|---|---|
| AC1 | `ForegroundConnectionTests.swift` | `"a call that times out leaves the connection alone"` | `coordinator.status` is `.offline` straight after the call, and `recovery.status` has already left `.connected` |
| AC2 | `ForegroundConnectionTests.swift` | `"a credential rejected mid-connection parks, and a wake earns exactly one fresh attempt"` | guard — passes today, must keep passing |
| AC3 | `ForegroundConnectionTests.swift` | `"a logical events-stream end reconnects and closes the abandoned socket"` | guard — passes today, must keep passing |

*Fakes: the existing `StubRelayTransport` / `StubRelaySocket` / `RecordingRelaySleeper`. No new stub.*

## Slices

| Slice | ACs | Files | Notes |
|---|---|---|---|
| A | AC1–AC3 | `Sources/DSHRemoteKit/State/ConnectionCoordinator.swift` | one `switch` case in `applyCallFailure` plus its comment |
| A | — | `Tests/DSHRemoteKitTests/ForegroundConnectionTests.swift` | one new case |

## Risk flags

- **C3 — concurrency.** The status policy changes; the task structure, the revision protocol and the
  cancellation path do not. The test observes the coordinator's status and a recorded socket count,
  never `Task.sleep`.
- **S1 — not ticked.** No write changes. A write that fails still throws to its caller with
  `retryPolicy: .none` intact; what changes is only whether it *also* tears the socket down.
- **C5 — not ticked.** Nothing here needs the relay. #26/#79 are the relay half of a different
  symptom.

## Out of scope

- **#79** — the relay answering 403 for a Host refusal, which is what makes `.pairingRequired` wrong
  in the first place.
- **#27** — recording *why* a connection ended.
- **A mux keepalive.** See the trade below.

## The trade, stated rather than hidden

With `.offline` no longer promoted from a call, a **half-open** socket (the peer gone, no FIN) is
detected by `$events` ending rather than by a request timing out. `MuxClient` has no keepalive today
(no ping/pong), so if that proves slow on a phone the answer is a keepalive on the mux — its own
issue. It is *not* a reason to keep treating a slow read as a dead socket, which is what makes the
status lie today.

A call that fails because the socket genuinely died is still covered: the same socket failure ends
the `$events` router, and `streamEnded` repaints the connection status.

## Red evidence

`Tools/check.sh --red` on `a3245aa` (the `Tests:` commit) with the fix stashed, so the tree is exactly
the tests:

```
red: ok it compiles and fails on assertions (kit: fail, app: pass; logs in .build/check).
check: ok — red for the right reason (35s)
```

Kit: 505 tests in 36 suites, **2 issues**, both assertion failures — no compile error.

| Test | Message |
|---|---|
| `a call that times out leaves the connection alone` | `coordinator.status == .connected` → not met (`:329`) |
| `a transport failure during session/list reaches the caller and leaves the connection alone` | `coordinator.status == before` → not met (`:676`) |

**A third pre-existing test encoded the defect as the contract** and is rewritten in that commit,
visibly. `StateTests.sessionListTransportFailureIsReported` required
`coordinator.status == .offline` with the comment *"SPEC §6.9 'Offline': the status says so"*. Its
real claim — a transport failure must not become a silent empty list — is kept as the typed throw it
already asserted; what changes is that a call the connection did not break no longer repaints the
connection. The replacement asserts the status is **unchanged**, which is strictly stronger than what
it replaced. It was found by the full check, not by the focused suite: the focused suite was green
while this one was red.

One assertion was written and then **removed for being vacuous**: `eventually { openedSocketRequests
.count == 1 }` returns true on its first check and therefore passes with the bug present. The status
implies the socket count instead, because the teardown is *caused* by a non-usable status.

## Verification

The fix was undone on the finished tree — `git revert --no-commit 20cbeed`, implementation gone and
tests kept — and `Tools/check.sh --red` re-run:

| AC | Undone how | Test failure with it undone |
|---|---|---|
| AC1 | `git revert --no-commit 20cbeed` | `ForegroundConnectionTests.swift:329` — `coordinator.status == .connected` not met; and `StateTests.swift:676` — `coordinator.status == before` not met |
| AC2 | same | `revokedCredentialParksAndRevives` still passes — `.pairingRequired` is still applied |
| AC3 | same | `logicalEndRecovers` still passes — `$events` ending still rebuilds |

- `Tools/check.sh`: **green** (full, 49 s) — 505 tests in 36 suites; coverage 86.74% against the
  86.83% baseline, within the tool's 0.30 run-to-run tolerance and therefore not lowered or raised;
  Debug **and** Release build; app tests pass; `guard-tests` clean.
- Risk checklist: **C3** answered in the PR; S1 and C5 reasoned as not ticked there.

## Reproduction status

Mechanism verified by reading the code; **not reproduced**. The phone's flicker was reported while
the app was not under observation from the Mac, and relay-side polling while the app is backgrounded
measures an idle app — a four-minute watch showed zero sockets and one request. The Diagnostics
screen taken *while it is flickering* would confirm whether generations advance, and that evidence is
still outstanding.
