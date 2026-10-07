# DSH wire contract

Machine-readable wire contract for DeepSeek Harness `0.2.0-rc.2`, extracted from
the descriptor the installed bundle carries. The iOS client's DTOs are meant to
be derived from these files, not from documentation or from method names.

| File | What it is |
|---|---|
| `extract.py` | Re-runnable extractor. Reads the asar, writes the two artefacts below. Standard library only, no network, no evaluation of bundle code. |
| `endpoints.json` | Every endpoint in the descriptor: identity, mode, parameters, result, and the raw DSL expression text behind each schema. |
| `schemas/*.json` | One JSON Schema per named request/result type, translated from the DSL. |
| `README.md` | This file: method, rules, provenance, and what is still unknown. |

Regenerate:

```bash
python3 Protocol/extract.py --verify
```

`--verify` re-reads what was written, checks every schema file parses, and
checks that every endpoint parameter and result resolves to one. Exit code is
`0` when everything resolved, `1` when something did not, `2` when the
descriptor could not be located at all. `--asar PATH` or `DSH_ASAR=PATH`
overrides the input path.

## Source

| | |
|---|---|
| Input | `/Applications/DeepSeek Harness.app/Contents/Resources/app.asar` |
| Size | 121,387,457 bytes |
| SHA-256 | `18d5036bbb58eaff41d351ede99314b8d06505aec06fb2e164c49874ada30f9e` |
| Harness version | `0.2.0-rc.2` (from `/dsh/desktop-runtime.json`) |
| Host protocol version | `4` |

## How the extraction works

The asar is a JSON header plus concatenated member files. `extract.py` parses
the header, walks the member tree, and reads each member by absolute offset.
It then scans only text members under 8 MiB — binaries and the multi-megabyte
client UI bundles are skipped.

**Locating the descriptor.** The descriptor is not one array. It is emitted per
package as `TYPERT_REMOTE = { package, descriptors: [...] }`, and the bundles
that carry the DSL form are:

- `/dsh/node_modules/@deepseek-ai/dsh-api-remotes/lib/client.js` — 25 arrays, 134 endpoints
- `/dsh/node_modules/@deepseek-ai/dsh-experimental-client-ui-voice-input/lib/client.js` — 1 array, 6 endpoints

The script finds every `descriptors` key in readable text, brace-matches its
array with a string-aware matcher, and reads the arrays with a small JavaScript
literal reader. Nothing is evaluated: identifiers and arrow functions are kept
as opaque text, arrays and objects are read as data.

**Resolving `create:`.** Each parameter and result carries a `create` symbol,
for example `_deepseek_ai_dsh_api_session_controller_session_follow_parameter_0$schema`.
The script collects every definition of the form

```js
const <name> = () => <name>$value ??= <expression>;
```

by name across the whole bundle (351 definitions, all of them in those same two
files), then reads the expression with a depth-0 scanner that stops at the
terminating `;` and skips string literals, template literals and comments. The
expression is then parsed by a recursive-descent parser for the harness's own
schema DSL.

**Cross-check.** Every endpoint also exists a second time as a zod mirror in its
package's `lib/typert.remote-client.js` — 28 descriptor-bearing files in total
(2 in the DSL form, 26 as zod mirrors), 26 DSL arrays against 26 zod arrays. The
two sets are identical: 140 endpoints in each, 0 in one dialect only, recorded
as `crossCheck` in `endpoints.json`. The extractor uses the DSL form because
that is the form the brief describes and the form the harness's own client
bundles ship.

## What the descriptor proves, and what it does not

Everything `endpoints.json` records as a field of the descriptor — identity,
`wire` names, `source`, `lookup`, `acceptsUndefined`, `scope`, `cancellation`,
`typeSymbol`, and the raw DSL text — is stated by the bundle verbatim. The JSON
Schema files are a translation, not a statement of their own. So the split is:

**Proven by the descriptor** (verbatim in `endpoints.json`):

- Endpoint identity: `id`, `service`, `namespace`, `method`, and `mode` when
  present (`mode` is only emitted for streams; absent means unary).
- The wire name of every parameter (`wire`), its origin (`source`: `json` or
  `lookup`, plus the `lookup` key), and whether the key may be omitted
  (`acceptsUndefined`).
- Whether a call is cancellable (`cancellation: {parameter: "signal"}`) and
  whether a parameter is projected from the caller's Context (`scope`).
- The `typeSymbol` of every parameter and result, and the exact DSL expression
  text behind it.

**Assumed, not proven:**

