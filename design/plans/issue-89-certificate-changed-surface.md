# Issue #89: a refused pin must surface as "certificate changed — re-pair", not Offline

**Status:** planned
**Branch:** `issue-89-certificate-changed` (worktree `.claude/worktrees/issue-89`)
**Version impact:** MINOR — new user-visible behaviour (a certificate-changed state with a
re-pair action), per the issue. No bump in this PR; a line under `## [Unreleased]`.

## Root cause, in one sentence

The transport's challenge handler refuses a certificate under a changed pin by answering
`.cancelAuthenticationChallenge`, and **records nothing** — so URLSession's resulting
`URLError.cancelled` is classified as `.cancelled` ("an error to show nothing"), and the phone
sits on **Offline** (or loops Reconnecting on the socket path) instead of saying
"the relay's certificate changed, re-pair" (SPEC §6.9).

## Context — why this is now a real incident, not a hypothetical

2026-10-19: the relay re-minted its self-signed cert with a new key at 07:15:48 (its address set
shrank when the Mac's WireGuard tunnel went down — fixed on the relay side in #114, which makes
this residue rarer). The phone, pinned to the Oct-7 key, could not connect for 2.5 h until
re-paired, and the user saw a generic connection failure. Classification evidence:

- `TransportDelegate.urlSession(_:task:didReceive:completionHandler:)`
  (`Network/RelayTransport.swift:572-590`) computes `pinning.decide(serverTrust:)` and answers
  `.cancelAuthenticationChallenge` on `.reject` — the rejection value is discarded.
- `send` catches and calls `RelayTransportError.classify(error)`; `URLError.cancelled` →
  `.cancelled` (`RelayTransport.swift:216`), documented "An error to show. No error to show."
- `ConnectError.cancelled` → status `.offline`, and `refreshStatus` swallows it
  (`State/ConnectionCoordinator.swift:180-182`).
- Socket path: `URLSessionRelaySocket`'s first `receive()` fails with the same -999 →
  `webSocketFailure` → `classify` → `.cancelled` → `MuxStreamError.socketFailed("transport
  cancelled: …")` — a detail that does **not** carry the "TLS pin mismatch" prefix
  `socketFailure` recovers on (`ConnectionCoordinator.swift:1091-1115`).
- Pairing path: `PairingClient.claim` only catches `DshRPCError`; the transport error escapes and
  `AppModel.claim` renders `String(describing: error)` — a Swift debug string on the pairing sheet.
- The status layer already anticipated the shape of the fix: `ConnectionStatus
  .isRecoverableWithoutUserAction`'s "unverified" note (`State/ConnectionStatus.swift:88-92`)
  says a pin mismatch arrives as `hostUnavailable` and "the app must therefore decide from the
  carried error, not from the status alone."

The downstream chain is already correct and already tested: a real `.tlsPinMismatch` maps to
`ConnectError.certificateChanged` → status `.hostUnavailable`, `isRetryable == false`
(`StateTests.swift:768-777`), stops the backoff loop (`ForegroundConnectionTests.swift:200-205`),
and `RelayExchange` turns it into `DshRPCError.certificateChanged` with the readable reason
"the relay's certificate changed: …" (`Network/RelayExchange.swift:98-99`, `RPCFailure.swift:167`).
The defect is entirely at the transport seam, plus the missing presentation.

## Acceptance criteria

**AC1 — the transport remembers its own refusal.** The shared challenge handler records, per
URL, the `RelayTrustRejection` of the latest server-trust decision it made: a `.reject` records
it, an `acceptPinned` (and a `deferToPlatform` decision) clears it. `send` and the mux socket map
a failed task to `.tlsPinMismatch(rejection.reason)` when — and only when — the failure is
`URLError.cancelled`, the transport itself recorded a rejection for that URL, and the caller's
`Task` is not cancelled (a caller cancellation is still `.cancelled`).

**AC2 — the mismatch keeps a readable identity.** Every `RelayTrustRejection` carries a
human-readable reason; the `.tlsPinMismatch` detail (and with it the stable "TLS pin mismatch: "
prefix `ConnectionCoordinator.socketFailure` recovers on) carries it. A saved host on a stale pin
ends at `ConnectError.certificateChanged`, status `.hostUnavailable`, non-retryable, and the
backoff loop stops.

