# DSH Remote for iPhone — Build Specification

Status: proposed implementation contract; no application code exists yet.
Date: 2026-10-07
Working product name: DSH Remote
Target: a personal-use native iPhone companion for DeepSeek Harness.
Baseline: harness `0.2.0-rc.2` (installed). Relay: `dsh-relay` v0.2.1 does not work with this harness generation and the fixes are unmerged upstream — see §12 — so the relay prerequisite is blocked.

## 1. Outcome and scope

Patrick can leave an agent working on his computer, open his iPhone, read its progress, send instructions, answer questions, and approve or reject a pending action. The harness continues executing when the phone disconnects or the app closes.

The first release is a useful personal app, not full Android feature parity. It connects to the existing harness and uses the models, Gaia roles, commands, and skills configured on that host. It does not run models or agent tools on the phone.

### V1 — required

- Pair with a `dsh-relay` using its QR code or pasted pairing JSON.
- Remember multiple paired hosts and manually select the active host.
- Browse sessions grouped by workspace.
- Open an existing session and page through its conversation.
- Send prompts and render streamed assistant responses.
- Show reasoning in collapsed disclosures when the host provides it.
- Show tool calls and results in expandable cards.
- Answer permission requests and structured user questions.
- Attach photos and files to prompts.
- List and execute host-advertised slash commands.
- Allow unrecognized slash input to reach the host as ordinary prompt text, enabling skills.
- Show the session's selected model and support model selection from its host catalog.
- Retain drafts per host/session and restore conversation state after suspension or network loss.
- Show read-only goal, plan, and todo summaries when available.
- Support system light/dark appearance, Dynamic Type, and VoiceOver for primary flows.

### Deferred

- Creating workspaces or sessions: v1 operates on sessions created on the computer.
- Push notifications while the app is suspended or terminated.
- Dedicated goal editing, plan-review workflows, and subagent controls beyond commands and question/approval cards.
- Terminal, file browser/previews, trajectory ledger, session export, feedback, archive/restore, and pin management.
- LAN subnet scanning, direct launch-token authentication, and automatic host switching.
- Offline prompt submission or approval queues.
- Localization beyond English, iPad-specific layouts, Apple Watch, widgets, and public App Store release.

## 2. Platform and technical decisions

| Area | Decision |
|---|---|
| UI | Native SwiftUI |
| Minimum OS | iOS 18.0 |
| Device | iPhone; portrait and landscape |
| Language | Swift 6 with strict concurrency |
| Network | URLSession HTTP and URLSessionWebSocketTask |
| State | Observable UI stores isolated to MainActor; networking and folding isolated from UI |
| Credentials | Keychain, device-only accessibility after first unlock |
| Local metadata | Codable files in Application Support, atomically replaced |
| Transcript cache | Memory only in v1; refreshed from host on reconnect |
| Photo/file staging | Protected temporary app files; cleaned after settlement or explicit removal |
| Markdown | SwiftUI-compatible renderer chosen at implementation, pinned version and license recorded |
| Testing | XCTest or Swift Testing for protocol/state tests; XCUITest for critical flows |
| Distribution | Signed development builds initially; TestFlight for sustained use |

No third-party analytics. No model-provider credentials are stored on the phone. Normal logs omit tokens, pairing codes, prompts, attachment contents, and tool arguments/results.

The iOS app is a new Swift implementation. The Android app's MIT-licensed code, fixtures, and documented behavior are references. Preserve required license notices for any copied material.

## 3. User experience

### 3.1 Navigation

Root navigation: Hosts → Sessions → Chat. Session details opens as a sheet from Chat. Settings is reachable from Hosts and Sessions. Returning from Chat preserves the session list's position.

Connection status remains visible on Sessions and Chat: Connecting, Connected, Reconnecting, Offline, Pairing required, or Host unavailable. Status uses text as well as color.

### 3.2 Hosts and pairing

The first launch presents “Pair a harness” with Scan QR and Paste pairing data actions. The camera is requested only when scanning. Denying camera access leaves paste available.

Pairing flow:

