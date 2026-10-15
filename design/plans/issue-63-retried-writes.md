# Issue #63: Writes are retried (event results, uploads, cancel, pairing claim)

**Status:** draft
**Branch:** `issue-63-retried-writes`
**Version impact:** MINOR. This differs from the issue, which says PATCH. Removing `retryPolicy:` from
`DshRpcClient.call/callVoid`, `DshBareEndpointClient.init/submitEventResult` and
`PairingClient.init/claim` changes a public kit API that callers use, and that is incompatible.
`docs/process/RELEASING.md` puts that at MINOR while 0.x. No bump in this PR, only a line under
`## [Unreleased]`. The issue gets corrected at gate 1.

## Context

AGENTS.md and SPEC §3.4/§8 say a write is sent once. `RelayExchange.perform` retries 429 and 502
up to 3 times, and four writes reach it with the default retrying policy:

| Write | Why it retries today |
|---|---|
| `$events/result` (approvals, answers) | `AppModel.swift:522` passes `retryPolicy: .none` to an `RPCFailureRetryPolicy?` parameter. Swift reads that as `Optional.none`, meaning "no policy given", so the client's default policy applies, and it retries. This is the trap described on `DshRpcClient.mutate`. |
| `session/uploadFileBinary` (both overloads) | `DshBareEndpointClient.init` defaults to `.default`, and both overloads use that exchange unchanged. |
| `session/cancel` | `ConnectionCoordinator.cancelSession` (`:604`) calls `client.call` without a policy. |
| Pairing claim | `PairingClient.init` defaults to `.default`. A 429 without `Retry-After` sleeps 60 s per retry, which uses up most of the code's 5-minute lifetime. |

