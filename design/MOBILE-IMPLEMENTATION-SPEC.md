# DeepSeek Harness iPhone — engineering wiring specification

Date: 2026-10-09  
Target: native SwiftUI, iOS 18+, Harness `0.2.0-rc.2`, host protocol `4`  
Status: implementation contract; this document does not claim the features below are shipped

This is the engineering companion to [MOBILE-UX-SPEC.md](MOBILE-UX-SPEC.md). It maps the approved [home/drawer](mockups/2026-10-09/01-home-and-workspaces.png) and [conversation/recovery](mockups/2026-10-09/02-conversation-and-recovery.png) concepts to real host operations, state owners, failure behavior, and tests.

Use the UX spec for appearance and interaction. Use this document for feature wiring and the corrections to earlier assumptions called out below. [SPEC.md](../SPEC.md) remains the underlying transport/security reference. [Protocol/endpoints.json](../Protocol/endpoints.json), its schemas, and installed host source establish the version-specific contracts. Historical entries in `NEXT.md` are investigation notes, not an implementation authority.

## 1. Evidence and important corrections

Three evidence levels must remain distinct:

| Level | What it establishes | Limitation |
| --- | --- | --- |
| Recorded traffic and existing tests | Particular request/response and recovery paths exercised by this repository | Does not establish all configurations or physical iPhone behavior |
| Installed host and web-client source, inspected on 2026-10-09 | Actual server implementation and the web app's integration in this installed build | Requires a native integration test before declaring a mobile feature complete |
| Descriptor/schema | Endpoint, exact argument names, types, and stream/unary classification | Does not prove ordering, durable idempotency, permissions, or UI behavior |

`Protocol/examples` contains generated examples, not live captures. Preserve that distinction in future tests and release notes. Bundle provenance and extraction caveats are in [Protocol/README.md](../Protocol/README.md).

The installed source resolves several previous uncertainties:

- **Standard mode is an agent preset.** Read `agentPresets/list`; select through `session/create.agentPreset` or `agentPresets/select`. Permission presets are a separate feature. The host refuses changing the agent preset once the session has started its first turn, with `agent-preset/locked`.
- **Permission approvals arrive on `$events` as `approval/request` waterfalls.** An ordinary question RPC cannot answer them. Reject is the result string `"rejected"`, not the transport outcome `kind:"rejected"`.
- **Questions have two answer paths.** A live `user-questions/request` waterfall uses `$events/result`. A question in the `continued` projection state uses `userQuestions/answer`. Historical tool calls alone do not prove answerability.
- **`session/attachment` reads an existing image.** It does not upload a file. Generic files use an upload receipt; inline prompt images use base64 and an image media type.
- **Creation supports an explicit session identity and adoption in this build.** The source checks location/preset conflicts and can report a partial workspace-attachment failure. This permits safe reconciliation, but does not justify generic automatic mutation retries.
- **Prompt deduplication exists in this build.** It checks the request identity in the current inbox and durable user messages. The app still must not automatically resend an uncertain prompt.
- **Live text shapes are available in source.** `text-delta` carries `index` and `text`; reconnect baselines contain compact stream records. The current Swift reducer does not yet reconstruct their text.

### Existing implementation versus required work

| Existing seam | Keep | Add or correct |
| --- | --- | --- |
| `ForegroundConnection` | Serialized foreground recovery, backoff, terminal auth/trust handling | Foreground liveness detection and network path integration |
| `ConnectionCoordinator` | Pairing/trust boundary, active RPC/mux generation | Replace the post-ready `$events` discard loop with a real event router |
| `MuxClient` | One socket, unique logical stream IDs, cancellation | Route all required streams through host/session stores |
| `AppModel` | Composition root, selected-host boundary | Persistent navigation, workspace/session store, service injection |
| `ChatSession` / `ConversationBuilder` | Actor isolation, durable sequence identity | Full follow baseline, live text, paging, observable snapshots, interaction reconciliation |
| `ChatView` | Working basic conversation and retained draft during reconnect | Persistent draft ownership, richer renderer, complete decision forms |
| `DshRpcClient` / `DshBareEndpointClient` | Envelope and raw-route primitives | Typed feature services; explicit no-retry policy on every mutation; file-backed uploads |

The working tree's recovery changes previously passed package tests and an iOS simulator build. Physical-phone recovery, new-session submission, approval routing, file uploads, and the redesigned screens remain release gates. Writing this spec does not retest or implement those features.

## 2. Ownership and dependency wiring

Keep one connection owner per selected host. SwiftUI views send intents and observe snapshots; they never create sockets, interpret wire payloads, or decide whether a mutation should retry.

The new names below are proposed implementation types, not existing files.

| Owner | Lifetime and isolation | Owns | Must not own |
| --- | --- | --- | --- |
| `AppModel` | App lifetime, `@MainActor` | Saved hosts, selection epoch, navigation, injected services, published UI snapshots | HTTP parsing, transcript folding |
| `ForegroundConnection` | Selected host, `@MainActor` orchestration | Foreground/background policy, connection attempt task, retry schedule | Per-screen retry loops |
| `ConnectionCoordinator` | Selected host, actor | Transport, credentials reference, mux, ready client identity, connection generation | Draft text or navigation |
| `RemoteEventRouter` | One ready generation, actor | Single `$events` consumer, typed remote events, cancellation, pending event correlation | A second competing iterator on `$events` |
| `HostSessionStore` | Selected host, actor with UI snapshots | Workspace registry, session index, control projections, freshness and errors | Global data mixed across hosts |
| `ConversationStore` | Selected conversation, actor; can extend `ChatSession` | Follow subscription, reducer, history pages, tool rows, transcript snapshots | Durable draft storage |
| `InteractionStore` | Selected host, actor | Approvals and question groups, reply channels, per-request submission state | Authorization inferred from transcript prose |
| `DraftStore` | App lifetime, actor | Atomic local persistence, revisions, new-session transactions, attachment ownership | Credentials or automatic send queues |
| Feature services | Injected, generation-scoped handles | Exact typed reads/writes through the coordinator | Hidden fallback hosts or implicit mutation replay |

Expose immutable `Sendable` snapshots through `AsyncStream` and publish on the main actor. Replace the view's periodic conversation polling. Coalesce rapid text updates for rendering, but deliver cancellation, errors, settlement, and user-input events immediately. A slow UI must not cause unbounded frame buffering.