1. Decode the QR/pasted JSON and require `kind = dsh-relay-pair`, supported `v = 1`, a valid HTTPS URL, an unexpired timestamp (epoch milliseconds), and a nonempty code. Ignore `plainUrl`; v1 requires the TLS origin.
2. Display the destination hostname and optional local display name before claiming the pairing.
3. If the payload supplies an SPKI fingerprint, use it as the trust anchor for the pairing connection and subsequent requests. Never learn a pin from an unverified network response.
4. POST the claim to the payload URL's `/relay/pair`, without following redirects. The code is single-use and expires after five minutes by default. A refusal is HTTP 403 carrying `{ "error": ..., "message": ... }`; show the message and offer a fresh code. Repeated failures lock the source address out, which is a rate limit rather than a wrong code, so do not present a lockout as a bad code.
5. On success, store the credential in Keychain and nonsensitive host metadata locally. Do not persist the pairing code.
6. Connect to the harness through the relay. Only mark the host connected after the stream readiness handshake completes.

For v1, reject plain HTTP pairing with an actionable HTTPS-required message. A payload without a fingerprint must pass normal platform TLS and hostname validation. A supplied pin mismatch is a hard error with an explicit re-pair action; it never silently falls back to normal CA validation. When both payload and response contain pins, require agreement.

Saved hosts show display name, endpoint, and last successful connection. Selecting a host disconnects the previous host, clears its pending request cards, and loads the selected host's state. Do not probe all saved hosts continuously.

“Forget host” requires confirmation and removes that host's credential, metadata, drafts, and staged files. It does not revoke the device at the relay; explain that distinction in the confirmation.

### 3.3 Session list

- Group sessions by the host's workspace registry.
- Show title, running/waiting status when known, and last activity when supplied.
- Local search filters loaded titles and workspace names.
- Initial landing is the last opened session for this host, if it still exists; otherwise show the list.
- Deleted or inaccessible sessions produce an empty-state explanation with Back to sessions.
- Host-side changes update the list while connected.

### 3.4 Chat

- Display human and assistant messages chronologically.
- Render Markdown, selectable text, copyable code blocks, and accessible links.
- Open external links only after an explicit tap; do not fetch remote Markdown images automatically.
- Reasoning is collapsed by default.
- Tool cards show tool name, state, and a short summary; expansion exposes readable arguments/results. Unknown tool types use a generic card.
- Bound initial rendering of very large tool output and provide explicit expansion; never truncate the underlying event used by the state reducer.
- Follow the live tail only when the user is already at the bottom. Otherwise show “New activity” to return to it.
- Load older history when the user requests it, preserving scroll position.
- Render one provisional assistant response during streaming and replace it with the durable settlement without duplication.

The composer has multiline text, attachments, command suggestions, and Send. Disable Send while disconnected, while any attachment is staging, or while a send is awaiting acknowledgement. Empty text is valid only when at least one admitted attachment exists.

A network failure after submission can leave acceptance unknown. Show “Delivery unconfirmed” and reconcile against the host's durable request ID before offering a retry. Never automatically resend an uncertain prompt.

While a session is busy, v1 follows the verified host prompt behavior. If accepted as queued, show that state; if rejected as busy, preserve the draft and explain the refusal. Do not pretend the message interrupted or steered a turn. Dedicated queue editing and steering controls are deferred.

### 3.5 Approvals and questions

Pending requests appear above the composer for the selected session and as a badge on the matching session row when the host supplies a session ID. A request without a resolvable session is shown in a host-level attention sheet.

An approval displays the supplied reason and action details, with Allow once and Reject. Never introduce “always allow” unless a later scope explicitly adds supported persistent permissions.

A question renders all items in host order, with single-select/multiple-select behavior and custom input as allowed by the request. Every item must contribute one response, even when skipped.

- Submit only while connected to the generation that delivered the request.
- Disable duplicate submission while awaiting the response.
- Remove the card after a successful own acknowledgement.
- Remove it when a cancellation arrives because another client answered or the host withdrew it.
- On reconnect, discard old IDs and wait for host replay. Do not retry old answers.
- Dismissal is a separate explicit action; it is not equivalent to empty answers.

### 3.6 Attachments

