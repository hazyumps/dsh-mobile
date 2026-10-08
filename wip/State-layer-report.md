# State layer: connected to a host, here are its sessions

Slice report. Three files, all offline-tested, `swift test` green.

## What landed

| File | Lines | What it is |
|---|---|---|
| `Sources/DSHRemoteKit/State/ConnectionStatus.swift` | 99 | The six SPEC §3.1 states as `Equatable, Sendable` (also `Hashable, Codable, CaseIterable`) with a `label`. No SF Symbol names, no UI types. |
| `Sources/DSHRemoteKit/State/ConnectionCoordinator.swift` | 889 | `actor` owning one `MuxClient` and one `DshRpcClient` per origin: connect with pinning, the `$events` readiness handshake, both SPEC §6.4 budgets, session list, clean shutdown, and a marked reconnect seam. |
| `Tests/DSHRemoteKitTests/StateTests.swift` | 683 | 24 Swift Testing cases, all through `StubRelayTransport` / `StubRelaySocket`. No network. |

Nothing under `Network/`, `Models/`, `Protocol/`, `Fixtures/`, `Persistence/`, `Generated/`, or `SPEC.md` was modified. `git status` is clean; the parent agent committed these files as they landed.

## `swift test` result

```
swift test --disable-sandbox --scratch-path .build-state
✔ Test run with 154 tests in 1 suite passed after 0.226 seconds.
  Executed 14 tests, with 0 failures (0 unexpected)
```

**168 total: 154 Swift Testing + 14 XCTest, all passing.** Stable across four consecutive runs (0.22–0.23 s; the two real waits are 0.2 s each).

Baseline when I started was 138 (124 + 14). The delta of 30 is **not** all mine — the other agent added `HostStoreTests.swift` and conversation tests concurrently, so I am not attributing the 30 to this slice. My contribution is the 24 cases in `StateTests.swift`.

Two transient failures I hit and did **not** cause, both from concurrent work in the same tree, both since resolved by that agent:

- `SwiftCompile ... Smoke/Smoke.swift:46: 'isPinned' is inaccessible due to 'internal' protection level` — `Smoke/Smoke.swift` reaches into `RelayPinningPolicy.isPinned`, which is `internal`.
- `Sources/DSHRemoteKit/State/Conversation/ConversationBuilder.swift` — three compile errors (`Int64?` to `Int??` at 946, `partitioningIndex` at 1007, `.page` at 1010). That file was moved to `wip/ConversationBuilder-stray.swift.wip`.

To get a trustworthy measurement while that was broken I mirrored the package to `/tmp/dsh-state-isolated` minus `State/Conversation` and `Apps/`, and ran there: same result, 154 + 14 green.

## SPEC behaviours: what has a test, what does not

### Has a test

| SPEC | Behaviour | Test |
|---|---|---|
| §3.1 | Exactly the six states, SPEC's own phrases, no duplicate or empty labels, only `connected` is usable | `connectionStatusIsTheSpecSix` |
| §6.4 | "The socket opening alone is not readiness" — socket open, no ready frame, status never reaches `connected` | `readinessRequiresTheReadyFrame` |
| §6.4 | Readiness budget fires → `readinessTimedOut`, status `hostUnavailable`, not a hang on `connecting` | `readinessRequiresTheReadyFrame` |
| §6.4 | Establishment budget fires on a hanging upgrade → `establishmentTimedOut` inside the budget | `establishmentBudgetFires` |
| §6.4 | The standard budget is the ten seconds the spec states | `standardBudgetIsTheSpecBudget` |
| §6.4 | `clientId` comes from the ready frame; the frame's `host` object is kept whole | `clientIdComesFromTheReadyFrame` |
| §6.4 | Frames before ready are skipped, not mistaken for readiness | `framesBeforeReadyAreSkipped` |
| §6.4 | An `error` frame before ready fails the attempt using the host's own code | `streamErrorBeforeReadyFailsTheAttempt` |
| §6.4 | Each attempt burns a new generation; the previous socket is closed | `eachAttemptBurnsAGeneration` |
| §6.4 | Reconnect-with-backoff is **absent** — but `Reconnecting` is reachable, so the next slice has a seam | `reconnectingIsSettable` |
| §3.3 | `session/list` decodes the captured response into `SessionSummary` (3 rows, title, `running`, `updatedAt`, `asOfSeq`) | `sessionListDecodesTheFixture` |
| §3.3 / §6.2 | The `_request` argument name, the POST path, the bearer and content-type headers, and `method` matching `path` | `sessionListUsesTheDescriptorArgumentName` |
| §6.2 | HTTP 200 with `ok: false` is surfaced with the host's `code` and `message`, not treated as success | `sessionListBusinessRefusal` |
| §6.9 | A transport failure during a call is an error and a status, not a silent empty list | `sessionListTransportFailureIsReported` |
| §6.9 | A transport failure during connect surfaces as `offline`, never stuck on `connecting` | `transportFailureSurfacesAsStatus` |
| §6.9 | A failed upgrade with no socket is reported, not hung | `upgradeFailureSurfacesAsOffline` |
| §6.9 | A socket that fails mid-connection demotes the status off `connected` | `socketLossAfterReadyDemotesTheStatus` |
| §6.9 | The whole failure→status map in one place: 403→`pairingRequired`, 401/502/429/404/business→`hostUnavailable`, offline→`offline` | `failureToStatusMapping` |
| §6.4 / §6.9 | A pin mismatch is recovered as `certificateChanged` and is **not** retryable | `pinMismatchStops` |
| §6.2 | An unpaired coordinator refuses locally without touching the relay or burning a generation | `unpairedCoordinatorRefusesLocally` |
| §6.4 | Shutdown closes the socket exactly once, cancels the stream, and leaves nothing reading | `shutdownLeavesNothingRunning` |
| §6.4 | Shutdown is idempotent and safe before any connect | `shutdownIsIdempotent` |
| §6.4 | A ready frame with no `clientId` is a failure, not a partial connect | `readyFrameWithoutClientIdFails` |
| §6.4 | An opened-but-never-ready socket is closed, not leaked | `readinessFailureClosesTheSocket` |

