# What is left for v1

## SPEC §1 conformance, assessed 2026-10-08 (round 93)
Checked against the scope list itself, with what each claim rests on:

| §1 item | state |
|---|---|
| Pair via QR or pasted JSON | **paste verified live**; QR not exercised |
| Remember hosts, select active | host list works; multi-host store is unit-tested, never tried with two |
| Browse sessions by workspace | **verified live** (both workspaces rendered) |
| Open a session, **page through** it | opens and renders; **paging older history is not built** (`session/page` scoped, never written) |
| Send prompts, stream responses | **verified live** |
| Reasoning in collapsed disclosures | reasoning renders inline, not collapsible |
| Tool calls and results as expandable cards | **missing** — though the capture now has `tool/call`, and `tool/result` was seen this round |
| Answer questions | **verified end to end** (round 91) |
| Answer permission requests | **missing** — `approval/policy` events arrive, nothing acts on them |
| Attach photos and files | **missing** |
| Execute slash commands | **missing**; unrecognized slash text does reach the host as prompt text, so skills work by that route |
| Model shown and selectable | **missing** |
| Drafts per host/session, restore after suspension | conversation restores via follow; **drafts are view state only** and are lost on navigation |
| Goal/plan/todo summaries | **missing** |
| Light/dark, Dynamic Type, VoiceOver | system appearance and type scale come free; **VoiceOver never tested** |

Out of scope for v1, so not gaps: session/workspace creation, push notifications,
goal editing, terminal and file browsing, LAN scanning, offline queues,
localization, iPad/watch, App Store release.

**The honest summary:** the app reads conversations, sends prompts, and answers
questions against the live harness. It is usable for that. Five §1 items are
plainly missing — tool cards, permissions, attachments, slash commands, model
selection — plus history paging, draft persistence, and the summaries. Anything
claiming "v1 complete" before those is overstating it.

### `session/control` is the projections stream (round 98)

Probed it with deliberately empty args and it opened straight away — no arguments
required — delivering two kinds of item:

- **`baseline`**: `{projections: {<sessionId>: {asOfSeq, values: {…}}}}`, and the
  values carry **`title`** and **`goal`**. The goal shape seen live:

  ```json
  {"goal": {"id": "goal-c9a53751-…", "revision": 1,
            "objective": "get a usable v1 iphone app", "phase": "active",
            "maxGoalRounds": …}}
  ```

  That is the §1 "read-only goal, plan, and todo summaries" item, available
  directly — no paging, no per-session call.

- **`projection`** items streamed continuously, one per session and key:
  `tokenUsage {uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}`,
  `contextPressure {pressureTokens, projectedTokens, contextWindow}`,
  `contextBreakdown {systemTokens, toolsTokens, messageTokens}`, and
  `sessionStats {turns, steps, llmMs, toolMs, ttftMs, ttftSteps, decodeMs, decodeTokens}`.

Two things worth knowing: the stream **covers every session**, not just one, so a
session id is not required and the app can show goals and usage across the board;
and it is a *stream*, so these values arrive live rather than needing polling.

That makes the summaries item buildable from a known shape, and hands the app a
usage/context readout for free.

### The next discovery task: capture an approval request

**Round 97 probed the attach call and the gateway named its arguments.** Three
arg shapes were sent to `userQuestions/attachWait`; the rejections are precise:

```
missing "agentId", "callId"; unexpected "request"      (sent the follow-shaped args)
missing "callId"                                       (sent agentId only)
missing "agentId", "callId"; unexpected "sessionId"    (sent sessionId)
```

So `attachWait` takes **`{agentId, callId}`** — the *same pair* `userQuestions/answer`
takes. It is not a session-level registration and not a broadcast subscription; it
attaches to one specific tool call. The flow is therefore:

1. a `tool/call` event arrives (a question, and presumably an approval too);
2. the app attaches by opening `userQuestions/attachWait` with
   `{agentId: sessionId, callId: thatCallId}` — holding the stream is the
   attachment, and `remainingMs` is how long the hold lasts;
3. the app answers with the same pair, which `answer(...)` already sends.

That closes the loop on why "without an available answerer the request fails
closed": the answerer is whoever holds that stream for that call. Nothing about
this needs a new identifier or a session-level registration.

Worth noting for whoever builds it: the three probes were cheap and the gateway's
error messages named every missing field, which is a faster way to learn an
argument shape than reading generated code. The probe script is
`/tmp/attachwait.cjs`, and the device was revoked afterwards.

