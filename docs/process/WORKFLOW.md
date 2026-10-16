# Workflow: from issue to merged

How a change gets made here, by a human or by an agent. `AGENTS.md` holds the rules; this file
holds the procedure. Where a step has a Claude Code shortcut it is noted, but every step is
written so that a person, or any other agent, can do it by hand from this page.

```
issue ─▶ plan ─▶ red tests ─▶ build ─▶ verify ─▶ PR + review ─▶ merge ─▶ (release)
         ▲ human approves plan + tests ▲                ▲ human approves ▲
```

| Role | Does | Must not |
|---|---|---|
| **Planner** | Turns the issue into acceptance criteria, a plan file, and failing tests. | Write the implementation. |
| **Builder** | Makes the tests pass. May add tests. | Edit, weaken or delete a planner test. |
| **Verifier** | Proves each test guards something, runs the full check and the risk checklist. | Be the builder of the slice it verifies. |
| **Reviewer** | A human — the teammate who did not drive the change. Approves the plan and the PR. | Approve a red check. |
| **Orchestrator** | Optional: an agent or person who runs the roles in order (see [ORCHESTRATION.md](ORCHESTRATION.md)). | Write production code itself. |

One human working with agents is normal: the agents hold planner, builder and verifier, and the
human is the reviewer at the two gates. What matters is that the judgement that wrote a test is
not the judgement that decides it passed.

---

## 0. The issue

Work starts on gitea, on an issue (`AGENTS.md`, "One issue, one branch").

- Use a template: `.gitea/ISSUE_TEMPLATE/feature.md` or `bug.md`.
- **A bug is triaged before anyone plans it** (`AGENTS.md`, "Bugs: triage before you fix"):
  - *Origin.* `git log -S'<symbol>' -- <file>` and `git blame` find when the behaviour changed.
    If a merged PR introduced it, label it `origin/regression` and link the PR. If it was always
    like this, `origin/pre-existing`. If SPEC and the design docs never say what should happen,
    `origin/spec-gap`, and ask the question on the issue.
  - *Priority.* `priority/P0` to `priority/P3`. Whoever files the issue picks one, and a human may
    change it.
  - *Cluster.* `tea issues list --state all --labels bug` and a search for the file or feature
    name. Three or more related issues: label them all `needs-design-review`, comment on each
    with links to the others, and stop. A P0 still gets its smallest fix.
  - *Go or wait.* P0 and P1 bugs that are not spec gaps and not in a cluster go to planning. Any
    other bug waits for a human to say "go" on the issue.
- **Triage risk now, not at review.** Read [RISK-FLAGS.md](RISK-FLAGS.md) and tick every flag the
  change could touch. Any security flag (S1–S10) adds the `security` label.
- **Size.** If the plan will need more than about three independent slices, or touches both a
  persisted format and a screen, split it into issues. Small issues are what make parallel
  builders and honest reviews possible.

