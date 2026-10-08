# What is left for v1

State as of 2026-10-07, round 13 of the goal "get a usable v1 iphone app".
Everything here is committed and the suite is green (162 Swift Testing + 14
XCTest). Read `SPEC.md` for the contract; this file is only the work list.

## Proven against the live harness

`swift run --disable-sandbox --scratch-path .build-smoke dsh-smoke --origin https://10.1.0.138:3443 --pin <pin>`
with a device token in `DSH_DEVICE_TOKEN` connected from a non-loopback
address and reported `SMOKE OK`: SPKI pinning accepted the self-signed
certificate without a trust chain, the bearer token authenticated, the mux
readiness handshake returned a `clientId`, the session list came back with 41
sessions, and shutdown was clean. That covers TLS, auth, mux, RPC, and
decoding below the UI.

## Three known defects, all small and all specified

1. **`MuxClient` discards the transport error kind.** Confirmed by inspection
   on 2026-10-07, not taken on trust:
   - `MuxStreamError.socketFailed(detail: String)` — `Network/MuxClient.swift:61`;
   - the kind is thrown away at both throw sites, `MuxClient.swift:194` and
     `MuxClient.swift:369`, each calling `RelayTransportError.classify(error).safeDescription`;
   - `ConnectionCoordinator.swift:232` reconstructs it by matching the literal
     prefix `"TLS pin mismatch: "`, and the comment at :676 admits this is a
     "long" shot that only works because that prefix construction is unique.

   SPEC §6.4 requires a pin failure to stop retrying and offer re-pairing, so
   the distinction is load-bearing. Fix: make the case carry
   `RelayTransportError` instead of a `String`, update both throw sites, then
   delete the prefix match. Expect `StateTests` to construct
   `.socketFailed(detail:)` and need updating with it.
2. **The `$events` ready frame is decoded as `.unknown`.** Deferred, not fixed,
   on 2026-10-07: an agent was given this as a bounded task and produced
   nothing across three rounds, so it was stopped. It is a modelling wart
   rather than a defect — `ConnectionCoordinator` matches `value.typeName ==
   "ready"` and that path is *proven live* by the smoke run, which cannot pass
   without the readiness handshake succeeding. The captured shape is
   `{"type":"item","streamId":"1","value":{"type":"ready","clientId":"<36>","host":{"home":"<path>"}}}`,
   with the fields flattened beside `type` exactly as `snapshot` decodes at
   `Models/StreamFrames.swift:200`. Do it only if something else needs the
   typed accessor; do not let it delay the chat screen.
3. **The establishment budget is tested through a test-local stall transport**
   because `StubRelayTransport.openSocket` cannot hang. A stub knob would
   remove the last non-stub double in `StateTests.swift`.

## Two defects the live smoke run found, both unfixed

Found by running the real coordinator against the live relay with a wrong pin
and with a revoked token. Both are client-side; the relay behaves correctly.

1. **A refused TLS challenge hangs `connect()` forever.** Wrong pin → the call
   never returns, no output past the credential line, and neither the 10 s
   establishment nor the 10 s readiness budget fires (still hung at 25 s). The
   mechanism, inferred from the code because no stack was obtainable:
   `URLSessionWebSocketTask` never resumes the continuation after
   `.cancelAuthenticationChallenge`, and `ConnectionCoordinator.withBudget`
   races the operation inside a `withThrowingTaskGroup`, which awaits *all*
   children before its scope exits — so a child parked on an unresumed
   continuation cannot be timed out or cancelled. Consequence: SPEC §6.9's
   "TLS pin mismatch → stop, show certificate changed, offer re-pair" row is
   unreachable; the app would hang instead of reporting `hostUnavailable`.
   Note this is *not* what `0c79bea` fixed: that made the error kind travel
   correctly, but the kind never arrives because nothing returns.

   **Reproduced twice, independently.** The smoke agent found it first; a second
   agent then reproduced it against the live relay and measured **41 s+ with
   idle threads** before being stopped. So the hang is not a timing artefact.

   **Checked the obvious fix, and it is not a one-liner.** The challenge handler
   at `Network/RelayTransport.swift:368-392` implements the *session-level*
   delegate method, which receives no task — so there is nothing there to
   `cancel()` after refusing. Two real options: implement the task-level
   `urlSession(_:task:didReceive:completionHandler:)` instead and cancel the
   task there (root fix, three cancel sites to change), or stop the budget race
   from awaiting a parked child (contains it, leaves a parked task). Do the
   first if possible.

   **What the fix hinges on, and was still being probed when the attempt was
   stopped:** what URLSession actually does to a `URLSessionWebSocketTask`
   whose authentication challenge was cancelled — whether the receive
   continuation is resumed with an error, never resumed, or resumed only when
   the task is cancelled. Settle that first (a tiny standalone URLSession
   probe against the relay with a wrong pin answers it), because both candidate
   fixes depend on it.