- That `namespace/method` is the HTTP path and the WS `endpoint` string. The
  brief and the recorded fixture agree (`POST /api/session/list`,
  `"method": "session/list"`), and the gateway's `remoteRequest` requires
  `endpoint` to split into exactly two non-empty segments
  (`dsh-api-gateway/lib/index.js`), but the descriptor itself names no transport.
- That the JSON Schema translation is faithful. It is checked against two
  recorded captures (`session/list` and `session/follow`, see *Verification
  performed*), not the whole surface.
- That the descriptor is complete for the running app. It is the *declared*
  surface; runtime-loaded plugins and the raw routes below are outside it.
- Anything about payload semantics: ordering, cursors, watermark rules,
  idempotency. Those live in the implementation, not in the types.

## Translation rules

### Rules taken from the brief

| DSL | JSON Schema |
|---|---|
| `object({ "k": T, ... })` | `{"type":"object","properties":{...},"required":[...]}` |
| `union([T, ...])` | `{"anyOf":[...]}` |
| `literal(x)` | `{"const": x}` |
| `string()` / `number()` / `boolean()` | `{"type":"string"}` / `"number"` / `"boolean"` |
| `.optional()` | the property is left out of `required` (everything else is required) |
| `.readonly()` | ignored |
| `intersection(string(), unknown())` | `{"type":"string"}` |
| `array(T)` | `{"type":"array","items":T}` |
| a named schema referenced by another | resolved by name and inlined, or emitted as a local `$ref` |

### Rules I had to derive — every guess, with its evidence

The DSL has more vocabulary than the brief lists. These are the decisions I
made and the evidence behind each. `translationGuesses` in `endpoints.json`
carries the same list.

| Construct | How it is translated | Why, and how risky |
|---|---|---|
| `intersection(T, unknown())`, generalised from `string()` | collapses to `T` | 355 of the 403 `intersection(...)` calls across the 351 definitions are this form, over primitives and over objects. Same mechanism as the `string()` case the brief names. Low risk. |
| `intersection(A, B)` otherwise | `{"allOf":[A, B]}` | The remaining 48: `intersection(object, object)` × 32 (a generated object widened by a second object) and `intersection(object, record)` × 16, e.g. `union([string(), intersection(object({ "en": string() }), record(string(), string()))])` for a localised title. `allOf` is the literal meaning. The generator's internal merge is not observable, so this is shape-preserving rather than byte-exact. Low risk. |
| `record(K, V)` | `{"type":"object","additionalProperties":V}` | 104 uses. `K` is always `string()`; `V` is `string()` or `never()`. Low risk. |
| `never()` | `{"not":{}}` | 8 uses: 6 as `record(string(), never())`, the attributes map of analytics events that carry none; 2 as `"readOnlyReason": never().optional()` inside settings-mutation result variants, where the field cannot be present. Means "no value is valid". Low risk; a client can also read it as an empty object or an absent field. |
| `_void()` | `{"type":"null"}` | 11 results (e.g. `terminal/close`, `credentials/set`). The Host method returns `undefined`, and `encodeRpcResult` (`dsh-api-gateway/lib/index.js`) wraps it as `{ok: true, value: undefined}` with no `encode` on this codec; `JSON.stringify` then drops the key. So the envelope is `{"ok":true}` with **no** `value` field. The `"type":"null"` here describes the type, not the envelope — the client should treat a missing `value` as success. |
| `_undefined()` inside a union | the member is dropped; the enclosing property leaves `required`, and a whole result gets `x-dsh-mayBeAbsent: true` | Never translated to `null`. `union([_undefined(), …])` is the generator's spelling of *absent*. Corroborated by the descriptor: all 8 parameters whose expression is `union([_undefined(), T])` also carry `acceptsUndefined: true`, and the gateway only tolerates a missing key when exactly that flag is set (`assertExactArguments`, `dsh-api-gateway/lib/index.js`). **Strong evidence, but the `null`-vs-absent choice is mine.** |
| `lazy(() => Name())` | inline `Name`, or a `$ref` into `$defs` when resolution is recursive | Used for the shared recursive JSON value type (`JsonValueRemoteCodec$schema…`) and for `JsonValue` parameters. A cycle is broken with a local `$ref`, so recursion terminates. Low risk. |
| `_instanceof(Uint8Array)` | `{"type":"null"}` | 2 occurrences, both the `data` field of a byte-result object (`workspaceFiles/readBytes`, `officeToPdf/render`). The generated `encode()` for those two results replaces `data` with `writeBytes(bytes, path)`; the gateway's `writeBytes` returns `null` and pushes `{path, bytes}` onto a sibling `attachments` array in the envelope (`encodeRpcResult`). So the JSON body really is `null` and the bytes are framed separately. The schema says `null`; `endpoints.json` marks the two results `byteAttachments: true`. The **framing itself is not in the descriptor**. |
| one schema file per `typeSymbol`, though the generator emits one `create:` closure per use site | compile all closures for a type, compare structurally with `$defs` keys normalised, emit the first | 247 type symbols came from 335 referenced `create:` closures (out of 351 definitions in the bundle). 0 types had closures that differ in shape. Recorded per file as `x-dsh-definition.allSymbols` and `.differingSymbols`. |
| object strictness | `additionalProperties` is **not** emitted | The gateway rejects unknown argument keys outright (`assertExactArguments` builds an `extra` set and fails with `gateway/arguments-invalid`). Treat request objects as closed even though the emitted schema does not say so. Documented rather than encoded, because the brief pinned the object rule. |