Use PhotosPicker for images and the system file importer for other files. Copy selected files into protected app staging storage; release security-scoped access promptly.

Each chip shows name, size, staging progress, ready/error status, and Remove. Selection and asynchronous work belong to the host/session draft that initiated them, even if navigation changes.

- Enforce host-provided image count, byte, pixel, and dimension limits before submission.
- Convert formats the host cannot admit, such as HEIC if unsupported, into an admitted format and validate the converted output.
- Stage files through the host binary upload route and send receipt references with the prompt.
- Keep the draft and attachments on a refusal.
- Clear them only after acceptance is confirmed.
- Treat receipts as session-scoped and single-use; re-stage when a receipt is rejected or no longer valid.
- After process restart, restore staged local selections but revalidate/re-stage before enabling Send; never assume a persisted receipt remains usable.

V1 imposes a 20 MiB per-file local upload cap, clearly labeled as an app limit rather than a harness limit. Image admission uses host limits plus a 20 MiB per-image app cap. Stream file bytes from disk rather than assembling a second full copy in memory.

### 3.7 Session details and settings

Details shows available model selection, context usage, goal summary, plan summary, and todos. Missing host capabilities are omitted rather than shown as broken controls. Numeric usage appears only when its units and shape are verified.

Settings includes appearance (system/light/dark), saved host management, application version, supported/tested harness versions, and a redacted diagnostics export. Diagnostics contain app/OS versions, endpoint hostname, connection transitions, and error codes; no credential-bearing URLs or content.

## 4. Architecture

```text
SwiftUI views
    ↓ user actions                ↑ observable state
HostStore / SessionStore / DraftStore
    ↓                            ↑ snapshots and domain events
DshAPIClient + ConnectionCoordinator
    ↓                            ↑ logical stream items
RPCTransport + StreamMultiplexer
    ↓                            ↑
URLSession HTTPS + WebSocket → dsh-relay → DeepSeek Harness
```

Suggested source layout:

```text
DSHRemote/
  App/                 app entry, navigation, dependency wiring
  Models/              wire DTOs and domain state
  Network/             HTTP, TLS policy, pairing, mux, reconnect
  State/               session reducer, live assistant reducer, stores
  Persistence/         Keychain, saved hosts, drafts, staging files
  Features/
    Hosts/
    Sessions/
    Chat/
    Attention/
    SessionDetails/
    Settings/
  UI/                  shared Markdown, tool cards, status components
DSHRemoteTests/
  Fixtures/
DSHRemoteUITests/
```

Use one active host connection, one `$events` stream, one workspace stream, and one session-control stream. Open a `session/follow` stream only for the selected conversation. Changing conversations cancels the old follow stream and prevents late frames from mutating the new conversation.

Network and reducer work must not block the main actor. Batch high-frequency text updates for UI rendering without discarding protocol frames. All stream tasks have explicit ownership and cancellation.

## 5. Local data model

| Entity | Fields and constraints |
|---|---|
| SavedHost | Local UUID, display name, relay origin, optional SPKI pin, Keychain credential reference, relay device ID, optional credential expiry, last connected time, last session ID |
| DraftKey | Host UUID + session ID |
| Draft | Text, local staged attachment descriptors, updated time; persisted with file protection |
| ConnectionGeneration | Fresh local generation ID, host UUID, server clientId after ready, connection phase |
| SessionSummary | Host session ID, workspace association, title, available activity metadata |
| ConversationState | Follow generation, opening cursor, durable records, hasMore, provisional assistant state |
| PendingRequest | Connection generation, eventId, optional agentId, event type, typed request body, submission state |
| OutgoingSubmission | Request ID, draft snapshot, status: submitting/accepted/unconfirmed/refused |

Treat all host IDs as opaque strings. Decode unknown keys tolerantly. Preserve unknown event types for a readable fallback instead of crashing. Do not let an unknown shape trigger a guessed write request.

## 6. API and protocol contract

### 6.1 Authority and compatibility

Initial target: harness `0.2.0-rc.2`, the version installed on Patrick's computer and the current npm `latest`. The Android project's documented baseline, `0.2.0-rc.1`, is one release candidate behind it and is not the target. Do not upgrade the host as part of app development without explicit approval.

