# Issue #13: a session's subagents, and their timing

**Status:** draft
**Branch:** `issue-13-subagents-view`
**Version impact:** MINOR — a new screen and new kit API (`SubagentRoster`, `SessionAddress`).
No bump in this PR; a line under `## [Unreleased]`.

## Context

`subagent`, `subagentCatalog` and `subagentTiming` are three session projections the installed
harness publishes for every session it knows, and this client reads none of them. The desktop shows
a parent session's whole delegation tree — label, mode, running state, token total and active-turn
duration, opened from the conversation header — while on the phone a delegated run is only a row in
someone else's transcript.

**Captured 2026-10-16** against the live relay (`https://127.0.0.1:3443`, host `0.2.0-rc.2`,
protocol 4), on a session with thirty continuable children:

- `session/projections` answers with `values.subagentCatalog`:
  `[{"mode":"continuable","label":"…","id":"…","createdAt":1792012370832}, …]` — **membership and
  order are the host's**, so nothing here is inferred from `parentSessionId` or a title.
- A child's own values carry `subagentTiming`:
  `{"settledMs":9634145,"active":{"since":1792106727891,"through":1792107446245}}` while its turn is
  open, and `{"settledMs":111848,"lastTurnCompleted":true}` once it closes. `since` and `through` are
  **epoch milliseconds**, the same unit as `session/list`'s `updatedAt` and `Models/EpochClock`.
- Two children were running at capture time, 26 inactive with a normally completed last turn, and 2
  inactive with a last turn that did **not** complete.

The host's own definition of the projection is in the installed source
(`@deepseek-ai/dsh-subagent/lib/index.js`, `subagentTimingProjectionDefinition`): `turn/start` opens
`active = {since: event.time, through: event.time}`; every later event advances `through`; `turn/end`
folds `settledMs += max(0, end − active.since)` and sets `lastTurnCompleted = reason.kind ==
"completed"`; a `subagent/descriptor` resets `settledMs` to 0. The desktop renders that as
(`@deepseek-ai/dsh-client-ui-subagent/lib/client.js`, `activityDuration`):

```js
if (timing.active === undefined) return timing.settledMs;
const end = activity === "running" ? now : timing.active.through;
return timing.settledMs + Math.max(0, end - timing.active.since);
```

This client never opens a subagent conversation today, and it cannot: the relay refuses the session
form of the address for a child. Probed on the same capture session —

```
POST /api/session/page  {"address":{"kind":"session","sessionId":"9b8e505c-…"}}
  → ok: false, code "session/agent-busy",
    message "subagent Sessions require their durable parent address"
POST /api/session/page  {"address":{"kind":"subagent","parentSessionId":"session-4755645d-…",
                                    "childSessionId":"9b8e505c-…","mode":"continuable"}}
  → ok: false, code "gateway/bad-request", message "session page through seq 999999 is past cursor 82"
```

The second refusal is this probe's own bogus `throughSeq`; the address form was accepted, which is
the point. `SessionPageRequestAddress` / `SessionFollowRequestAddress` already model both members, so
this is a call-site change, not a new payload.

## Acceptance criteria