Suggested placement:

- Extend [ConnectionCoordinator.swift](../Sources/DSHRemoteKit/State/ConnectionCoordinator.swift), [ForegroundConnection.swift](../Sources/DSHRemoteKit/State/ForegroundConnection.swift), [ChatSession.swift](../Sources/DSHRemoteKit/State/ChatSession.swift), and [ConversationBuilder.swift](../Sources/DSHRemoteKit/State/ConversationBuilder.swift).
- Add kit state types under `Sources/DSHRemoteKit/State/`, feature services under `Sources/DSHRemoteKit/Services/`, and `DraftStore` under `Sources/DSHRemoteKit/Persistence/`.
- Compose them in [AppModel.swift](../Apps/DSHRemote/Sources/AppModel.swift). Add the Home, drawer, workspace sheet, model/mode sheets, and secondary views under `Apps/DSHRemote/Sources/`.
- Extend [Tools/generate-models.py](../Tools/generate-models.py) when another declared DTO is needed. Never hand-edit `Sources/DSHRemoteKit/Generated/`.

### Identity and stale-result guards

Use these identities separately:

| Identity | Purpose |
| --- | --- |
| Local saved-host UUID | Stable local namespace for navigation, drafts, and Keychain lookup |
| Host selection epoch | Reject work belonging to a host selection the user left |
| Connection generation | Reject results from an old socket/RPC handle, including after reconnect to the same host |
| Follow subscription UUID | Reject an old session follow or page after navigation/rebaseline |
| Ready `clientId` + remote `eventId` | Correlate a live waterfall reply within its delivery generation |
| Prompt `requestId` | Persisted identity of one human submission, distinct from transport `rpcId` |
| Draft revision / attachment UUID | Prevent asynchronous completion from clearing newer text or attaching a file to another draft |

Every asynchronous completion checks its owner token before mutating visible state. A callback from host A must not update host B even when the session IDs happen to match. An old request's `defer` must not clear a newer request's loading flag.

The host may replay the **same event ID** on a new `$events` client. Invalidate the old correlation tuple; accept the new delivery. Do not require the event ID itself to change.

## 3. Transport and service contracts

### Ordinary RPC

POST `/api/<namespace/method>` using the saved device credential and existing trust policy. The JSON body is an envelope; the feature payload belongs in `payload.args`:

```json
{
  "type": "client-request",
  "rpcId": "transport-request-uuid",
  "method": "session/list",
  "payload": {"args": {"_request": {}}}
}
```

Check `result.ok` in the response. HTTP 200 alone does not establish success. Some successful void/optional results omit `value`; do not turn those into decoding failures. Preserve structured error code/details for classification, while keeping logs redacted.

Use the generated endpoint argument wrappers in [Generated/Endpoints.swift](../Sources/DSHRemoteKit/Generated/Endpoints.swift). The gateway checks argument names strictly: `request`, `_request`, and `agentId` are not interchangeable. Optional properties are omitted rather than filled with speculative `null` values.

**Retry rule:** safe reads may use the bounded existing read-retry policy. Every write must explicitly pass `RPCFailureRetryPolicy.none`, including create, model/preset changes, prompt, commands, answers, event results, and upload. Do not write `.none` where Swift could infer `Optional.none` and select the default retry policy. Add a mutation-specific service helper to make the policy unavoidable.

After an uncertain mutation, refresh/reconcile state and retain the user's input. A reconnect retries subscriptions and reads, never a pending human action. An automatic recovery operation may delegate an unhandled event with `outcome.next`; it must never manufacture an approval or answer.

### Multiplexed streams

Use one authenticated WebSocket at `/api/remote.mux`. Each logical stream gets a fresh UUID:

```json
{
  "type": "open",
  "streamId": "stream-uuid",
  "endpoint": "session/follow",
  "payload": {"args": {"request": {
    "address": {"kind": "session", "sessionId": "session-example"},
    "assistantStream": true,
    "maxMessages": 60
  }}}
}
```

Items arrive inside `{type:"item",streamId,value:...}`. Cancel a subscription with `{type:"cancel",streamId}`. Cancellation ends observation; it does not cancel the agent's work.

| Stream | Exact args | Owner and opening condition |
| --- | --- | --- |
| `$events` | `{}` | Coordinator/router; first stream, wait for `{type:"ready",clientId,host}` |
| `workspace/follow` | `{}` | Host store; after ready |
| `session/control` | `{}` | Host store; after ready |
| `session/follow` | `{request:{address:{kind:"session",sessionId},assistantStream:true,maxMessages:60}}` | Selected conversation; after ready |
| `userQuestions/attachWait` | `{agentId:sessionId,callId}` | Interaction store; only for the matching live timed question |

`60` is a proposed initial phone page size, not a host requirement. Tune after device measurements. `$events` accepts **no** `agent`, `agentId`, or session filter argument. Receive events for the host, then scope their presentation using the delivered `agentId`.

Replace the coordinator's current post-ready drain with one router that also reports stream termination to recovery. Do not leave the discard loop running beside another consumer. An event arriving immediately after ready must not be lost while stores mount.

### Connection readiness and screen readiness

Track transport status independently from each resource's `empty/loading/current/stale/failed` state. A ready socket is not proof that the workspace list, transcript, or pending controls are current.

On foreground return:

1. Preserve the selected screen, transcript display, scroll anchor, and local drafts.
2. Invalidate the previous generation, disable its action channels, cancel subscriptions/tasks, and await transport teardown.
3. Connect with the saved credential and pin. Wait for a new ready frame; publish the new generation.
4. Open host streams and refresh the session index. Reopen the selected follow independently so a list failure does not prevent an already known session from loading.
5. Reconcile interaction state and pending submissions. Enable each action only when its required state is current.

Keep the existing jitter/backoff behavior. Treat authentication refusal and changed host trust as terminal until the user resolves them. Do not repeatedly re-pair on ordinary network errors.

Remaining liveness work: add an injectable network-path observer and a bounded WebSocket ping deadline while foregrounded. Initial policy: ping after 20 seconds without inbound traffic, allow 10 seconds for a response, then recover; tune on a physical phone. A path-change callback triggers one coalesced liveness/recovery attempt, not a loop per callback. Path availability is a hint, not proof of host reachability. Stop probes in the background; do not promise an immortal background socket.