Two smaller conventions:

- Every schema file carries provenance under `x-dsh-*` keys: the `typeSymbol`,
  the defining symbol and its bundle path, every endpoint and role that uses it,
  the raw DSL text, and `x-dsh-mayBeAbsent` when the value may be absent.
- Schema file names are the `typeSymbol` with the npm scope stripped and
  `#`, `/`, `:` replaced by `.`. A collision (never observed here) would gain a
  numeric suffix.

## Endpoint inventory

140 endpoints, 127 unary and 13 stream, across 30 namespaces and 26 descriptor
arrays (25 packages plus the speech package). 247 schema files.

| Namespace | # | Namespace | # | Namespace | # |
|---|---|---|---|---|---|
| `session` | 19 | `dynamicCordisRunner` | 12 | `pluginManager` | 12 |
| `account` | 11 | `workspace` | 11 | `terminal` | 10 |
| `goals` | 7 | `speech` | 6 | `schedule` | 5 |
| `settings` | 5 | `workspaceFiles` | 5 | `agentPresets` | 3 |
| `credentials` | 3 | `directoryPicker` | 3 | `job` | 3 |
| `llm` | 3 | `messageFeedback` | 3 | `productAnalytics` | 3 |
| `commands` | 2 | `officeToPdf` | 2 | `subagents` | 2 |
| `userQuestions` | 2 | `fileReferences` | 1 | `fileUploads` | 1 |
| `permissionPresets` | 1 | `pluginInventory` | 1 | `pluginRegistryProbe` | 1 |
| `sessionFeedback` | 1 | `sessionReferenceResolver` | 1 | `skills` | 1 |

All 140 use `invocation: {kind: "direct"}`. 31 carry a `scope`, 44 carry
`cancellation`. No endpoint in this version declares an `uplink`, even though
the descriptor type allows one.

## Endpoints the iPhone client needs

`Present` means a descriptor endpoint exists and a schema file was generated for
each parameter and the result. Everything below was checked mechanically
against `endpoints.json`.

### Named in the brief

| Endpoint | Status | Mode | Wire parameters | Result schema |
|---|---|---|---|---|
| `session/list` | present | unary | `_request` | `dsh-api-session-controller.types.SessionListValue.json` |
| `session/follow` | present | stream | `request` | `dsh-api-session-controller.types.SessionFollowFrame.json` |
| `session/page` | present | unary | `request` | `dsh-api-session-controller.types.SessionPage.json` |
| `session/prompt` | present | unary | `request` | `dsh-api-session-controller.types.SessionPromptValue.json` |
| `session/create` | present | unary | `request` | `dsh-api-session-controller.types.SessionCreateValue.json` |
| `commands/list` | present | unary | `agentId` | `dsh-commands.commands.list.result.json` |
| `commands/execute` | present | unary | `agentId`, `line`, `submittedAttachments` | `dsh-commands.commands.execute.result.json` |
| `session/uploadFileBinary` | **absent** | — | — | — |
| `$events/result` | **absent** | — | — | — |

### Absent from the descriptor — go to the bundle source, not to a schema

Neither of the two absent entries is a Typert endpoint. Both are exact routes
registered on the Connection HTTP handler, and neither appears in any
`descriptors` array.

- **`POST /api/session/uploadFileBinary`** — raw-byte route owned by
  `@deepseek-ai/dsh-client-file-upload`. Source:
  `/dsh/node_modules/@deepseek-ai/dsh-client-file-upload/lib/types/protocol.js`
  (`FILE_UPLOAD_PATH`) and the same package's `lib/index.js`
  (`handleFileUploadHttp`). Contract: `Content-Type: application/octet-stream`,
  query `sessionId` (required, non-empty) and `name` (optional). Any other
  method is `405` with `Allow: POST`; a wrong content type is `415`; a missing
  `sessionId` is `400`. Success and failure both return HTTP `200` with a bare
  body — `{"ok":true,"value":…}` or `{"ok":false,"error":{code,message,details}}`
  — **not** an RPC envelope. The staged receipt value is
  `dsh-client-file-upload.types.FileUploadValue.json`, reachable through the
  descriptor as `fileUploads/upload`.
