# Scheduled-task notifications on the phone — engineering specification

What it takes to make a scheduled task announce itself on the iPhone, ordered so
that each slice is useful on its own and the last one is the only part that needs
the relay.

Issue: #54. Slices are cut from it one branch at a time.

Read [MOBILE-IMPLEMENTATION-SPEC.md](MOBILE-IMPLEMENTATION-SPEC.md) §10 for the
scheduled-tasks surface this extends. Where this document contradicts it, this
one is newer; where it contradicts the host, the host wins.

## 1. The correction that changes the plan

**The phone cannot read scheduled tasks because it is asking for the wrong
namespace — not because the relay is missing a route.**

`Protocol/endpoints.json` was extracted from the app bundle's descriptor and
contains five `schedule/*` endpoints from `@deepseek-ai/dsh-schedule`. That
package is present in the bundle, but it is registered by
`@deepseek-ai/dsh-experimental-schedule-bundle`, and that bundle is **not in the
running profile's bundle list**:

```
~/.dsh/profiles/desktop/package.json → dsh.profile.bundles
  @deepseek-ai/dsh-base
  @deepseek-ai/dsh-web-app
  @deepseek-ai/dsh-experimental-auto-review
  dsh-plugin-usage
  dsh-plugin-scheduled-tasks      ← the scheduled-tasks feature that IS installed
  dsh-relay
  dsh-plugin-mcp
  dsh-codex-connect
```

The bundle's own patch says so out loud: *"Experimental Schedule over the shipped
Web composition, which carries none of these rows."* So `schedule/catalog` 404s
because nothing serves it — the relay is a transparent proxy with no route
allowlist to extend.

What is installed instead is `dsh-plugin-scheduled-tasks`, whose host half
registers the Remote namespace **`scheduledTasks`**:

| Method | Result |
| --- | --- |
| `scheduledTasks/list` | `{tasks: TaskRecord[]}` |
| `scheduledTasks/settings`, `saveSettings` | plugin defaults |
| `scheduledTasks/workspaces` | workspace choices for the editor |
| `scheduledTasks/create`, `update`, `delete`, `runNow` | mutations |

It is a peer feature, not the same one. The shipped scheduler delivers a due
occurrence **as a follow-up in the original session** (`lastDelivery.messageId`,
one `sessionId` per schedule). The plugin starts a **new session per run**, named
`<task> — <YYYY-MM-DD>`, and records each run on the task. The union in §10's
table describes the shipped one and will not decode a plugin row.

**This is not yet verified over the relay.** The plugin declares itself callable
from anything that can call `ctx.scheduledTasks`, and the relay forwards
everything, so `/api/scheduledTasks/list` should answer. Probing it is the first
task of the implementation, before any code, and the captured response is pinned
in a test the way `AttachmentUploaderTests` pins its capture — date, command, and
an excerpt of the real answer. Do not build on the assumption.

## 2. What a "scheduled task fires" looks like on this host

`TaskRecord` is the whole input to everything below:

```
{ id, title, enabled, workspaceId, createdAt, updatedAt,
  schedule: { id, kind, title, prompt, scheduledAt, time?, timeZone?,
              weekdays?, everySeconds?, afterSeconds?, expression? },
  target: { provider, model, effort, preset },
  lastRun: { occurrenceAt, sessionId, finishedAt, ok, error } | null,
  runs: [ …same shape… ]   // newest first, capped at 20
}
```

Two properties decide how cheap the client can be:

- **`schedule.scheduledAt` is the next occurrence**, not the time the task was
  created. The scheduler calls `advance()` after every run and stores the
  replaced record, so a client reading `list` is handed the next fire time with
  no recurrence arithmetic of its own. `lib/recurrence.js` is 700 lines of DST,
  IANA-zone and cron handling that the phone must not reimplement.
- **`lastRun` is the receipt.** `sessionId` lands only after
  `sessionController.create` returns, so a run that failed to start has
  `sessionId: null` and `ok: false` with the message in `error`.