Schema authority, in order:

1. The installed harness's own source at `0.2.0-rc.2`. The checkout at `~/repo/deepseek-harness` is `0.1.0-rc.5` (2026-08-13) and predates the remote protocol: it contains `events.mux` and `events.host` and no `remote.mux`, so it cannot serve as the authority.
2. Recorded fixture captures from that harness through the relay.
3. The relay's documents and the Android project's documents, both secondary.

The relay's [client integration contract](https://github.com/sorsama/deepseek-harness-relay/blob/v0.2.1/docs/CLIENT_INTEGRATION.md) is the closest authority for pairing, pinning, and authentication, and it confirms the payload, claim request, response fields, SPKI encoding, and 403-never-401 rule in §6.3. It is written against a pre-0.2 harness, so its stream and timeout sections are historical: it describes two concurrent upgrades on a shared 3000 ms budget where `0.2.0-rc.2` composes one `remote.mux` socket with logical streams. Verify both against the installed harness.

Validate `remote.mux` open arguments, `session/prompt`, model selection, image submission, paging, and question schemas against the installed source rather than inferring them from method names.

Implement one verified target version first. Hide optional features when capabilities are absent; do not promise compatibility with older harness versions until tested.

### 6.2 HTTP RPC

Unary requests are POST `/api/<namespace>/<method>`:

```json
{
  "type": "client-request",
  "rpcId": "<new UUID>",
  "method": "commands/list",
  "payload": {"args": {"agentId": "<session ID>"}}
}
```

`method` must match the path. Wire argument names are exact, including the distinction between `agentId`, `sessionId`, and named `request` objects. An HTTP 200 does not establish business success: decode `result.ok` and its typed error.

Every relay request, including WebSocket upgrade and binary upload, carries `Authorization: Bearer <device token>`. Do not forward credentials to redirects or another origin. Do not follow API redirects in v1.

### 6.3 Pairing

Pairing payload:

```json
{
  "v": 1,
  "kind": "dsh-relay-pair",
  "url": "https://host:3443",
  "fingerprint": "<optional base64 SHA-256 SPKI>",
  "code": "<one-time code>",
  "expiresAt": 1755500000000
}
```

POST `/relay/pair` with `Content-Type: application/json` and `{ "code": "...", "name": "<device display name>" }`. The result supplies `deviceId`, `token`, `expiresAt`, and optional fingerprint; both timestamps are epoch milliseconds. Failure is HTTP 403 with `{ "error": "...", "message": "..." }`. The token does not expire on use and is the whole credential.

The pin is SHA-256 over DER SubjectPublicKeyInfo, not a hash of the whole certificate or a platform-specific raw public key representation. Include known-vector tests and a real self-signed relay test on iPhone.

### 6.4 Multiplexed streams

Connect to `/api/remote.mux`. Open logical streams by sending:

```json
{"type":"open","streamId":"1","endpoint":"$events","payload":{"args":{}}}
```

Cancel with `{ "type": "cancel", "streamId": "1" }`. Server frames are `item`, `error`, or `end`, scoped by stream ID. Confirm each stream's open argument schema against the harness.

The `$events` ready frame supplies the server `clientId`. The socket opening alone is not readiness. After ready, establish workspace/control baselines and follow the selected session.

Connection time budgets: 10 seconds for initial socket establishment, then 10 seconds for ready. The relay's contract describes a 3000 ms budget for two concurrent upgrades against a pre-0.2 harness; record the installed harness's actual budget in Stage 0 and correct this line to match observed behaviour. Reconnect with jittered exponential backoff starting at 0.5 seconds and capped at 10 seconds while foregrounded. Honor relay rate limiting. Stop retries for credential or pin failures and offer the relevant user action.

The host heartbeat is protocol-level WebSocket ping/pong. Verify URLSession responds correctly against the target host; do not invent an application heartbeat to mask failure.

### 6.5 Conversation state and recovery

