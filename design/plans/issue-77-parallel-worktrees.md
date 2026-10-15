# Issue #77: Run several issues at once — the test simulator collides across worktrees, and /feature branches in the shared checkout

**Status:** draft, awaiting gate 1. Written 2026-10-14 by the planner agent.
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
  - Proposed as a follow-up issue (Decision 5).
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
  - `/release` and RELEASING.md → out of scope;
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
5. **`/release` is out of scope.** Should it get a follow-up issue?
6. **Verification touches the real dedicated simulator.** P3 deletes "DSH Remote Tests", and the
   next run recreates it, with a cold boot. P5 boots it by hand.
7. **After the merge, Dan runs `Tools/setup-dev.sh` once** on this machine. That replaces the
   absolute `core.hooksPath` and `allowedSignersFile` in the shared `.git/config`.

## Red evidence

*Filled in by the planner in the tests phase (Decision 4): the output of P1, P3, P5, P7, P8, P9 and
P10 on the unchanged tree.*

```
```

## Verification

*Filled in by the verifier: for each AC, how it was undone, the probe's result with it undone, and
the result once restored. Then `Tools/check.sh` (full) and the version-impact check.*

| AC | Undone how | Probe result with it undone |
|---|---|---|

- `Tools/check.sh`: green / red
- Risk checklist: not applicable (no flag)

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
