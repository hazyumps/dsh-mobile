# DSH Remote — iPhone design concepts
Date: 2026-10-08

Proposed screens with illustrative content, generated using the built-in image generation tool. No app implementation changes.

## Images

- [Sessions and conversation](01-sessions-and-chat.png)
- [Approval and session details](02-approval-and-details.png)

## Direction

A native iPhone companion centered on checking progress, answering decisions, and continuing work. Open on sessions for the remembered host, with a compact host picker. Keep connection state visible in chat. Use charcoal surfaces, clear type, blue actions, amber waiting states, and a corresponding system light appearance.

| Screen | Proposed features |
| --- | --- |
| Sessions | Search, workspace grouping, running/waiting filters, pending decisions first, active host picker |
| Conversation | Clear user/assistant distinction, proper Markdown, expandable reasoning and tools, live streaming, stop control, photo/file attachment and command entry |
| Approval | Action and reason visible before Allow once / Reject, expandable supplied details, host/session context |
| Details | Host-advertised model selection, connection state, read-only goal, plan and task summaries |

Supporting work: per-host/session draft persistence; older-history paging; QR pairing; reconnect behavior; accessible controls, Dynamic Type, and VoiceOver. Only show fields the host actually provides. Stop is a proposed addition via the existing cancel contract; the current view does not expose it. Approval details are supplied action metadata, not a general file browser.

A later phase can add background push alerts and a secure path away from the home network. These require host-side services and are not implied by the mockups. Session creation remains outside the current v1 scope.

## What the source currently implements

SwiftUI app plus a separate Swift 6 kit. Paste pairing, saved hosts, directory-grouped session rows, conversation following, prompt sending and basic single-option question replies are wired. NEXT.md records a successful physical-iPhone install; that device result was not repeated during this review.

The current views do not expose photo/file attachment, slash-command suggestions, model selection, history paging, general tool cards, approval controls, or session details. Draft text is local view state. Several old status claims in SPEC.md and the READMEs predate the current implementation; source and the latest NEXT.md entries were used to determine current state.

## Review findings to address with the redesign

1. **P1 — host selection can keep the previous connection.** In Apps/DSHRemote/Sources/AppModel.swift:275, connected(to:) returns any usable coordinator without checking the requested host. After connecting to host A, opening host B can still list and send work through A. Track the coordinator's host identity and shut down/switch before reusing it.
2. **P1 — streamed text changes do not always reach the UI.** Apps/DSHRemote/Sources/ChatView.swift:240 assigns the latest messages only when the count changes. Text chunks and provisional-to-durable replacement can modify the existing last message without changing the count, leaving stale text visible. Observe content/revision changes rather than only array length.
3. **P2 — arrival of a message forces the reader to the bottom.** Apps/DSHRemote/Sources/ChatView.swift:94 scrolls whenever the message count changes, including when the reader is browsing earlier messages. Track whether the reader is at the live tail and otherwise offer New activity.
4. **P1 — prompt and answer retries are unintentionally enabled.** Sources/DSHRemoteKit/State/ConnectionCoordinator.swift:497 and :549 pass `.none` to an optional retry-policy argument. The compiler explicitly resolves this to Optional.none, so DshRpcClient keeps its default retry policy. HTTP 429/502 can therefore resend a prompt or answer despite the intended no-retry behavior. Use the explicit `RPCFailureRetryPolicy.none` value and verify the retryable status paths. The existing prompt test uses HTTP 500, which is not retried by either policy and therefore misses this defect.

These findings come from source inspection, not a fresh physical-device reproduction.

## Verification

177 Swift package tests reported passing. This package test target exercises DSHRemoteKit; it does not cover SwiftUI view behavior. The live Keychain delete and round-trip checks explicitly reported SKIP because no Keychain was reachable. These were not verified by this run. Compiler warnings exposed the optional retry-policy defect above.

Command used after redirecting the initially blocked compiler cache:
`CLANG_MODULE_CACHE_PATH=/tmp/dsh-mobile-review-module-cache swift test --cache-path /tmp/dsh-mobile-review-spm-cache --disable-sandbox`

Both generated images were visually inspected for readable controls, consistent hierarchy, and complete screen bounds. They are visual concepts; text and control sizing still need native-layout validation during implementation.