### Does not have a test — deliberately

- **Reconnect with jittered backoff.** Not implemented, by instruction. The seam is documented in a `// MARK: - Reconnect (next slice)` block at the bottom of `ConnectionCoordinator.swift`, spelling out the five things already in place (`connect()` restarting clean, `isRetryable`, `status`, `reportReconnecting()`, a fresh transport per attempt) and the one thing missing (the schedule, plus §7 foreground gating and `Retry-After`).
- **`session/follow` and §6.5 conversation state.** Not in scope. `activeStream()` hands out the live `MuxClient` plus its generation so the follow reducer can own its own stream, and the drain loop keeps the `$events` sequence alive until then.
- **The other three streams of §4** (workspace, session-control, follow). `$events` only.
- **Session grouping by workspace registry (§3.3).** No capture maps `cwd` (or anything else) to a workspace ID, so nothing is derived from it.
- **No main-actor blocking.** Not testable without the app, and not possible by construction: the coordinator is an `actor`, not `@MainActor`.
- **A live socket / TLS handshake.** No network in tests, by constraint.

## Interpretation choices I had to make

Each of these was a judgement call, not something the spec settled.

1. **`ConnectionStatus` duplicates the app's enum.** `Apps/DSHRemote/Sources/AppModel.swift:8` already defines an identical `ConnectionStatus` (raw values, labels, plus `symbol`). There is no `import` of it — the app is UI-only and hasn't switched. I mirrored its raw values and labels exactly so the app can delete its copy and get identical strings. **I did not touch the app target.** The app keeps ownership of the glyph mapping, which is why the library names no symbols — and there's a test asserting no label contains a `.`.

2. **`reconnecting` is unreachable except through `reportReconnecting()`.** SPEC §3.1 lists the state; nothing in this slice can produce it. Rather than leave a state the UI renders and nothing sets, I exposed one method for the next slice's loop to call. The spec comment says so and a test pins it.

3. **A connection refusal gets a status; a call refusal does not.** These route through two different methods on purpose. `abandon(_:)` (connect path) always writes the status. `applyCallFailure(_:)` (call path) writes it **only** for `offline` and `pairingRequired`. A 404, a 429, or a business refusal arrives over a socket that demonstrably still works, so demoting a live connection to `Host unavailable` because one endpoint 404'd would make the status lie. Both are documented at their definitions.

4. **Code, not status, decides `pairingRequired`.** A call-path 403 does get demoted to `pairingRequired`. Nothing in this slice makes a live call, so it is currently untriggerable, but the mapping is tested directly rather than left unverified.

5. **One meaning per `ConnectError` case.** `failure(from:)` lifts `DshRPCError.transportInterruption` and `.certificateChanged` out of `.rpc(_)` into the flat `transportInterruption` / `certificateChanged` cases. Without that, "the socket dropped" would be `.rpc(.transportInterruption)` on the call path and `.transportInterruption` on the connect path — two spellings of one condition, and the app's retry rule would hold in one place and not the other. Every other `DshRPCError` stays wrapped so the app keeps `guidance`, `isPairingLockout`, and `rpcError`. This was a real bug I introduced and then fixed; the test caught it.

6. **A ready frame without a `clientId` fails the connect.** SPEC §6.7 needs the `clientId` to address `$events/result`, so a generated one would silently address the wrong connection. Tested against both a missing and an empty field.

7. **A `status` is a failure state, and `clientId` is a success state.** `ConnectionCoordinator.status` is a computed mapping from a stored `phase` plus the failure mapping, recomputed before every return and every throw inside the actor.