- `session/follow` establishes a complete snapshot and optional live assistant baseline.
- Store its opening cursor for paging. `session/page` must use that generation's `throughSeq`; never combine a page from an old generation with a new baseline.
- Maintain durable history separately from transient assistant chunks.
- Use attempt identity, revision, and chunk index to detect stale, duplicate, or gapped live frames.
- On settlement, retire the matching provisional response and show the durable result exactly once.
- On a gap, drop the invalid preview and recover from a fresh follow snapshot or valid durable settlement.
- Reconnect creates a new generation and replaces baselines; there is no assumed `afterSeq` continuation.
- Merge overlapping projection snapshots using their verified watermark ordering, not arrival time alone.

### 6.6 Sending prompts and commands

Generate a new persistent request ID for each human submission. Preserve that ID while reconciling an uncertain result. A deliberate new message receives a new ID. Never equate an RPC ID with the human submission request ID.

Fetch `commands/list` for the selected session. If the leading slash input matches a registered command, use `commands/execute` with `agentId`, `line`, and `submittedAttachments` (including an empty array). Otherwise use `session/prompt` with the verified request DTO.

Enforce each command's advertised attachment policy before calling it. Preserve input on command refusal. A successful `session/prompt` means accepted, not completed.

### 6.7 Answering host requests

POST `/api/$events/result` using the normal envelope and args:

```json
{
  "clientId": "<current ready frame clientId>",
  "eventId": "<current waterfall eventId>",
  "outcome": {"kind":"result", "value":"allowed-once"}
}
```

Approval rejection uses result value `rejected`. Question results use `{ "answers": [...] }` as the value.

Question constraints:

- Exactly one answer per question, in request order, with matching IDs.
- Selected labels must come from that question's choices, without duplicates.
- Single-select questions allow at most one selected label.
- For single-select, nonempty custom input and a selected option are mutually exclusive.
- Omit blank custom input; an intentionally skipped question has `selected: []`.
- Dismissing the entire question uses a rejected outcome with the host-compatible cancellation error, not `kind: next`.

Retire a successful own submission from the UI immediately on acknowledgement. A host cancellation may only reach the other clients. Failure ends or invalidates the affected generation as required by the host; wait for replay rather than retrying old event IDs.

### 6.8 Files and images

Binary file staging uses POST `/api/session/uploadFileBinary?sessionId=...&name=...` with `application/octet-stream`. Encode query values correctly. Decode its bare `{ok,value/error}` response rather than expecting the RPC envelope.

Only a 404 may trigger the documented base64 `fileUploads/upload` fallback, and only within the 20 MiB app cap. Do not use fallback to bypass an authentication or admission failure.

Prompts cite file receipt IDs. Images follow the target harness's verified image submission contract and limits; stored attachment metadata may differ after host normalization. Treat stored attachment IDs as opaque.

### 6.9 Error presentation

| Condition | Required behavior |
|---|---|
| Offline/transport interruption | Preserve draft; reconnect in foreground |
| Relay 403 | Explain credential rejection; offer re-pair; no endless retry |
| Relayed 401 | Explain relay-to-harness authentication failure; phone re-pair is not presented as the fix |
| TLS pin mismatch | Stop; show certificate changed and explicit re-pair action |
| 404 optional capability | Hide/disable that feature with explanation where relevant |
| 429 | Honor Retry-After; use 60 seconds if missing |
| 502 | Show harness unavailable behind relay; bounded retry |
| Business refusal | Show supplied readable reason and retain user input |
| Malformed response | Show protocol incompatibility; retain state/draft; log redacted diagnostics |

## 7. iOS lifecycle and networking

When the app becomes inactive/backgrounded, persist drafts and release foreground stream work when background execution ends. Do not use audio, location, VoIP, or background modes to keep a generic socket alive.

On foreground return, reconnect and obtain fresh baselines before enabling actions. Existing host execution continues independently of the phone. Do not imply the harness stopped merely because the phone is offline.

Request Local Network permission when connecting to LAN destinations, with a purpose string explaining harness access. V1 does not require Bonjour discovery or subnet scanning. Pairing and TLS must be verified on a physical device; the simulator is insufficient for final validation.

Off-LAN access requires a reachable relay through an existing network path such as the user's VPN. Installing or changing VPNs, DNS, reverse proxies, relay configuration, or host services is outside app implementation and requires explicit approval.