Branch from `main` in a worktree of the issue's own rather than by switching the checkout you are in
([Several issues at once](#several-issues-at-once)); `/feature` and `/bugfix` do this for you.

## 1. Plan (planner)

Copy [PLAN-TEMPLATE.md](PLAN-TEMPLATE.md) to `design/plans/issue-<n>-<slug>.md` and fill it in.
The parts that matter most:

- **Acceptance criteria**, numbered `AC1`, `AC2`, … Each is one observable behaviour, phrased so a
  test can fail on it. "The approval is sent once even when the relay answers 502" — not "retries
  are handled".
- **Test list**: for every AC, the suite and test name, and *why it fails today*.
- **Slices**: groups of ACs whose files do not overlap, so builders can work in parallel.
- **Risk flags** and **version impact** (PATCH / MINOR / none, per [RELEASING.md](RELEASING.md)).

Commit it as the first commit on the branch: `Plan: <what> (#n)`.

**Gate 1 (human).** The reviewer reads the plan and says so on the issue ("plan approved", or what
to change). For a one-AC bug fix the plan can be five lines; the gate still applies.

> Claude Code: `/feature <n>` or `/bugfix <n>` runs the planner and stops here for you.

## 2. Red tests (planner)

The planner writes the tests from the test list, and commits them **alone**:

```
Tests: <what they pin> (#n)
```

Rules — `Tools/check.sh --red` enforces the first three:

1. **They compile.** A compile error is not a red test; it carries no information. If a test needs
   an API that does not exist yet, add the *signature* in `Sources/` as a stub, in the same
   `Tests:` commit.
2. **They fail on assertions.** `#expect(sent.count == 1)` failing with `3` is the goal.
3. **Stubs never crash.** A stub returns a wrong-but-valid value or throws. Never `fatalError` or
   `preconditionFailure`: Swift Testing runs every test in one process, so one crash ends the run
   and hides every other result.
4. **Each test names its criterion**: `@Test("AC2: an approval is sent once on a 502")`. The name
   is the failure message.
5. **Kit, not app.** Tests live in `Tests/DSHRemoteKitTests/` and use Swift Testing (`import
   Testing`, `@Test`, `#expect`, `#require`). If the behaviour lives in the app target, the plan's
   first slice moves it into `DSHRemoteKit`: rules go in the kit. A bug that lives only in a view's
   rendering (a modifier, not a rule) gets a render test in `Tests/DSHRemoteTests/` instead (see
   [IOS-PRIMER.md](IOS-PRIMER.md)).
6. **Reuse the fakes**: `StubRelayTransport` / `StubRelaySocket` (scripted HTTP and socket answers,
   with a request log), `InMemorySecretStore`, `FixedEpochClock`, and `Fixtures.swift` for captured
   payloads. A new fixture declares its provenance (`FixtureProvenanceTests` will fail otherwise).
7. The test smells in `AGENTS.md` apply: no `Task.sleep` to wait for something, no shared mutable
   state, assert on what a caller sees.

Paste the red summary (`Tools/check.sh --red` output, the failing test names and their messages)
into the plan's **Red evidence** section and commit that with the tests.

**Gate 1 continues**: the reviewer looks at the tests before building starts. Reading tests is the
cheapest review this project will ever get.

## 3. Build (builders)

Builders implement until the tests pass.

- **Never change a line from a `Tests:` commit.** `Tools/guard-tests.sh` fails the check if a
  non-`Tests:` commit removes or edits a line in a file a `Tests:` commit touched. Adding lines is
  fine. If a planner test is wrong, stop and say so in the plan file; the planner fixes it in a new
  `Tests:` commit whose body says why.
- Commit normally: imperative subject, `(#n)`, body says why (`AGENTS.md`, "Commits").
- Inner loop: `swift test --disable-sandbox --filter <SuiteName>`; before pushing,
  `Tools/check.sh --fast`; anything touching the app target, `Tools/check.sh` (it builds Debug *and*
  Release).
- **Parallel builders** each take one slice from the plan, in their own git worktree, branched off
  the issue branch, and merge back into it:

  ```sh
  git worktree add .worktrees/issue-63-a -b issue-63-a issue-63-retried-writes
  # ...build slice A there...
  git checkout issue-63-retried-writes && git merge --no-ff issue-63-a
  git worktree remove .worktrees/issue-63-a && git branch -d issue-63-a
  ```

  Slices must not share files; if two do, they are one slice.

## 4. Verify (verifier)

A different agent or person than the builder. Record the results in the plan's **Verification**
section (or the PR description):

1. `Tools/check.sh` is green — full mode, not `--fast`.
2. **Every AC is shown to be guarded.** For each one, undo the implementation of that AC only
   (`git revert --no-commit <sha>`, or re-introduce the bug by hand), run its test, and paste the
   failure. Then restore (`git revert --abort`, or `git checkout -- <file>`; not `git stash`, which
   every worktree shares). A test that still passes with its fix removed is a liability, and the
   verifier says so — this repo has a precedent (`AGENTS.md`, "Verifier").
3. If any risk flag is ticked, run the matching checklist in [RISK-FLAGS.md](RISK-FLAGS.md) and
   paste it, answered, into the PR.
4. Check the **version impact** claim against [RELEASING.md](RELEASING.md).
5. Docs: a new `DSH_*` variable is in `Apps/DSHRemote/README.md`; a rule taken from the spec cites
   it (`SPEC §8`); a discovery is pinned in a test with its capture date.
6. Coverage: if `Tools/check.sh` says coverage rose, run `Tools/coverage.sh --update-baseline` and
   commit `Tools/coverage-baseline.txt` on the branch.

## 5. Pull request and review

```sh
git push -u origin issue-<n>-<slug>        # the pre-push hook runs Tools/check.sh
tea pulls create --base main --head issue-<n>-<slug> --title "<subject> (#n)"
```

The PR description follows `.gitea/pull_request_template.md`. Starting it with `Closes #n` links
the issue. For a bug, the root cause and origin come from the plan. The size line comes from
`git diff --shortstat main...HEAD -- Sources Apps ':!Sources/DSHRemoteKit/Generated'`.

**Gate 2 (human).** The reviewer approves the PR. A `security`-labelled PR needs the answered
checklist and an explicit approval from the human who did not drive it.

**Merge with a merge commit**, not a squash. The `Tests:` commit is the evidence that the tests
were red first; squashing deletes it. The merge message carries `Closes #n`. Then delete the
branch, locally and on gitea.

## 6. Release

Not every merge is a release. When `main` holds something worth installing, follow
[RELEASING.md](RELEASING.md): one commit bumps the version and the changelog, and a signed tag sits
on it.

---

## Exceptions

**Discovery work runs the other way** (`AGENTS.md`). When the question is "what does the host
actually do?", probe first, then pin what you saw in a test that records the capture date, the
command and an excerpt. Discovery ends in a test, not in prose — and that test is the red test of
whatever feature it unblocks.

**Documentation-only changes** need no plan and no tests, but still go through a branch and PR,
unless they fix a typo. The pre-push hook notices a docs-only branch and runs the fast check.

**Parking.** Unchanged from `AGENTS.md`: push the branch, say on the issue what works, what does
not and what is next. A parked branch may be red; push it with `git push --no-verify` and say so.

## Local CI

There is no CI server yet. `Tools/check.sh` is the single definition of green, and
`.githooks/pre-push` runs it before anything leaves the machine. When a CI runner exists it should
call `Tools/check.sh` and nothing else.

| Step | Script | Fails when |
|---|---|---|
| Lint | `Tools/lint.sh` | a `retryPolicy: .none` or an `RPCFailureRetryPolicy?` declaration (writes retried), a `DSH_*` read outside `#if DEBUG`, a `print(` in the kit — beyond the counts tracked in `Tools/lint-allowlist.txt` |
| Generated models | `Tools/generate-models.py --check` | `Sources/DSHRemoteKit/Generated/` no longer matches `Protocol/` |
| Version | `Tools/check-version.sh` | `Info.plist` ≠ `project.yml`; build number went down; a new version lacks a changelog section; a tag names a different version |
| Planner tests | `Tools/guard-tests.sh` | a builder commit changed a `Tests:` commit's lines |
| Kit tests | `swift test --enable-code-coverage` | any test fails |
| Coverage | `Tools/coverage.sh` | kit line coverage (excluding `Generated/`) drops below `Tools/coverage-baseline.txt`, or a file in `Tools/must-test.txt` falls below its floor |
| App builds | `xcodebuild` Debug and Release | either configuration fails to compile |
| App tests | `xcodebuild build-for-testing`, then `test-without-building` on a simulator | `Tests/DSHRemoteTests` does not compile, or a render test fails |

Modes: `Tools/check.sh` (everything), `--fast` (no app builds or app tests, no simulator), `--red`
(for a `Tests:` commit: the kit and app tests must compile, and at least one must fail). The hook
picks the mode from what is being pushed.

**The app tests take a per-user lock**, because every clone and worktree shares their simulator and
two runs on it at once fail each other. A second `Tools/check.sh` prints that it is `waiting`, and
for whom, then carries on; a killed run frees the lock. The inner loop takes the same lock:

```sh
lockf -k "$(getconf DARWIN_USER_TEMP_DIR)dsh-remote-tests-simulator.lock" \
  xcodebuild test -project Apps/DSHRemote/DSHRemote.xcodeproj -scheme DSHRemote \
  -destination 'platform=iOS Simulator,name=DSH Remote Tests' -only-testing:DSHRemoteTests \
  -collect-test-diagnostics never   # else a failing run can wait 10 minutes on diagnostics
```

"DSH Remote Tests" is the tests' own simulator, created by the first `Tools/check.sh` run (or set
`DSH_TEST_SIMULATOR` to a UDID). It is not for review or pairing: the tests launch the real app,
which reconnects any host paired there.

**One-time setup per machine:** `Tools/setup-dev.sh` — it points git at the hook and `.gitsigners`
by relative paths (repairing absolute ones), and checks for Xcode, XcodeGen, `tea`, and an iOS
simulator runtime with an iPhone device type.

**Adding a lint rule** is the right response to a bug that a grep could have caught. Add it to
`Tools/lint.sh` with a comment naming the bug, and put existing violations in the allowlist with an
exact count and an issue number.

## Several issues at once

A **worktree** is a second checkout of the same clone, in its own directory and on its own branch,
sharing one history: a commit made in one is visible from all of them. A branch can be checked out
in only one worktree at a time. Give each issue in flight a worktree, and leave the shared checkout
(the directory you cloned) on `main`: switching its branch switches it under anyone working there.

**Start** each issue in its own terminal, from the shared checkout:

```sh
claude -w issue-<n>          # a Claude Code session in a new worktree; then /feature <n> in it

# or by hand:
git fetch origin
git worktree add .claude/worktrees/issue-<n>-<slug> -b issue-<n>-<slug> origin/main
cd .claude/worktrees/issue-<n>-<slug>
```

`/feature` and `/bugfix` make the worktree themselves. `git worktree list` shows them all.

**What the worktrees share:**

- **The test simulator:** a check may print `waiting` while another worktree's app tests run.
- **The review simulator:** check things by eye one session at a time, and name it in `simctl`
  commands (`"iPhone 18 Pro"` or a UDID), not `booted`, which may pick "DSH Remote Tests".
- **`git stash`:** there is one for all worktrees. Set work aside with a WIP commit instead.
- **`CHANGELOG.md`:** of two PRs that each add a line, the second to merge conflicts there: merge
  `main` into it, keep both lines, re-run `Tools/check.sh`.

A new worktree's first build is cold (about 4–6 minutes). **Clean up** after the merge, from the
shared checkout:

```sh
git worktree remove <path>   # `git worktree list` gives the path and branch
git branch -d <branch>
```

Xcode keeps each worktree's build output (300–500 MB) in
`~/Library/Developer/Xcode/DerivedData/DSHRemote-*` after it is removed; delete old ones for space.

## Definition of done

- [ ] Issue exists, labelled, risk flags triaged; a bug also has its origin, its priority and a
      cluster check
- [ ] `design/plans/issue-<n>-*.md` approved on the issue
- [ ] A `Tests:` commit, red for the right reason, evidence recorded
- [ ] Planner tests untouched by builders (`Tools/guard-tests.sh`)
- [ ] Every AC verified by putting its bug back
- [ ] `Tools/check.sh` green (full)
- [ ] Risk checklist answered in the PR, where flagged
- [ ] For a bug, the PR states its root cause in one sentence, and any production growth over ~50
      lines is explained
- [ ] Anything found along the way is filed as its own issue and linked, not fixed here
- [ ] Version impact stated; changelog line under `## [Unreleased]`
- [ ] PR approved by the other human; merged with a merge commit and `Closes #n`; branch deleted