## 4. Home, workspaces, and session cards

### Data and subscriptions

`workspace/follow` starts with:

```json
{"type":"baseline","value":{
  "items":[{"workspaceId":"workspace-example","path":"/example/project","title":"Project","sessionIds":[],"createdAt":"2026-10-09T00:00:00Z","updatedAt":"2026-10-09T00:00:00Z"}],
  "archivedSessionIds":[],"pinnedSessionIds":[]
}}
```

Its deltas are `upsert` with `workspace`, `remove` with `workspaceId`, `order` with `workspaceIds`, `archived` with `archivedSessionIds`, and `pinned` with `pinnedSessionIds`. Apply them to an ordered registry. Treat paths as host paths and IDs as opaque; never derive a workspace ID from its title or a local iPhone directory.

Read sessions with a single `session/list` call carrying `{_request:{}}`. **This build is not paginated.** `SessionListRequest` does declare an optional `cursor`, but the installed remote handler ignores its request outright — `async list(_request, signal) { return { items: await this.listState.list(signal) }; }`, where the underscore prefix marks the parameter deliberately unused — and `SessionListValue` is `{items:[…]}` with no cursor property, so no next-page token is ever returned. One call supplies the whole index. Build each refresh into a temporary index and publish successful data without discarding the previous display on failure. A failed refresh must not imply that missing sessions were deleted. Re-check this against the installed version before adding paging: a cursor field that nothing reads is not evidence of a paged endpoint.

The list returns `items` with `sessionId`, `updatedAt`, `running`, `blank`, `agentAvailable`, optional `cwd`/parent/origin, and projection data. Use `workspace.sessionIds` for membership; do not guess from title. Sessions without known membership can appear in a clearly labeled ungrouped section. Subagents are not ordinary new-session targets.

`session/control` sends a `baseline` whose `value.projections` is keyed by session ID, then `{type:"projection",sessionId,key,value,seq}` updates. Track versions per session **and projection key**: several keys can legitimately update at the same sequence. A baseline's `asOfSeq` applies to the values it actually supplies, not to every possible key forever. Ignore older values; accept independently newer keys. Keep follow, list, and control projections behind the same merger.

Use control projections for `title`, `agentPreset`, `modelSelection`, `permissions`, `inbox`, `userQuestions`, and other known fields. Unknown projection keys remain safely decodable. `session/projections` with `{request:{sessionId}}` supplies a targeted refresh when needed.

### Card behavior and freshness

- Recent cards use host timestamps and real titles, with an explicit untitled fallback. Workspace names come from the registry.
- “Needs input” comes from current interaction channels/projections. A historical `ask_user_question` tool call does not produce this badge by itself.
- Running status initially comes from the list and selected-session lifecycle events. Until a verified event-to-list invalidation map exists, refresh `session/list` on foreground, opening the drawer, pull-to-refresh, and at most every 15 seconds while the recent list is visible. Do not invent a `running` control projection.
- Local search covers loaded sessions and workspaces. Do not label local filtering as full transcript search; the host does expose `session/search {request:{query}}`, which searches current visible message content without activating a matching session. That endpoint is deferred here rather than overlooked, so the first slice stays local and honest about its scope.
- Cached cards remain visible during refresh. An empty loading result, an empty successful workspace, and a failed session list are different screens.

The two misfiled session initialization stubs documented in [CONNECTION-REVIEW.md](mockups/2026-10-09/CONNECTION-REVIEW.md) can currently make host session listing fail. They are a separate host-data problem. The phone must display that resource error while remaining connected; it must not silently repair or delete host files.

## 5. Persistent drafts and first submission

### Draft storage contract

Store drafts by local host UUID plus either a session ID or a new-session draft UUID associated with a workspace ID. Using only a workspace key would let two new drafts overwrite each other.

Persist text, monotonically increasing revision, desired agent preset/model, local attachment references and preparation state, and any in-progress submission identity. Store attachment bytes in the app's private directory; retain the security-scoped import only long enough to copy the file. Use atomic writes and iOS file protection. Debounce typing writes, flush at submission and lifecycle transitions, and surface persistence errors without destroying the in-memory text.

Persist navigation separately: last host, workspace, session, and optional scroll anchor. A restored destination must be checked against the current host before enabling actions. Cached transcript persistence is optional for this slice; persistent drafts are required.

Capture a submission's draft revision. Acceptance clears only that revision's submitted content. If the user typed new text while the operation was pending, preserve the newer draft. A late upload completion uses its original draft/attachment key even if the user navigates away.

### New-session transaction

Opening New session changes local UI only. Do not create a host session until the first Send.

Before any request, atomically persist a transaction containing the host/workspace, a proposed `session-<UUID>`, selected preset/model, prompt `requestId`, captured text/attachment references, draft revision, and stage. Suggested stages: `prepared`, `creating`, `created`, `configuring`, `uploading`, `submitting`, `accepted`, `uncertain`.

Create using `session/create` with the following `payload.args`:

```json
{"request":{
  "sessionId":"session-example",
  "workspaceId":"workspace-example",
  "agentPreset":"host-advertised-preset-id"
}}
```

`workspaceId` and `cwd` are mutually exclusive, and the host enforces it rather than picking one: supplying both is refused with `gateway/bad-request` and the message `session.create accepts workspaceId or cwd, not both`. An unknown `workspaceId` is refused separately with `workspace/not-found` carrying `{workspaceId}`. The phone uses a selected existing workspace. Omit `agentPreset` when using the host default. The result is `{sessionId,agentPreset?}`.

Omitting `sessionId` makes the host mint one (`session-<uuid>`), and that also disables the persisted-identity checks: the host passes `request.sessionId !== undefined` as its `checkPersistedIdentity` flag, so a conflict with an existing directory header is only detected when the client supplied the identity itself. Supplying the ID is therefore what makes adoption safe, and it is the phone's job to supply it rather than let the host invent one.

Perform these steps in order:

1. Validate the selected host, workspace, current capabilities, local input, and attachment preparation. Freeze the submission input; keep later edits separate.
2. Create/adopt the persisted session identity once. Do not generate a replacement ID in a timeout handler.
3. Save the returned identity and bind navigation/draft ownership to it before another host operation. Preserve the transaction until the prompt is reconciled.
4. Open `session/follow` and wait for its valid snapshot. Read model/image limits and current selection.
5. Apply the staged model selection if different from the host's confirmed selection. Do not submit using a different model after selection fails.
6. Upload prepared generic files into this session; inline images remain prompt content. Wait for required uploads to succeed.
7. Submit `session/prompt` using the already persisted request ID. Mark accepted only from a positive response or authoritative reconciliation.
8. Clear only the submitted draft revision and navigate to the live conversation. A created session remains available if a later step fails.

The installed server explicitly adopts a supplied session ID, checks persisted cwd/preset conflicts, and rejects subagent ownership. Native tests must still cover live/adopted/resumed cases. After unknown creation outcome, query/follow the proposed identity before offering Retry; a user retry reuses the same identity and frozen create parameters. Do not automatically replay on reconnect.

`session/workspace-attach-failed` means the session may already exist. Read `details.sessionId`, reconcile it, and show the attachment problem; do not create a second session. Retry of attachment/adoption is a deliberate recovery action after checking the supported host behavior.

### Existing-session prompts

Submit `session/prompt` with:

```json
{"request":{
  "requestId":"human-submission-uuid",
  "sessionId":"session-example",
  "mode":"queue",
  "content":[{"type":"text","text":"Review the connection recovery."}],
  "clientTimeZone":"America/Chicago"
}}
```

Use `TimeZone.current.identifier`, not a hardcoded zone. The host rejects empty text without an attachment. Ordinary Send uses `queue`; a distinct, deliberately designed steer action may use `steer` later. The source routes them to `followup` and `steer` respectively. `{accepted:true}` means accepted for processing, not finished.

For an uncertain send, inspect inbox `next-turn`/`next-step` entries and durable `user/message.data.source` for `{kind:"user",rpcId:<requestId>}`. Presence establishes submission; absence from a limited window does **not** establish non-delivery. Keep “Delivery unconfirmed,” preserve the transaction, and allow deliberate retry only under the verified host deduplication contract. Reuse the original request ID for that retry, with the same content. A new human message gets a new ID.

Do not send a new prompt before the conversation baseline is current. Do not queue network sends while offline. Loss of the phone connection must never call `session/cancel`.

## 6. Model and mode pickers

| Control | Read | Mutation | Confirmation |
| --- | --- | --- | --- |
| Model/reasoning | `session/modelCatalog {}`; session `modelSelection` projection | `session/selectModel {request:{sessionId,provider,model,reasoningEffort?}}` | Returned `{selected:{provider,model,reasoningEffort?}}`, then projection |
| Agent mode | `agentPresets/list {}`; session `agentPreset` projection | Create with `agentPreset`, or `agentPresets/select {agentId,agentPreset}` for a blank session | Returned preset ID; `agent-preset/selected` event updates the `agentPreset` projection |
| Permission status | `permissionPresets/catalog {}` and `permissions.currentValue` | No permission-preset mutation in this initial design | Read-only label/details |

The model catalog contains `default`, `routableProviders`, `groups`, and `failures`. Each group's `id` identifies the provider; each model has an `id` and display `name`, with optional advertised reasoning choices. Preserve provider/model IDs exactly. Show provider failures without hiding the usable groups. Never hardcode Spark, Ember, or a DeepSeek model as the selected backend.

The model-selection response is normalized by the host, which resolves the request through its own call-config path and returns the settled `{provider, model, reasoningEffort?}` rather than echoing what was asked for. Its source also saves the selection as a host default asynchronously — `agentDefaultModel.saveSelection` is deliberately not awaited, and a failure is logged as a warning, so the session selection can succeed while the default silently does not persist. Document the side effect in Settings/help and do not promise the choice affects only this phone. Do not offer unsupported reasoning efforts.

A model the host cannot resolve is refused with `session/model-unavailable` carrying `{provider, model}`, which is the state the picker must show rather than leaving the old selection displayed as if it had taken.

Stage selections locally before creation. While an existing selection request is pending, serialize selection and sending so the prompt cannot race ahead on the old model. On refusal, restore the confirmed display and keep the draft. On uncertainty, refresh projections before enabling Send.

The roster provides `id`, `isDefault`, optional `name`, `description`, and `broken`. Display “Standard mode” as the web app's label for the appropriate default; use the roster ID on the wire. A broken preset is unavailable with its explanation. After a first turn starts, show the mode as read-only; handle `agent-preset/locked` even if a stale `blank` flag suggested it was selectable.

## 7. Conversation, live text, tools, and history

### Follow reducer

A `session/follow` snapshot carries `header`, `cursor`, `records`, `hasMore`, `projections:{asOfSeq,values}`, and optional `assistantStream:{revision,activeAttempt?}`. Preserve all of them. The current minimal reducer's record-only snapshot handling is insufficient.

On a new follow generation, construct a new authoritative baseline off-screen, then replace the current window atomically. Keep the previous screen visible as stale until replacement succeeds. Do not merge an old transient attempt into a new baseline. Previously paged history may remain only after a verified same-session history policy; the initial implementation can discard it and allow paging again.

Durable events are keyed by sequence and session. Ignore duplicates, maintain ordering, and advance the expected live sequence from `snapshot.cursor + 1`, not the last visible message. Non-message events still count toward the sequence. A missing sequence triggers a rebaseline; it is not proof of lost user data. Keep unknown event payloads available for a restrained unsupported-activity row rather than crashing or inventing a meaning.

Use a typed presentation layer above durable records:

- User and assistant messages: Markdown, fenced code, lists, links, and image references. Treat host text as untrusted display content; never run embedded scripts or commands.
- Tool calls/results: join by verified call identity, keep independent concurrent calls separate, and derive running/success/failure only from their actual events. Expand exact arguments/output on demand, with bounded rendering for large results.
- Model-provided reasoning: optional collapsed detail where the host supplies it; never synthesize it from ordinary text.
- Goals/todos: display verified projections as read-only progress for this slice. Do not invent edit controls without their own mutation flow.