## 8. Acceptance contract

V1 is complete only when all required cases below pass against the recorded target harness/relay versions.

| ID | Observable acceptance criterion | Verification |
|---|---|---|
| A01 | Fresh install pairs using QR or pasted JSON and reaches the session list | Device smoke + pairing integration test |
| A02 | Invalid kind/version, expired code, HTTP URL, and mismatched pin are rejected without storing credentials | Unit/integration tests |
| A03 | Reopening restores saved host and draft; credentials are absent from metadata files and logs | Persistence test + inspection |
| A04 | Sessions appear under correct workspaces and host-side updates become visible | Fixture test + live smoke |
| A05 | A prompt appears once, streams a reply, and settles without duplicate assistant text | Reducer tests + live smoke |
| A06 | Disconnect during streaming then reconnect yields the correct transcript without gaps or duplication | Scripted transport test + device test |
| A07 | Older history joins the live cut without gaps; stale pages cannot affect a new generation | Reducer/paging tests |
| A08 | Tool calls/results and unknown event types render without crashing | Fixture rendering tests |
| A09 | Allow once and Reject settle the correct host request; answering on desktop removes the phone card | Integration tests + two-client smoke |
| A10 | Questions support single/multiple/custom/skipped answers; dismiss is distinct | DTO tests + UI/integration test |
| A11 | Reconnect invalidates old approval/question IDs; no old answer is automatically resent | Generation race test |
| A12 | Photos and files reach the selected session; limits are enforced; refusal preserves draft | Upload tests + device smoke |
| A13 | Switching sessions during upload cannot attach the result to another draft | Race test |
| A14 | Registered commands use command execution; unregistered slash input uses prompt submission | Routing tests |
| A15 | Model selection uses the host catalog and reflects confirmed host state | Integration test |
| A16 | Backgrounding for five minutes and reopening restores live state without pretending to have received background events | Device lifecycle test |
| A17 | Ambiguous send failure cannot silently duplicate a user message | Lost-ack fixture/integration test |
| A18 | Large transcript remains scrollable and typing remains responsive during streaming | Physical-device profiling with ≥1,000 messages and long tool output |
| A19 | Primary flows work with VoiceOver and largest accessibility text sizes without inaccessible controls | Manual accessibility pass |
| A20 | Forget host removes local credentials, drafts, and staging data after confirmation | Persistence test |

Additional protocol tests: RPC business errors carried by HTTP 200; Unicode split across chunks; settlement arriving around stream end in either order; abandoned attempts; late frames after cancellation; authentication on WebSocket upgrade; SPKI known vectors; receipt reuse refusal; rate-limit backoff; cancelled request while submission is in flight.

Use small sanitized fixtures derived from the upstream mock/capture tooling or the target host. Do not commit private transcripts, pairing payloads, cookies, or credentials.

## 9. Build sequence and estimates

Estimates are cumulative elapsed working time for one experienced developer using AI assistance. They assume access to the working harness and to a physical iPhone with signing credentials; Stage 0 stands up the relay. They exclude waiting for account setup and external review.

| Stage | Deliverable | Estimate from start |
|---|---|---|
| 0 | Stand up the relay; record the harness, relay, and device baseline; resolve schemas and pinning against the installed harness; capture sanitized fixtures; create the signed app shell | 2–3 days |
| 1 | Pair, list sessions, open one conversation, send and stream a basic prompt | 2–4 days |
| 2 | Approvals/questions, reconnect recovery, command routing, draft persistence, model picker | 5–8 days |
| 3 | Photos/files, read-only details, accessibility pass, physical-device acceptance checks | 1–2 weeks, with 3 weeks reserved if protocol/lifecycle issues emerge |
| 4 | Push notification bridge, broader controls, polished TestFlight beta | 4–6 weeks |
| 5 | Broad Android parity including terminal/previews and richer session management | 6–10+ weeks |

