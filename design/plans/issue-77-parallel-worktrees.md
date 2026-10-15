# Issue #77: Run several issues at once — the test simulator collides across worktrees, and /feature branches in the shared checkout

**Status:** built and verified. The plan was approved by Dan on 2026-10-14 as written, including
Decisions 1–4 and 6, as relayed by the orchestrator; `/release` went to #78 (Decision 5). Dan
reviewed the red evidence the same day, and both gate-1 comments are on #77. One addition is
outside the approved plan, made at Dan's request during the build so that future sessions need no
explanation ("make sure there are instructions for this in the appropriate place"). It is `45414b1`:
a "Several issues at once" bullet in `CLAUDE.md` and a paragraph in ORCHESTRATION.md "In Claude
Code". The verifier checked it, and the one sentence it could not confirm, about background
sessions, was then made exact. Written 2026-10-14 by the planner agent.
**Branch:** `issue-77-parallel-worktrees`, in the worktree `.claude/worktrees/issue-77-parallel-worktrees`,
from `origin/main` at `51d7088` (which includes #74's app test target and simulator step).
**Version impact:** none. Only tooling, docs and Claude Code commands change: nothing in `Apps/` except
its README, nothing in `Sources/`, `Package.swift`, `Protocol/` or `Info.plist`
(`docs/process/RELEASING.md`). The changelog line goes under "Added (process, no version impact)".

## Context

We want several issues in flight at once, each in its own worktree (`claude -w issue-75` in one
terminal, `claude -w issue-76` in another). The bug: every checkout runs the app tests on the one
"DSH Remote Tests" simulator (#74), which all of the user's worktrees and clones share. Two runs at
once both fail, one blaming the tests, and two first runs create two simulators. Also:
- `/feature` and `/bugfix` run `git checkout -b`, which switches the shared checkout's branch.
- `core.hooksPath` is absolute on this machine; `setup-dev.sh` replaces it silently and writes
  `gpg.ssh.allowedSignersFile` absolute itself.
- `.claude/worktrees/` is not ignored, and nothing says what worktrees share.

Siblings found: a killed run leaves the simulator booted; the verifier is told to `git stash pop`;
review commands target `booted`; the inner-loop `xcodebuild test` bypasses `check.sh`.

## Acceptance criteria

- **AC1 (reproduction)** — Two worktrees whose full `check.sh` reach the app tests together both
  get the result each gets alone: `app tests: ok`, never "crashed" or "did not run".
- **AC2** — A run that finds the simulator in use prints one `waiting` line naming the holder
  (pid, path), then continues when the holder's simulator section ends. Only that section waits.
  `--fast` never waits, and `DSH_TEST_SIMULATOR` runs take the same lock.
- **AC3** — Two first runs at once create exactly one "DSH Remote Tests".
- **AC4** — A killed run never leaves the next stuck, and nothing is deleted by hand. After Ctrl-C
  the next run does not wait. After `kill -9` of `check.sh` alone, it waits only while the orphaned
  `xcodebuild` runs, and `lsof` on the lock is empty afterwards.
- **AC5 (sibling)** — After a run, "DSH Remote Tests" is shut down even if it was found booted.
  Today a killed run leaves it booted for good (`check.sh:186`). A `DSH_TEST_SIMULATOR` simulator
  is left as found.
- **AC6** — `/feature` step 0, and so `/bugfix`, never switches the shared checkout's branch.
  - In a linked worktree: resume `issue-<n>-…`, or with a clean tree and no commits of its own,
    `git switch -c issue-<n>-<slug> origin/main`; otherwise ask.
  - In the shared checkout: `git worktree add .claude/worktrees/issue-<n>-<slug> -b … origin/main`
    (no `-b` if the branch exists; reuse a worktree that has it), then work there by absolute path.
- **AC7** — `setup-dev.sh` sets `core.hooksPath=.githooks` and
  `gpg.ssh.allowedSignersFile=.gitsigners` (relative, so per worktree), warning with each old value.
  It reads both back and reports `miss`, with the origin, if another scope still overrides one.
- **AC8** — `.gitignore` ignores `.claude/worktrees/`, and nothing else under `.claude/`.
- **AC9 (sibling)** — No doc or brief says to undo with a bare `git stash` or `git stash pop`
  (WORKFLOW step 4, the ORCHESTRATION verifier brief, `verifier.md`, AGENTS.md). They give `git
  revert --no-commit`/`--abort`, `git checkout --`, or a tagged stash applied by SHA.
- **AC10 (sibling)** — The review commands in `Apps/DSHRemote/README.md` and IOS-PRIMER.md name
  the simulator, not `booted`: with several devices booted, `simctl` picks one of them.
- **AC11 (sibling)** — WORKFLOW.md's app-test inner loop takes the same lock
  (`lockf -k <lock> xcodebuild test …`).
- **AC12** — WORKFLOW.md "Several issues at once" covers starting, one checkout at a time on the
  test simulator, the shared review simulator and stash, the second CHANGELOG PR merging `main`,
  cold first builds and cleanup (DerivedData too). WORKFLOW step 0 and AGENTS.md point to it,
  "Local CI" names the lock, ORCHESTRATION matches AC6 (slice worktrees go under the issue
  worktree's `.worktrees/`), and the `check.sh` header and the CHANGELOG are updated.

## Test list

There is no Swift test: every criterion is a recorded probe, as in #62 and #74 AC5. A committed
guard was rejected: it needs a simulator and about 2 minutes, it would wait on its own lock inside
`check.sh`, a regression fails loudly rather than going green, and no grep can see a missing lock.

Harnesses: `section.sh` is today's `generate_project`, `choose_test_simulator` and `run_app_tests`,
copied with `sed` from the `check.sh` under test, and `choose.sh` is the simulator choice alone.
Checkout B is a copy of `git ls-files` at another path. After the fix, probes use real `check.sh`
runs, with overlap forced by an external holder (`lockf -k "$LOCK" tail -f /dev/null &`), not by
sleeps. `LOCK` is `$(getconf DARWIN_USER_TEMP_DIR)dsh-remote-tests-simulator.lock`.

| AC | Probe | Predicted today |
|---|---|---|
| AC1 | P1: `section.sh` in two checkouts, alone then at once (after the fix: two full runs under the holder) | ok alone; together one "test process crashed", the other "tests did not run" |
| AC2 | P2: full, `--fast` and `DSH_TEST_SIMULATOR` runs under the holder | no `waiting` (no lock): guards the fix only |
| AC3 | P3: `choose.sh` twice at once (after the fix: delete the simulator, two full runs under the holder) | two `created`, a count of 2 |
| AC4 | P4: (a) SIGINT to a run's process group mid-test; (b) `kill -9` of `check.sh` alone; then a second run | n/a, no lock; a `mkdir`/PID lock would fail (b) |
| AC5 | P5: boot the simulator by hand, then a full run; guard: the same with `DSH_TEST_SIMULATOR` | left `(Booted)` |
| AC6 | P6: read step 0; check the `rev-parse` detection in a worktree and in a scratch clone | `feature.md:14`: `git checkout -b … main` |
| AC7 | P7: scratch clone, `setup-dev.sh` with (a) absolute values, (b) a worktree-scope override | (a) only `ok`, signers stored absolute; (b) a false `ok` |
| AC8 | P8: `git check-ignore --no-index` on a worktree path and on the tracked `.claude/` files | exit 1 / exit 1 |
| AC9–AC10 | P9, P10: grep for `stash`, and for `booted` in the README and IOS-PRIMER | 4 bare-stash instructions; 4 `booted` commands |
| AC11 | P11: the documented inner loop under the holder | starts at once |
| AC12 | P12: grep each point of AC12 | absent |

The planning pilot (2026-10-14) matched the red evidence. It also showed that two cold
`build-for-testing` runs in parallel are fine (38 s; DerivedData is per path). Under bash 3.2,
`lockf -t 0` on a held descriptor exits 75, and a SIGKILLed holder's inheriting child keeps the
lock until it exits. Nothing `xcodebuild` or `simctl` starts outlives the section holding the lock.

## Slices

| Slice | ACs | Files |
|---|---|---|
| A | AC1–AC5 | `Tools/check.sh` |
| B | AC6–AC12 | `.claude/commands/feature.md`, `.claude/agents/verifier.md`, `Tools/setup-dev.sh`, `.gitignore`, `AGENTS.md`, `docs/process/{WORKFLOW,ORCHESTRATION,IOS-PRIMER}.md`, `Apps/DSHRemote/README.md`, `CHANGELOG.md` (`bugfix.md` runs `/feature`: no change) |

**The lock (Slice A).**
- **Primitive:** `/usr/bin/lockf` on a descriptor the script holds (`exec 9>> "$LOCK"`). It uses
  `flock(2)`, so the kernel frees it when every holder exits, SIGKILL included. Rejected:
  `mkdir`/PID locks and `shlock` (stale detection, pid reuse, waiter races, left by SIGKILL), and
  `flock(1)` (not on macOS).
- **Location:** `getconf DARWIN_USER_TEMP_DIR`, which is per user like the simulators and ignores
  `$TMPDIR` (a sandbox can vary it). Not the git common dir, which separate clones do not share.
- **Scope:** choosing or creating the simulator, `test-without-building` and the shutdown. Builds
  stay outside (DerivedData and `.build` are per path).
- **Holding:** children inherit the descriptor, so an orphaned `xcodebuild` keeps the lock while it
  uses the simulator. One lock serves all runs. A waiter prints one `waiting` line and waits with
  no limit. The holder appends its pid, path and time to the file, for information only.
- **Never delete the lock file; always `lockf -k`.** A deleted file lets two runs lock different
  inodes.
- The dedicated simulator is shut down after every run; an override is left as found. Bash 3.2
  means a fixed descriptor number, with no `{fd}>` and no `$BASHPID`.

## Risk flags

- [x] **None.** S7: no app variable; `DSH_TEST_SIMULATOR` is read only by `check.sh`. S9: the lock
  file is in the user's own temp dir and holds a pid, a path and a time. C3: no Swift change; the
  probes watch output, `lsof` and `pgrep`, and never sleep. C4: nothing runs on a device.

## Out of scope

- **`/release` and RELEASING.md**, which have the same branch-switching shape: #78, "Let /release
  work from a worktree too".
- **Two `check.sh` runs in one worktree**: SwiftPM and `xcodebuild` refuse loudly; one session per
  worktree.
- **A review simulator per worktree** (`simctl clone`): the docs say "one by-eye check at a time".
- **Shared caches** (ModuleCache, SwiftPM manifests): built for concurrency; the pilot's passed.
- **The pre-push hook's "commit or stash them first"**: stashing is safe; popping another's isn't.
- **A lint rule**: no grep sees this bug; a docs lint would flag the warnings themselves.
- **Repairing this machine's git config**: Decision 7.
- **Which branch `claude -w` creates**: the repo does not control it, and AC6 copes with any name.
- **`check.sh`'s crash classifier**: the lock removes the cause it misread.

## Siblings checked

- Fixed temp paths in `Tools/` or `Smoke/`: none.
- `booted`: `check.sh` uses UDIDs; the docs → AC10. The test simulator outside `check.sh`: the
  inner loop → AC11. A killed run's booted simulator → AC5.
- Switching the shared checkout's branch: `/feature` → AC6; `/release` → #78. WORKFLOW step 0
  and the AGENTS.md example stay, as a human's single-checkout path, with a pointer → AC12.
- The shared stash: the verifier → AC9; the pre-push message → out of scope. Config paths into
  one checkout: both → AC7.
- Already fine: the hook runs from the pushing worktree; `.build`, logs, the generated project and
  DerivedData are per path; kit tests are isolated; `origin/main` and tags are rightly shared.

## Decisions for the reviewer

Decisions 1–4 and 6 were approved on 2026-10-14. Decision 5 became #78, and Decision 7 is a step
for Dan after the merge.

1. **No time limit on the wait.** A killed run frees the lock at once. A hung run still holds the
   simulator, and the waiting line names it.
2. **One lock for all runs.** A lock per UDID would cost a second lock and two reads of the state.
3. **AC5 replaces #74's "leave it as found"** for the dedicated simulator only.
4. **No Swift test.** The `Tests:` commit holds only this plan's red evidence. `--red` does not
   apply, and that commit is never the tip at push.
5. **`/release` is out of scope:** #78.
6. **The verifier may delete and recreate "DSH Remote Tests"** (P3) and boot it by hand (P5).
7. **Dan runs `Tools/setup-dev.sh` once after the merge**, to make the shared `.git/config`'s
   absolute `core.hooksPath` and `allowedSignersFile` relative.

## Red evidence

The full probe scripts and logs are in the history:
`git show 81b9006:design/plans/issue-77-parallel-worktrees.md` (red) and
`git show 86ef86d:design/plans/issue-77-parallel-worktrees.md` (verification).

Run 2026-10-14 on `1755292`, whose `check.sh` and `setup-dev.sh` are byte for byte `main`'s, with
all scratch deleted afterwards. **Every probe that can fail today did.** P2 and P4 guard only the
fix, and P12 waits for the docs.

| Probe | Observed on the unchanged tree |
|---|---|
| P1, alone | A and B each: `simulator: 355F197E… (Shutdown)`, 4 tests passed, `app tests: ok` |
| P1, together, trial 1 | A: `app tests: FAIL the test process crashed … stub with a wrong value or a thrown error, not fatalError.` (log: `Early unexpected exit … Test crashed with signal kill before establishing connection.`). B found the simulator `(Booting)`: `Failed to install or launch the test runner … (Mach error -308 - (ipc/mig) server died)`, then `app tests: FAIL the tests did not run`. Both ended at +33 s. |
| P1, together, trial 2 | The same two failures, with A and B swapped |
| P3 | Two `simulator: created "DSH Remote Tests probe-77"` lines (`D6B81BC1…`, `9011269C…`), a count of 2, and a third run silently picked `9011269C…` |
| P5 | `simulator: 355F197E… (Booted)`, `app tests: ok`, `check: green (full, 140s)`, still `(Booted)` after. Guard (`DSH_TEST_SIMULATOR`): `(Booted)` before and after, as intended. |
| P7 (a) | Only `ok   core.hooksPath = .githooks` and `ok   gpg.ssh.allowedSignersFile = .gitsigners`. Read back: `.githooks` and `<clone>/.gitsigners`, which is absolute. |
| P7 (b) | The same `ok` lines, while `file:.git/config.worktree /tmp/elsewhere/.githooks` was still in effect |
| P8 | `.claude/worktrees/x/AGENTS.md`: exit 1. The tracked `.claude/` files: exit 1. |
| P9, P10 | `AGENTS.md:92`, `ORCHESTRATION.md:115`, `WORKFLOW.md:125`, `verifier.md:14` (`git stash pop`); `booted` at IOS-PRIMER 74 and 177 and README 281–282 |
| P6, P11 | `feature.md:14`: `git checkout -b … main`; WORKFLOW 195–196: bare `xcodebuild test` |

## Verification

The raw output of every probe is in `git show 86ef86d:design/plans/issue-77-parallel-worktrees.md`.

The verifier agent ran on `3e48673` on 2026-10-14. Checkout B was in the ignored
`.worktrees/probe-77-b` (`coverage.sh` skips `.build/`); P6 and P7 used a scratch clone; all was
deleted afterwards. Each AC was undone with `git revert --no-commit` and restored with `--abort`.
**`Tools/check.sh` (full): green** (67 s before the probes, 70 s after). **Every AC is guarded.**

| AC | Undone how | Probe result with it undone | Restored |
|---|---|---|---|
| AC1 | revert `1143714` ¹ | A: `FAIL the tests did not run`; B: `FAIL the test process crashed`. Each was ok alone. | both green; B waited 60 s while A tested |
| AC2 | revert `1143714` ¹ | no `waiting` under the holder; it tested at once | one `waiting` line, naming the holder or "holder unknown"; `--fast` never waits; `DSH_TEST_SIMULATOR` waits |
| AC3 | revert `1143714` ¹ | two `created`, count 2 | one `created`, count 1, both runs green |
| AC4 | revert `1143714` ¹ | no lock, nothing to leave behind (as planned) | Ctrl-C: next run doesn't wait. `kill -9`: it waits only for the orphan, then green. `lsof` empty after. |
| AC5 | revert `46381e2` | found `(Booted)`, left `(Booted)` | `(Shutdown)` after; `DSH_TEST_SIMULATOR`: left `(Booted)` |
| AC6 | revert `2b7243d` | `feature.md:14`: `git checkout -b … main` | matches AC6; detection right; a #999 dry run in a clone left its branch alone |
| AC7 | revert `85eba0f`, in the clone | (a) only `ok`, signers absolute; (b) a false `ok` | (a) a `warn` per old value, both relative; (b) `miss … from file:.git/config.worktree`, exit 1 |
| AC8 | revert `c29dcfc` | exit 1 | `.gitignore:21:.claude/worktrees/`; tracked files unignored |
| AC9 | revert `2796ffb` ² | all four bare-stash instructions back | only warnings and the tagged form |
| AC10 | revert `50dd1eb` | `booted` at README 281–282, IOS-PRIMER 74 and 177 | prose only; commands name "iPhone 18 Pro" |
| AC11 | revert `4c8bce2` | the bare loop ran to `TEST SUCCEEDED` under the holder | nothing for 20 s under the holder, then `TEST SUCCEEDED` |
| AC12 | revert `4c8bce2`, `56782e0` | 15 of 16 points absent (the 16th goes with `1143714`) | all 16 present |

¹ It conflicts with `46381e2` in the header and the `--help` range. Resolved by hand to `main`'s
`run_app_tests` plus the shutdown rule; `bash -n` clean. ² Conflicts with `4c8bce2` in WORKFLOW
step 4, so the grep read both sides.

Other observations:
- `choose.sh` cannot tell fix from bug: #77 did not change `choose_test_simulator`. So AC3 also
  raced the real `run_app_tests`: 2 simulators undone, 1 restored (B waited 70 s).
- The lock file kept one inode throughout. The docs' DerivedData cleanup `grep -l` named exactly
  B's folder. P3 recreated the dedicated simulator, which is now `C9463903…`.
- Version impact none, confirmed: no `Sources/`, `Package.swift`, `Protocol/`, `project.yml` or
  `Info.plist`; `check-version.sh` printed `ok 0.2.0 (238)`; the CHANGELOG line is in place.
- Risk flags none: no Swift changed, no variable steers the lock path, and the temp dir is
  `drwx------`.
- `45414b1` (outside the plan, no AC) was checked by hand against `claude --help` (`-w,
  --worktree [name]`), `.claude/worktrees/`, and WORKFLOW's list of what is shared.

**After verification:** Dan asked for less Markdown after reviewing PR #84. `a29362b` shortened
the worktree guidance, dropping the tagged-stash recipe and the DerivedData `grep` mentioned above,
and this plan was condensed from 948 lines. The doc probes P6 and P9–P12 were re-run on
`a29362b` and still pass, and the pre-push hook ran the full check again.

**Findings for the human.** None blocks the merge.
1. **45414b1's background-session sentence** could not be confirmed (`--help` says nothing for
   `--bg`). It was made exact in `2d09aa0`.
2. **The shared checkout is on `issue-62-dev-process`, not `main`**, which the new docs assume.
3. **A relative `allowedSignersFile` (AC7)** checks each worktree against its own `.gitsigners`. So
   in a PR's worktree, a key the PR adds verifies that PR's commits. Before, it trusted whatever the
   shared checkout had. Not an S-flag, but read `.gitsigners` changes before trusting signatures.
4. **A killed run's line can name the wrong holder.** It stays in the lock file until the next
   `check.sh` takes the lock. If the inner loop's `lockf -k`, which writes nothing, takes it first,
   a waiter names the dead run instead of "holder unknown". The lock itself was right.
5. **Kit coverage drifts** between runs of unchanged code (86.70–86.74%), never "It rose", so the
   baseline stays 86.70.

## Notes for the next person

- **`/usr/bin/lockf` uses `flock(2)`, not POSIX record locks.** Closing *another* descriptor on
  the file keeps the lock, so the holder's second `>` write is safe. Deleting the file is not safe,
  because a waiter may hold the old inode. Hence `-k`, and never `rm`.
- **Under Claude Code's worktree isolation**, compound one-liners with `$(…)` or loops were
  refused. Write probe scripts as files in the ignored `.build/` and run them as `bash <path>`.
- **Timings here (2026-10-14):** the app-test section alone takes 40–46 s; two cold
  `build-for-testing` runs in parallel took 38 s; a DerivedData folder is 300–500 MB.