Use durable row identities to preserve scroll position. Auto-follow new output only when already near the bottom; otherwise show a new-content affordance. Prepending a page retains the visible row and offset. Keyboard and Dynamic Type changes must not reset the transcript.

### Assistant stream contract

Outer `assistant-stream` values wrap a `frame` with `start`, `chunk`, or `end`. Maintain attempt identity, revision, expected chunk index, and block index separately. The outer frame index is not the inner content-block index.

The installed LLM source encodes visible text chunks as `{type:"text-delta",index:<block>,text:<fragment>}` and reasoning as `reasoning-delta` with the same fields. Tool argument fragments use `tool-call-delta` with `index`, `id`, optional `name`, and `argumentsDelta`. Do not parse incomplete argument fragments as complete JSON.

Reconnect `activeAttempt.stream` is a compact prefix, not an array of identical live frames. Implement and fixture-test expansion of `chunk`, `text-chunks`, `reasoning-chunks`, and `tool-call-chunks` records, including their timing arrays. Restore `nextIndex` and do not append an already included prefix again. Reference `dsh-llm/lib/types/assistant-stream.js::expandAssistantStream` and the host/web folds listed in §13.

The exact compact shapes, read from `validateRecord` in that file, which validates them at a durable boundary by requiring **exactly** these keys:

| Record | Keys | Members |
| --- | --- | --- |
| `text-chunks` | `type`, `time0`, `index`, `dt`, `texts` | `texts`, non-empty |
| `reasoning-chunks` | `type`, `time0`, `index`, `dt`, `texts` | `texts`, non-empty |
| `tool-call-chunks` | `type`, `time0`, `index`, `dt`, `id`, `args`, plus `name` only when the run carried one | `args`, non-empty |
| `chunk` | `type`, `time`, `chunk` | one raw chunk, verbatim |

`dt` holds the inter-member gaps and therefore has exactly `members.count - 1` entries. Expansion is cumulative from the run's start, not relative to the previous member:

```js
let time = record.time0;
for (let i = 0; i < members.length; i += 1) {
    if (i > 0) time += record.dt[i - 1];
    // text-chunks      -> { type: "text-delta",      index: record.index, text: members[i] }
    // reasoning-chunks -> { type: "reasoning-delta", index: record.index, text: members[i] }
    // tool-call-chunks -> { type: "tool-call-delta", index: record.index, id: record.id,
    //                       ...(has name ? { name: record.name } : {}), argumentsDelta: members[i] }
}
```

Three consequences worth stating, because each is easy to get wrong:

- A run's `index` is the **content-block** index. It is not the outer assistant-stream frame's `index`, which advances per frame.
- A `tool-call-chunks` run requires non-empty `id` and `name`; the accumulator falls back to a raw `chunk` record when either is empty, so a tool call can arrive either way and both must expand.
- The host's accumulator keeps an internal `lastTime` while merging runs, and strips it when publishing the durable form. The wire records above carry no `lastTime`, and a decoder that requires one will reject every real record.

`chunk` records are the fallback for everything that does not compact — including the other model chunk kinds, `block-start`, `block-end`, `usage`, and `finish` — so the expander must pass an unrecognised raw chunk through rather than drop it.

Duplicate/older frames must not duplicate text; gaps, contradictory baselines, or unsupported structural changes cause a fresh follow. Never require a new live `start` after reconnect when a valid active baseline already supplies it.

On a committed end, associate the named durable event sequence/type with the provisional attempt. Render the final answer once. Test both settlement arrival orders, and missing settlement recovery. On abandonment, retire the provisional attempt. Preserve any valid durable failure/interruption content. The source web fold is the reference for settlement identity; the native view need not reproduce its fractional presentation sequence numbers.

### Older history and cancellation

Call `session/page` with `{request:{address,throughSeq:<opening snapshot cursor>,beforeSeq:<oldest loaded seq>,maxMessages:60}}`. `throughSeq` is fixed for that follow generation; `beforeSeq` is exclusive. The first page may omit `beforeSeq`. Merge `records` by sequence, use `hasMore`, prevent concurrent duplicate page loads, and reject a page completing after rebaseline/navigation. Do not substitute `session-log-deepseek/delivery-accepted.throughSeq` for the opening follow cursor.

`session/cancel` takes `{request:{sessionId}}`, not a follow address. Installed source calls agent cancellation with `keepInbox:true`. Earlier live observations did not establish immediate interruption. Keep a stop control gated until tested with active tools and queued messages. If exposed, say “Stop requested” on acceptance and wait for host settlement before saying stopped; never imply the inbox was cleared.

## 8. Approval and question cards

### Remote event routing

The `$events` router handles `ready`, `emit`, `waterfall`, and `cancel` values. A waterfall is shaped as follows; request content depends on the event:

```json
{"type":"waterfall","event":"approval/request","eventId":"event-example","agentId":"session-example","request":{
  "toolName":"bash","callId":"call-example","reason":"Run the requested test command"
}}
```

Correlate by host/generation/client/event and session. Match tool cards through `callId` when present. A host-wide event without usable session scope must not be attached to whichever chat happens to be visible. Unsupported waterfalls are delegated with `{kind:"next"}` so this client does not strand another provider; this does not authorize the requested action. Record only a redacted diagnostic classification.

`{type:"cancel",eventId}` retires the corresponding live delivery. Installed source sends cancellation on event completion as well as abortion, so do not present every cancel frame as “the user rejected.” A cancellation arriving during submission wins over a stale local button state.

### Permission approval

For `approval/request`, show the supplied tool name/reason and available details. Use a matched tool record for additional context only when identity is verified; never fabricate a command absent from the request/history.

Reply via `DshBareEndpointClient.submitEventResult`, using ordinary RPC framing for `/api/$events/result` and these args:

```json
{"clientId":"current-ready-client","eventId":"event-example","outcome":{"kind":"result","value":"allowed-once"}}
```

Reject uses the same args with `value:"rejected"`. `outcome:{kind:"rejected",error:...}` rejects the remote continuation with an error; it is not the Reject button. `next` hands off to another listener; it is not rejection either. No “Always allow” action is included.

Disable duplicate taps while submitting. On acknowledgement, retire this client's actionable controls. Do not claim the agent executed the action: another client may have already settled it, and the gateway ignores stale/undelivered results while still allowing an acknowledgement. Follow host activity for the actual outcome. On uncertain delivery, keep the decision history and resynchronize; never replay automatically.

