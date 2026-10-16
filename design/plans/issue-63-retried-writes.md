# Issue #63: Writes are retried (event results, uploads, cancel, pairing claim)

**Status:** verified (2026-10-15)
**Branch:** `issue-63-retried-writes`
**Version impact:** MINOR. This differs from the issue, which says PATCH. Removing `retryPolicy:` from
`DshRpcClient.call/callVoid`, `DshBareEndpointClient.init/submitEventResult` and
`PairingClient.init/claim` changes a public kit API that callers use, and that is incompatible.
`docs/process/RELEASING.md` puts that at MINOR while 0.x. No bump in this PR, only a line under
`## [Unreleased]`. The correction is posted on the issue.

**Gate-1 decisions (Dan, 2026-10-15).** The lint rule lands first with temporary #63 allowlist
entries, as planned. The RISK-FLAGS S1 row and the WORKFLOW Lint row edits stay in this PR. The
remaining "write through `call`" gap is filed as #87. `MOBILE-IMPLEMENTATION-SPEC.md:111` stays as
written. The AC1 reasoning and the duplicated AC7/AC8 cases are accepted.

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
- **A write sent through `call`** is still expressible: #87 (see Notes).
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

`Tools/check.sh --red` on the `Tests:` tree (2026-10-15):

```
red: ok it compiles and fails on assertions (kit: fail, app: pass; logs in .build/check).
check: ok — red for the right reason (156s)
```

Kit: 532 tests in 37 suites, **10 failing tests, 28 issues**, all in `WritesAreSentOnceTests`. Every
other suite passes, including the two edited `NetworkTests` cases. Lint is ok. The 17 guard cases
(dropped connection for AC1–5, and all of AC6–9) pass, as predicted. Each red test's first failure
(`WritesAreSentOnceTests.swift:<line>`):

| Test | First failure | Also |
|---|---|---|
| AC1 … answers 502 | `:127` `(requestsSent → 3) == 1` | sleeps `[0.5, 1.0]`; `harnessUnavailable(attempts: 3)` |
| AC1 … answers 429 | `:142` `(requestsSent → 3) == 1` | sleeps `[5.0, 5.0]`; `rateLimited(5, attempts: 3)` |
| AC2 … on 502 | `:180` `(requestsSent → 3) == 1` | sleeps `[0.5, 1.0]`; `attempts: 3` |
| AC2 … on 429 | `:195` `(requestsSent → 3) == 1` | sleeps `[5.0, 5.0]`; `attempts: 3` |
| AC3 … on 502 | `:233` `(requestsSent → 3) == 1` | sleeps `[0.5, 1.0]`; `attempts: 3` |
| AC3 … on 429 | `:250` `(requestsSent → 3) == 1` | sleeps `[5.0, 5.0]`; `attempts: 3` |
| AC4 … on 502 | `:285` `(requestsSent → 3) == 1` | sleeps `[0.5, 1.0]`; `.exchange(.harnessUnavailable(attempts: 3))` |
| AC4 … without Retry-After | `:303` `(requestsSent → 3) == 1` | sleeps `[60.0, 60.0]`; `.exchange(.rateLimited(60, attempts: 3))` |
| AC5 … on 502 | `:337` `(requestsSent → 3) == 1` | `.rpc(.harnessUnavailable(attempts: 3))`; 1.7 s of real backoff |
| AC5 … on 429 | `:349` `(requestsSent → 3) == 1` | `.rpc(.rateLimited(0, attempts: 3))` |

One difference from the test list: the AC4 502 case also records sleeps of `[0.5, 1.0]`, which the
prediction left out. It is the same bug. `isLockout` in the AC4 429 case is already true at red,
because a three-attempt 429 is still a lockout.

## Verification

Verified 2026-10-15 at `6a84d09`, by a verifier that did not build it. Each criterion was undone on
its own, by hand on the finished tree, and its tests re-run
(`swift test --disable-sandbox --filter WritesAreSentOnceTests`, or the named `NetworkTests` for
AC11). The tree was restored with `git checkout -- <file>` and the suite was green again before the
next one. Every write test fails by count, so the message reads `requestsSent → 3` where it expects 1.