8. **Session list is returned, not stored.** SPEC §4 gives `SessionStore` ownership of sessions and the task asked for a fetch-and-decode. `sessions()` returns `[SessionSummary]`; `SessionListValue.swift` (generated) and `SessionListResult` (hand-written, in `Models/`) both exist, and a test asserts the fixture decodes identically through the generated wrapper, so the two cannot drift.

9. **`ready` is read as `MuxFrameValue.unknown`.** The ready frame's real shape is captured in SPEC §6.4 but is **not** in `Fixtures/mux-stream-frames.json` (whose header records that no ready frame exists and all twelve captured frames are `item`). Adding a modelled case to `Models/StreamFrames.swift` would mean inventing a shape from a spec sentence in a file I was told not to touch, so the extension lives in `State/` with a `public static let readyRawValue = "ready"` and an `unknownValue` accessor. **Capturing a real ready frame would let that become a proper modelled case and the extension go away entirely.**

10. **`withBudget` takes a `RelaySleeper`.** Not currently injectable from the public initialiser — the budgets are the injection point a test uses. If a future test wants a third budget without wall-clock, adding a `sleeper` parameter to `init` is the change.

11. **Actor, not `@MainActor` class.** SPEC §4: "Network and reducer work must not block the main actor."

## Findings worth carrying forward

1. **The establishment budget cannot be exercised through `StubRelayTransport`, because the seam has no stall in `openSocket`.** `StubRelayTransport.openSocket` either returns a canned socket or throws immediately — it cannot model "the upgrade hangs". Two paths therefore share one code path and are indistinguishable from the test's side: "the upgrade is hanging" and "the upgrade completed but nothing was sent". I test the stall with a six-line test-local `StalledServeTransport`, which is the only non-stub transport in the file. A `StubRelayTransport` knob for this would remove the last one.

2. **`MuxClient` discards the error *kind* on a socket failure.** This is the most consequential finding. `MuxStreamError.socketFailed(detail: String)` keeps only the redacted text from `RelayTransportError.safeDescription`. A real pin mismatch happens inside `transport.openSocket` (that is where the TLS challenge is answered), so it arrives as `.socketFailed(detail: "TLS pin mismatch: …")` and the distinction between "certificate changed, stop and re-pair" and "network dropped, retry" survives only in prose. SPEC §6.4 says to stop retrying pin failures. I recover the kind from the `safeDescription` prefix — the only prefix construction in the codebase — and both `socketFailure(detail:)` and `pinMismatchPrefix` are commented with the limitation. **The durable fix is to carry the `RelayTransportError` case through `MuxStreamError` instead of a string**, which would be a small, non-breaking change to `Network/MuxClient.swift`. I made the change here because it was a Network change I did not need to make, and `MuxClient` is the more natural home.

3. **A socket opened for an abandoned attempt can outlive it.** If a timeout wins while `MuxClient.ensureSocket`'s `transport.openSocket` call is still suspended, the cancellation check only happens *after* that call returns; the freshly created socket is then stored with no one to close it. The socket teardown needs the transport to be cancellation-aware. Nothing in this slice can trigger it offline (where the timeout fires, the socket is always established), and teardown covers everything reachable today.

4. **`RPCResponse<SessionListValue>` is the correct decode, not `SessionListValue`.** The generated wrapper is the value half only; the captured fixture is a full `RPCResponse` envelope. I got this wrong first and the test caught it. Worth knowing before adding more fixture decoding.

5. **`RelayExchange` re-classifies a raw `RelayTransportError.offline` as unknown**, so a transport failure on the call path yields `transport failure: …` rather than `transport offline: …`. This is existing behaviour and arguably intentional, since a URLError that is not yet mapped has no better name. Worth checking the same way once. Nothing here depends on the string.

6. **The initialiser's default is the real transport**, using the pinning policy from the supplied `Origin`, mirroring the stub convention from `PairingClient` so this package can be exercised without a network.

## What I could not determine

- **Whether the harness's real budgets are ten seconds.** SPEC §6.4 itself flags this: the line is to be "corrected to match observed behaviour" and the relay's 3000 ms figure is historical. The client enforces what the spec currently states (10 / 10) and the value lives in one `Budget` value.
- **Whether an `end` frame carries a stream ID**, and what an `error`/`end` payload actually looks like. No fixture has either. `firstReadyFrame` treats `end` on `$events` as a refusal and `MuxClient` already treats a stream-less `error`/`end` as covering every open stream — both are documented as unproven.
- **What the ready frame's `host` object contains** beyond the captured `{"home": "<path>"}`. Kept as `JSONValue`.
- **Whether a stream ID must be numeric.** SPEC §5 calls it an opaque client-chosen string, so I use `events-<generation>`. Untested against a live host.