### Structured questions

One group is keyed by `(host,sessionId,callId)` when a call ID exists. Each question is keyed within that group. The current dictionary keyed only by question ID can collide across calls and must be replaced. Unnamed live questions use their event correlation and do not reuse a persisted named draft.

Render every question in the batch, its options/details, single/multiple-selection rule, and permitted custom input. Validate the complete answer before submission:

```json
{"answers":[{"id":"question-example","selected":["Option exactly as advertised"]}]}
```

Exactly one entry per question; IDs and selected labels must match the request, with no duplicate selections. Include optional `custom` only for a permitted nonblank custom answer. Single-select cannot combine a nonempty custom answer with a selection. An intentionally skipped item uses `selected:[]` if permitted by the question contract. Persist partial forms under their question group; restore them only when the current question structure still matches.

Choose the answer channel from current host state:

| State | Action channel | Success/refusal handling |
| --- | --- | --- |
| Current `user-questions/request` waterfall | `$events/result` with `outcome:{kind:"result",value:<complete answer>}` | Disable this delivery on ack; reconcile cancellation/projections |
| Live timed waterfall with `request.wait:{callId,timed:true}` | First open `userQuestions/attachWait {agentId,callId}`; then answer the same waterfall | The stream yields `{remainingMs}` and holds the host wait while attached |
| `userQuestions.active` row with `state:"continued"`, no live answer channel | `userQuestions/answer {agentId,callId,answer:<complete answer>}` | `true` accepts the reply; `false` means no longer answerable, not success |
| Historical/settled row only, or `open` without a current delivery | No mutation | Read-only history or “Updating request…” |

The host's continued-answer implementation queues a steer message with source `{kind:"user-question-reply",callId,outcome:"answered"}`. Suppress the editable card while matching replies exist in inbox `next-step` or `next-turn`, then reconcile active/settled projections. Treat the source's `REPLY_QUEUED` error as reconciliation, not permission to send again; preserve its wire encoding in a captured fixture before depending on a particular error-envelope location.

For timed questions, the native UI owns the foreground claim's lifetime. Release it on background, request cancellation, host switch, or completion. A claim pauses the host timer while attached; never keep it hidden indefinitely. Mirror the web behavior: derive the local deadline from `remainingMs`, pause the visible countdown while the user focuses/edits the answer, and on an unattended local timeout send a `UserQuestionError` rejected outcome with code `ASK_TIMED_OUT`, then reconcile the continued state. Closing and reopening a sheet does not refresh the original deadline arbitrarily.

Hiding a named question card is local presentation only. Provide a way to reopen it. An explicit cancellation for a live unnamed question uses `outcome:{kind:"rejected",error:{name:"UserQuestionError",message:"the user cancelled ask_user_question",code:"ASK_CANCELLED"}}`. Ordinary navigation/reconnect never sends a fabricated cancellation or answer. Releasing an event to another handler uses `next`, with no approval implication.

The web client defines a third code alongside those two — `ASK_ABORTED`, with the message `ask_user_question was aborted before the user answered` — so a live question can also be settled by the host aborting it rather than by a timeout or a user cancellation. Render an aborted question as settled history exactly like the other two; do not leave a live card behind for it, and do not treat it as a rejection the user made. All three codes come from the same table in `dsh-client-ui-user-questions/lib/client.js` (`rejectionMessages`), which is the reference for their exact strings.

Replace the existing one-question helper with a full-batch reply intent that selects the verified channel. The transcript parser can support history rendering; it cannot be the authority for active controls.

## 9. Images, files, and slash commands

### Attachments

Selecting a file only prepares local content. A new-session draft must acquire its actual session identity before uploading. Bind every upload to its draft, session, host, and attachment UUID. Keep prepared bytes after network failures so the user does not have to pick the file again.

For generic files, prefer POST `/api/session/uploadFileBinary?sessionId=<encoded>&name=<encoded>` with `Content-Type: application/octet-stream` and the existing authenticated transport. Add a file-URL/streaming upload primitive; the current `Data` method must not force large files and their base64 copy into memory.

The raw route returns a **bare** `{ok,value/error}`, without an RPC envelope. Success value is `{receiptId,file:{attachmentId,name,bytes}}`. Both HTTP status and `ok` matter. Only a 404 indicating the raw route is unavailable may trigger the bounded base64 fallback `fileUploads/upload {agentId,request:{data:<base64>,name?}}`; retain the existing 20 MiB app cap for that fallback. Never fallback around auth, size, or admission errors.

Include a staged file in a prompt as `{type:"file",receiptId}`. `attachmentId` is not a substitute. Installed source scopes receipts to the receiving session runtime, binds them to a prompt request, and retires them when that prompt becomes a durable user message or its queue occurrence is removed. Do not assume receipt durability after host restart or invent an expiry time. A rejected/uncertain receipt must be reconciled before explicit reupload/resend; no generic automatic write retry.

Images are distinct: use `{type:"image",mediaType,data:<base64>,name?}` in prompt content. Support only host-advertised media types and enforce `imageLimits` fields `maxImageBytes`, `maxImagesPerMessage`, `maxMessageImageBytes`, `maxImagePixels`, and `maxImageDimension`. Prepare phone formats into an allowed representation and report conversion errors before Send. The host also validates the selected model's image input capability; do not infer that capability from its display name.

To display a previously stored image, call `session/attachment {request:{sessionId,attachmentId}}`. Its result includes image metadata under `attachment` and base64 `data`. The server validates that the image is referenced by that session. Decode off the main actor, downsample for display, and bound memory/disk caches. Arbitrary file browsing/download is a separate feature, not implied by this image endpoint.

### Commands

Read `commands/list {agentId}` for the selected session. Entries provide `name`, `description`, optional `definitionId`, and optional `input:{hint,attachments?}`. Refresh when the session/preset changes and on a command-refused refresh path. Cache only within the appropriate host/session scope.

Typing `/` filters suggestions. A registered command submits through `commands/execute {agentId,line,submittedAttachments}`; include an explicit empty array when none are present. Use the generated submitted-attachment union, not an invented array of filenames. Respect each command's advertised attachment rule. Unknown slash input uses the ordinary prompt path rather than being silently executed as an arbitrary command.