**Round 96 mapped the gap to endpoints, and the answerer question is answered.**
Listing the generated endpoints (`grep '^// MARK: - ' Generated/Endpoints.swift`)
shows there is **no separate answerer-registration call**. The only candidate is
`userQuestions/attachWait`, which is a **stream**: holding it open *is* the
attachment, and its `{remainingMs}` result is how long the hold lasts. That fits
everything — a stream that registers a holder, and while it is held, approvals and
questions are delivered to it. `session/control` is the other stream worth
checking if that turns out to be wrong.

The same listing gives every remaining §1 gap a concrete call rather than a
research task:

| §1 gap | endpoint |
|---|---|
| paging older history | `session/page` |
| attachments | `session/attachment` |
| model shown, model selection | `session/modelCatalog`, `session/selectModel` |
| goal / plan / todo summaries | `session/projections` |
| permissions and approvals | hold `userQuestions/attachWait` open as the answerer |
| slash commands | `commands/*` (`CommandsExecuteLine`, `CommandsListResult` are already generated) |
| permission presets | `permissionPresets/catalog` |

So the sequence that was missing is clear: **attach by opening
`userQuestions/attachWait`, keep it open, and only then does an approval request
have anywhere to go.** Until the app does that, a session that needs approval
fails closed and the phone cannot help it.

Everything below is the earlier attempt and what it ruled out.

**Round 95 tried it and learned why nothing came back.** A session was created and
prompted to run `sudo -n true`, and no `approval/*` request event appeared at all.
The reason is in the session's own runtime context, which the follow stream carries
verbatim:

> Current DSH file policy: workspace-write… **Approval policy: ask. Operations that
> require approval may ask through the configured answerers; without an available
> answerer, the request fails closed.**

So requests are not broadcast to whoever happens to be watching — **they are
delivered to a registered answerer, and with none attached the request fails
closed**. That reframes the work completely: the app must first *attach as an
answerer*, and only then will an approval request ever reach it. No amount of
watching the follow stream would have shown one.

It also makes sense of `userQuestions/attachWait`, whose result is only
`{remainingMs}` and which looked useless when questions turned out to arrive as
`tool/call` events: it may be the *attach* half of exactly this mechanism —
registering a holder and being told how long the hold lasts — rather than a
question carrier.

**Next step, changed accordingly:** find the answerer-registration call in
`Protocol/endpoints.json` (look beside `userQuestions/attachWait` and
`userQuestions/answer`, and for anything named attach/register/holder/wait),
attach as one, and *then* trigger an approval with a command that needs it. Only
after attaching should a request event be expected at all.

The device used for the attempt was revoked immediately afterwards.

Permission requests are the gap that most affects usability, because a session
that needs approval **stops** — and unlike a question, the phone currently cannot
answer it at all.

Do not guess this one. The question path only became buildable after a capture,
and the same applies here: `approval/policy` has been seen (`{"policy":"ask"}`),
but **no approval *request* event has ever been captured**, so neither its shape
nor the call that answers it is known.

Capture it the way questions were captured (round 85): create a session, prompt it
to do something that needs approval — something outside the workspace sandbox, so
the `ask` policy actually fires — and follow it with
`/tmp/capture-question.cjs`, which prints each event type and needs only a session
id and a device token. Then read the request's shape out of the capture and find
the answering call in `Protocol/endpoints.json` beside `userQuestions/answer`.

Everything else on this list is ordinary UI work on shapes that are already known.
This one is not, which is why it is called out separately.

State as of 2026-10-08, round 53 of the goal "get a usable v1 iphone app".
Everything here is committed; the suite is green at 163 Swift Testing + 14
XCTest. Read `SPEC.md` for the contract; this file is only the work list.

## Start here

### Answering what the harness asks — CAPTURED (round 85)

The wire shape is no longer a guess. A session was prompted to ask a question
through the live relay, and the follow stream was captured with an authenticated
mux connection (`/tmp/capture-question.cjs`; the relay's own `ws` is needed to
set the Authorization header, and the follow args require the `address` union).

**The carrier is a durable event, not `userQuestions/attachWait`:**

