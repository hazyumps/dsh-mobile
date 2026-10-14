# Issue #62: Codify the development workflow — plan → red tests → build → verify, local CI, coverage ratchet

**Status:** verified, awaiting review
**Branch:** `issue-62-dev-process` (stacked on `issue-64-release-build`, PR #70: the full check builds
Release, which does not compile on `main` until #64 lands)
**Version impact:** none — tooling and docs only (`docs/process/RELEASING.md`)

## Context

There is no Mac CI runner, so every change is built and judged on a laptop. `AGENTS.md` described a
planner → builder → verifier loop that nothing enforced: tests and implementation landed in one
commit, and "red first" was a sentence in a commit message. Versioning had drifted (#54 unbumped;
`v0.2.0` tagged on a stale plist), and a Release build had silently stopped compiling (#64).

## Acceptance criteria

- **AC1** — `Tools/check.sh` is the single definition of green, and a versioned pre-push hook runs it.
- **AC2** — a `retryPolicy: .none` write, a `DSH_*` read outside `#if DEBUG`, or a `print(` in the
  kit fails the check, beyond exact, issue-tracked allowlist counts; a fixed violation forces its
  allowlist entry out.
- **AC3** — `Info.plist` out of step with `project.yml`, a lower build number, a new version without
  a changelog section, or a tag naming another version fails the check.
- **AC4** — a non-`Tests:` commit that changes a line from a `Tests:` commit fails the check;
  adding tests does not.
- **AC5** — `--red` accepts a `Tests:` commit only if it compiles, fails, and does not crash.
- **AC6** — removing tests fails the coverage ratchet and the must-test floors; a stale profile is
  refused rather than read.
- **AC7** — a Release-only compile error fails the full check.
- **AC8** — the procedure is written for any agent (`docs/process/`), with the Claude Code layer
  (`CLAUDE.md`, `.claude/`) pointing at it rather than restating it.

## Test list

Tooling is verified by breaking things on purpose in a scratch worktree and watching the check
fail; each probe below is the "test" for its criterion.

## Red evidence

Not applicable in the usual sense: before this branch there was no check to be red. The baseline:
`Tools/check.sh` on this branch is green in full mode (37 s warm, 54 s from a fresh worktree);
kit line coverage 86.70% (identical across four runs), 501 Swift Testing tests in 36 suites plus 14
XCTest.

## Verification

Run 2026-10-13 in `.worktrees/guards` (scratch branch, discarded afterwards).

| AC | Probe | Result |
|---|---|---|
| AC2 | add `….call("x", retryPolicy: .none)` in `ConnectionCoordinator.swift` | `lint: FAIL retry-none …ConnectionCoordinator.swift:598` |
| AC2 | add a fourth unguarded `DSH_*` read to `ConversationView.swift` (allowlist permits 3) | `lint: FAIL … (allowlist permits 3 …; found 4)` |
| AC2 | fix the #63 call (`RPCFailureRetryPolicy.none`) | `lint: FAIL allowlist entry 'retry-none …AppModel.swift' (#63) permits 1 but only 0 remain` |
| AC3 | bump `project.yml` to 0.2.1 without regenerating the plist | `version: FAIL …Info.plist says 0.2.0 (238) but …project.yml says 0.2.1 (250)` |
| AC3 | regenerate, but no `## [0.2.1]` in the changelog | `version: FAIL CHANGELOG.md has no '## [0.2.1]' section` |
| AC3 | new version, build number reused | `version: FAIL a new version (0.2.1) needs a new build number (> 238)` |
| AC3 | the real `v0.2.0` state (plist from the tag) | `version: FAIL …Info.plist says 0.1.0 (1) but …project.yml says 0.2.0 (238)` |
| AC3 | tag HEAD `v0.3.0` | `version: FAIL HEAD is tagged v0.3.0 but …project.yml says 0.2.0` |
| AC4 | `Tests:` commit, then a builder commit changing `== 3` to `== 2` | `guard-tests: FAIL … changes or removes lines in planner test file …` |
| AC4 | builder commit adding a test to the same file | `guard-tests: ok` |
| AC5 | `Tests:` commit with a failing assertion | `red: ok the suite compiles and fails on assertions` |
| AC5 | `Tests:` commit whose test passes | `red: FAIL every test passed` |
| AC5 | `Tests:` commit calling a missing API | `red: FAIL the tests do not compile` |
| AC5 | `Tests:` commit with a `fatalError` stub | `red: FAIL the test process crashed` |
| AC6 | delete `DraftStoreTests.swift` | `coverage: FAIL … 83.27% is below the baseline 86.70%` and `Persistence/DraftStore.swift is at 0.00%, below its must-test floor of 80%` |
| AC6 | profile older than the last raw profile | `coverage: the profile is older than the last test run` |
| AC7 | call a `#if DEBUG`-only type unguarded | `app: ok Debug`, then `error: cannot find 'ScratchDebugOnly' in scope` → `check: RED … app build Release` |
| AC1 | pre-push with a code change / a `Tests:` tip / another ref / a dirty tree | full / `--red` / refused / refused |
| AC1 | pre-push mode decision (run under bash, as the hook does): docs-only vs docs + code | `--fast` / full |

## Notes for the next person

- Swift 6.4's SwiftPM writes to `.build/out/Products/Debug/`; `.build/debug` is sometimes a symlink
  to it and sometimes absent. `Tools/coverage.sh` asks `swift test --show-codecov-path` instead of
  assuming.
- SwiftPM only merges `default.profdata` when the run passes; a failed run leaves the previous
  green run's file in place. `Tools/coverage.sh` refuses a profile older than the newest `.profraw`.
- `grep -q` at the end of a pipe under `set -o pipefail` can report failure when it matched (the
  writer gets SIGPIPE). The scripts capture output first.
- Patrick's signing key (`SHA256:WZqRbx…`) is not among his published gitea keys; `.gitsigners`
  waits for him to add it.