**AC3 — pairing says what happened.** A claim whose handshake the pin refused shows a readable
"the relay's certificate changed" message on the pairing sheet (through the existing
`RelayExchange` → `DshRPCError.certificateChanged` → `PairingError.exchange` mapping), never a
`String(describing:)` debug string. The single-use code is not spent.

**AC4 — the app offers the re-pair (SPEC §6.9 "offer re-pair").** A kit presentation rule
`ConnectionNotice.certificateChanged(status:lastError:)` is true exactly for
`(status == .hostUnavailable, lastError is .certificateChanged)`. `AppModel` captures
`coordinator.lastError` into a published `lastConnectError` on every status application (it is
cleared on connect, so the notice does not outlive the failure). The Home offline banner takes a
certificate-changed form — wording plus a **Re-pair** button that opens the pairing sheet — and
the conversation's unavailable view shows the same notice and button.

**AC5 — the docs stop lying.** The `RelayPinningPolicy` doc comment that claimed a mismatch
becomes `.tlsPinMismatch` is now true (it says *how*: the recorded refusal); the
`socketFailure` comment that called the prefix match "a long way from matching on prose" is
updated to name the new guarantee it rests on.

## Tests (kit; land red first with API stubs in the same commit)

1. `RelayTransportError.classify`: `URLError(.cancelled)` + a recorded `.pinMismatch` rejection →
   `.tlsPinMismatch` whose detail contains the pin's reason; `URLError(.cancelled)` with no
   rejection → `.cancelled` (unchanged); `CancellationError` → `.cancelled` (existing guard).
2. Delegate recording, offline: a fake challenge (the `TLSChallengeHandlerTests` machinery) with
   a wrong pin, handed to the real delegate for a dummy task's URL →
   `transport.trustRejection(for: url) == .pinMismatch`; a matching-pin challenge → `nil`
   (cleared). This proves the object URLSession calls records, not a copy of its logic.
3. Socket mapping: a -999 socket failure with a recorded rejection → `.tlsPinMismatch`; the same
   failure with a 403 upgrade response → `.webSocketRejected(credentialRejected)` (existing guard);
   -999 without a rejection → `.cancelled` (unchanged).
4. Pairing claim: a stub transport whose `send` throws `.tlsPinMismatch` → `claim` throws
   `PairingError.exchange(.certificateChanged)` with `readableReason` containing
   "certificate changed".
5. Coordinator: a scripted transport (the `StateTests` `makeTransport` pattern) whose `openSocket`
   throws `.tlsPinMismatch` → the connect attempt fails with `ConnectError.certificateChanged`,
   status `.hostUnavailable`, `isRetryable == false`.
6. `ConnectionNotice.certificateChanged` table: `(hostUnavailable, certificateChanged)` true;
   `(hostUnavailable, transportInterruption)`, `(offline, certificateChanged)`,
   `(connected, certificateChanged)`, `(hostUnavailable, nil)` all false.

App-target verification (no app test target — the repo rule): a new screens-gallery value,
`DSH_SCREEN_GALLERY=home-cert-changed`, seeds `status: .hostUnavailable` +
`lastConnectError: .certificateChanged` through the existing `seedForGallery` seam and renders
the real `HomeView`; screenshot is the review. No new `DSH_*` environment variable, so the
debug-env allowlist count is unchanged.

## Out of scope

- #79 (relay fence 403 / authority snapshot) — relay side, its own issue.
- #18 (QR pairing) — makes re-pair a scan; orthogonal to this classification and presentation.
- The pin-storage semantics cluster (#86, #90, #93) — design review territory; this slice touches
  no pin storage.
- Retrying policy changes: `isRecoverableWithoutUserAction` stays as-is for this slice; the
  notice is derived from the carried error, exactly as its "unverified" note prescribes.

## Stubs carried by the Tests: commit (so the red is an assertion, not a compile error)

- `RelayTrustRejection.reason` → placeholder string.
- `RelayTransportError.classify(_:rejectedRejection:)` → parameter ignored (today's behaviour).
- `URLSessionRelayTransport.trustRejection(for:)` → `nil`.
- `ConnectionNotice` → rule returns `false`.
- `AppModel.lastConnectError` + `seedForGallery(lastError:)` → stored, not yet read by the banner.