```json
{"type":"event","event":{"type":"tool/call","seq":21,"data":{
  "turn":1,"step":1,
  "callId":"call_00_ET_EBIuBY8wfsMAMoUnsQ0P2566",
  "name":"ask_user_question",
  "arguments":"{\"questions\": [{\"id\": \"colour\", \"header\": \"Colour\", \"question\": \"Which colour do you prefer?\", \"options\": [{\"label\": \"Blue\"}, {\"label\": \"Red\"}]}]}"
}}}
```

Three things that matter and are easy to get wrong:

- **`arguments` is a JSON *string***, so the questions array must be parsed a
  second time out of the event.
- The question shape is `{id, question, header?, options?: [{label, description?}], multi_select?}`
  — taken from the tool's own schema, which also arrives in the stream as a
  `request/header` event listing every tool the model was given.
- **`callId` is the answer's identifier.** `answer(agentId: sessionId, callId: data.callId, questionId: q.id, …)`
  — the agentId is the session, the callId is that field, and the questionId is
  the question's own `id`.

The same tool call also appears inside `assistant/message` (seq 20) as a
`{"type":"tool-call","id":…,"name":"ask_user_question","arguments":"…"}` block,
so a renderer can pick it up from either place; the durable `tool/call` event is
the one that survives a reconnect.

Other event types seen in the same capture, useful generally: `approval/policy`
(`{"policy":"ask"}`), `permission/preset` (`workspace-write`), `sandbox/mode`,
`session/title`, `session/title-llm-request`, `request/header`, `system/message`,
`user/message` (with `surfaceOp`), `agent/inbox/spliced`, `turn/start`,
`step/start`.

**Remaining work is now small and concrete:** model `tool/call` (an event case the
builder probably treats as unmodelled today — check `unmodelledEvents`), render a
card above the composer for `name == "ask_user_question"`, and wire its buttons to
`answer(...)`, which is already built and waiting.

**Round 89: the card renders, and the answer RPC works — with a correction in
round 91 that supersedes the guess below.**

Answering a question through the live relay returns:

```json
{"ok":true,"value":false}
```

`UserQuestionsAnswerResult` is a plain `Bool`. Round 89 guessed `false` meant "the
host did not apply it"; **round 91 disproved that.** A fresh session was asked a
question, answered through the same call, and it worked end to end — `tool/result`
arrived, the agent produced a second message, the turn ended — **and the response
was still `false`**. So the value is not a reliable signal of whether the answer
landed.

The app therefore clears the card on any accepted call and does not surface the
value at all; using it made a working answer look like a failure. The `Bool` stays
on `ConnectionCoordinator.answer` because that is the honest shape of the
response — it is the *interpretation* that was wrong, not the type.

What is still not demonstrated end to end is the agent *receiving* an answer,
because the only question available had gone stale. A fresh scratch session asking
a fresh question would settle it in one run.

Also captured the capture script: `/tmp/capture-question.cjs`, and the scratch
session `session-11be456b-80a5-4bc6-bc4d-af77c28e1ffb` still has the pending
question, so it remains a valid fixture for the card.

**Round 83 correction: the question's wire shape is still unknown, and that is
the actual blocker.** Reading further changed the picture:

- `userQuestions/attachWait` returns only `{ remainingMs: Int64 }`. It is a
  *wait*, not the carrier — it tells a client how long to hold, and nothing about
  the question itself.
- There is no tool-call model generated beyond `ToolCallId`, and **no captured
  fixture contains a question or tool frame at all**. `ask_user_question` appears
  nowhere in `Protocol/` or `Sources/` — it belongs to the harness's own plugin,
  so the earlier extraction never saw it.

So before any UI, the same discipline that produced the rest of this protocol
applies: **capture it**. Create a session through the live relay, prompt it so it
asks a question, and capture the follow-stream frames into
`Fixtures/mux-stream-frames.json` alongside the twelve that are already there.
Then the question model is written from a capture rather than from a guess, which
is exactly what `Protocol/README.md` records as the rule for this repo.

