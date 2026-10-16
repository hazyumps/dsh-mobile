# Issue #13: a session's subagents, and their timing

**Status:** verified — all three slices; the entry point goes on the
conversation toolbar, as a count badge opening a sheet. Approved by Patrick 2026-10-15.
**Branch:** `issue-13-subagents-view`
**Version impact:** MINOR — a new screen and new kit API (`SubagentRoster`, `SessionAddress`).
No bump in this PR; a line under `## [Unreleased]`.

## Context

`subagent`, `subagentCatalog` and `subagentTiming` are three session projections the installed
harness publishes for every session it knows, and this client reads none of them. The desktop shows
a parent session's whole delegation tree — label, mode, running state, token total and active-turn
duration, opened from the conversation header — while on the phone a delegated run is only a row in
someone else's transcript.

**Captured 2026-10-15** against the live relay (`https://127.0.0.1:3443`, host `0.2.0-rc.2`,
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
- **AC9** — *(added by the planner before slice C, in its own `Tests:` commit.)* The roster
  assembled from a store reads a projection key from the live `session/control` value when that
  stream has sent it and from the `session/list` row otherwise, **per key**; membership is the
  catalog from whichever source has it, and a child with no row and no live value still lists with
  nothing reported.

  AC1–AC6 take the catalog and the child facts as given and are silent about where they come from.
  Slice C has to answer that, and it is a rule rather than glue: the two sources disagree about
  which sessions they carry (39 versus 200 on the capture host), so a whole-session choice is wrong
  in one direction or the other. Leaving it to the app target would put an untested rule behind a
  view, which is what C6 is about.

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

Why per key rather than per session: the control baseline carried **39** sessions on 2026-10-15 while
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

`Tools/check.sh --red` on the `Tests:` commit — the stubs in `Sources/` are deliberately wrong, so
the tree is the contract and nothing else:

```
kit tests: fail on assertions (full log: .build/check/test.log)
app tests: ok
red: ok it compiles and fails on assertions (kit: fail, app: pass; logs in .build/check).
check: ok — red for the right reason (33s)
```

Kit: **577 tests in 41 suites**, 32 issues, all of them assertion failures — 23 new tests in two
suites, and no compile error, no crash. The 16 that fail:

| Test | First assertion that fails |
|---|---|
| `AC1: the roster is the catalog, in the host's order` | `roster.entries.map(\.mode) == [.continuable, …]` → `[.unknown, …]` |
| `AC1: an unlabelled entry falls back to its session id` | `roster.entries.first?.mode == .oneShot` → `.unknown` |
| `AC1: an unrecognised mode keeps its raw value rather than failing the catalog` | `roster.entries.first?.mode == .unrecognized("cascading")` → `.unknown` |
| `AC2: the entry point shows only for a reported, non-empty roster` | `showsEntryPoint == false` for an absent and for an empty catalog → `true` |
| `AC3: activity follows the index and the last turn` | `map(\.activity) == [.running, .completed, .inactive]` → `[.inactive, …]` |
| `AC3: a completed turn is told apart from an interrupted one` | `timing?.lastTurnCompleted == true` → `nil` |
| `AC3: a child the index does not know reports no activity, not inactive` | `activity == nil` → `.inactive` |
| `AC4: with no turn open the duration is settledMs` | `durationMs(now:) == 500` → `nil` |
| `AC4: a running child's open turn runs to now` | `== 2_500` → `nil` |
| `AC4: an inactive child's open turn is bounded by its own through` | `== 900` → `nil` |
| `AC4: the captured running child's duration is settled plus its open window` | `== 9_634_145` → `nil` |
| `AC5: the token total sums the four disjoint buckets` | `== 112_414_835` → `nil` |
| `AC5: a partial usage sums what the host reported` | `== 100` → `nil` |
| `AC6: the running count is the running children, and the tick follows it` | `runningCount == 1` → `0` |
| `AC7: a subagent follow opens with the durable parent address` | `address["kind"] == "subagent"` → `"session"` |
| `AC7: a subagent page carries the durable parent address` | `address["kind"] == "subagent"` → `"session"` |

**Four planned guards pass against the stubs**, and that is what makes them guards rather than
evidence:

- `AC2: an absent catalog is not an empty one` — the stub's `isReported` is the real rule, so this
  pins that the *implementation* does not collapse the two.
- `AC4: no reported timing is nil, not zero` and `AC5: a child with no reported usage has no token
  total` — the stub's `Entry` carries no timing or usage at all, so both pass; each fails the moment
  an implementation substitutes `0`.
- `AC7: an ordinary session still follows / pages by session address`, and
  `the child's own subagent projection agrees with the catalog` — the unchanged behaviour, which had
  to keep passing.

The first draft of the `Tests:` commit crashed instead of failing: the stub returned an **empty**
`entries` array for every catalog, so two tests died on `entries[0]` with `Index out of range` and
the process ended, hiding every other result. `WORKFLOW.md` step 2 is explicit about this — a stub
returns a wrong-but-valid value, never a crash — so the stub builds one row per catalog member and
every assertion gets to speak.

### The AC9 commit (slice C)

`Tools/check.sh --red` on the **second** `Tests:` commit, with slice A and slice B already built:

```
kit tests: fail on assertions (full log: .build/check/test.log)
app tests: ok
red: ok it compiles and fails on assertions (kit: fail, app: pass; logs in .build/check).
check: ok — red for the right reason (33s)
```

Kit: **582 tests in 42 suites**, 15 issues, all assertion failures. Four of the five new tests fail:

| Test | First assertion that fails |
|---|---|
| `AC9: the live control value wins per key over the session index row` | `child?.id == "subagent-1"` → `nil`: the stub reports no members |
| `AC9: a child with no live value and no row still lists, with nothing reported` | `roster.entries.count == 1` → `0` |
| `AC9: the live catalog is membership too, and the index row is not membership` | `isReported == true` → `false` |
| `AC9: the captured fixture assembles through this path too` | `entries.map(\.id) == […]` → `[]` |

`AC9: no catalog in either source is not reported, not empty` passes against the stub — a guard, for
the same reason as `AC2`'s. The crash above was repeated in this commit's first draft and caught the
same way: `entries[0]` in the last test against a stub that reports no members. It now uses
`#require(entries.first)`, and says why in the test.

A second planner defect was found by the build and fixed in a third `Tests:` commit: the test's row
helper took a `title:` and dropped it, because `SessionRecord.title` reads the typed
`projections.values` and the helper only filled `projectionValues`. The test failed with the string
nowhere in the record, which is the honest kind of failure — the setup was wrong, not the rule. The
helper now puts the title where the host puts it, and says so.

## Verification

The implementation was undone on the finished tree with the tests kept: `Sources/` restored to the
stubs the `Tests:` commits declared — `SubagentRoster.swift` at `dc33cf0` plus the `a2c8366` factory
stub, `SessionAddress.swift` at `dc33cf0`, `HostSessionStore.swift` at `a2c8366` — and the suite
re-run.

```
✘ Test run with 582 tests in 42 suites failed after 0.291 seconds with 48 issues.
```

**20 tests fail, every one on assertions, and nothing crashes.** Restoring `Sources/` and re-running
gives 582 passed.

| AC | Undone how | Tests that fail |
|---|---|---|
| AC1 | `Sources/` at the `Tests:` stubs | `the roster is the catalog, in the host's order`; `an unlabelled entry falls back to its session id`; `an unrecognised mode keeps its raw value rather than failing the catalog` |
| AC2 | same | `the entry point shows only for a reported, non-empty roster` |
| AC3 | same | `activity follows the index and the last turn`; `a completed turn is told apart from an interrupted one`; `a child the index does not know reports no activity, not inactive` |
| AC4 | same | `with no turn open the duration is settledMs`; `a running child's open turn runs to now`; `an inactive child's open turn is bounded by its own through`; `the captured running child's duration is settled plus its open window` |
| AC5 | same | `the token total sums the four disjoint buckets`; `a partial usage sums what the host reported` |
| AC6 | same | `the running count is the running children, and the tick follows it` |
| AC7 | same | `a subagent follow opens with the durable parent address`; `a subagent page carries the durable parent address` |
| AC9 | same | `the live control value wins per key over the session index row`; `a child with no live value and no row still lists, with nothing reported`; `the live catalog is membership too, and the index row is not membership`; `the captured fixture assembles through this path too` |

Six planned guards still pass with the implementation gone, which is what makes them guards:

- `AC2: an absent catalog is not an empty one`
- `AC4: no reported timing is nil, not zero`
- `AC5: a child with no reported usage has no token total`
- `AC7: an ordinary session still follows … / pages … by session address`
- `the child's own subagent projection carries the same mode and label as the catalog`

One correction to the red evidence above: `AC9: no catalog in either source is not reported, not
empty` **passes** at `a2c8366` but **fails** in this combined tree, because here the *roster rules*
are stubbed too and the stub's `showsEntryPoint` is unconditionally `true`. It is a real assertion,
guarded by the rules it exercises rather than by the factory.

`Tools/check.sh`: **green** (full, 60 s) — 582 tests in 42 suites, coverage 88.38% against the
88.36 baseline raised from 88.05 in the same commit, Debug **and** Release build, app tests pass,
`guard-tests` clean, lint clean (the `DSH_SUBAGENTS` read sits inside `#if DEBUG`, so the
`debug-env` allowlist count is unchanged).

**AC8 by eye, on the real host.** Paired `dsh-verify` to the running relay on loopback (one-shot
code, SPKI pin from the pairing page), opened the radiance session with `DSH_OPEN_SESSION=1` and
`DSH_SESSION_ID=session-4755645d-…`, and opened the sheet with the new **`DSH_SUBAGENTS=1`**.

- The **toolbar control read `34`**, and the host's own `session/projections` for that session
  answers `subagentCatalog` with exactly **34** entries. The badge is the host's number.
- The **sheet read `4 running of 34`**, and cross-checking the catalog against `session/list` gives
  exactly **4** rows with `running: true`. The count, the order, the labels, the titles, the
  durations and the token totals all came from the host.
- Live screenshots are **not committed**: they are real session labels and titles, and `AGENTS.md`
  says host data stays local.

So the toolbar control that was going to be "reviewed, not looked at" is looked at, and the only
part of the live path not exercised by eye is the push from a row into a child's transcript. That
part is what AC7's tests cover, and the probe above shows the host accepting the subagent address —
`session/page` refused the *cursor*, not the address.

`DSH_SUBAGENTS` is S7: inside `#if DEBUG` (the compiler, not a runtime check, so no Release build can
read the variable at all) and listed in `Apps/DSHRemote/README.md`.

**AC8's gallery shots** are kept, because they are synthetic and show the states the live host does
not: `design/mockups/2026-10-15-subagents/01-subagents-light.png` and `02-subagents-dark.png`. Five
children render as intended: running (a dotted circle, `8m 30s`, 1,262,840 tokens), completed (a green
check, `46m 0s`), interrupted (a small dot, `5m 24s` — `settledMs` plus the bounded `through`, not the
wall clock), an unlabelled one-shot whose row is named by its session id, and one the index has not
reported, drawn with no glyph and no figures. Light and dark were both checked, because a
single-appearance screenshot has been wrong before.

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
- **`session/list` returned exactly 200 rows on the capture host**, which had 402 session
  directories on disk. Whether that is a cap or a filter is not established; what is established is
  that a session outside the index has no catalog here unless the control baseline still carries it
  (39 sessions on the same host). A parent in neither shows no subagents control at all, which is the
  honest rendering of "not reported" but is not the whole tree. If it bites, the fix is the unary
  `session/projections` read the conversation screen already makes — it answers the parent's catalog
  directly — used as a third source, which needs its own AC.
- The child's own `subagent` projection carries the same `mode` and `label` as its catalog entry
  (the capture agrees, and a test pins it). The catalog is still what drives membership: it is the
  parent's own statement, it is ordered, and it is what the desktop reads.
- `SubagentRoster.Entry` is built only by the roster, so the memberwise initialiser stays internal.
  Nothing outside the kit constructs one.