Decode the command result's `success`/`error` variant, optional text, and optional `sourceEventSeq`. A permitted absent result is also possible; do not assume every command returns text. If the host supplies a durable source event, avoid rendering a duplicate local transcript message. Keep command drafts on refusal and never replay execution after reconnect. On a new draft, establish the session through the same create transaction before executing a session-scoped command.

## 10. Secondary drawer destinations and capability limits

These destinations should become useful read-only surfaces first. A drawer label is not evidence of a supported API.

| Destination | Initial wiring | What remains gated |
| --- | --- | --- |
| Plugins | `pluginInventory/list {}` → entries with module/title, enabled state, fiber phase, errors; optional preset rows | Installation, enable/disable, removal and `pluginManager` actions need separate mutation UX and tests; `managementAvailable` must be honored |
| Scheduled tasks | `schedule/catalog {}` for host catalog; `schedule/list {request:{sessionId}}` for a session; `schedule/history {request:{sessionId,id,limit:20,before?}}` for delivery history | Creating/editing/deleting tasks is a later slice; do not reinterpret a delivery prompt as an instruction to the phone |
| MCP | No dedicated inventory endpoint established by the inspected descriptor | Keep unavailable or omit until the real service/configuration surface is traced; plugin presence is not server health |
| Usage | Session-level usage only where durable assistant events or verified projections supply it | No verified host-wide usage endpoint here; do not treat account balance as token usage or estimate totals from a partial transcript |
| Settings | Saved-host selection, connection details, pairing/forget, appearance, diagnostic export | Live relay/VPN/DNS changes and server secret management are separate authorized work |

Schedule catalog entries include `sessionId`, `status`, schedule kind/parameters, and optional `lastDelivery`. Honor their actual time zone and timestamps. Do not assume there is a schedule stream; refresh on entry, pull-to-refresh, and foreground return while that screen is visible.

Maintain a small capability state per host/version: `unknown`, `available`, `unavailable(reason)`, or `failed(error)`. Start from known descriptors for this build and actual read results. A transport 404 or unknown-method response needs endpoint-specific interpretation; 401/403, timeout, and host-data failure are not proof that a capability is absent. Do not probe destructive methods to discover support. There is no invented universal `/capabilities` endpoint.

## 11. Remote identity, address changes, and diagnostics

### Pairing and saved-host management

Reuse the existing `PairingClient`, `SavedHost`, host store, and Keychain store. The QR scanner and paste form feed the same payload parser and expiry/trust validation; neither goes through a browser session. Show the host identity before the deliberate first-pair action. Persist the claimed device token in Keychain and only nonsecret host metadata in the host store. If either write fails, report the incomplete save and keep the user in a recoverable pairing state; do not claim the host is remembered.

Selecting a saved host starts recovery immediately. Renaming a local display name preserves its UUID, credentials, and drafts. Forget uses an explicit confirmation and then removes that host's local data; it does not silently revoke a relay device or delete host sessions. The exact pairing transport and pin validation remain governed by [SPEC.md §6.3](../SPEC.md#63-pairing).

### Address and trust behavior

Automatic reconnect is required for the already trusted host. Preserve the local host UUID, device credential, and pin across ordinary network changes. Resolve the configured hostname afresh on a new connection rather than retaining a resolved IP indefinitely. An obsolete literal IP cannot discover a new host location by itself.

A stable HTTPS/WSS hostname reachable from Wi-Fi and cellular is the intended deployment target for the UX spec's no-phone-VPN experience. The current LAN address remains a development route. A stable hostname does not by itself fix relay grants tied to an address; the relay investigation records that limitation. Host identity should ultimately remain independent of advertised URL, with a deliberate, verified migration path for a changed origin and retained device identity. Until that relay behavior is implemented and tested, do not promise seamless host-address migration.

Keep address migration distinct from a changed TLS key. A mismatched pin stops recovery and requires identity verification; never accept any certificate merely to make the connection succeed. Do not forward saved bearer credentials across an unrelated redirect/origin. Switching Wi-Fi/cellular should not need another application approval if the same trusted endpoint remains reachable.

Diagnostics should record a correlation UUID, endpoint/stream kind, connection generation, resource state, status/error code, and durations. Exclude authorization headers, pairing payloads/codes, raw prompts, answers, uploads, signed URLs, and full private paths. Make diagnostic export explicit and previewable. A data error should identify its resource without dumping session contents.

Repair of the two misfiled initialization logs, relay changes, VPN/tunnel deployment, DNS, and credential changes require their own approved operational action. None is a side effect of implementing this app spec.

## 12. Delivery sequence and acceptance tests

Each slice must work with real data before visual polish expands its surface. Use injected transports/stores, a stub mux server, sanitized captured fixtures, and a disposable authorized host session. Do not send verification prompts to an existing working conversation.

| Slice | Implementation boundary | Required completion evidence |
| --- | --- | --- |
| A. Foundations | Router, generation guards, draft persistence, observable snapshots | No lost post-ready event; host isolation; draft survives app relaunch |
| B. Home and drawer | Workspace/control streams, session pages, native navigation/cards | Actual host hierarchy and errors render; selection survives foreground return |
| C. Conversation | Baselines, text/tool renderer, paging, approval/question routes | Fixture coverage plus real approval and both question paths in a scratch session |
| D. Start and compose | Create/adopt transaction, model/mode, images/files, commands | End-to-end create → configure → follow → upload → submit without duplicate work |
| E. Secondary views | Capability-gated plugin/schedule/session-usage views | Every visible control has a verified source/action; unsupported sections are honest |
| F. Device/route validation | Background recovery, network handover, deployment-specific identity | Physical iPhone evidence; separate approval for host/relay changes |

### Integration test matrix