- **`POST /api/$events/result`** — Gateway-internal unary endpoint. Source:
  `/node_modules/@deepseek-ai/dsh-api-gateway/src/stream-protocol.ts`
  (`REMOTE_EVENT_RESULT_ENDPOINT`, `parseRemoteEventResult`) and
  `/dsh/node_modules/@deepseek-ai/dsh-api-gateway/lib/index.js`
  (`dispatchRpc`, `parseRemoteEventResultPayload`). Contract: the RPC `payload`
  must contain exactly one `args` field, and `args` must be exactly
  `{clientId, eventId, outcome}`. `outcome` is `{"kind":"next"}` with no other
  key, or `{"kind":"result"}` with an optional `value`, or
  `{"kind":"rejected","error":…}`. A successful call returns
  `{ok: true, value: undefined}`.

Two more things the client needs that are not descriptor endpoints either:

- **`GET /api/remote.mux`** — the single WebSocket carrying every logical
  stream (`REMOTE_STREAM_MUX_PATH`). Logical streams open with
  `{"type":"open","streamId":…,"endpoint":…,"payload":{"args":{…}}}`, where
  `endpoint` is `"<namespace>/<method>"`. Cancel with
  `{"type":"cancel","streamId":…}`.
- **`$events`** — the reserved Gateway logical endpoint
  (`REMOTE_EVENT_STREAM_ENDPOINT`) that carries forwarded Host events, opened
  with `{"args":{}}`. Its allowlist is not in the descriptor; it is
  `API_REMOTE_FORWARDED_EVENTS` in
  `/dsh/node_modules/@deepseek-ai/dsh-api-remotes/lib/index.js`, 27 events:
  `agent-preset/selected`, `approval/request`, `api-session/activity`,
  `api-session/added`, `api-session/error`, `api-session/removed`,
  `api-session/status`, `commands/change`, `deepseek-account/session-expired`,
  `deepseek-account/model-sign-in-required`, `credentials/record-updated`,
  `credentials/reference-updated`, `goal/activation-changed`,
  `cordis/request-run`, `cordis/request-run-resolved`, `cordis/dynamic-package`,
  `cordis/dynamic-retract`, `cordis/inspect-query`,
  `cordis/inspect-query-resolved`, `llm/adapters-updated`,
  `permission-presets/catalog-changed`, `plugin-manager/changed`,
  `plugin-manager/install-log`, `plugin-manager/install-state`,
  `settings/document-updated`, `schedule/changed`, `user-questions/request`.
  `approval/request` and `user-questions/request` are the two waterfalls — the
  ones that expect an answer through `$events/result`. The others are one-way.

### Everything else the client asked about

All present, with the module-shaped request objects the descriptor names:

| Concern | Endpoints |
|---|---|
| Conversation and control | `session/control` (stream), `session/cancel`, `session/projections`, `session/rename`, `session/search`, `session/fork`, `session/attachment`, `session/updateQueue` |
| Models | `session/modelCatalog`, `session/selectModel`, `session/initializeDefaultModel`, `llm/listProviders`, `llm/listConfigurableProviders`, `llm/discoverModels`, `agentPresets/list`, `agentPresets/read`, `agentPresets/select`, `permissionPresets/catalog` |
| Settings | `settings/describe`, `settings/update`, `settings/mutate`, `settings/replace`, `settings/openSettingsDocument`, `credentials/describe`, `credentials/set`, `credentials/unset` |
| Workspaces | `workspace/follow` (stream), `workspace/create`, `workspace/rename`, `workspace/delete`, `workspace/archiveSession`, `workspace/unarchiveSession`, `workspace/pinSession`, `workspace/unpinSession`, `workspace/insertBefore`, `workspace/insertSessionBefore`, `workspace/initializeDefault`, `directoryPicker/list`, `directoryPicker/pick`, `directoryPicker/createDirectory` |
| Files | `workspaceFiles/list`, `workspaceFiles/read`, `workspaceFiles/readBytes`, `workspaceFiles/stat`, `workspaceFiles/changes` (stream), `fileUploads/upload`, `fileReferences/list` |
| Goal | `goals/get`, `goals/create`, `goals/edit`, `goals/pause`, `goals/resume`, `goals/complete`, `goals/clear` |
| Questions and approvals | `userQuestions/answer`, `userQuestions/attachWait` (stream), plus `$events` / `$events/result` above |
| Feedback | `messageFeedback/list`, `messageFeedback/put`, `messageFeedback/delete`, `sessionFeedback/record` |
| Commands and skills | `commands/list`, `commands/execute`, `skills/list` |
| Jobs and subagents | `job/list` (stream), `job/follow` (stream), `job/kill`, `subagents/prompt`, `subagents/interruptByParent` |