Absent is not zero, and it is not "due". A task that is disabled or a one-shot
that already ended keeps a `scheduledAt` in the **past**; neither means "fire
now". No `scheduledAt`, no notification.

## 3. Three mechanisms, and what each one actually buys

| | Arrives when | Reports | Needs | Honest limit |
| --- | --- | --- | --- | --- |
| **A. Local notification, scheduled ahead** | On time, even with the app killed or the phone offline | Only that the task was *due* | Nothing | 64 pending per app; one occurrence ahead; fires when the host is asleep and nothing runs |
| **B. Background refresh polling `list`** | Minutes to hours late, or never | What actually ran, with `ok`/`error` and the run's session | `BGTaskScheduler` identifier, `UIBackgroundModes` | Opportunistic — Low Power Mode, low battery, and force-quit all suppress it |
| **C. APNs push from the host** | Seconds, app terminated or not | What actually ran, or that it is starting | Paid Apple Developer team, a token registration path, a host hook, relay token storage | Real work in three repos; the only mechanism that is genuinely a *push* |

They are not exclusive and the order matters: **A is a reminder, B and C are
reports.** Shipping A first is not a stepping stone that gets thrown away — the
scheduling, permission, and tap-routing code is shared with C, and A keeps
working when the host is unreachable.

One more thing A must not do: claim a run happened. "Northstar training brief —
scheduled to run now" is true whether or not the Mac is awake. "Northstar
training brief — ran" is a lie until B or C supplies `lastRun`.

## 4. Slices

Each slice is its own issue and branch. Slices 0–2 are `dsh-mobile` only.

### Slice 0 — discovery (no code)

- Probe `scheduledTasks/list` and `scheduledTasks/settings` over the relay with
  the phone's own paired token. Capture the raw response.
- Confirm the running profile is the desktop one (the relay is a desktop-profile
  plugin, so it is — confirm the namespace anyway, because the profile can be
  switched).
- Pin the capture in a test in `DSHRemoteKit`, with the date, the command, and
  an excerpt. That test is the spec for the decoder.

### Slice 1 — the task list, read-only

- A `ScheduledTasksStore` in the kit decoding `{tasks: [...]}` into a
  `ScheduledTask` with the six-arm `kind` union and the `runRecord` shape.
- `SchedulesView` renders it and says "not available on this harness" when the
  namespace is absent — distinguished from "failed", as `CapabilityOverlay`
  already does.
- Acceptance: the Northstar task is visible on the phone with its next run time
  and its last run's outcome. A host without the namespace shows the honest
  unavailable state.

### Slice 2 — local notifications for due tasks (client-only)

- Authorization request at a moment the user chose, from Settings, never on
  launch. `denied` is a stated state with a deep link to system settings, not
  silence.
- `NotificationPlan.build(tasks:budget:now:)` in the kit: one trigger per
  enabled task whose `schedule.scheduledAt` is in the future, soonest first,
  truncated to the budget. Pure and fully testable without a `UNUserNotificationCenter`.
- Identifier `task.<taskId>.<occurrenceISO8601>`, so re-planning replaces a
  task's pending notification instead of duplicating it.
- Re-plan on: catalog load, foreground return, and after any run is observed.
- Tap routing: `sessionId` present → that conversation; only `taskId` → the
  Scheduled tasks screen; unknown payload → ignored, never a crash. A cold
  launch must buffer the payload until the host store and connection exist —
  publishing a route before its dependencies do is how a screen sits on
  "Reading…" forever.
- Acceptance: with the app killed, a task fires a notification at its next
  `scheduledAt`; tapping it lands in the right place; a disabled task schedules
  nothing; 100 tasks schedule the soonest 60.

### Slice 3 — background refresh turns reminders into reports (client-only)

- `BGAppRefreshTaskRequest` with `BGTaskSchedulerPermittedIdentifiers` and
  `UIBackgroundModes: fetch` in `project.yml`.
- On wake: connect, read `list`, compare each task's newest
  `run.occurrenceAt` against a persisted per-task watermark, notify for runs the
  phone has not reported, then `setTaskCompleted`.