- **AC1** — a roster lists exactly the children the parent's `subagentCatalog` names, in the host's
  order, each with that entry's `mode` and `label`; an entry with no `label` reports its session id
  as `displayLabel` (the desktop's own rule, `client.js`: `entry.label ?? entry.id`).
- **AC2** — an absent catalog is not an empty one: `catalog == nil` reports "not reported"
  (`isReported == false`) and an empty roster, while `catalog == []` reports a **known** empty roster
  (`isReported == true`, `entries.isEmpty`). The conversation's entry point shows for a **reported,
  non-empty** roster only.
- **AC3** — a child's activity is `.running` when the session index says it is running; otherwise
  `.completed` when its `subagentTiming.lastTurnCompleted` is true; otherwise `.inactive`. A child the
  index has not heard of reports **no** activity rather than `.inactive`.
- **AC4** — a child's duration is the host's own arithmetic and nothing else: `nil` when the host
  reported no timing; `settledMs` when no turn is open; `settledMs + max(0, now − active.since)` for a
  running child with an open turn; `settledMs + max(0, active.through − active.since)` for one that is
  not running — the desktop's "an interrupted open turn is bounded by its same-cut `active.through`".
- **AC5** — a child's token total is the sum of the four disjoint `tokenUsage` buckets, summing
  whichever the host reported, and `nil` when it reported none. Absent is not zero.
- **AC6** — `runningCount` counts the children whose activity is `.running`, and `needsTick` is true
  exactly when that count is positive, which is what drives the one-second clock.
- **AC7** — a subagent conversation is followed and paged with the **subagent** address
  (`{kind:"subagent", parentSessionId, childSessionId, mode}`), and an ordinary session with the
  session address, unchanged.
- **AC8** — `DSH_SCREEN_GALLERY=subagents` renders the Subagents screen from a fixture roster
  carrying a running, a completed and an interrupted child, so the layout can be reviewed on a
  machine that cannot tap. The variable is inside `#if DEBUG` and listed in
  `Apps/DSHRemote/README.md`.

## Test list

| AC | Suite / file | Test name | Fails today because |
|---|---|---|---|
| AC1 | `SubagentRosterTests.swift` | `"AC1: the roster is the catalog, in the host's order"` | `SubagentRoster` does not exist |
| AC1 | `SubagentRosterTests.swift` | `"AC1: an unlabelled entry falls back to its session id"` | stub returns `label` verbatim (nil) |
| AC2 | `SubagentRosterTests.swift` | `"AC2: an absent catalog is not an empty one"` | stub reports `isReported == true` for both |
| AC3 | `SubagentRosterTests.swift` | `"AC3: activity follows the index and the last turn"` | stub returns `.inactive` for every entry |
| AC3 | `SubagentRosterTests.swift` | `"AC3: a child the index does not know reports no activity"` | stub returns `.inactive` |
| AC4 | `SubagentRosterTests.swift` | `"AC4: duration is the host's arithmetic, in all four cases"` | stub returns `settledMs` for every case |
| AC5 | `SubagentRosterTests.swift` | `"AC5: the token total sums the four buckets, and absent is nil"` | stub returns `0` |
| AC6 | `SubagentRosterTests.swift` | `"AC6: the running count and the tick"` | stub returns `0` |
| AC7 | `SubagentFollowTests.swift` | `"AC7: a subagent follow opens with the subagent address"` | `ChatSession` builds a session address from an id; the recorded `open` args carry `kind: "session"` |
| AC7 | `SubagentFollowTests.swift` | `"AC7: a subagent page carries the subagent address"` | `ConnectionCoordinator.page` hardcodes `.session(…)` |
| AC7 | `SubagentFollowTests.swift` | `"AC7: an ordinary session still follows by session address"` | guard — passes today, must keep passing |

*Fakes: `StubRelayTransport` / `StubRelaySocket` for the follow (the existing `ChatSessionTests`
helpers record the `open` args), `FixedEpochClock` for `now`, and the new captured fixture for the
roster cases. No new stub.*

*Stubs added in `Sources/` by the `Tests:` commit, so the tests compile and fail on assertions:
`Presentation/SubagentRoster.swift` (types with wrong-but-valid returns) and the `SessionAddress`
case on `ChatSession.init` / `ConversationPageRequest`.*

## Slices

| Slice | ACs | Files | Notes |
|---|---|---|---|
| A | AC1–AC6 | `Sources/DSHRemoteKit/Presentation/SubagentRoster.swift`, `Tests/DSHRemoteKitTests/SubagentRosterTests.swift`, `Fixtures/rpc-response-subagent-roster.json`, `Tests/DSHRemoteKitTests/Fixtures.swift`, `Tests/DSHRemoteKitTests/FixtureProvenanceTests.swift` | pure rules; no transport |
| B | AC7 | `Sources/DSHRemoteKit/State/ChatSession.swift`, `Sources/DSHRemoteKit/State/ConnectionCoordinator.swift`, `Tests/DSHRemoteKitTests/SubagentFollowTests.swift` | address plumbing only |
| C | AC8 | `Sources/DSHRemoteKit/State/HostSessionStore.swift`, `Apps/DSHRemote/Sources/SubagentsView.swift`, `ConversationView.swift`, `AppModel.swift`, `ScreensGalleryView.swift`, `Apps/DSHRemote/README.md`, `CHANGELOG.md` | depends on A and B |

A and B touch disjoint files and can be built in parallel; C needs both.

### The two read sources, and which one a key comes from

A child's facts are read **per key**: the live `session/control` value when that stream has sent the
key, otherwise the `session/list` row's own `projections.values`. Until now the index row was decoded
only into the typed ``SessionProjectionValues``, so `HostSessionStore.SessionRecord` gains
`projectionValues: [String: JSONValue]?` — decoded from the same `projections.values` key, which is
the shape `SessionUsage` and `SessionInputSignal` already consume. `Models/` is not touched.

Why per key rather than per session: the control baseline carried **39** sessions on 2026-10-16 while
`session/list` carried **200**, and a child of the capture session that was *not* in the baseline
proved the two sets differ. Reading only the control map would leave older children with no timing;
reading only the index would freeze a running child between the 15-second refreshes.

## Risk flags

- **C2 — the protocol.** No `Protocol/` change and no regeneration: every payload used here is already
  modelled (`SessionFollowRequestAddress`, `SessionPageRequestAddress`) or already generated. The one
  hand-modelled payload is `subagentTiming`, and it carries the captured fixture above, with its date,
  command and host version in the file and in `FixtureProvenance`.
- **C3 — concurrency.** The screen's clock is a `Timer`/`TimelineView` on the main actor driving a
  one-second `now`; no new actor, no `@unchecked Sendable`. No test sleeps to establish anything: the
  duration tests pass an explicit `now`.
- **C6 — UI with no kit test.** Every rule the screen needs — membership, order, labels, activity,
  duration, counts, whether the entry point shows — lives in `SubagentRoster` and is tested there. The
  view composes strings from those values, and AC8's gallery affordance is how the layout is checked
  by eye. No pixel test: nothing here is a glyph-clipping question like #74.
- **S5 — size and shape of untrusted input.** Ticked for the record, not for a new bound: this change
  reads **no new bytes**. The catalog arrives inside the `session/list` and `session/control` frames
  the transport already caps (`ChatSession.pageMessages` documents the measured ~1 MB ceiling), and
  the roster allocates one `Entry` per member of an array the host sent.
- **S1, S4, S6, S8, S9, S10 — not ticked.** No write is added or changed; no credential, file,
  entitlement, log or outside input is touched. Opening a child is read-only by construction (AC8:
  no composer).
- **C1 — not ticked.** Nothing persisted changes.
- **C4 — not ticked.** No Keychain, notification, camera or background path.
- **C5 — not ticked.** No relay or host change is needed or worked around; the host already publishes
  all three projections.

## Out of scope

- **A composer on a subagent conversation.** The desktop elects one for a continuable child when its
  exact parent is unavailable; that is `subagents/prompt`, a new write path, and it needs its own
  once-only test. A child opens read-only here. If Patrick wants it, it is a new issue.
- **Nested catalogs.** The desktop expands a child's own catalog in place. Every child's
  `subagentCatalog` is already in the value map, so a deeper level is a second push of the same
  screen; if the tree proves useful on the phone it is a follow-up.
- **Stopping a running child.** `subagents/interruptByParent` is a write (S1) and is not needed to
  *see* the roster.
- **The `@label` reference source** (`client.js`'s separate inert feature). Nothing in the model's
  input changes here.

## Red evidence

*To be filled in with the `Tests:` commit.*

## Verification

*To be filled in by the verifier.*

## Notes for the next person

- The three projections are registered by `@deepseek-ai/dsh-subagent`, not by the API package, so
  they are absent on a host without that plugin — which is exactly the absent-vs-empty case in AC2.
- `running` is **not** on the control stream. It is a `session/list` row field, refreshed on the
  screens' own 15-second cadence, so a child that stops is reported as inactive up to one refresh
  late. The duration is bounded by `active.through` in that window only if the turn actually closed;
  a *completed* turn leaves no `active`, so the figure freezes correctly.
- `active` persisting while `running` is false is a real state (an interrupted open turn), not a
  bug in the host: the capture had two children like it. It is what AC4's fourth case is for.
- The relay's own message for the wrong address is `session/agent-busy` / "subagent Sessions require
  their durable parent address". That is the string to look for if a child ever renders "Host
  unavailable" again.