### Plan and todos are not endpoints

Neither has a `plan/*` or `todos/*` endpoint. Both ride in the session
projections, which is where the read-only summaries in `SPEC.md` §1 come from.

- **todos** — a named, optional key of the `values` object in
  `session/projections`, `SessionFollowFrame` and `SessionPage`.
- **The projection registry is open.** The descriptor writes `values` as
  `intersection(object({…}), record(string(), JsonValue))`: 13 keys are *named*
  (`inbox`, `agentPreset`, `title`, `todos`, `sessionListMetadata`,
  `imageLimits`, `modelSelection`, `permissions`, `subagentCatalog`,
  `subagentTiming`, `subagent`, `goal`, `userQuestions`), every one of them
  optional, behind an open `record` for anything else the Host registers. So
  the presence of a key is a Host fact, not a contract fact. `plan` is one of
  the unnamed ones — the live capture in `Fixtures/mux-stream-frames.json`
  carries `values.plan = {active, pending}` even though the descriptor's static
  object never mentions it.
- **plan** — no `plan/*` endpoint. Plan mode appears as a value
  (`user-questions` intent `{"kind":"plan-review"}`; `plan` in projections).
  The submitted plan itself is read from session history:
  `@deepseek-ai/dsh-client-ui-plan`'s client bundle recovers it from a
  `tool/call` event whose `data.name` is `exit_plan_mode` and whose arguments
  carry `plan` as Markdown. So plan content comes through `session/follow` /
  `session/page`, not through its own call.

## Verification performed

- **Determinism.** Two consecutive runs produce byte-identical `endpoints.json`
  and all 247 schema files (`diff -r` over a copy of the previous run).
- **Self-check.** `--verify` confirms every schema file parses and every
  parameter and result in `endpoints.json` resolves to one. 0 unresolved.
- **Cross-dialect.** 140 endpoints in the DSL form and 140 in the zod mirror,
  identical sets (`crossCheck` in `endpoints.json`).
- **Against live captures.** Two fixtures recorded from the running relay were
  validated against the generated schemas with an ad-hoc validator covering the
  emitted keywords (`type`, `const`, `anyOf`, `allOf`, `properties`, `required`,
  `items`, `additionalProperties`, `not`, `$ref`):
  - `Fixtures/rpc-response-session-list.json` — `result.value` validates against
    `schemas/dsh-api-session-controller.types.SessionListValue.json`.
  - `Fixtures/mux-stream-frames.json` — all 12 captured `session/follow` frames
    (snapshot, assistant-stream start/chunk/end, and 8 event frames) validate
    against `schemas/dsh-api-session-controller.types.SessionFollowFrame.json`.
    That run relaxed 38 `const` comparisons, every one of them a place where the
    capture had replaced a literal string with `"redacted"`; the relaxation is
    counted and printed rather than applied silently.

  This is two endpoints, not 140. It shows the translation is not
  systematically wrong; it does not certify all 247 files.
- **Shape agreement.** No `typeSymbol` compiled from more than one `create:`
  closure produced a differing shape.

## What remains unknown

- The exact framing of the two `_instanceof(Uint8Array)` byte results. The
  generated `encode()` and the gateway's `writeBytes` establish that the JSON
  field is `null` and the bytes ride in an envelope-level `attachments` array
  with a `path`, but the descriptor does not describe that array's encoding
  (base64 or otherwise), and this contract does not either. Confirm against a
  live capture before writing that DTO.
- Whether `null` is accepted where the DSL says `_undefined()`. The gateway only
  speaks about missing keys, so this contract says "may be absent" and
  deliberately does not admit `null`.
- Whether every endpoint mounted in Patrick's running profile is in this
  descriptor. Plugins are loadable at runtime; the descriptor is what the
  installed bundle declares. `pluginManager/*`, `dynamicCordisRunner/*` and
  `speech/*` in particular exist for the desktop client and are unlikely to be
  part of the iOS client's surface.
- The reference documents' account of streams and timeouts. `SPEC.md` §6.1
  already flags that the relay's client-integration contract predates `0.2.0`
  and describes two concurrent upgrades where this version composes one
  `remote.mux` socket. The descriptor settles method and schema questions only;
  timing and upgrade behaviour are not in it.
