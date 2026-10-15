# Issue #77: Run several issues at once — the test simulator collides across worktrees, and /feature branches in the shared checkout

**Status:** plan approved by Dan on 2026-10-14, as written, including Decisions 1–4 and 6, as
relayed by the orchestrator. `/release` went to #78 (Decision 5). Reproduction recorded under
"Red evidence"; waiting for the tests gate. Written 2026-10-14 by the planner agent.
**Branch:** `issue-77-parallel-worktrees`, in the worktree `.claude/worktrees/issue-77-parallel-worktrees`,
from `origin/main` at `51d7088` (which includes #74's app test target and simulator step).
**Version impact:** none. Only tooling, docs and Claude Code commands change: nothing in `Apps/` except
its README, nothing in `Sources/`, `Package.swift`, `Protocol/` or `Info.plist`
(`docs/process/RELEASING.md`). The changelog line goes under "Added (process, no version impact)".

## Context

We want several issues in flight at once, each in its own git worktree: `claude -w issue-75` in one
terminal, `claude -w issue-76` in another. The issue lists what already copes. These parts do not:

- **The app tests' simulator (the bug, from #74).** Every checkout's full and `--red`
  `Tools/check.sh` runs the app tests on one simulator, "DSH Remote Tests", and nothing coordinates
  two runs. Simulators belong to the macOS user (`~/Library/Developer/CoreSimulator`), so two
  worktrees share it, and so do two separate clones.
  - A pilot during planning (see "Pilot" under the test list) ran today's app-test section from two
    checkouts at once. Both runs failed, and one failure blamed the tests: "the test process
    crashed … not fatalError". Each run passed alone.
  - Two first runs at once each created a "DSH Remote Tests".
- **`/feature` step 0, which `/bugfix` uses,** runs `git checkout -b … main`. In the shared
  checkout, that switches the branch under whoever else is working there.
- **`core.hooksPath` is absolute on this machine**: `/Users/dan/Fernlabs/dsh-mobile/.githooks`, in
  the shared `.git/config`. So every worktree runs the main checkout's copy of the hook.
  - `Tools/setup-dev.sh` overwrites the value with `.githooks` but never says it did.
  - Planning found the same problem in `gpg.ssh.allowedSignersFile`, which `setup-dev.sh` itself
    writes as an absolute path (`$ROOT/.gitsigners`).
- **`.claude/worktrees/` is not ignored.** That is where `claude -w` and Claude Code put
  worktrees. `git check-ignore -v --no-index .claude/worktrees/x/AGENTS.md` exits 1, so the shared
  checkout lists every worktree as untracked, and `git add -A` there would add them as embedded
  repositories.
- **Not written down:** how to start parallel work, and what worktrees share. They share the review
  simulator, `git stash`, and the `## [Unreleased]` section of the changelog.
- **Wrong once work runs in parallel.** The sibling search found three instructions:
  - the verifier is told to undo with `git stash` and restore with `git stash pop`;
  - the review commands target `booted`;
  - the app tests' inner-loop command uses the test simulator directly, outside anything that
    coordinates `check.sh`.

## Acceptance criteria

### The test simulator (`Tools/check.sh`)

- **AC1 (the reproduction)** — Two checkouts whose `Tools/check.sh` reach the app tests at the same
  moment both get the result each gets alone. Take a tree whose app tests pass, and start two full
  runs from two worktrees together:
  - both print `app tests: ok` and `check: green (full, …)`;
  - neither prints `the test process crashed` or `the tests did not run`.
- **AC2** — A run that finds the simulator in use waits, and says so.
  - It prints one line containing `waiting`, which names the run that has the simulator (its pid
    and checkout path).
  - It starts its own app tests once that run's simulator section has ended.
  - Only the simulator section waits. Lint, the kit tests, the Debug and Release builds and
    `build-for-testing` all go ahead while another checkout is testing.
  - `--fast` never waits.
  - A run with `DSH_TEST_SIMULATOR` set waits for the same lock.
- **AC3** — Two first runs at once create exactly one "DSH Remote Tests". With no such simulator,
  two full runs that reach the app tests together print `simulator: created "DSH Remote Tests"`
  once between them, and `xcrun simctl list devices` then lists one.
- **AC4** — A run that is killed never leaves the next one stuck, and no file ever has to be deleted
  by hand.
  - **Ctrl-C** during the app tests (SIGINT to the run's process group): once the interrupted
    processes have exited, the next run starts its app tests without waiting.
  - **`kill -9` of `check.sh` alone** during the app tests: the next run waits only while the
    orphaned `xcodebuild` runs, which is still using the simulator. Then it proceeds, and afterwards
    nothing holds the lock (`lsof <lock file>` lists nothing).
- **AC5 (sibling)** — After a run that used "DSH Remote Tests", that simulator is shut down, even if
  the run found it booted.
  - Today a run killed between boot and shutdown leaves it booted. Every later run then finds it
    "Booted", assumes someone else booted it, and leaves it booted too (`check.sh:186`).
  - A booted test simulator answers `xcrun simctl … booted` in place of the review simulator.
  - A simulator named by `DSH_TEST_SIMULATOR` is still left as it was found.

### Starting work, and the git setup

- **AC6** — `/feature` step 0, and so `/bugfix`, starts in a worktree and never switches the shared
  checkout's branch.
  - **In a linked worktree** (`git rev-parse --path-format=absolute --git-dir` differs from
    `--git-common-dir`):
    - if an `issue-<n>-…` branch is checked out there, the run resumes on it;
    - otherwise, if the tree is clean and the branch has no commits beyond `origin/main`, it runs
      `git fetch origin` and then `git switch -c issue-<n>-<slug> origin/main` there. The branch
      `claude -w` made may be deleted with `git branch -d`;
    - anything else: stop and ask.
  - **In the shared checkout:** `git fetch origin`, then
    `git worktree add .claude/worktrees/issue-<n>-<slug> -b issue-<n>-<slug> origin/main`.
    - If the branch already exists, the same command without `-b`.
    - If the branch is already checked out somewhere, `git worktree list` says where, and the run
      continues there.
    - From then on, every command, agent and slice worktree uses that worktree's absolute path.
- **AC7** — `Tools/setup-dev.sh` reports and repairs the two git settings that hold a path into a
  checkout.
  - **`core.hooksPath`:** if it is anything other than `.githooks`, the script prints a `warn` line
    naming the old value, saying that every worktree ran that copy of the hook. Then it sets
    `.githooks`.
  - **`gpg.ssh.allowedSignersFile`:** set to the relative `.gitsigners`, so each worktree verifies
    against its own copy. An earlier absolute value is reported the same way.
    - A relative value works: `git -c gpg.ssh.allowedSignersFile=.gitsigners log -1 --format='%h %G?
      %GS' be0009f` printed `be0009f G dan.lambert4@gmail.com`, from the worktree root and from
      `docs/process/`, on 2026-10-14.
  - **Read back:** after setting them, the script reads the effective values. If another config
    scope still overrides one (for example a worktree-scope value), it reports `miss` with the
    origin from `git config --show-origin`, not `ok`.
  - When both values are already relative, it prints the same `ok` lines as today.
- **AC8** — `.gitignore` ignores `.claude/worktrees/`, and nothing else under `.claude/`: the agents,
  commands and settings stay tracked.

### Docs and agent briefs

- **AC9 (sibling)** — No process doc or agent brief tells anyone to undo with a bare `git stash` or
  to restore with `git stash pop`.
  - The stash is shared by every worktree, so a pop can take another session's entry.
  - This covers WORKFLOW.md step 4, the verifier brief in ORCHESTRATION.md,
    `.claude/agents/verifier.md` and AGENTS.md ("Verifier").
  - Instead they name `git revert --no-commit <sha>` and `git revert --abort`,
    `git checkout -- <file>`, or a stash pushed with a unique message and applied by SHA.
- **AC10 (sibling)** — The review commands in `Apps/DSHRemote/README.md` ("Debug affordances") and
  IOS-PRIMER.md name the simulator instead of using `booted`.
  - `xcrun simctl help` says: "If multiple devices are booted when the "booted" device is selected,
    simctl will choose one of them". While another worktree's check runs, "DSH Remote Tests" is
    booted too.
  - `simctl` accepts a name: `xcrun simctl getenv "iPhone 18 Pro" HOME` resolved it on 2026-10-14.
- **AC11 (sibling)** — The app tests' inner-loop command in WORKFLOW.md ("Local CI") takes the same
  lock as `check.sh` (`lockf -k <lock file> xcodebuild test …`). A developer's inner loop and
  another worktree's check then cannot collide either.
- **AC12** — The way to work in parallel is written down.
  - **WORKFLOW.md gets a short "Several issues at once" section.** It covers:
    - **Starting:** `claude -w issue-<n>` per terminal, or `git worktree add …`. `/feature` and
      `/bugfix` do it themselves.
    - **The test simulator:** `check.sh` runs the app tests for one checkout at a time per macOS
      user, and a second run says it is waiting.
    - **The review simulator is shared:** by-eye checks go one at a time, and commands name the
      simulator.
    - **`git stash` is shared:** use a WIP commit, or a tagged stash applied by SHA.
    - **The changelog:** when two PRs each add a line under `## [Unreleased]`, the second merges
      `main` and re-runs the check.
    - **Cold first build:** each new worktree's first build is cold, because SwiftPM's `.build` and
      Xcode's DerivedData are per path. `check.sh`'s header says about 4–6 min.
    - **Cleanup:** `git worktree list`, `git worktree remove`, `git branch -d` and
      `git worktree prune`, plus the worktree's DerivedData folder. That folder is 300–500 MB here,
      and it outlives the worktree.
  - **WORKFLOW.md step 0** points to that section as the alternative to `git checkout -b`.
  - **WORKFLOW.md "Local CI"** says the app tests take a per-user lock.
  - **AGENTS.md** "One issue, one branch" points to the section.
  - **ORCHESTRATION.md** agrees with AC6: `/feature` starts in an issue worktree, and slice
    worktrees are created from inside it, so they nest under its ignored `.worktrees/`.
  - **`check.sh`'s header comment** describes the lock.
  - **`CHANGELOG.md`** has one line under "Added (process, no version impact)".

## Test list

There is no Swift test. Nothing here is in the kit or the app; every criterion lives in a shell
script, a command file or a doc. As in #62 and #74 (AC5), each criterion is checked by a **recorded
probe**. The probe procedures are written out below, so the tests phase and the verifier can repeat
them exactly.

### Why recorded probes, not a committed guard

A small script that races two runs, or a self-test mode in `check.sh`, was considered and rejected:

- It needs a real simulator and about two minutes. It cannot run inside `check.sh`, which would
  have to wait for its own lock and would double in length. So it would run only when someone
  remembers it, which is what a recorded probe already is.
- If the lock breaks again, the failure is loud, not a wrong green. The issue and the pilot both
  show a failed check.
- What it would guard is about fifteen lines of bash, which change rarely.
- No grep can see "a shared resource without a lock", so a `Tools/lint.sh` rule does not apply
  either.

The procedures below are exact commands and harnesses, so "recorded" does not mean "by hand from
memory".

### Pilot, run during planning (2026-10-14): what the predictions rest on

This ran on `51d7088` with scratch scripts in the git-ignored `.build/probe-77/`, which were
deleted afterwards along with everything else the pilot created. The scripts were files run as
`bash <absolute path>`, because Claude Code's worktree guard refused compound one-liners. The
setup was:

- **Checkout A** was this worktree.
- **Checkout B** was a copy of the tracked tree (`git ls-files`, then `rsync --files-from`) in
  `.build/probe-77/b`. It has its own project path, so its own DerivedData.

Results:

- **Concurrent builds are fine.** Two cold `build-for-testing` runs, one per checkout, at once,
  using `check.sh`'s own command: both exited 0, in 38 s. Xcode's module cache is shared between
  them, and it did not get in the way.
- **Each section passes alone.** The `section.sh` harness (below), run in A and then in B, printed
  `simulator: 355F197E-5390-4BEC-A835-5BDC2D9DFE42 "DSH Remote Tests" (Shutdown)`,
  `✔ Test run with 4 tests in 2 suites passed`, and `app tests: ok`, in about 40–46 s each.
- **Both at once, both fail, after 33 s:**
  - A printed: `app tests: FAIL the test process crashed (full log: .build/check/app-tests.log). A
    crash hides every result after it; stub with a wrong value or a thrown error, not fatalError.`
    The log said: `DSHRemote encountered an error (Early unexpected exit, operation never finished
    bootstrapping - no restart will be attempted. (Underlying Error: Test crashed with signal kill
    before establishing connection.))`, and also `DTServiceHubClient failed to bless service hub
    for simulator DSH Remote Tests … IS NOT still alive`.
  - B printed: `DSHRemote encountered an error (Failed to install or launch the test runner.
    (Underlying Error: The operation couldn’t be completed. (Mach error -308 - (ipc/mig) server
    died)))`, then `app tests: FAIL the tests did not run (full log: .build/check/app-tests.log)`.
  - Afterwards the simulator was Shutdown.
- **Creation race:** the `choose.sh` harness (below), started twice at once with the probe name
  `DSH Remote Tests probe-77`:
  - each copy printed `simulator: created "DSH Remote Tests probe-77" <UDID>
    (com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro,
    com.apple.CoreSimulator.SimRuntime.iOS-27-0)`, with two different UDIDs (`5F229F98…`,
    `A65146AE…`);
  - `xcrun simctl list devices` then counted 2;
  - a third run picked `A65146AE…`.

  Both probe simulators were deleted afterwards.
- **The lock primitive, under `/bin/bash` 3.2.57.** The pilot locked fd 9 with `exec 9>> f;
  lockf -s -t 0 9`:
  - a second process's `lockf -t 0` exited 75 (EX_TEMPFAIL);
  - after `kill -9` of the holding shell, a child that had inherited fd 9 still held the lock, and
    `lsof -t` named that child;
  - once the child exited, the lock was free, with no cleanup;
  - a child started with `9>&-` did not hold the lock.
- **Nothing outlives the section holding the lock.** The pilot ran today's whole app-test section
  (`xcodebuild test-without-building`, `simctl shutdown`) with a locked fd 9 inherited by all of
  it, then closed the fd. `lsof` listed no holder, and a new `lockf -t 0` exited 0.
- **DerivedData is per project path.** `~/Library/Developer/Xcode/DerivedData` has one
  `DSHRemote-*` folder each for the main checkout, the #74 worktree, `.worktrees/guards` and a
  Claude job clone. So `build-for-testing` needs no lock.

### The harnesses: today's code, copied verbatim from the `check.sh` under test

`section.sh <checkout root>` runs that checkout's app-test section the way a full run does:

```bash
#!/bin/bash
set -uo pipefail
cd "$1" || exit 2
src=Tools/check.sh mode=full LOG_DIR=.build/check
mkdir -p "$LOG_DIR"
eval "$(sed -n '/^APP_PROJECT=/p; /^TEST_SIMULATOR_NAME=/p' "$src")"
eval "$(sed -n '/^project_ready=""/,/^}/p' "$src")"        # generate_project
eval "$(sed -n "/^SIMULATOR_PY='/,/^'\$/p" "$src")"
eval "$(sed -n '/^test_simulator=""/,/^}/p' "$src")"       # choose_test_simulator
eval "$(sed -n '/^app_tests=""/,/^}/p' "$src")"            # run_app_tests
run_app_tests; echo "app_tests=$app_tests"
```

`choose.sh <path to check.sh> <simulator name>` runs only the simulator choice. Give it a probe
name, so that the real "DSH Remote Tests" is untouched:

```bash
#!/bin/bash
set -uo pipefail
eval "$(sed -n "/^SIMULATOR_PY='/,/^'\$/p" "$1")"
eval "$(sed -n '/^choose_test_simulator() {/,/^}/p' "$1")"
TEST_SIMULATOR_NAME="$2"; test_simulator=""; test_simulator_state=""
choose_test_simulator
```

Both harnesses reproduce the bug on today's `check.sh`. The verifier uses them on the fix reverted.
They are not the after-fix probes, because the lock may live outside the functions they extract.
The after-fix probes use real `Tools/check.sh` runs.

**The lock file.** After the fix, `LOCK="$(getconf DARWIN_USER_TEMP_DIR)dsh-remote-tests-simulator.lock"`
(Slice A). An **external holder**, `lockf -k "$LOCK" tail -f /dev/null &`, holds the lock until it
is killed. That makes overlap deterministic: the probe starts runs, waits for their `waiting`
lines, which is a signal and not a sleep, and then kills the holder.

### Probes

| AC | Probe | Today (predicted) | After the fix |
|---|---|---|---|
| AC1 | **P1.** Two checkouts at the same commit: this worktree and either a copy in `.build/probe-77/b` (the pilot's way, which touches nothing shared) or `git worktree add --detach .worktrees/probe-77 HEAD`. Warm both. Run `section.sh` in each alone, then both at once. After the fix: two full `Tools/check.sh` runs, one per checkout, with the overlap forced by the external holder. | Alone: `app tests: ok` twice. Together: both fail, about 30 s in. One prints `app tests: FAIL the test process crashed …` (log: `Early unexpected exit … Test crashed with signal kill`). The other prints `app tests: FAIL the tests did not run` (log: `Failed to install or launch the test runner … Mach error -308`). Which checkout gets which can vary; what matters is that at least one fails while each passes alone. | Both runs print `app tests: ok` and `check: green (full, …)`. |
| AC2 | **P2.** With the external holder running, start a full `Tools/check.sh`. Then do the same with `--fast`, and with `DSH_TEST_SIMULATOR=355F197E-5390-4BEC-A835-5BDC2D9DFE42` (the dedicated simulator's UDID, so nothing is installed on a second simulator). | No line contains `waiting`, because there is no lock. The full run goes straight to the simulator and is green. This criterion guards the fix, not the bug. | After `== app tests` and `build-for-testing`, one line containing `waiting` that names the holder. A holder that wrote nothing shows as unknown. Nothing more is printed until the holder is killed, then the run continues to green. `--fast`: green, with no `waiting`. With `DSH_TEST_SIMULATOR`: it waits too. |
| AC3 | **P3.** Today: `choose.sh` twice at once, with the name `DSH Remote Tests probe-77`. After the fix: `xcrun simctl delete 355F197E-…` (the dedicated simulator, which the next run recreates), hold the lock, start two full runs from two checkouts, wait for both `waiting` lines, then kill the holder. | Two lines `simulator: created "DSH Remote Tests probe-77" <UDID>`, with different UDIDs, and a count of 2. This is the pilot's result. | Exactly one `simulator: created "DSH Remote Tests"` across the two outputs, and `xcrun simctl list devices \| grep -c "DSH Remote Tests ("` prints 1. |
| AC4 | **P4.** Run a full check under job control (`set -m`, so that it gets its own process group). When its output shows `simulator:`: **(a)** `kill -INT -<pgid>`, wait for `pgrep -g <pgid>` to be empty, then start another full run; **(b)** in a separate trial, `kill -9 <check.sh pid>` only, and start another full run straight away. | Not applicable: there is no lock to leave behind. The criterion guards the shape of the fix. A `mkdir` or PID-file lock would fail (b). | (a) The second run prints no `waiting` and is green. (b) The second run prints `waiting`, naming the killed run. It continues when the orphaned `xcodebuild` exits, and is green. Afterwards `lsof "$LOCK"` lists nothing. |
| AC5 | **P5.** Run `xcrun simctl boot 355F197E-…`, which is the state a killed run leaves. Then run a full `Tools/check.sh`. Scope guard: the same, with `DSH_TEST_SIMULATOR=355F197E-…`. | After the run, `xcrun simctl list devices` shows `DSH Remote Tests (…) (Booted)`. `check.sh:186` skips the shutdown when it found the simulator "Booted". With `DSH_TEST_SIMULATOR`: also Booted. | `(Shutdown)`. With `DSH_TEST_SIMULATOR`: still `(Booted)`, left as found. Then shut it down by hand. |
| AC6 | **P6.** Read step 0 of `.claude/commands/feature.md` against AC6. Check the detection: in the issue worktree, `git rev-parse --path-format=absolute --git-dir --git-common-dir` prints two different paths; in a scratch clone (`git clone -q <worktree> .build/probe-77/clone`) it prints the same path twice. Optionally, in that clone, follow step 0 for a made-up `#999`: a worktree appears at `.claude/worktrees/issue-999-…`, and the clone's own branch is unchanged. | `feature.md:14` says to find or create the branch "from `main` (`git checkout -b … main`)". | The text matches AC6. The detection behaves as described. `bugfix.md` needs no change, because it runs `/feature`. |
| AC7 | **P7.** In a scratch clone of the commit under test (`.build/probe-77/clone`, which has its own `.git`, so the shared config is untouched). **(a)** Set `core.hooksPath` to `/tmp/elsewhere/.githooks` and `gpg.ssh.allowedSignersFile` to `/tmp/elsewhere/.gitsigners` with `git -C <clone> config`, run `<clone>/Tools/setup-dev.sh`, and read both values back. **(b)** `git -C <clone> config extensions.worktreeConfig true`, `git -C <clone> config --worktree core.hooksPath /tmp/elsewhere/.githooks`, then run the script. | (a) From the code: `ok   core.hooksPath = .githooks (pre-push runs Tools/check.sh)` and `ok   gpg.ssh.allowedSignersFile = .gitsigners (verifies teammates' signatures)`. Neither old value is mentioned. The signers file becomes `<clone>/.gitsigners`, absolute. (b) The same `ok` line, while `git config --get core.hooksPath` still prints `/tmp/elsewhere/.githooks`: a false `ok`. | (a) A `warn` line for each setting, naming its old value. Both values end up relative. (b) A `miss` line with the overriding origin (`file:.git/config.worktree`). |
| AC8 | **P8.** `git check-ignore -v --no-index .claude/worktrees/x/AGENTS.md`, then `git check-ignore --no-index .claude/agents/planner.md .claude/commands/feature.md .claude/settings.json`. | The first exits 1 (observed 2026-10-14). The second exits 1. | The first exits 0 and prints `.gitignore:<n>:.claude/worktrees/`. The second still exits 1. |
| AC9 | **P9.** `grep -rn -i stash AGENTS.md docs .claude`. | `AGENTS.md:92` ("or stash the fix"), `WORKFLOW.md:125` (`git stash`), `ORCHESTRATION.md:115` (`git stash`), `verifier.md:14` (`git stash pop`). | No undo instruction uses a bare `git stash` or `git stash pop`. What remains is the "Several issues at once" warning and the tagged form (`git stash push -m …`, `git stash apply <sha>`). |
| AC10 | **P10.** `grep -n booted Apps/DSHRemote/README.md docs/process/IOS-PRIMER.md`. | README lines 281 and 282, and IOS-PRIMER lines 74 and 177, use `booted` as the device. | No command uses `booted` as its device. Prose may still explain why. |
| AC11 | **P11.** With the external holder running, run the inner-loop command exactly as WORKFLOW.md "Local CI" shows it. | It is a bare `xcodebuild test …`, and it starts at once. | It starts with `lockf -k "$(getconf DARWIN_USER_TEMP_DIR)dsh-remote-tests-simulator.lock"`, shows no `xcodebuild` output until the holder is killed, and then passes. |
| AC12 | **P12.** Read the new section in WORKFLOW.md, step 0, "Local CI", the AGENTS.md pointer, ORCHESTRATION.md, the `check.sh` header and `CHANGELOG.md` against AC12. | The section, the pointer and the changelog line do not exist. | Each point in AC12 is present. |

**Undoing each criterion (for the verifier).**
- P1 and P3: revert Slice A's `check.sh` commit or commits with `git revert --no-commit`, then run
  the harnesses again. They should give the pilot's results.
- P5: put back the `!= "Booted"` condition alone.
- P7: revert the `setup-dev.sh` commit.
- P8: revert the `.gitignore` line.
- AC6 and AC9–AC12: these are docs. Their probe is the grep or the reading.

Clean up after the probes:
- delete probe simulators;
- delete the DerivedData folder of any copied checkout, after checking its `WorkspacePath` in
  `info.plist`;
- remove the scratch clone or worktree;
- leave "DSH Remote Tests" shut down.

## Slices

There are two slices, which can run in parallel because their files do not overlap. Slice B writes
against the lock file path and the waiting line that this plan fixes for Slice A.

| Slice | ACs | Files | Notes |
|---|---|---|---|
| A | AC1–AC5 | `Tools/check.sh` | The lock, the waiting line, and the shutdown rule. Header comment included. |
| B | AC6–AC12 | `.claude/commands/feature.md`, `.claude/agents/verifier.md`, `Tools/setup-dev.sh`, `.gitignore`, `AGENTS.md`, `docs/process/WORKFLOW.md`, `docs/process/ORCHESTRATION.md`, `docs/process/IOS-PRIMER.md`, `Apps/DSHRemote/README.md`, `CHANGELOG.md` | Checked and needs no change: `.claude/commands/bugfix.md`, which runs `/feature`. |

### Slice A: the lock (`Tools/check.sh`)

- **The primitive is `/usr/bin/lockf` on a descriptor the script holds**, for example
  `exec 9>> "$LOCK"`, then `lockf -s -t 0 9`.
  - `lockf` uses `flock(2)`. The man page says "BSD-style locking is used … the mere existence of
    the file is not considered to constitute a lock". The kernel releases the lock when every
    process holding the descriptor has exited, whether by Ctrl-C, SIGKILL or a crash. So there is
    never a stale lock to detect or clean up.
  - Rejected: a `mkdir` or PID-file lock, including `/usr/bin/shlock`. Each needs stale-lock
    detection with `kill -0`, which pid reuse can fool. Two waiters can race to break the same
    stale lock. And a SIGKILLed holder leaves the lock behind, which AC4 forbids.
  - Rejected: `flock(1)`, which macOS does not ship.
- **The location is `$(getconf DARWIN_USER_TEMP_DIR)dsh-remote-tests-simulator.lock`.**
  - The lock is per macOS user, like the simulator set, and shared by every clone and worktree.
  - Rejected: the git common dir. Two clones of the repo share the simulator but not that
    directory.
  - Rejected: `$TMPDIR`. A sandbox or a tool can set it differently per session, and two sessions
    would then not see each other's lock. `getconf` is keyed by user and ignores the environment.
  - The value ends in `/`.
  - WORKFLOW.md's inner-loop command (Slice B) names the same path. Say so in a comment.
- **Scope.** In `run_app_tests`, the lock is taken after `build-for-testing` succeeds and before
  `choose_test_simulator`. It covers choosing or creating the simulator, `test-without-building`,
  and the shutdown.
  - It is released when that section ends, by closing the descriptor, or when the process exits.
  - The kit tests and the app builds, including `build-for-testing`, stay outside it. DerivedData
    is per project path (see the pilot), and SwiftPM's `.build` is per worktree.
- **Children inherit the descriptor. Keep it that way.** Then an orphaned `xcodebuild` keeps the
  lock until it exits, which is correct: it is still using the simulator. The pilot found nothing
  that `xcodebuild` or `simctl` starts that outlives the section with the descriptor open.
- **One lock for every run, including `DSH_TEST_SIMULATOR`.** This is correct even when the
  override names the dedicated simulator. The cost is that two runs on two different override
  simulators also queue, at about 30–45 s each. (Decision 2.)
- **Waiting.**
  1. Try `lockf -s -t 0 <fd>`.
  2. On exit 75, print one line containing `waiting`, naming the holder from the lock file's
     contents, or saying it is unknown. For example: `simulator: waiting: another Tools/check.sh is
     running the app tests (pid 4242, /…/issue-75, since 20:31:07)`.
  3. Then wait with no time limit (`lockf -s <fd>`; Decision 1). Saying how long it waited is
     optional.
  4. Any other non-zero exit is an error: print it, and the result is `not-run`, like a lock file
     that cannot be opened.
- **The holder's details.** After taking the lock, the holder writes `pid $$, $ROOT, since <time>`
  into the lock file. This is information only; the lock is the `flock`, not the file's contents.
  - Open the file for appending (`>>`), so that a waiter opening it does not truncate the holder's
    line.
  - **Never delete the lock file**, and any command-form `lockf` must use `-k`. If a file is
    removed while a waiter holds it open, two processes can each lock a different inode. The man
    page recommends `-k` for this reason.
- **The shutdown rule (AC5).** After the section, shut down the dedicated simulator whatever state
  it was found in. Under the lock no other `check.sh` is using it, and it is documented as not for
  review. A `DSH_TEST_SIMULATOR` simulator is left as found, as today.
- **Bash 3.2.** `/bin/bash` is 3.2.57, so:
  - use a fixed descriptor number, because there is no `{fd}>` syntax;
  - do not use `$BASHPID`;
  - keep `set -uo pipefail` in mind.
- **Header comment.** It says that the app tests run for one checkout at a time per macOS user,
  and where the lock is.
- **Validate:** P1–P5, then a full `Tools/check.sh` green on its own.

### Slice B: starting work, setup, and the docs

- **`.claude/commands/feature.md` step 0:** AC6, written so that it works in either place. Keep "if
  the working tree is dirty, stop and ask". Step 3's slice worktrees are created from the issue
  worktree.
- **`docs/process/ORCHESTRATION.md`:**
  - the loop and the "In Claude Code" table say that `/feature` starts in an issue worktree;
  - "Parallel builders" says the slice worktrees are made from inside it;
  - the verifier brief follows AC9.
- **`.claude/agents/verifier.md` and AGENTS.md "Verifier":** AC9.
- **`Tools/setup-dev.sh`:** AC7.
  - Read the effective value, compare it, set it, and read it back.
  - `git config` run in a worktree writes the shared `.git/config`, which is right: it fixes every
    worktree.
- **`.gitignore`:** `.claude/worktrees/`, under a comment like the one on `.worktrees/`.
- **`docs/process/WORKFLOW.md`:** the new section, step 0, "Local CI", and step 4 (AC9, AC11,
  AC12). Keep the section short; the issue asked for short.
- **`docs/process/IOS-PRIMER.md` and `Apps/DSHRemote/README.md`:** AC10. Name the review simulator
  ("iPhone 18 Pro" on this machine, or a UDID). Say in one line why not `booted`.
- **`AGENTS.md`:** one pointer sentence under "One issue, one branch", plus the AC9 wording.
- **`CHANGELOG.md`:** one line under "Added (process, no version impact)". For example: "Several
  issues can run at once, each in its own worktree: `Tools/check.sh` runs the app tests for one
  checkout at a time, `/feature` and `/bugfix` start in a worktree, and `Tools/setup-dev.sh` repairs
  absolute hook and signer paths (#77)."
- **Validate:** P6–P12, and `Tools/check.sh --fast`. The pre-push hook treats this slice as docs
  only, apart from `setup-dev.sh` and `.gitignore`.

## Risk flags

- [x] **None.** No S-flag or C-flag applies. The ones considered:
  - **S7 (debug affordances):** no app variable is added or read. `DSH_TEST_SIMULATOR` is read
    only by `check.sh`, and its behaviour changes only in that it waits for the lock.
  - **S9 (what leaves the sandbox):** the lock file sits in the per-user temp directory and holds a
    pid, a checkout path and a time. That is no secret, and nothing from the app.
  - **C3 (concurrency):** this flag is about Swift isolation, and no Swift changes. The
    process-level locking is the subject of AC1–AC4. Its probes observe signals (output lines,
    `lsof`, `pgrep`) and do not sleep.
  - **C4 (device-only):** nothing here runs on a device.

## Out of scope

- **`/release` and RELEASING.md.** They have the same shape as AC6: `git checkout main`,
  `git checkout -b release-X.Y.Z`, and the hotfix branch.
  - A release is rare and driven by one human, and its tag steps assume `main` is checked out.
    Making it worktree-safe means rewriting those steps.
  - Moved to its own issue: #78, "Let /release work from a worktree too" (Decision 5).
- **Two `check.sh` runs in the same worktree at once.** SwiftPM locks `.build` itself, and
  `xcodebuild`'s build database refuses a second build, loudly. One session per worktree is the
  model.
- **A review simulator per worktree** (`xcrun simctl clone`). The docs say "one by-eye check at a
  time" instead.
- **Shared caches** (Xcode's `ModuleCache.noindex`, SwiftPM's manifest cache). They are built for
  concurrent use. The pilot's two concurrent cold `build-for-testing` runs both succeeded.
- **The pre-push hook's "commit or stash them first".** Stashing your own changes is safe. The
  hazard is popping someone else's entry, which AC9 covers.
- **A `Tools/lint.sh` rule.** No grep can see this bug. `lint.sh` reads Swift, and a lint over the
  docs would flag the warnings that explain the hazard.
- **Repairing this machine's `core.hooksPath` and `allowedSignersFile`.** `Tools/setup-dev.sh` does
  it when Dan runs it after the merge. A branch does not change someone's git config as a side
  effect.
- **What branch `claude -w` creates, and from what base.** The repo does not control that, and
  AC6 copes with any name.
- **`check.sh`'s crash classifier**, which blamed the tests in the pilot. The lock removes the
  cause, so the classifier stays as it is.

## Siblings checked

The bugfix rule is to look for the same mistake elsewhere. Here the mistake is assuming one
checkout or one simulator.

- **Fixed temp paths in the scripts:** none. A grep for `/tmp`, `mktemp`, `TMPDIR`, `tempfile` and
  `gettempdir` over `Tools/` and `Smoke/` finds only a historical mention in
  `Tools/capture/README.md`. The logs live in each worktree's `.build/check/`.
- **`booted` as a device:** `check.sh` never uses it; it targets the simulator by UDID. The docs
  do → AC10.
- **The test simulator used outside `check.sh`:** the WORKFLOW.md inner loop → AC11. The
  `project.yml:57` comment only names it.
- **A killed run's booted simulator** stays booted forever → AC5.
- **Switching the branch of the shared checkout:**
  - `/feature` → AC6;
  - `/release` and RELEASING.md → out of scope, now #78;
  - WORKFLOW.md step 0 and AGENTS.md's example are a human's single-checkout path. They stay, with
    a pointer → AC12.
- **The shared stash:** the verifier's instructions → AC9; the pre-push message → out of scope.
- **Paths into one checkout in the git config:** `core.hooksPath`, and also
  `gpg.ssh.allowedSignersFile` → AC7.
- **Already fine, as the issue says:**
  - the pre-push hook runs from the worktree that pushes;
  - `.build`, `.build/check` and the generated project are per worktree;
  - DerivedData is per path (seen on 2026-10-14);
  - the kit tests are isolated;
  - `origin/main` and the tags, which `guard-tests.sh` and `check-version.sh` read, are shared refs,
    and sharing them is correct.

## Decisions for the reviewer

1. **The wait has no time limit.** A killed run frees the lock at once (AC4). A *hung* run still
   holds the simulator, so timing out could only fail, and the human would still have to stop the
   hung run. The waiting line names it.
   - The alternative is to fail after, say, 10 minutes with the holder's details. That bounds the
     wait for an unattended push.
2. **One lock for all runs.** The alternative is one lock per simulator UDID, which would let two
   runs with different `DSH_TEST_SIMULATOR` values test at once. It costs a second lock file and
   reading the simulator's state twice, inside and outside the lock. A run waits about 30–45 s.
3. **AC5 changes #74's "leave it as found" for the dedicated simulator**: after a run, it is always
   shut down. Please confirm.
4. **The tests phase has no Swift test.** The proposal: after approval, the planner runs P1, P3,
   P5, P7, P8, P9 and P10 on the unchanged tree and pastes the results under Red evidence. That is
   committed alone as `Tests: Reproduce the simulator collision and the setup gaps (#77)`, which
   touches only this file.
   - The name keeps ORCHESTRATION.md's branch-state table working.
   - `Tools/check.sh --red` does not apply: no Swift test changes, so it would report "every test
     passed".
   - That commit is never the tip at push time, so the pre-push hook never runs `--red` on it.
   - The alternative is a different subject, such as `Repro:`.
5. **`/release` is out of scope.** Resolved: it is #78.
6. **Verification touches the real dedicated simulator.** P3 deletes "DSH Remote Tests", and the
   next run recreates it, with a cold boot. P5 boots it by hand.
7. **After the merge, Dan runs `Tools/setup-dev.sh` once** on this machine. That replaces the
   absolute `core.hooksPath` and `allowedSignersFile` in the shared `.git/config`.

## Red evidence

Recorded on 2026-10-14 on `1755292`, the plan commit.
- **The scripts under test are `main`'s.** Its `Tools/check.sh` and `Tools/setup-dev.sh` match
  `main` byte for byte (`git diff --quiet 51d7088 -- <file>`).
- **Cleanup.** Scratch work lived in the ignored `.build/probe-77/`. All of it was deleted
  afterwards, along with the probe simulators and the copy's DerivedData, and "DSH Remote Tests"
  was left Shutdown.
- **How to read the output:**
  - `<worktree>` stands for `/Users/dan/Fernlabs/dsh-mobile/.claude/worktrees/issue-77-parallel-worktrees`;
  - UDIDs are cut to their first block;
  - `…` marks lines left out of xcodebuild's error dictionary.
- **No `--red` run.** There is no Swift test, so `Tools/check.sh --red` does not apply
  (Decision 4).

**Every probe that can show a bug today showed it. None failed to reproduce.**
- P2 and P4 guard the shape of the fix and have nothing to show before it, as planned.
- P12 is the absence of the new docs.

**P1 (AC1): two checkouts run the app-test section at once.**
- Checkout A is this worktree.
- Checkout B is a copy of `git ls-files` in `.build/probe-77/b`. It has its own path, so its own
  DerivedData.

First, `section.sh` alone in each checkout, one after the other:

```
A: simulator: 355F197E… "DSH Remote Tests" (Shutdown)
   ✔ Test run with 4 tests in 2 suites passed after 0.128 seconds.
   app tests: ok
B: simulator: 355F197E… "DSH Remote Tests" (Shutdown)
   ✔ Test run with 4 tests in 2 suites passed after 0.113 seconds.
   app tests: ok
```

Then both at once, trial 1:

```
== A (this worktree)
simulator: 355F197E… "DSH Remote Tests" (Shutdown)
app tests: FAIL the test process crashed (full log: .build/check/app-tests.log). A crash hides every
           result after it; stub with a wrong value or a thrown error, not fatalError.
app_tests=crash
[A ended at +33s]
   A's .build/check/app-tests.log:
	DSHRemote encountered an error (Early unexpected exit, operation never finished bootstrapping - no restart will be attempted. (Underlying Error: Test crashed with signal kill before establishing connection.))
** TEST EXECUTE FAILED **
… DTServiceHubClient failed to bless service hub for simulator DSH Remote Tests (355F197E…) …
== B (the copy)
simulator: 355F197E… "DSH Remote Tests" (Booting)
	DSHRemote encountered an error (Failed to install or launch the test runner. (Underlying Error: The operation couldn’t be completed. (Mach error -308 - (ipc/mig) server died)))
	The operation couldn’t be completed. (Mach error -308 - (ipc/mig) server died)
…
app tests: FAIL the tests did not run (full log: .build/check/app-tests.log)
app_tests=not-run
[B ended at +33s]
== simulator after: DSH Remote Tests (355F197E…) (Shutdown)
```

Trial 2 gave the same two failures with the checkouts swapped:
- A: `app tests: FAIL the tests did not run`, after `Failed to install or launch the test runner …
  (Mach error -308 - (ipc/mig) server died)`;
- B: `app tests: FAIL the test process crashed …`, with `Early unexpected exit, operation never
  finished bootstrapping … Test crashed with signal kill before establishing connection` in its
  log;
- both ended at +33 s.

Result: **reproduced, twice.** Each checkout passes alone. Together both fail, and whichever is
told its tests "crashed" is also told to stop using `fatalError`.

In trial 1, B found the simulator `(Booting)`, because A had started booting it a moment before.
Without a lock, the state a run reads can be one that another run is in the middle of changing.

**P3 (AC3): two first runs at once.** `choose.sh`, started twice at once, with the name
`DSH Remote Tests probe-77`:

```
before: 0 simulator(s) named "DSH Remote Tests probe-77"
run 1: simulator: created "DSH Remote Tests probe-77" D6B81BC1… (com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro, com.apple.CoreSimulator.SimRuntime.iOS-27-0)
run 2: simulator: created "DSH Remote Tests probe-77" 9011269C… (com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro, com.apple.CoreSimulator.SimRuntime.iOS-27-0)
after: 2 simulator(s) named "DSH Remote Tests probe-77"
    DSH Remote Tests probe-77 (9011269C…) (Shutdown)
    DSH Remote Tests probe-77 (D6B81BC1…) (Shutdown)
a third run: simulator: 9011269C… "DSH Remote Tests probe-77" (Shutdown)
```

Result: **reproduced.** Two simulators were created, and the next run silently picked one of them.

**P5 (AC5): a run that finds the test simulator booted.** First `xcrun simctl boot 355F197E…`,
after which `simctl list` showed `(Booted)`. Then a full `Tools/check.sh`:

```
✔ Test run with 501 tests in 36 suites passed after 0.603 seconds.
== app tests
simulator: 355F197E… "DSH Remote Tests" (Booted)
✔ Test run with 4 tests in 2 suites passed after 0.102 seconds.
app tests: ok
check: green (full, 140s)
-- xcrun simctl list devices, afterwards: DSH Remote Tests (355F197E…) (Booted)
```

The scope guard: `DSH_TEST_SIMULATOR=355F197E…`, with the simulator still booted, run through
`section.sh`:

```
simulator: DSH_TEST_SIMULATOR=355F197E… "DSH Remote Tests" (Booted)
✔ Test run with 4 tests in 2 suites passed after 0.098 seconds.
app tests: ok
-- afterwards: (Booted)
```

Result: **reproduced.**
- A green full run leaves the test simulator booted, and every later run would do the same.
- The guard shows today's "leave as found" for an override. That behaviour stays.
- The simulator was shut down by hand afterwards.
- The same run is the baseline: the unchanged tree is green in full mode, in 140 s, including a
  cold kit build in this worktree.

**P7 (AC7): `setup-dev.sh` and paths into a checkout.** This ran in the scratch clone
`.build/probe-77/clone`. Before anything else, `git rev-parse --path-format=absolute --git-dir`
printed `<worktree>/.build/probe-77/clone/.git`, confirming that the clone has its own `.git` and
that the shared config is untouched.

(a) The two values before the run (`git config --show-origin --get`):

```
file:.git/config	/tmp/elsewhere/.githooks
file:.git/config	/tmp/elsewhere/.gitsigners
```

The Git section of `<clone>/Tools/setup-dev.sh`'s output:

```
Git
  ok   core.hooksPath = .githooks (pre-push runs Tools/check.sh)
  ok   gpg.ssh.allowedSignersFile = .gitsigners (verifies teammates' signatures)
  ok   commit signing on (ssh)
  ok   your signing key is in .gitsigners
```

The values read back afterwards:

```
file:.git/config	.githooks
file:.git/config	<worktree>/.build/probe-77/clone/.gitsigners
```

Result: **reproduced.** Both old values were replaced without a word. The signers file is stored
as an absolute path, even though the `ok` line says `.gitsigners`.

(b) After `git config extensions.worktreeConfig true` and
`git config --worktree core.hooksPath /tmp/elsewhere/.githooks`, the value's origin was
`file:.git/config.worktree	/tmp/elsewhere/.githooks`. Then `setup-dev.sh` again:

```
Git
  ok   core.hooksPath = .githooks (pre-push runs Tools/check.sh)
  ok   gpg.ssh.allowedSignersFile = .gitsigners (verifies teammates' signatures)
  ok   commit signing on (ssh)
-- git config --show-origin --get core.hooksPath, afterwards:
file:.git/config.worktree	/tmp/elsewhere/.githooks
```

Result: **reproduced.** The script printed `ok` while the hook path in effect still points
elsewhere.

**P8 (AC8): `.gitignore`.**

```
$ git check-ignore -v --no-index .claude/worktrees/x/AGENTS.md
exit 1
$ git check-ignore --no-index .claude/agents/planner.md .claude/commands/feature.md .claude/settings.json
exit 1
```

Result: **reproduced.** Worktrees under `.claude/worktrees/` are not ignored. The second command is
the scope guard: these files are tracked and must stay unignored.

**P9, P10, P6, P11 (the docs), by grep:**

```
P9 $ grep -rn -i stash AGENTS.md docs .claude
AGENTS.md:92:3. **Verifier** checks the test actually guards something: reinstate the bug (or stash the fix)
docs/process/ORCHESTRATION.md:115:> 2. For **each** acceptance criterion: undo just its implementation (`git stash`, `git revert
docs/process/WORKFLOW.md:125:   (`git stash`, `git revert --no-commit <sha>`, or re-introduce the bug by hand), run its test, and
.claude/agents/verifier.md:14:- Undo one criterion at a time. Always restore (`git checkout -- .`, `git stash pop`, or

P10 $ grep -n booted Apps/DSHRemote/README.md docs/process/IOS-PRIMER.md
docs/process/IOS-PRIMER.md:74:SIMCTL_CHILD_DSH_TRACE=1 xcrun simctl launch --console-pty booted net.fernlabs.dshremote
docs/process/IOS-PRIMER.md:177:| `xcrun simctl install booted <path to .app>` | install a simulator build |
Apps/DSHRemote/README.md:281:  xcrun simctl launch booted net.fernlabs.dshremote
Apps/DSHRemote/README.md:282:xcrun simctl io booted screenshot conversation.png

P6 $ grep -n "checkout -b" .claude/commands/feature.md
14:- Find or create the branch `issue-$ARGUMENTS-<slug>` from `main` (`git checkout -b … main`). If the

P11 $ grep -n -A1 "The app tests' inner loop" docs/process/WORKFLOW.md
195:The app tests' inner loop is `xcodebuild test -project Apps/DSHRemote/DSHRemote.xcodeproj -scheme
196-DSHRemote -destination 'platform=iOS Simulator,name=DSH Remote Tests' -only-testing:DSHRemoteTests
```

Result: **each one matches the plan's "today" column.** The stash, `booted`, `git checkout -b` and
bare `xcodebuild test` instructions are all still there.

**Not run today, as planned:**
- P2 and P4 need the lock.
- P12 has nothing to check until the new docs exist.

## Verification

Verified on 2026-10-14 by the verifier agent, on `3e48673`, in this worktree.
- **Setup.**
  - Checkout B for P1–P4 was a copy of `git ls-files` in the ignored `.worktrees/probe-77-b`. It was
    not under `.build/`, which `coverage.sh` skips.
  - P6 and P7 ran in a scratch clone with its own `.git`, in `.build/probe-77v/clone`.
  - Probe scripts lived in the ignored `.build/probe-77v/`.
  - All of these were deleted afterwards, along with B's DerivedData folder.
- **Undo and restore.** Each criterion was undone with `git revert --no-commit <sha>` and restored
  with `git revert --abort`. After each restore, `git status` was clean and `swift test` or the full
  check was green.
- **`Tools/check.sh` (full): green.** `check: green (full, 67s)` on `3e48673` before the probes;
  `check: green (full, 70s)` after the last restore.
- **Every criterion is guarded.** Each probe failed with its fix undone and passed with it restored.
- `<worktree>` below stands for this worktree's absolute path, and UDIDs are cut to their first
  block.

| AC | Undone how | Probe result with it undone | Restored |
|---|---|---|---|
| AC1 | revert `1143714` ¹ | P1, both at once: A `app tests: FAIL the tests did not run`, B `app tests: FAIL the test process crashed …`. Each was `app tests: ok` alone. | P1: both `app tests: ok`, both `check: green (full, …)` |
| AC2 | revert `1143714` ¹ | P2: under the holder, no `waiting`. The run tested at once, and was green. | P2: one `waiting` line, naming the holder. `--fast` never waits; `DSH_TEST_SIMULATOR` waits. |
| AC3 | revert `1143714` ¹ | P3: two `simulator: created`, count 2. Both with `choose.sh` and with the real `run_app_tests`. | P3: one `simulator: created`, count 1 |
| AC4 | revert `1143714` ¹ | Without a lock there is nothing to leave behind, as planned. P1–P3 show the failure. | P4 (a) and (b): nothing stale. (b) waits only for the orphan. `lsof` empty after. |
| AC5 | revert `46381e2` alone | P5: found `(Booted)`, left `(Booted)` | P5: `(Booted)`, then `(Shutdown)`. With `DSH_TEST_SIMULATOR`: left `(Booted)`. |
| AC6 | revert `2b7243d` | P6: `feature.md:14` says `from main (git checkout -b … main)` | P6: step 0 matches AC6, and the detection is right in both places |
| AC7 | revert `85eba0f`, in the clone | P7 (a): only `ok` lines, and the signers file stored absolute. (b): a false `ok`. | P7 (a): a `warn` naming each old value; both end relative. (b): `miss` naming `file:.git/config.worktree`, exit 1. |
| AC8 | revert `c29dcfc` | P8: exit 1 | P8: `.gitignore:21:.claude/worktrees/`, exit 0. The tracked files stay unignored. |
| AC9 | revert `2796ffb` ² | P9: all four bare-stash instructions are back | P9: only warnings and the tagged form |
| AC10 | revert `50dd1eb` | P10: `booted` at README:281–282 and IOS-PRIMER:74 and 177 | P10: only prose. The commands name "iPhone 18 Pro". |
| AC11 | revert `4c8bce2` | P11: the bare inner loop ran to `TEST SUCCEEDED` under the holder | P11: nothing for 20 s under the holder, then `TEST SUCCEEDED` |
| AC12 | revert `4c8bce2` and `56782e0` | P12: 15 of 16 points absent. The 16th, the `check.sh` header, goes with `1143714`. | P12: all 16 present |

¹ This revert conflicts only in the header comment and the `--help` line range, which `46381e2`
also edits. I resolved it by hand to `46381e2`'s header sentence, without the lock paragraph. The
code it leaves is `main`'s `run_app_tests` plus `46381e2`'s shutdown rule, and `bash -n` is clean.

² WORKFLOW.md step 4 conflicts with `4c8bce2`'s later edit, so the grep read both sides of the
conflict. The other three files reverted cleanly.

**P1 (AC1), undone.**
- `section.sh` read the reverted `check.sh`. Alone in A, then alone in B: `app tests: ok` each.
- Both at once, both ending at +33 s, as in the pilot:

```
A: app tests: FAIL the tests did not run (full log: .build/check/app-tests.log)
   log: DSHRemote encountered an error (Failed to install or launch the test runner. (Underlying
        Error: … (Mach error -308 - (ipc/mig) server died)))
B: app tests: FAIL the test process crashed (full log: .build/check/app-tests.log). A crash hides every
              result after it; stub with a wrong value or a thrown error, not fatalError.
   log: DSHRemote encountered an error (Early unexpected exit, operation never finished bootstrapping
        - no restart will be attempted. (Underlying Error: Test crashed with signal kill before
        establishing connection.))
```

**P1 (AC1), restored.** Two full runs, A and B, with the external holder taken first.
- B printed `waiting` at 21:44:03 and A at 21:44:17. Nothing followed either line while the lock
  was held.
- On release, A took the lock first:

```
A  21:44:17  simulator: waited 0s
   21:44:17  simulator: 821CACC8… "DSH Remote Tests" (Shutdown)
   21:45:03  app tests: ok              check: green (full, 97s)
B  21:45:03  simulator: waited 60s
   21:45:44  app tests: ok              check: green (full, 138s)
```

**P2 (AC2).**
- **Undone.** A full run under the holder printed no `waiting`. It went straight to
  `simulator: 821CACC8… (Shutdown)` and was green, while the holder still had the lock.
- **Restored, under the holder.** The waiting line came after `== app tests` and
  `build-for-testing`. Lint, the kit tests, coverage and both app builds had already run while the
  lock was held. A holder that writes nothing reads as `simulator: waiting: another run holds the
  app tests' simulator (holder unknown; lsof <lock file> names it)`.
- **Restored, natural overlap** (A and B started together, with no holder). B printed:

```
simulator: waiting: another Tools/check.sh is running the app tests (pid 69896, <worktree>, since 21:46:31)
simulator: waited 47s                      (at 21:47:18, the second A printed "app tests: ok")
```

  Both runs were green.
- **`--fast` under the holder:** `check: green (fast, 3s)`, with no `waiting`.
- **`DSH_TEST_SIMULATOR=821CACC8…` under the holder:** it printed `waiting`, then nothing for 10 s,
  then `waited 10s` on release, and was green.

**P3 (AC3).**
- **Undone, the plan's `choose.sh`, twice at once:** `created "DSH Remote Tests probe-77v"
  16B180E7…` and `… DF14301E…`, and a count of 2.
- **`choose.sh` cannot tell the fix from the bug.** It extracts only `choose_test_simulator`, which
  #77 did not change, so it shows the race either way. So the real `run_app_tests` (`section.sh`,
  under the name `DSH Remote Tests probe-77s`) was raced in A and B as well:
  - undone: two `created` (`F1C98B38…`, `F90EBBA9…`), a count of 2;
  - restored: one `created` (`611D5AE4…`). B printed `waiting … (pid 81615, <worktree>, since
    22:07:06)` and `waited 70s`, then used that simulator. A count of 1.
- **Restored, the plan's own probe.**
  - Steps: `xcrun simctl delete 821CACC8…`, take the holder, start two full runs, wait for both
    `waiting` lines, then release.
  - Result: exactly one `simulator: created "DSH Remote Tests" C9463903-08EA-4A3D-B5B1-E488370B9E5D`,
    from B. A printed `waited 73s`, then `simulator: C9463903… (Shutdown)`.
  - Both runs were green, and `simctl list` showed one simulator.
  - **The dedicated simulator's UDID is now `C9463903…`.**

**P4 (AC4), restored.**
- **(a) Ctrl-C.** SIGINT went to the run's process group once the simulator was Booted.
  - During the section, `lsof -t` named `check.sh` 72441 and its `xcodebuild` 73066.
  - The run ended `check: RED … app tests did not run`, and `lsof` then listed nothing.
  - Run 2 printed no `waiting`, and was green.
- **(b) `kill -9` of `check.sh` 73836 alone.**
  - It was reaped, and its orphaned `xcodebuild` 74435 was then paused with SIGSTOP, so that run 2
    could reach the lock while the orphan still held it.
  - `lsof -t` named only 74435. The lock file still said `pid 73836, <worktree>, since 21:51:56`.
  - Run 2, in B, printed: `simulator: waiting: another Tools/check.sh is running the app tests (pid
    73836, <worktree>, since 21:51:56; it has exited, and a process it started is still using the
    simulator)`.
  - The orphan was resumed and exited at 21:54:28. Until then run 2 printed nothing more; it printed
    `waited 60s` at 21:54:27, and was green.
  - Afterwards `lsof` listed nothing.
- **The lock file was never deleted.** It kept inode `80090711` from the first probe to the last.

**P5 (AC5).**
- **Undone** (`46381e2` reverted, the simulator booted by hand): `simulator: 821CACC8… (Booted)`,
  green, and `(Booted)` afterwards.
- **Restored:** the same start, and `(Shutdown)` afterwards.
- **With `DSH_TEST_SIMULATOR=821CACC8…`:** `(Booted)` before and after, as found. It was shut down
  by hand.

**P6 (AC6), restored.**
- In this worktree, `git rev-parse --path-format=absolute --git-dir --git-common-dir` printed
  `…/.git/worktrees/issue-77-parallel-worktrees` and `…/.git`. In the scratch clone it printed
  `<clone>/.git` twice.
- I followed step 0 in the clone for a made-up #999.
  - `git worktree add .claude/worktrees/issue-999-probe -b issue-999-probe origin/main` made the
    worktree.
  - The clone stayed on its own branch, and `git status` there was clean, because the path is
    ignored.
  - Inside the new worktree, the detection printed two paths.
- `bugfix.md` runs `/feature`, so it needs no change.

**P7 (AC7), in the scratch clone.**
- The shared `.git/config` was read before and after, and it is unchanged. It still holds the
  absolute `core.hooksPath` and `allowedSignersFile` (Decision 7).
- **Undone**, after `git -C <clone> revert --no-commit 85eba0f`:
  - (a) Only `ok` lines. The read-back was `file:.git/config .githooks` and
    `file:.git/config <clone>/.gitsigners`.
  - (b) `ok   core.hooksPath = .githooks`, while `file:.git/config.worktree
    /tmp/elsewhere/.githooks` stayed in effect.
- **Restored:**

```
(a) warn core.hooksPath was /tmp/elsewhere/.githooks (file:.git/config): every worktree ran the hook
         from there. Setting .githooks.
    warn gpg.ssh.allowedSignersFile was /tmp/elsewhere/.gitsigners (file:.git/config): every worktree
         verified signatures against that file. Setting .gitsigners.
    read back: file:.git/config .githooks / file:.git/config .gitsigners
(b) miss core.hooksPath is still /tmp/elsewhere/.githooks, from file:.git/config.worktree, which
         overrides .git/config: unset it there                                  (exit 1)
```

- With both values already relative, the script printed only the `ok` lines.
- The relative signers file verifies: `45414b1 G dan.lambert4@gmail.com`, from the clone's root and
  from `docs/process/`.

**P8–P12, restored.**
- **P8:** `.gitignore:21:.claude/worktrees/	.claude/worktrees/x/AGENTS.md`, exit 0. The agents,
  commands and settings check exits 1.
- **P9:** the remaining mentions are ORCHESTRATION.md:128 and 167, WORKFLOW.md:130 and 260–263, and
  verifier.md:17–20. All are warnings or the tagged form.
- **P10:** only prose: IOS-PRIMER.md:78–79 and 181, and README.md:286–288.
  `xcrun simctl getenv "iPhone 18 Pro" HOME` resolves `CC0A81E3…`.
- **P11:** the `lockf -k …` command under the holder printed nothing and started no `xcodebuild` for
  20 s, then printed `** TEST SUCCEEDED **` 41 s after the release. The lock file keeps its inode.
  - Undone, the bare command printed `** TEST SUCCEEDED **` and exited 0 at +43 s, with the holder
    still holding the lock.
- **P12:** 16 greps, one per point of AC12, all present. The cleanup command
  `grep -l "<path>/" ~/Library/Developer/Xcode/DerivedData/DSHRemote-*/info.plist` named exactly
  checkout B's folder, which its `WorkspacePath` confirmed.

**Version impact: none, confirmed.**
- `git diff --name-only 51d7088 HEAD` touches `.claude/`, `.gitignore`, `AGENTS.md`, `CLAUDE.md`,
  `CHANGELOG.md`, `Tools/check.sh`, `Tools/setup-dev.sh`, `docs/process/`,
  `Apps/DSHRemote/README.md` and this plan.
- Nothing in `Sources/`, `Package.swift`, `Protocol/`, `project.yml` or `Info.plist`.
- RELEASING.md says "Docs, tests, tooling only | none". `check-version.sh` printed
  `version: ok 0.2.0 (238)`.
- The changelog line is under `## [Unreleased]`, "Added (process, no version impact)".

**Risk flags: none touched, as planned.**
- **S7:** no Swift changed: no app `DSH_*` variable, no `ProcessInfo` read, no `#if DEBUG`.
  - `DSH_TEST_SIMULATOR` is read only by `check.sh`, as since #74. #77 makes a run that uses it wait
    for the lock, and keeps "left as found".
  - The lock path comes from `getconf DARWIN_USER_TEMP_DIR`, not from the environment, so no variable
    steers it.
  - Lint and the Release build are green.
- **S9:** the lock file is in the per-user temp directory, which is `drwx------` and owned by the
  user. It holds a pid, a checkout path and a time, and no app data.
- Risk checklist: not applicable (no flag).

**`45414b1`, added outside the plan** (CLAUDE.md, and "In Claude Code" in ORCHESTRATION.md). No AC
covers it, so no probe guards it. I checked it against the CLI and WORKFLOW.md:
- **Accurate:**
  - `claude --help` lists `-w, --worktree [name]`, "Create a new git worktree for this session".
  - Claude Code's worktrees live under `.claude/worktrees/`, as this one does.
  - What it says the worktrees share matches WORKFLOW.md, "Several issues at once".
- **Not confirmed: "Background sessions isolate themselves in a worktree the same way."**
  - `claude --help` says nothing about worktrees for `--bg`.
  - Only `claude rm` mentions one, as "its worktree when that is safe".
- **"The shared checkout … stays on `main`" is not today's state.** `git worktree list` shows it
  on `issue-62-dev-process`.

**Findings for the human.** None blocks the merge; every criterion is guarded.
1. **Confirm or soften 45414b1's sentence about background sessions** (above).
2. **The shared checkout is on `issue-62-dev-process`, not `main`.** The new docs assume `main`.
3. **A relative `gpg.ssh.allowedSignersFile` (AC7) checks each worktree against its own
   `.gitsigners`.** So inside a PR branch's worktree, a key the PR itself adds verifies that PR's
   commits.
   - Before, the absolute path trusted whatever the shared checkout had checked out, which today is
     not `main` either.
   - Not an S-flag. Read any `.gitsigners` change in a PR before trusting its signatures.
4. **A killed run's line can name the wrong holder.** It is minor, and observed with
   `check.sh`'s own lock functions.
   - A `kill -9`'d run's line stays in the lock file until the next `check.sh` takes the lock.
   - If the inner loop's `lockf -k`, which writes nothing, takes the lock first, a waiting run
     names the dead run instead of "holder unknown": `waiting: another Tools/check.sh is running
     the app tests (pid 99999, /a/killed/run, since 21:00:00; it has exited, and a process it
     started is still using the simulator)`.
   - The lock itself was right; only the name was wrong.
5. **The kit's coverage moves between runs of unchanged code.** It printed 86.70–86.74% without
   "It rose", so the baseline stays 86.70.

## Notes for the next person

- **`/usr/bin/lockf` locks with `flock(2)`, not with POSIX record locks.**
  - Closing a *different* descriptor on the same file does not release the lock. That is why
    writing the holder's details through a second `>` is safe.
  - Deleting the file is not safe, because a waiter may still hold the old inode. Hence `-k`, and
    never `rm`.
- **Under Claude Code's worktree isolation,** compound one-liners with `$(…)` or loops were refused.
  Write probe scripts as files in the ignored `.build/` and run them as `bash <absolute path>`.
- **Timings on this machine (2026-10-14), from the pilot:**
  - the app-test section alone took 40–46 s, including a no-op `build-for-testing`;
  - two cold `build-for-testing` runs in parallel took 38 s;
  - a DerivedData folder is 300–500 MB.