| AC | Undone how | Failure with it undone |
|---|---|---|
| AC1 | `submitEventResult` only: `usingExchange.retryPolicy = .default` before `perform` (uploads left on `.none`) | the 502 and 429 cases only: `:127`/`:142` `requestsSent → 3`; `slept` `[0.5, 1.0]` / `[5.0, 5.0]`; `harnessUnavailable(attempts: 3)`, `rateLimited(5, attempts: 3)` |
| AC2 | the in-memory `uploadFileBinary` only (`DshBareEndpointClient.swift:201`) uses `.default` | the AC2 502/429 cases only: `:180`/`:195` `requestsSent → 3`; `slept` `[0.5, 1.0]` / `[5.0, 5.0]`; `attempts: 3` |
| AC3 | the file `uploadFileBinary` only (`:239`) uses `.default` | the AC3 502/429 cases only: `:233`/`:250` `requestsSent → 3`; `slept` `[0.5, 1.0]` / `[5.0, 5.0]`; `attempts: 3` |
| AC1–3 | `DshBareEndpointClient.init`'s exchange back to `RPCFailureRetryPolicy.default` | all six 502/429 cases of AC1–3, `requestsSent → 3` (18 issues) |
| AC4 | `PairingClient.init`'s exchange back to `RPCFailureRetryPolicy.default` | `:285`/`:303` `requestsSent → 3`; `slept` `[0.5, 1.0]` / `[60.0, 60.0]`; `.exchange(.harnessUnavailable(attempts: 3))`, `.exchange(.rateLimited(60, attempts: 3))` |
| AC5 | `cancelSession` back to `client.call` (the coordinator client's `.default`) | `:337`/`:349` `requestsSent → 3`; the error is still `harnessUnavailable`/`rateLimited` but not `attempts: 1` |
| AC6 | `createSession` back to `client.call` | `:382`/`:394` `requestsSent → 3`; `attempts: 1` expectation fails |
| AC7 | `prompt` back to `client.call` | `:427`/`:439` `requestsSent → 3`; `attempts: 1` expectation fails |
| AC8 | `answer` back to `client.call` | `:474`/`:486` `requestsSent → 3`; `attempts: 1` expectation fails |
| AC9 | `answerContinued` back to `client.call` | `:525`/`:537` `requestsSent → 3`; `attempts: 1` expectation fails |
| AC10 | `retryPolicy: RPCFailureRetryPolicy? = nil` added to `PairingClient.claim`; then the same as `Optional<RPCFailureRetryPolicy>`; then an `RPCFailureRetryPolicy?` property in `AppModel.swift` | `lint: FAIL` `optional-retry-policy Sources/DSHRemoteKit/Network/PairingClient.swift:100: …` for both spellings, and `optional-retry-policy Apps/DSHRemote/Sources/AppModel.swift:…` for the app |
| AC10 (comments) | only a `///` line naming `` `retryPolicy: RPCFailureRetryPolicy? = nil` `` added | `lint: ok`, as intended |
| AC10 (old trap) | `AppModel.swift:522` back to `submitEventResult(request, retryPolicy: .none)` | `lint: FAIL` `retry-none Apps/DSHRemote/Sources/AppModel.swift:522` (and the app no longer compiles: the parameter is gone) |
| AC11 | `call` passes `RPCFailureRetryPolicy.none` (the write policy leaks into reads) | `readsStillRetry` caught `.rateLimited(0, attempts: 1)`; `status429ExhaustsToBackoff` `attempts: 1`, `slept → []`; `status502ExhaustsToHarnessUnavailable` `attempts: 1`; four more 429/502 retry tests fail |
| AC11 | `call` ignores the client's policy and always uses `.default` | `retryPolicyNoneStopsAfterOneAttempt`: `attempts → 3`, `slept → [5.0, 5.0]`, `rateLimited(5, attempts: 3)` |

On HEAD, `grep -rn "RPCFailureRetryPolicy?" Sources Apps` prints nothing, and the allowlist has no
`#63` line. With everything restored, `swift test --disable-sandbox` is green: 532 tests in 37 suites.

- `Tools/check.sh`: **green** (full, 283 s). Lint ok, models up to date, version ok 0.2.0 (238),
  `guard-tests` clean, 532 kit tests pass, coverage 87.12% (baseline 86.83%), Debug **and**
  Release build, 4 app tests pass.
- Coverage: the baseline goes from 86.83 to **87.12** in this commit
  (`Tools/coverage.sh --update-baseline` after `swift test --enable-code-coverage` on HEAD), as
  "Coverage only goes up" requires.
- Version impact: **MINOR** is right. `DshRpcClient.call`/`callVoid`,
  `DshBareEndpointClient.init`/`submitEventResult` and `PairingClient.init`/`claim` lose a public
  parameter, and `AppModel` used it. That is "a public kit API that callers use, changes
  incompatibly" (`docs/process/RELEASING.md:32`), which is MINOR while 0.x. `project.yml` and
  `Info.plist` are untouched (no bump). `CHANGELOG.md` `[Unreleased]` has the `### Fixed` line and
  a `### Changed` line marked MINOR, both with `#63`.
- Risk checklist: in the PR (S1 and S3, from the security reviewer's pass).

## Notes for the next person

- **A write sent through `call` can still be written.** That is the shape of the `session/cancel`
  bug. The API change removes the `.none` trap, but `call` can't tell a read from a write. The
  guards are the S1 checklist and one 429/502/offline test per write. A lint rule listing the write
  method constants was considered and rejected as a list nobody will keep up to date. Filed as #87.
- **Other sessions running in parallel own:** #66 the `uploadFileBinary` bodies and docs,
  `AttachmentUploader.swift` and `AttachmentUploaderTests.swift`; #68 `RelayTransport.swift` and
  AppModel `~1655`; #65 AppModel `~19, ~115, ~275, ~320-352, ~1669-1672` and
  `forget()`/`disconnect()`. Slice A stays out of all of them. Every session adds a CHANGELOG line,
  and whoever merges second resolves that conflict.