Stage 0 status, 2026-10-07: the harness baseline is recorded. The relay is not: `dsh-relay` v0.2.1 was installed into the `desktop` profile, refused to boot there, and was rolled back. Its client bundle requires a settings service that harness `0.1.7-rc.2` and later no longer provide, and the published build is stale as well; both fixes exist as unmerged pull requests upstream (§12). Everything behind the relay — pairing, pinning, proxied streams, approvals — is therefore blocked. Application scaffolding can proceed against fixtures; nothing live can.

### Ordered implementation tasks

1. Confirm the harness baseline: record the installed version and verify `remote.mux`, `session/follow`, and `uploadFileBinary` in the source for that version. The checkout at `~/repo/deepseek-harness` is superseded and cannot serve this. Deliverable: a written baseline naming the version and the source path inspected.
2. Stand up the relay in the `web` profile. It is a harness plugin, not a separate service, and a second listener rather than a relocation: the harness keeps its loopback bind and the relay fronts it on 3443. Two constraints learned the hard way: a git-hosted plugin's `prepare` build is refused until pnpm's exact spec is listed under `allowBuilds` in that profile's `pnpm-workspace.yaml`, and a bundle whose client half cannot activate leaves the profile's UI unable to boot, so trial it in `web` and never in the desktop profile. The current release does not support the pinned harness at all — see §12. Deliverable: a relay listening on 3443, a password set, one paired device, and the harness still on loopback.
3. Verify Xcode, signing, and physical-device access.
4. Resolve the exact wire schemas against the installed harness, reconcile the connection budget, and commit sanitized fixtures.
5. Create the SwiftUI project, core models, Keychain wrapper, and draft persistence.
6. Implement relay pairing and TLS validation; prove a self-signed pinned relay works on-device.
7. Implement RPC envelopes, typed errors, multiplexed streams, and connection generation ownership.
8. Build Hosts and Sessions screens with live baseline recovery.
9. Implement durable history folding, paging, assistant streaming, and Chat rendering.
10. Add prompt submission and uncertain-delivery reconciliation.
11. Add approvals and questions, including two-client and reconnect races.
12. Add command catalog routing and model selection.
13. Add protected attachment staging, upload progress, limits, and session ownership.
14. Add read-only session details and redacted diagnostics.
15. Complete lifecycle, accessibility, and performance verification on the physical iPhone.
16. Record supported versions, known limitations, and signing/install instructions; produce a signed build.

Each stage ends with a working app. Add focused tests around protocol/state boundaries and meaningful user behavior, not tests that mirror view implementation details.

## 10. Phase 2: background notifications

This is a separate server-and-client milestone, not a v1 checkbox.

Required architecture:

```text
Harness events → persistent host observer → APNs provider → iPhone notification
                                                        ↓ tap
                                                app reconnects to relay
```

The existing relay documentation does not establish APNs support. Budget a small host-side notification component or relay extension, and inspect host event semantics before deciding which.

Requirements:

- Explicit notification opt-in and device registration bound to an authenticated relay device.
- APNs credentials remain server-side; the phone holds only its device token.
- Notify on completion, blocked goal, permission request, or question.
- Observer maintains the streams needed to detect events while no phone is connected.
- Dedupe notifications by stable event identity and device.
- Default lock-screen payload contains generic status, not prompt/tool content.
- Deep links identify host and session; opening always refreshes the live state.
- Do not offer approval actions directly from stale notification payloads.
- Remove registrations on revocation and handle APNs token changes.
- Verify physical-device delivery while locked and after ordinary termination; APNs delivery remains best-effort.

Infrastructure deployment requires separate approval. TestFlight/APNs use requires appropriate Apple Developer enrollment and entitlements.

## 11. Risks and release gates

| Risk | Mitigation / release gate |
|---|---|
| Host API moves between release candidates | Pin initial target, verify schemas, retain fixtures, record tested versions |
| iOS suspension loses socket state | Treat foreground return as a fresh generation and baseline recovery |
| Self-signed TLS implementation differs from Android | Known-vector SPKI tests plus real-device pairing before building the rest |
| Duplicate sends after lost acknowledgement | Persist request ID, reconcile, never blind-retry |
| Pending requests answered from multiple clients | Current generation IDs, own-ack retirement, cancellation handling |
| Long transcripts and output overload the UI | Lazy rendering, bounded initial output, UI batching, device profiling |
| Reference docs contain historical or conflicting details | Target source and captured wire behavior are authoritative |