| Area | Cases | Required assertion |
| --- | --- | --- |
| Ready/router | Ready immediately followed by waterfall; event replay after reconnect; normal/error stream close | No lost event; one consumer; recovery once; latest client correlation used |
| Host isolation | Slow host A list/upload/answer response after switching to B | No B state mutation, no cross-host draft/file leakage |
| Background | Lock/unlock, app switch, repeated active notifications, response arriving during teardown | One live generation, no repeated approval, current subscriptions restored |
| Dead connection | Silent socket, Wi-Fi loss, path callbacks, 429/502, Retry-After | Bounded/coalesced retry, UI remains usable, no mutation replay |
| Auth/trust | 401, 403, pin mismatch, changed origin/redirect | Terminal classification; credentials not leaked; no retry storm |
| Lists | Full-index refresh, partial error, bad host session record, workspace reorder/removal | Cached data retained; connection stays usable; no pagination asserted that the host does not supply |
| Projections | List/control/follow overlap; equal sequence updates for different keys; old value after newer | Per-key ordering; no lost question/title/model state |
| Drafts | Navigation, process relaunch, disk-write error, accepted old revision after new typing | Submitted text clears once; later edits and attachment ownership survive |
| Create | Success, lost response, existing supplied ID, cwd/preset conflict, workspace attach failure | No replacement session ID; no duplicate host session; partial success recoverable |
| Models/modes | Failed provider, normalized model, unsupported effort/image, preset locked, selection/send race | Confirmed selection only; no prompt on unintended model; visible refusal |
| Prompt | Accepted, refused, timeout before/after host admission, inbox evidence, limited history | Persistent request identity; uncertainty preserved; zero automatic duplicate prompts |
| Live text | Baseline during active stream, text/reasoning, duplicate/gapped indices, settlement in either order, abandonment | Exact text once; no stale preview; correct rebaseline |
| Paging | Overlapping page, arriving live events, navigation/reconnect mid-page, empty/last page | Correct fixed cursor; no duplicates; stable scroll; old page ignored |
| Approval | Allow/reject, double tap, remote client wins, cancel races, old generation response | Correct result strings; one local submit; no false execution claim |
| Questions | Multiple questions; repeated IDs in different calls; live/continued; false reply; queued reply; timed claim release | Full batch; correct channel; no resurrected historical form or held background wait |
| Uploads | Unicode filename, binary success/error, 404 fallback, 413/auth failure, cancellation, host restart, navigation | Correct raw/enveloped decoding; session receipt scope; no automatic upload/send replay |
| Commands | Registered vs unknown slash text, policy-forbidden attachments, absent result, durable result echo, timeout | Correct endpoint; valid attachment union; no duplicate transcript/action |
| Secondary views | Missing endpoint, authorization failure, partial inventory, schedule history pagination, partial usage | Unavailable differs from failed; no invented totals or management controls |
| Accessibility | Small/large phone, landscape, keyboard, largest supported Dynamic Type, VoiceOver, Reduce Motion | Readable cards; reachable actions; stable focus/scroll; status announced without spam |

Fixtures must state whether they are synthetic or captured, include host version/protocol, and omit tokens/private content. Add focused regression tests at service/reducer boundaries and a small number of UI smoke tests; do not test every SwiftUI layout constant.

Run `swift test` for kit changes and the app's documented Xcode build for integration changes. A simulator build is not a substitute for these physical-device checks: background for 30 seconds and several minutes; lock while an assistant is streaming; return with a partial draft; change Wi-Fi/cellular with a stable reachable route; lose the route then restore it; relaunch after an uncertain submission. Verify Keychain access in a signed app. Record the tested iOS/device/host/relay versions and whether sends were reconciled correctly.

A feature is complete only when its visible control uses the actual contract, refusal/uncertain states work, relevant tests pass, and the native host round-trip is recorded. Remaining source-only behavior stays explicitly unverified in the release checklist.

## 13. Source map for the next implementer

All installed package paths below are members of `/Applications/DeepSeek Harness.app/Contents/Resources/app.asar`, under `/dsh/node_modules/@deepseek-ai/`. They were read as source data; none of this investigation executed bundled code.

| Package member | Relevant symbols / reason |
| --- | --- |
| `dsh-api-gateway/lib/index.js` | `openRemoteEvents`, `startRemoteEvent`, `receiveRemoteEventResult`, `finishRemoteEvent`, `parseRemoteEventResult`: delivery, replay, outcome and cancellation semantics |
| `dsh-api-session-controller/lib/index.js` | `create`, `createOrAdopt`, `prompt`, `hasPromptRequest`, `selectModel`, `cancel`, `follow`, `page`, `paginate`: transactional and sequence behavior |
| `dsh-api-session-controller/lib/types/assistant-stream.js` | Host compact assistant baseline and revision handling |
| `dsh-api-session-controller/lib/types/client/sessions/assistant-stream.js` | `ClientAssistantStream`: baseline adoption, chunk indexing and settlement |
| `dsh-llm/lib/types/assistant-stream.js` | `expandAssistantStream`: compact text/reasoning/tool-argument records |
| `dsh-agent-preset-registry/lib/index.js` | `select`: first-turn lock and committed preset selection |
| `dsh-client-ui-agent-preset/lib/client.js` | Standard mode label and staged mode selection |
| `dsh-client-ui-approval/lib/client.js` | `approval/request` listener and allowed/rejected values |
| `dsh-user-questions/lib/index.js` | `answer`, `askTimed`, `attachWait`, `TimedQuestionWait`: continued replies and timed claims |
| `dsh-client-ui-user-questions/lib/client.js` | `answerQuestion`, `publishContinuedQuestions`, `PendingQuestion`: correct live/continued routing and question UI lifetime |
| `dsh-client-file-upload/lib/index.js` | `handleFileUploadHttp`, `upload`, `uploadStream`, `commit`, `bindPrompt`, `retire`: raw route and receipt lifetime |

Use the read-only ASAR reader in [Protocol/extract.py](../Protocol/extract.py) to inspect these members. Running its CLI regenerates contract files; it is not a read-only verification command. Recheck the installed version before extending this spec to a different host build.

For exact nested fields, consult [Protocol/schemas](../Protocol/schemas) and the generated argument wrappers rather than expanding JSON from illustrative mockups. Inspect unknown payloads through redacted fixtures and primary host source. Never fill a missing contract with an assumed endpoint or a fabricated success state.

Documentation validation on 2026-10-09: all eight fenced JSON examples parse; six descriptor-backed payloads validate against the repository's JSON Schemas; argument names for 24 referenced endpoints match the extracted descriptor. The two bare event examples were checked against gateway/web-client source, not a live approval exchange. Local document links resolve. These checks validate the specification's examples, not feature implementation or device behavior.