- The watermark is new local state; it is not a secret and does not go in the
  Keychain.
- Acceptance: with the app backgrounded, a completed run produces exactly one
  notification carrying `ok`/`error`, and opening it lands in the run's session.

### Slice 4 — APNs (host, relay, and app)

The only true push, and the only slice that leaves this repo. Two companion
issues must exist first:

- **`dsh-plugins`** — the host hook. `runDue` already knows the moment a run
  starts and ends; add a sender that posts after `recordRun`, with the task
  title, `sessionId`, and `ok`. APNs credentials are Infisical
  (`homelab-infra/prod`), never a repo.
- **`deepseek-harness-relay`** — device-token storage. The relay already owns
  device identity in `~/.dsh/relay/state.json` (`devices{}`), so the APNs token
  belongs on that record rather than in a parallel registry, with a small
  registration route and an internal "send to this device" service the plugin
  can reach.

Then the app: `registerForRemoteNotifications()`, send the hex token after
pairing and on every relaunch, handle a payload with category
`SCHEDULED_TASK_RUN` ("Open run" / "Open task"), and revoke the token on Forget.

**Prerequisite, not a task: push notifications require a paid Apple Developer
team.** A free Personal Team profile cannot carry the `aps-environment`
entitlement, so slice 4 cannot even be tested until that is confirmed. The
project already names `DEVELOPMENT_TEAM: U6LC736TBG`; confirm it is a paid team
before scheduling the work.

## 5. Cross-repo boundaries

| Change | Repo | Why there |
| --- | --- | --- |
| `scheduledTasks/*` decoding, notification planning, tap routing, background refresh | `dsh-mobile` | Client surfaces |
| Push on run start/end | `dsh-plugins/scheduled-tasks` | It owns the run path and the record |
| Device-token storage, APNs credentials, send service | `deepseek-harness-relay` | It already owns devices and pairing |
| `schedule/*` removal or support | neither — it is an uninstalled experimental bundle | Nothing to fix until someone enables it |

The client change must not touch the relay or the host. That boundary is in
`AGENTS.md` and this spec does not bend it.

## 6. Test list

Follows the repo's convention: planner writes these first, failing for the right
reason; the builder does not edit them.

| Test | Guards |
| --- | --- |
| `ScheduledTask` decodes a captured `list` response | The pinned discovery capture |
| `ScheduledTask` decodes an unknown `kind` without failing | A future host arm must not break the screen |
| `NotificationPlan` takes the soonest N within budget | The 64-notification ceiling |
| `NotificationPlan` skips disabled and ended tasks | "Absent is not due" |
| `NotificationPlan` skips a `scheduledAt` in the past | A stale one-shot must not fire on load |
| Re-planning twice yields identical identifiers | Replace, never duplicate |
| `RunWatermark` reports a run once | Repeated polls must not re-notify |
| `RunWatermark` carries `ok: false` and its `error` into the notification | A failed run is the one you most want to hear about |
| `NotificationRoute` on a payload with no `sessionId` opens the task list | A run that failed to start still routes somewhere |
| `NotificationRoute` ignores an unknown payload | Forward compatibility |
| Authorization `denied` produces a stated reason | No silent no-op |

`UNUserNotificationCenter` is a system singleton with no protocol seam, so the
kit takes the plan, not the center: the app turns a plan into requests. That is
also what keeps these tests off a simulator, matching the 0.3-second suite.

## 7. Non-goals

- Creating, editing, pausing or deleting tasks from the phone. That is issue #8's
  ground and it needs mutation UX and its own tests.
- Reproducing `lib/recurrence.js`. The host's `scheduledAt` is the schedule.
- Notification for anything other than scheduled tasks. "Needs your input" is
  #19; it wants the same tap-routing plumbing and can share it later.
- A silent push that wakes the app. Nothing here needs one.

## 8. Version impact

New behaviour, new screens, new persisted state: **MINOR** (0.1.0 → 0.2.0) when
slice 1 lands. Slice 4 changes nothing a stored payload can break.