If the relay has already processed a write and then answers 502, the retry sends it again. For an
approval that means a second turn of agent work; for an upload, a duplicate file. **Decided scope
(Dan):** close the trap completely. Afterwards reads use `call` (the client's own policy), writes
use `mutate` or a write-only client, and no `RPCFailureRetryPolicy?` parameter remains anywhere.

## Acceptance criteria

Each write criterion means: with a 502, a 429, or a dropped connection scripted, the relay sees
**exactly one** request, nothing sleeps, and the caller gets the failure with `attempts: 1`.

- **AC1 (reproduction)**: an approval or answer sent through
  `DshBareEndpointClient.submitEventResult` goes out once on a 502, a 429 and a dropped connection.
- **AC2**: `uploadFileBinary(sessionId:name:bytes:)` goes out once in the same three cases.
- **AC3**: `uploadFileBinary(sessionId:name:fileURL:)` goes out once in the same three cases.
- **AC4**: `PairingClient.claim` goes out once in the same three cases. A 429 reports the lockout
  straight away (`isLockout`, `rateLimited(attempts: 1)`) and does not spend the code's lifetime
  sleeping.
- **AC5**: `ConnectionCoordinator.cancelSession` goes out once in the same three cases.
- **AC6**: `createSession` goes out once in the same three cases. *Refactor guard: correct today.*
- **AC7**: `prompt` goes out once in the same three cases. *Refactor guard.*
- **AC8**: `answer` (`userQuestions/answer`) goes out once in the same three cases. *Refactor guard.*
- **AC9**: `answerContinued` (`userQuestions/answer`) goes out once in the same three cases.
  *Refactor guard.*
- **AC10**: no API takes an optional retry policy, so a write that retries cannot be written.
  `Tools/lint.sh` gains an `optional-retry-policy` rule that fails on any `RPCFailureRetryPolicy?`
  or `Optional<RPCFailureRetryPolicy>` declaration in `Sources/` or `Apps/`. Lint is clean with the
  `retry-none … AppModel.swift … #63` allowlist entry removed and no new entry added. The app still
  builds in Debug and Release.
- **AC11**: reads still retry. `call` uses the policy the client was built with. *Guard: already
  pinned by `readsStillRetry`, the 429/502 exhaustion tests in `NetworkTests.swift`, and
  `retryPolicyNoneStopsAfterOneAttempt` as rewritten below.*

## Test list

All new tests go in a new file, **`Tests/DSHRemoteKitTests/WritesAreSentOnceTests.swift`**,
`@Suite("Writes are sent once")`, with one `@Test` per case.

- **Clients are built the way production builds them today, with no policy argument.** The tests
  therefore compile both before and after the fix, and at red they fail on a count, not on a
  compile error.
- **AC1 tests the call AppModel makes.** `AppModel.swift:522` passes `retryPolicy: .none`, which is
  `Optional.none`. That is the same value as the parameter's `nil` default, so
  `submitEventResult(request)` sends exactly what the app sends today. The test can't spell out
  `retryPolicy: .none` itself, because that stops compiling once the parameter is gone. The app line
  is guarded separately: by the app build (the parameter no longer exists) and by lint (AC10).
- **Each transport answers every request with the scripted response** (`setDefault`), so a retry
  meets the same status again rather than an empty script.
- **The kit clients get a `RecordingRelaySleeper`.** `ConnectionCoordinator` builds its own
  `DshRpcClient` with the real `TaskRelaySleeper`, and so does `makeTransport: { _ in transport }`
  as used in `StateTests.makeCoordinator`. Its 429 cases therefore script `Retry-After: 0`, and its
  502 cases cost about 1.5 s of real backoff at red (none in AC6–9, which don't retry, and none
  after the fix).
- **The request count goes into a named local (`requestsSent`)**, so the failure message reads
  `(requestsSent → 3) == 1`.
- **429 cases script `Retry-After: 5`**, except pairing, which scripts none: that is the issue's
  case, 60 s per retry.

| AC | Test name | Fails today because |
|---|---|---|
| AC1 | `"AC1: an approval is sent once when the relay answers 502"` | `(requestsSent → 3) == 1`; error is `harnessUnavailable(attempts: 3)`; sleeps `[0.5, 1.0]` |
| AC1 | `"AC1: an approval is sent once when the relay answers 429"` | `(requestsSent → 3) == 1`; `rateLimited(retryAfterSeconds: 5, attempts: 3)`; sleeps `[5, 5]` |
| AC1 | `"AC1: an approval is sent once when the connection drops"` | green at red: a transport failure never loops |
| AC2 | `"AC2: an in-memory upload is sent once on 502"` | `(requestsSent → 3) == 1` |
| AC2 | `"AC2: an in-memory upload is sent once on 429"` | `(requestsSent → 3) == 1`; sleeps `[5, 5]` |
| AC2 | `"AC2: an in-memory upload is sent once when the connection drops"` | green at red |
| AC3 | `"AC3: a file upload is sent once on 502"` | `(requestsSent → 3) == 1` |
| AC3 | `"AC3: a file upload is sent once on 429"` | `(requestsSent → 3) == 1`; sleeps `[5, 5]` |
| AC3 | `"AC3: a file upload is sent once when the connection drops"` | green at red |
| AC4 | `"AC4: a pairing claim is sent once on 502"` | `(requestsSent → 3) == 1`; `.exchange(.harnessUnavailable(attempts: 3))` |
| AC4 | `"AC4: a pairing claim rate-limited without Retry-After reports the lockout at once"` | `(requestsSent → 3) == 1`; sleeps `[60, 60]`; `.exchange(.rateLimited(retryAfterSeconds: 60, attempts: 3))` |
| AC4 | `"AC4: a pairing claim is sent once when the connection drops"` | green at red |
| AC5 | `"AC5: a cancel is sent once on 502"` | `(requestsSent → 3) == 1`; `.rpc(.harnessUnavailable(attempts: 3))` |
| AC5 | `"AC5: a cancel is sent once on 429"` | `(requestsSent → 3) == 1`; `.rpc(.rateLimited(retryAfterSeconds: 0, attempts: 3))` |
| AC5 | `"AC5: a cancel is sent once when the connection drops"` | green at red |
| AC6 | `"AC6: a session create is sent once on 502"` / `"… on 429"` / `"… when the connection drops"` | green at red: already `RPCFailureRetryPolicy.none` |
| AC7 | `"AC7: a prompt is sent once on 502"` / `"… on 429"` / `"… when the connection drops"` | green at red: same |
| AC8 | `"AC8: an answer is sent once on 502"` / `"… on 429"` / `"… when the connection drops"` | green at red: same |
| AC9 | `"AC9: a continued answer is sent once on 502"` / `"… on 429"` / `"… when the connection drops"` | green at red: same |
| AC11 | `NetworkTests.retryPolicyNoneStopsAfterOneAttempt`, `readsStillRetry`, the 429/502 exhaustion tests | green before and after |

That makes 27 new tests: **10 red** (the 502 and 429 cases of AC1–5) and 17 green at red (the
dropped-connection case for AC1–5, and all of AC6–9). AC6–9 duplicate the prompt and answer
429/502 cases in `PromptTests.swift` on purpose, so the S1 checklist can name a single file. The AC3
tests write their file to a unique path under `FileManager.default.temporaryDirectory` and remove it
afterwards. No state is shared between tests.

**Two existing call sites in `NetworkTests.swift` change in the `Tests:` commit.** They have to
compile on both sides of the fix, and `guard-tests.sh` stops a builder changing them later:

- `retryPolicyNoneStopsAfterOneAttempt` (`:549`, `:552`) builds the client with
  `makeRPCClient(transport:sleeper:policy: .none)` and calls `callVoid` without a policy. Its
  comment is reworded the same way. It is still green: it now pins the init policy, which is AC11.
- `pairingLockoutIsDistinguished` (`:1565`) drops `retryPolicy: .none` from `PairingClient(...)`.
  It stays green at red: its sleeper records instead of sleeping, and the guidance is still
  `.backOff(seconds: 120)`.

**AC10 is a lint check, not a Swift test.** How it is proven is in Slice A, step 1, and in
Verification.

*Fakes: `StubRelayTransport`, `RecordingRelaySleeper`, `FixedEpochClock` (the pairing payload's
expiry, as in `NetworkTests`). No stubs are needed in `Sources/`, since every API the tests call
already exists.*

## Slices

There is one slice: every file below changes together, and AC10 needs all of them.

| Slice | ACs | Files | Notes |
|---|---|---|---|
| A | AC1–AC11 | `Network/DshRpcClient.swift` | Remove `retryPolicy:` from `call`/`callVoid`. Private `perform` takes a non-optional policy: `call` passes the client's own, `mutate` passes `.none`. Keep the init parameter. Fix the `callVoid(_:args:retryPolicy:)` DocC link (`:85`), and cut the `mutate` doc's trap story down to one sentence of history. |
| | | `Network/DshBareEndpointClient.swift` | **Only `init` and `submitEventResult`** (#66 owns the `uploadFileBinary` bodies and docs). Drop the `retryPolicy` init parameter; the exchange is always `RPCFailureRetryPolicy.none`. Drop the parameter and the `usingExchange` override from `submitEventResult`. |
| | | `Network/PairingClient.swift` | Same treatment for `init` and `claim`. |
| | | `State/ConnectionCoordinator.swift` | `cancelSession` moves to `mutate`. `createSession` (`:522`), `prompt` (`:763`), `answer` (`:815`) and `answerContinued` (`:868`) move from `call(…, retryPolicy: RPCFailureRetryPolicy.none)` to `mutate`. Move the stray `page()` doc comment and `@discardableResult` (`:585-593`) from `cancelSession` back onto `page`. |
| | | `Apps/DSHRemote/Sources/AppModel.swift` | **Line 522 only**: `try await client.submitEventResult(request)`. |
| | | `Tools/lint.sh`, `Tools/lint-allowlist.txt` | The new rule. Reword `retry-none` to drop "or spell out `RPCFailureRetryPolicy.none`". Remove the `#63` entry. |
| | | `Sources/DSHRemoteKit/README.md:135-137`, `docs/process/RISK-FLAGS.md` (S1 row), `docs/process/WORKFLOW.md` (Lint row), `CHANGELOG.md` | Docs: "writes go through `mutate` or a write-only client". Name the new lint rule. CHANGELOG gets a `### Fixed` line (writes no longer retried) and a `### Changed` line (kit API, `retryPolicy:` removed; MINOR). |

**Slice A, step 1, is the lint rule, done the way WORKFLOW.md's "Adding a lint rule" describes.**
In its own commit, before the fix, the builder adds:

```
optional-retry-policy   a declaration typed `RPCFailureRetryPolicy?` or
                        `Optional<RPCFailureRetryPolicy>` (comment lines excluded). An optional
                        policy is what made `.none` mean "the default, retrying policy" (#63).
                        Writes take no policy; a client's policy is non-optional.
```

The same commit allowlists today's five violations with exact counts and `#63`:
`DshRpcClient.swift 3` (`:94`, `:110`, `:161`), `DshBareEndpointClient.swift 1` (`:255`) and
`PairingClient.swift 1` (`:96`). That commit shows the rule matches the real violations and is not a
regex that matches nothing. The fix commits then remove the parameters, and lint's stale-entry
check fails until all four `#63` entries are deleted (the three new ones and `retry-none`). When the
slice ends, the allowlist has no `#63` line.

`RelayExchange.swift`, `RPCFailureRetryPolicy`, `AttachmentUploader` and the claim site in
`AppModel` (`~1660`) don't change.

## Risk flags

- [x] **S1 writes / retries**: the whole issue. Answers: every changed write has a 429, a 502 and a
  dropped-connection test in `WritesAreSentOnceTests.swift`. No write takes a policy parameter, and
  lint is clean with no new allowlist entry. An uncertain approval is already reported rather than
  replayed: `InteractionStore` settles the request `.uncertain` and throws
  `InteractionRefusal.uncertain` (`InteractionStore.swift:333-339`).
- [x] **S3 pairing**: `PairingClient` changes. The claim is no longer retried (AC4), and a 429
  reports the lockout at once. `PairingPayload.validate()` and pin agreement don't change.
- [ ] S2: not ticked. Neither `RelayTransport.swift` nor the pinning policy changes; #68 owns both.
- [ ] S4, S5, S6, S7, S9: not ticked. No secrets, bounds, file scopes, debug affordances or
  outbound text change. The upload's file handling belongs to #66.
- [ ] C1–C6: not ticked. No persisted format, protocol, concurrency, device-only or relay change.
  The app edit is one argument, and the behaviour it depends on lives in the kit.

## Out of scope

Everything below came out of the sibling search; the next section lists what was searched.

- **Writes already correct, with no change**: `session/selectModel` and `agentPresets/select`
  (`ModelModeCatalog.swift:354, :377`), `commands/execute` (`CommandCatalogStore.swift:139`) and
  `fileUploads/upload` (`AttachmentUploader.swift:133`, #66's file). All of them use `mutate`, which
  `NetworkTests.mutationHelperNeverRetries` already pins.
- **The mux socket.** Its only writes are stream `open` frames, which are subscriptions and
  therefore reads, and the stream `cancel` frame (`MuxClient.swift:389`), which is sent once with
  `try?` and never looped. Reconnecting creates a new `MuxClient` and re-subscribes, so nothing is
  replayed (`AppModel.swift:660`).
- **The base64 upload fallback** runs only on a 404 (`AttachmentUploader.swift:98-107`), so after
  this fix a 502 on the binary upload can't turn into a second upload through the fallback route.
- **`design/MOBILE-IMPLEMENTATION-SPEC.md:111`**, which says every write "must explicitly pass
  `RPCFailureRetryPolicy.none`". It is a design record and is left as written.

## Sibling search (what was searched, what was found)

- `grep -rnE '\.(call|callVoid|mutate|mutateVoid)\(' Sources Apps` turned up 23 sites, and each
  method was resolved to its constant:
  - **Reads through `call` (correct):** `session/list` ×2, `session/projections`, `session/page`,
    `session/modelCatalog`, `agentPresets/list`, `permissionPresets/catalog`, `schedule/catalog`,
    `schedule/list`, `schedule/history`, `scheduledTasks/list`, `pluginInventory/list`,
    `commands/list`, `session/attachment`.
  - **Writes through `call`:** `session/cancel` (**bug**, AC5); `session/create`, `session/prompt`
    and `userQuestions/answer` ×2 (correct with `RPCFailureRetryPolicy.none`; AC6–9 guard the
    move).
  - **Writes through `mutate`:** the four listed under "Out of scope".
- `grep -rn 'RelayExchange(' Sources Apps` found three constructions, one in each client
  (`DshRpcClient`, `DshBareEndpointClient`, `PairingClient`). The bare client and the pairing
  client carry nothing but writes, and both default to retrying: AC1–4.
- `grep -rn 'retryPolicy\|RPCFailureRetryPolicy' Sources Apps Tests Smoke Tools` found the five
  optional parameters (AC10), the four coordinator `RPCFailureRetryPolicy.none` sites, the trap at
  AppModel `:522`, and the three test lines above. Nothing turned up in `Smoke/` or the app tests.
  `RelayTransport.swift:234` only reads `.default.defaultRetryAfterSeconds` to build a WebSocket
  429 error, and it is #68's file.
- `grep -rnE '(DshRpcClient|DshBareEndpointClient|PairingClient)\('` in `Apps/` found four sites.
  `:384` is the stores' read client. `:402` is the uploader's bare client, fixed by the init change
  with no edit at that line. `:515/522` is the event result (the one app edit). `:1660` is the
  claim, fixed inside `PairingClient` with no edit (#68 and #65 own the lines around it).
- Loops that resend a write (`resend`, `for attempt`, `maxAttempts`, `retry(`): none outside
  `RelayExchange`. `SecondaryViews.swift:366` "Try again" re-runs a read.

## Red evidence

*To be filled in with the `Tests:` commit.*

```
```

## Verification

*Filled in by the verifier. Planned checks:*

| AC | Undone how | Expected failure with it undone |
|---|---|---|
| AC1 | restore the `retryPolicy` parameter and override in `submitEventResult` (or the bare client's `.default`) | `(requestsSent → 3) == 1` |
| AC2, AC3 | give `DshBareEndpointClient.init` back `retryPolicy: .default` | `(requestsSent → 3) == 1` for both overloads |
| AC4 | give `PairingClient` back its `.default` | `(requestsSent → 3) == 1`; sleeps `[60, 60]` |
| AC5 | `cancelSession` back to `client.call` | `(requestsSent → 3) == 1` |
| AC6–9 | one site at a time back to `call` with no policy | `(requestsSent → 3) == 1` |
| AC10 | add `retryPolicy: RPCFailureRetryPolicy? = nil` to any write; then add a `///` line naming `RPCFailureRetryPolicy?` | `lint: FAIL … optional-retry-policy …`; then `lint: ok` (comments are not matched) |

- Full `Tools/check.sh`: Debug and Release builds prove `AppModel` compiles against the narrower
  API.
- The S1 and S3 checklists go in the PR, from a security-reviewer pass.

## Notes for the next person

- **A write sent through `call` can still be written.** That is the shape of the `session/cancel`
  bug. The API change removes the `.none` trap, but `call` can't tell a read from a write. The
  guards are the S1 checklist and one 429/502/offline test per write. A lint rule listing the write
  method constants was considered and rejected as a list nobody will keep up to date.
- **Other sessions running in parallel own:** #66 the `uploadFileBinary` bodies and docs,
  `AttachmentUploader.swift` and `AttachmentUploaderTests.swift`; #68 `RelayTransport.swift` and
  AppModel `~1655`; #65 AppModel `~19, ~115, ~275, ~320-352, ~1669-1672` and
  `forget()`/`disconnect()`. Slice A stays out of all of them. Every session adds a CHANGELOG line,
  and whoever merges second resolves that conflict.