2. **A revoked credential reads as retryable.** After revoking the device, a
   connect exits with `status: offline` and
   `transport interruption: URLError -1011`, and `offline` is recoverable
   without user action — which SPEC §6.9 forbids for a relay 403. The RPC path
   maps 403 to "pair again"; the mux *upgrade* path does not.

Also worth keeping: **loopback proves nothing about authentication.** From
`127.0.0.1` the relay serves `/api` with a garbage token and with no
`Authorization` header at all. Any token or pairing work must be verified
against the LAN address in the certificate's SANs (`https://10.1.0.138:3443`),
which is where the revoke → `403 {"error":"forbidden"}` was actually observed.

**The API a `ChatSession` implementer needs, written down so nobody has to go
looking again** (read from `State/ConnectionCoordinator.swift`, which is why
four delegations stalled — each spent its budget rediscovering this):

```swift
public actor ConnectionCoordinator {
    public func connect() async throws -> Connection        // :347
    public func sessions() async throws -> [SessionSummary] // :443
    public func activeStream() -> StreamHandle?             // :477  the $events stream
    public func shutdown() async                            // :534
    public func reportReconnecting()                        // :565
    public private(set) var status: ConnectionStatus
    public private(set) var connection: Connection?         // non-nil iff connected
    public private(set) var lastError: ConnectError?

    public struct StreamHandle: Sendable {                  // :273
        public let client: MuxClient
        public let generation: Generation
        public let eventsStreamId: String
    }
}
```

`MuxClient` is the thing that opens a second logical stream (`session/follow`)
on the same socket; read its `open`/subscription surface in
`Network/MuxClient.swift`. `Connection` carries `generation`, `clientId` and
`host`. The `session/follow` args take a named `request` whose required
`address` is `{kind: "session", sessionId}`; `session/prompt` takes a named
`request` with `requestId`, `sessionId`, `mode: "queue"` and `content`.

## Then the chat screen

**Reducers: settled.** `State/ConversationBuilder.swift` stands. The rebuilt
alternative in `wip/ConversationBuilder2.swift.wip` raised one genuine defect
in it — a `committed` end arriving before its durable record cleared the
preview and briefly rendered neither — and that is now fixed: a settled
preview is held until the `seq` its `outcome` named exists, with a test for
the order the capture did not exercise. Its other disagreement, dropping the
whole attempt when one revision goes backwards rather than only the stale
frame, is resolved in favour of the surgical reading. The parked duplicate is
now redundant and can be deleted.

`Sources/DSHRemoteKit/State/ConversationBuilder.swift` is done and tested
(190 lines, eight tests). What it needs from the UI:

- `messages` gives ordered `ConversationMessage`s with `role`, `text`,
  `isProvisional`, and `reasoning` kept apart from the answer;
- `isStreaming` drives a live indicator — a provisional message carries **no
  text** on purpose, because nothing proves where stream text deltas live;
- `hasGap` should surface as a visible note rather than being swallowed;
- `unmodelledEvents` is where tool calls, plan updates, and permission
  presets live; render them as generic cards, never drop them.

The screen itself is `Apps/DSHRemote/Sources/` — add `ChatView.swift`, a
`$events` subscription through `ConnectionCoordinator`, and a `session/follow`
stream opened for the selected session. SPEC §3.4 governs the composer and
§3.6 the attachments; neither exists yet.

## Then the app has to leave this machine

- **No signing identity**: `security find-identity -v -p codesigning` is empty,
  so open `Apps/DSHRemote/DSHRemote.xcodeproj` in Xcode, pick a Team, and put
  the id in `project.yml` (`DEVELOPMENT_TEAM`) so a regenerate keeps it.
- **No simulator runtime**: `xcrun simctl runtime list -v` reports zero images,
  so running locally needs `xcodebuild -downloadPlatform iOS` (several GB).
  Building for `generic/platform=iOS Simulator` works without it.

## Things deliberately not built

Reconnect with jittered backoff (`ConnectionCoordinator` has a marked seam),
the other three reactor streams in SPEC §4, workspace grouping in the session
list (it groups by `cwd` meanwhile), drafts, attachments, approvals, and the
question cards. `wip/ConversationBuilder-*.swift.wip` is a dead 1,519-line
attempt; delete it whenever.