Before calling the app usable, Patrick must be able to start work on the computer, leave the phone locked for five minutes, reopen the app, see the correct current conversation, answer a real pending request, and send a follow-up successfully.

## 12. References and evidence

Inspected on 2026-10-07 on Patrick's computer:

- Installed harness `0.2.0-rc.2`, also npm `latest`. Its bundle contains `remote.mux`, `session/follow`, `uploadFileBinary`, `waterfall`, and `throughSeq`.
- Local checkout `~/repo/deepseek-harness` at `0.1.0-rc.5` (2026-08-13): contains `events.mux` and `events.host`, no `remote.mux`. Superseded as an authority.
- Relay v0.2.1 does not run on this harness generation, and both faults are upstream and unmerged. The desktop app refused to boot with `dsh-relay: pending (waiting for service: settingsScope)`: the relay's client bundle injects `settingsScope` and registers into the slot `settings.plugin.item`, and neither exists at `0.1.7-rc.2` or later — `0.2.0-rc.2` has zero occurrences of both, and the replacement surface is `configForms` with the slot `plugins.item`. Independently reported, with the same version table and the same fix branches, as [sorsama/deepseek-harness-relay#11](https://github.com/sorsama/deepseek-harness-relay/issues/11). The second fault is the stale published build (`lib/index.js` 121,168 bytes, no `client-connection`); built from the `v0.2.1` tag it is 127,555 bytes with the marker. Fixes are in unmerged pull requests: #6 for the publish path, #10 for the client surface and a cold-start bug.
- The rollback, and why it was quick: the desktop profile's `package.json`, `pnpm-workspace.yaml`, and `pnpm-lock.yaml` were backed up before the install and restored after, and the app boots again. A third-party bundle's client half can fail the desktop app's entire boot, because any pending entry is a boot failure there. Trial bundles in the `web` profile only, where the blast radius is that profile's own UI.
- The build-allowance detail, if the relay is retried: pnpm refuses a git-hosted plugin's `prepare` build until the exact spec — the full `dsh-relay@https://codeload.github.com/...tar.gz/<sha>` key, not the package name — is listed under `allowBuilds` in the profile's `pnpm-workspace.yaml`. Adding it as a plain list is rejected with that message.
- `dsh` is not on `PATH`; the app ships one at `/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh`, reporting `0.2.0-rc.2`, which is the version to use for profile operations.
- Registry `dsh-relay@0.2.1`: `lib/index.js` is 121,168 bytes with no `client-connection` or `browser-session` strings. The 0.2.0 changelog states that code mints the harness browser session and that without it every proxied request is answered 401; the `v0.2.1` tag ships `src/harness-session.ts`, and no later version is published. Install from the tag, then confirm `client-connection` appears in the installed `lib/index.js`. Reproduced as sorsama/deepseek-harness-mobile#40.

Reference documents:

- Relay client integration contract: https://github.com/sorsama/deepseek-harness-relay/blob/v0.2.1/docs/CLIENT_INTEGRATION.md
- Relay getting started: https://github.com/sorsama/deepseek-harness-relay/blob/main/docs/GETTING_STARTED.md
- Android reference project: https://github.com/sorsama/deepseek-harness-mobile
- Architecture: https://github.com/sorsama/deepseek-harness-mobile/blob/main/docs/ARCHITECTURE.md
- Protocol: https://github.com/sorsama/deepseek-harness-mobile/blob/main/docs/PROTOCOL.md
- Harness: https://github.com/deepseek-ai/deepseek-harness
- Relay: https://github.com/sorsama/deepseek-harness-relay

Implementation authorities to inspect during Stage 0: the installed harness's API type definitions, gateway stream protocol, assistant stream types, and file-upload client at the pinned version.

Evidence boundary: this specification is based on the reference projects' published documentation plus the version, bundle, and packaging observations recorded above. No connection to Patrick's harness, a relay, or an iPhone has been tested. Platform and scope choices remain proposed decisions for this implementation, not observed properties of an existing iOS app.