**Round 84 got halfway, and hit an obstacle worth knowing.** The asking session
was created and its prompt accepted (`session-11be456b-…`, prompt invited
`ask_user_question`), and the old capture harness is still in `/tmp`:
`mux-follow.mjs` takes a session id and prints frame shapes, and
`mux-edge-frames.json` holds 575 KB of previously captured frames. But
`mux-follow.mjs` now fails with `socket error`, because it connects to
`wss://127.0.0.1:3443` with no credential — and **loopback no longer bypasses
authentication for the mux upgrade**, a direct consequence of turning address
grants off earlier in this project. The capture needs a bearer credential in the
upgrade, either by giving the script a header (Node's global `WebSocket` cannot)
or by capturing against the LAN address with the device token.

Everything else is ready: `ConnectionCoordinator.answer(...)` is built and takes
the `agentId`, `callId` and answer the capture will supply.

The app's own empty-state copy promises this: *"Pair a harness to read its
sessions, follow a conversation, and answer what it asks."* Reading and sending
work; answering does not, and a session that asks a question stalls on the phone
until somebody reaches a computer. That makes it the biggest remaining v1 gap.

The API is already generated, so this is UI plus wiring rather than protocol work:

- **`userQuestions/attachWait`** — a *stream*. This is how pending questions
  arrive; it belongs beside the follow stream in `ChatSession`, folded into
  something the view can render.
- **`userQuestions/answer`** — unary. Args are
  `UserQuestionsAnswerArguments(answer: AskUserQuestionAnswer)`, and:

  ```swift
  AskUserQuestionAnswer { answers: [AskUserQuestionAnswerAnswersItem] }
  AskUserQuestionAnswerAnswersItem { id: String, selected: [String], custom: String? }
  ```

  So a question carries an `id`, may be answered by selecting from a set, may
  accept a custom string, or both.

Where it goes: a card above the composer in `ChatView`, with the options as
buttons and a free-text field when `custom` is allowed. `Sending` it is the same
shape as `ConnectionCoordinator.prompt` — one more unary call, with retries off
for the same §3.4 reason: an answer sent twice is worse than one reported as
uncertain.

Also generated and worth knowing about for later: `PermissionCatalog`, plus
`UserQuestionsAttachWaitResult` and `UserQuestionsAnswerResult`.

### The composer verification, ready to run (round 77)

A scratch session exists for exactly this:

```
session-429af9e1-6e19-4872-bae2-c4e2d5aa94e5
```

created on the live harness with `cwd /Users/patrick/repo/dsh-mobile`, empty, and
safe to send into. The device that created it was revoked immediately; the app's
own paired device (`dsh-verify`, in the simulator's keychain) is what reads it.

Three small DEBUG-only edits, then rebuild and look — the same pattern as
`DSH_OPEN_HOST`:

1. `AppModel`: `launchSessionId` (env `DSH_SESSION_ID`) and `launchMessage` (env
   `DSH_SEND_MESSAGE`), both `#if DEBUG`, reading `ProcessInfo` **in AppModel**
   because that file already imports Foundation — a view with only `import
   SwiftUI` may not see `ProcessInfo`, and that guess costs a build cycle.
2. `SessionsView`'s existing `.task`: prefer `model.launchSessionId` over the
   first session in the list.
3. `ChatView`'s `.task`: after `start()` succeeds, if `model.launchMessage` is
   set, put it in `draft` and `await send()`.

Then `simctl launch` with `DSH_OPEN_HOST=1`, `DSH_SESSION_ID=<id>`,
`DSH_SEND_MESSAGE="hello from the app"`, and screenshot: the turn should stream
back into the bubble list, which is the one thing about sending that unit tests
cannot show.

**`ChatSession.swift` exists as of round 56** (`d5de6ff`) and compiles: it opens
the follow stream with the captured args shape, folds frames into a
`ConversationBuilder`, and exposes `messages`, `hasGap`, `isStreaming`,
`unmodelledEvents`. It is **untested** — the suite is green but nothing exercises
it yet, and that is the first thing to fix.

To write those tests without hunting: `StubRelayTransport(sockets:)` serves the
mux socket, `StubRelaySocket` is an **actor** (so `await push(...)`, `await fail()`)
with `push(text:)`, `push(json:)`, `fail(with:)` and `finish()`, and
`muxFrameObject(_:)` in `Tests/DSHRemoteKitTests/StreamFrameTests.swift` returns a
captured frame's raw JSON — which is what the socket wants, not a re-encoded
`MuxFrame`.

**Round 57 tried exactly that and it did not work — read this before repeating it.**
A test file was written, compiled, and failed four expectations: the pushed
snapshot never reached the builder. Two things were learned, one fixed and one
still open:

- **Fixed:** the fixture redacts each frame's captured id (`"streamId": "redacted"`),
  and `MuxClient` drops any frame whose id is not registered — its leak guard,
  working as designed. A test must rewrite `streamId` to the id the session
  opened (`follow-\(sessionId)`).
- **Still open:** even with the right id, a frame pushed *after* `start()` never
  arrived. Two candidates, and checking them is the next step: whether
  `StubRelaySocket.receive()` only hands over a message that was pushed while a
  receive was **already waiting** (that would make the ordering impossible from a
  test), or whether `MuxClient` withholds delivery until the stream's `ready`
  frame — note the fixture has **no `ready` entry at all**, and a real mux stream
  opens with one. The second is the more likely of the two and would also mean
  `open` can be observed only after a ready frame.

The test file was removed rather than left failing; the tree is green at 163.

### The app layer, read on 2026-10-08 so `ChatView` is a one-pass write

- `AppModel` (`Apps/DSHRemote/Sources/AppModel.swift`) is `@Observable final class`
  with `status`, `hosts`, `sessions`, `sessionListError`, `isLoadingSessions`,
  `pairingOutcome`, `deviceName`, `isClaiming`, `claimError` — and
  **`private var coordinator: ConnectionCoordinator?`**.
- **That privacy is the one thing that needs a change before the screen can exist:**
  the view cannot reach the coordinator to build a `ChatSession`, so `AppModel`
  needs a method such as `func chatSession(for sessionId: String) async -> ChatSession?`
  that wraps `ChatSession.connected(to:sessionId:)`. Sending uses
  `coordinator.prompt(sessionId:text:)`.
- `SessionsView` is a `List` over `model.sessionGroups` with a **private
  `SessionRow`**, and it has **no `NavigationStack` yet** — so the push has to be
  added in `SessionsView` itself (the row is private to that file), wrapping the
  list and giving each row a `navigationDestination`.
- The chat screen needs: a scroll of `session.messages` (each carrying `role`,
  `text`, `isProvisional`, `reasoning`), a composer calling `prompt`, a
  "history has a gap" notice when `hasGap`, and a streaming indicator from
  `isStreaming`. None of that needs kit changes beyond the accessor above.

Everything below is the older, still-accurate work list.

The app builds, pairs a harness, and lists real sessions. Below the UI everything
is proven against the live relay — see the smoke run below. **The one thing that
makes it usable is the chat screen, and it is two files.**

1. **`Sources/DSHRemoteKit/State/ChatSession.swift`** plus
   `Tests/DSHRemoteKitTests/ChatSessionTests.swift`. The API you need, the two
   argument shapes that cannot be guessed, and the four behaviours to test are
   all written out under "The API a ChatSession implementer needs" below. Five
   delegated attempts at this produced nothing — every one stalled on
   rediscovering that API, which is why it is spelled out here. Write the file
   first, then iterate; do not start by exploring.
2. **`Apps/DSHRemote/Sources/ChatView.swift`** — a screen over the conversation
   builder, which is finished and tested. `SessionsView` needs a navigation push.
   The chat view's requirements are under "Then the chat screen".
3. **Then the machine, not the code:** an Apple ID in Xcode for `DEVELOPMENT_TEAM`
   (no signing identity exists here), or `xcodebuild -downloadPlatform iOS` to
   get a simulator runtime. Both are under "Then the app has to leave this
   machine".

Two defects that were found and fixed, and one accepted residual, are recorded
below with their measurements, so none of them needs rediscovering either.

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

   **The assumed mechanism is wrong, and that is measured — twice.** Two
   standalone probes against `wss://10.1.0.138:3443`, each with a session-level
   delegate that refuses every server-trust challenge:

   - `/tmp/ws-probe.swift` — a pending `receive()` **resumes on its own in
     0.02 s** with `NSURLErrorDomain Code=-999 "cancelled"`;
   - `/tmp/ws-probe2.swift` — and so does a pending `send()`, in the same
     instant, `-999` as well;
   - `/tmp/ws-probe3.swift` — and so do a `receive()` and a `send()` issued
     *after* the task has already failed (`-999` at the moment of the call,
     three seconds after the refusal). A stopped agent reported an 18-second
     park on a late `receive()`; it does not reproduce, and its own note says
     that run was cancelled at t=0, so treat it as an artefact rather than a
     lead.

   URLSession parks nothing, on any call, early or late. **The hang is in our
   code**, and both candidate fixes built on the framework theory were aimed at
   the wrong layer.

   **Read the connect path and the transport, which relocates the suspect
   again.** `URLSessionRelayTransport.openSocket` (`Network/RelayTransport.swift:326`)
   does not await anything at all — it creates the task, calls `resume()`, and
   returns the socket wrapper. So the establishment step cannot hang in the
   transport. With `send` and `receive` both throwing immediately, the park is
   most likely in the **teardown path**: failing the open stream, and closing a
   `URLSessionWebSocketTask` whose handshake never completed. If any of that
   awaits a delegate callback (`didCloseWith`, `didCompleteWithError`) that a
   refused challenge never delivers, then the `withBudget` operation child parks
   *after* its error, cancellation cannot interrupt it, and the group's scope
   exit waits forever — which is exactly the shape observed: the budget never
   reports, and neither does anything else.

   So the next look is `MuxClient`'s failure and stream-completion paths, not
   `connect()` and not URLSession. Five things are now cleared by reading, and
   each one *should* have hung if the framework theory were right:

   1. `URLSessionRelayTransport.openSocket` (`RelayTransport.swift:326`) awaits
      nothing — create, `resume()`, return the wrapper;
   2. `URLSessionRelaySocket.send(_:)` (`:429`) is `try await task.send(…)`,
      which throws `-999` immediately (probe 2);
   3. `URLSessionRelaySocket.receive()` (`:437`) is `try await task.receive()`,
      which throws `-999` immediately (probes 1 and 3);
   4. `URLSessionRelaySocket.close()` (`:450`) is synchronous;
   5. `MuxClient.ensureSocket()` (`MuxClient.swift:248`) has **no retry loop** —
      it classifies and throws.

   **That leaves a contradiction worth stating plainly: every function on the
   path either returns without awaiting or throws immediately, yet `connect()`
   hangs for more than forty seconds.** So the park is not in a function body I
   have read; it is in bookkeeping those bodies call into — the three unread
   candidates are `ConnectionCoordinator.teardown()` (awaited at the top of
   `connect()` and again in `abandon()`), `TaskRelaySleeper.sleep`, and the
   receive loop's own error handling in `MuxClient.startReceiveLoop`.

   Instrumentation is therefore the only remaining move, and it should start
   with `teardown()`, because it is awaited twice on the failing path and is the
   only one of the three that sits directly in `connect()`'s way.

   **Two more cleared, and the hang re-reproduced by hand.** `teardown()`
   (`ConnectionCoordinator.swift:547`) cancels the drain task and awaits
   `mux.close()`, which is synchronous; `TaskRelaySleeper.sleep`
   (`RelayTransport.swift:228`) is a cancellable `Task.sleep`; and the
   transport builds its `URLSession` with `delegateQueue: nil`
   (`RelayTransport.swift:295`) — the same configuration the probes used. Running
   the smoke with a wrong pin against the LAN address still prints up to
   `credential:` and then sits past eighteen seconds.

   So the code reads clean end to end and misbehaves anyway, which means the
   cause is in an interaction rather than a body. The way to see it is to stop
   probing raw URLSession and probe **the package's own transport**: a temporary
   executable that builds `URLSessionRelayTransport` with a wrong pin, calls
   `openSocket`, and prints around each step. That isolates our wrapper from the
   framework, and it is the one experiment nobody has run — every probe so far
   re-implemented the delegate path instead of using the code under suspicion.

   **FOUND, by instrumenting the real path (round 41).** Three prints around the
   establishment budget in `performConnect`, then the wrong-pin reproduction:

   ```
   [probe] before establishment budget
   [probe] inside budget, calling client.open
   … and nothing else, past fifteen seconds
   ```

   Neither print after `client.open` fires — not the `defer` inside the closure,
   not the one after `withBudget`. Two facts follow. **The park is inside
   `MuxClient.open`**, because the closure that wraps it never returns *or*
   throws. And the closure is parked such that **cancellation cannot unwind
   it**, because `defer` does not run either — which is why the budget can never
   report: `withThrowingTaskGroup` may not exit its scope while a child is
   parked, so the expiry is computed and then thrown away.

   **Narrowed to one call (round 42).** Instrumenting `MuxClient.open` itself,
   with the wrong-pin reproduction:

   ```
   [probe] open: before ensureSocket
   [probe] open: socket ready
   [probe] open: calling send
   … and nothing else
   ```

   `ensureSocket` returns promptly; **`liveSocket.send(…)` never returns and
   never throws.** So the parked await is `URLSessionRelaySocket.send` →
   `task.send(.string(…))`.

   **And the obvious explanation is refuted.** A probe with the app's exact call
   order — resume, start a pending `receive()`, then `send` — still throws
   `-999` in 0.21 s (`/tmp/ws-probe4.swift`). So a concurrent receive is not what
   changes `send`'s behaviour, and neither is the delegate or the session
   configuration, which match.

   What is left between the probe and the app is `MuxClient.startReceiveLoop`:
   the app's receive is a **loop**, and if it re-issues `receive()` on a dead
   task without yielding, it can starve the cooperative pool that the pending
   `send` continuation needs — a spin, not a park. That is the next thing to
   instrument, and it is two lines: print inside the receive loop's `catch`, and
   print its call count. If the count is climbing while `send` is parked, the fix
   is to stop looping on a failed socket (or at minimum to yield), not to touch
   the budget.

   **Round 43: that is refuted too, and five probes now point somewhere else.**
   `startReceiveLoop` exits on the first error — the `catch` is outside the
   `while`, so there is no spin. And the `URLRequest` form the app uses
   (`GET` + `Authorization`) behaves exactly like a plain `URL`: with a refused
   challenge, `send` throws `-999` at once, with or without a pending receive
   (`/tmp/ws-probe5.swift`). Five probes have now exonerated raw URLSession in
   every configuration constructible by hand:

   | probe | shape | result |
   |---|---|---|
   | 1 | pending `receive` | `-999` in 0.02 s |
   | 2 | `send` | `-999` immediately |
   | 3 | `send`/`receive` *after* the failure | `-999` at call time |
   | 4 | app's order: pending receive, then send | `-999` in 0.21 s |
   | 5 | `URLRequest` + auth header, with and without pending receive | `-999` immediately |

   **The remaining difference is the delegate's own work.** Every probe refuses
   the challenge on the spot. The app's `TransportDelegate` first computes the
   actual SPKI from the trust and compares it to the pin (`RelayTransport.swift:368-392`)
   before answering, and if that work blocks or never returns on the delegate
   queue, the completion handler is never called, the handshake neither succeeds
   nor fails, and `task.send` waits forever — which is every symptom, including
   the defer never running and the budget being unable to unwind the closure.

   **Round 44: the delegate is innocent, and this is the sharpest fact so far.**
   Instrumenting `urlSession(_:didReceive:completionHandler:)` itself, then the
   wrong-pin reproduction:

   ```
   [probe] delegate: computing SPKI
   [probe] delegate: comparing pins
   [probe] delegate: mismatch, refusing
   ```

   All three print, so the completion handler **is** called and the challenge
   **is** refused, promptly. Combined with round 42 — where `open` printed up to
   `calling send` and nothing after — the picture is now unambiguous:

   > the TLS challenge is refused in time, and `task.send` still never returns.

   The identical call, in a standalone probe, throws `-999` immediately. So the
   park is **not** in TLS, not in the delegate, not in the transport, not in the
   budget, and not in `send`'s implementation — the difference is the runtime
   context the call is made from.

   **What differs, and is unexplored:** in the app the send is issued from an
   **actor** (`MuxClient`) that has, moments earlier, started a **concurrent
   receive loop against the same task**, and registered a continuation whose
   `onTermination` spawns another `Task`. None of the five probes reproduced
   that combination — they used free functions and a detached `Task`.

   **Next experiment, and it is small:** an `actor` that resumes a task, starts
   its receive loop in a `Task`, then `try await task.send(…)` — with the same
   refused challenge. If that parks, the cause is the actor/reentrancy
   interaction and not URLSession at all, and the fix will be in how `MuxClient`
   sequences its first send against its receive loop.

   **Round 45: that is refuted as well, and the probe route is exhausted.** The
   last untested ordering — send issued *while* a receive is still outstanding,
   with the challenge refused after both are in flight — also throws `-999`, in
   0.02 s (`/tmp/ws-probe6.swift`, case A; case B confirms the settled ordering
   too). Six probes have now covered every ordering and every construction:

   | probe | shape | result |
   |---|---|---|
   | 1 | pending `receive` | `-999` in 0.02 s |
   | 2 | `send` alone | `-999` immediately |
   | 3 | `send`/`receive` after the failure | `-999` at call time |
   | 4 | pending receive → send | `-999` in 0.21 s |
   | 5 | `URLRequest` + auth header, ± pending receive | `-999` immediately |
   | 6 | send in flight during the refusal, receive outstanding | `-999` in 0.02 s |

   **Round 46: the budget is now measured, not read — and it is the reason
   nothing reports.** `/tmp/budget-probe.swift` recreates `withBudget` exactly
   and drives it two ways, with no URLSession anywhere:

   ```
   [  0.00] A threw expired                                     <- op throws: prompt, correct
   [ 11.02] B PARKED past 10s even though the 2s budget fired   <- op parked: never returns
   ```

   Case B parks the operation on a continuation that is never resumed — which
   is what a stuck socket call looks like from the budget's side. **The sleeper
   fires at two seconds and `withBudget` still never returns.** That is the
   documented Swift behaviour biting: `withThrowingTaskGroup` cannot leave its
   scope while a child is parked, so the expiry is computed, thrown at the
   group, and then discarded by the scope exit. It does not matter which error
   was meant to surface; nothing surfaces.

   **So this is why the app hangs for forty seconds instead of failing at ten.**
   I cleared `withBudget` twice by reading it; measured, it fails exactly the way
   SPEC §6.9 forbids.

   **The containment fix is independent of the root cause** and should be done
   first, because it turns an unbounded hang into a reportable failure: do not
   let the timeout depend on the group's scope exiting. Run the operation in a
   detached task and race it against the sleep, resuming a continuation from
   whichever finishes first, so the expiry is delivered even when the operation
   never finishes. The parked operation is then abandoned (or cancelled) rather
   than joined. With that in place, a wrong pin becomes
   `establishmentTimedOut` → `hostUnavailable` → "offer re-pairing", which is
   what §6.9 asks for.

   Why the app's `send` parks at all is **still unexplained** — six probes
   cannot reproduce it — but it no longer has to be solved first, and the
   containment fix is worth doing on its own merits: a budget that cannot fire
   is worse than the bug it was meant to catch.

   **Round 47: FIXED, and verified against the live relay.** `withBudget` now
   races through a continuation with a gate (`BudgetGate`) that whichever side
   finishes first claims; the loser is abandoned and the parked operation is
   cancelled rather than joined. The wrong-pin run that used to hang for 41 s+
   now reports, in about ten seconds:

   ```
   connect: FAILED
   status: hostUnavailable (Host unavailable)
   error: socket was not established within 10.0s
   ```

   which is the bounded, actionable failure SPEC §6.9 asks for. The suite stayed
   green at 163 through the change, and the **success path was re-verified live
   afterwards**: a fresh device token against the LAN address still gives
   `connect: OK`, `status: connected`, a `clientId`, **47 sessions read through
   the generated models**, and a clean shutdown — `SMOKE OK`. So both directions
   are confirmed after the budget rewrite, not just the one that was broken.

   **The residual, settled as far as it can be (round 48).** Instrumenting
   `URLSessionRelaySocket.send` itself — the two-line passthrough — prints
   `sock.send: enter` and then neither `returned` nor `threw`; the budget fires
   and reports `establishmentTimedOut`. So **`task.send(.string(…))` never
   returns inside this process**, while the identical call in six standalone
   probes throws `-999` immediately. There is no code of ours left to blame: it
   is URLSession's own call, parked under conditions the probes cannot recreate.

   **Accepted, not chased.** The user-visible behaviour is now correct — a bad
   certificate produces a bounded `hostUnavailable` with an offer to re-pair,
   which is what §6.9 requires — and the cost is a full ten-second budget plus
   one abandoned task per attempt. Reproducing it further means hunting a
   framework-internal park with no reliable trigger, and that is a worse use of
   effort than finishing the chat screen, which is what "usable v1" actually
   lacks. Revisit only if a real device shows the ten-second delay mattering. Start by finding which await is actually parked: instrument
   `ConnectionCoordinator.connect()` with a print at each await boundary and run
   the wrong-pin reproduction below — that will name the parked wait in one run
   instead of another round of inference. Suspects, in order: a task joined on
   the connect *error* path that outlives the failure; the readiness wait
   surviving a socket-open failure; something in `MuxClient`'s subscription
   teardown that ignores cancellation. `withBudget` itself is sound — it takes
   the first result, cancels the rest, and its sleeper is a cancellable
   `Task.sleep`, so do not start by rewriting it.

   **Checked the obvious fix, and it is not a one-liner.** The challenge handler
   at `Network/RelayTransport.swift:368-392` implements the *session-level*
   delegate method, which receives no task — so there is nothing there to
   `cancel()` after refusing. That is now moot: cancelling the task is not what
   unblocks anything, because nothing was blocked.
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
