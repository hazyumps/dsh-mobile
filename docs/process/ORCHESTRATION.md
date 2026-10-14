# Running the workflow with agents

[WORKFLOW.md](WORKFLOW.md) defines the steps. This file is for running them with AI agents: one
**orchestrator** that coordinates, and separate agents in the **planner**, **builder** and
**verifier** roles. It is written for any agent tool. Where Claude Code has a shortcut, the
section says so — but nothing here *requires* Claude, and the role briefs below are meant to be
pasted into whatever agent you use.

## Principles

1. **Handoffs are files, not memory.** Each role leaves its work in the branch: the plan file, the
   `Tests:` commit, the Red evidence and Verification sections. Any agent, or a person, can pick
   up a branch cold by reading those. Nothing important lives only in a chat transcript.
2. **Separate judgements.** The agent that wrote a test does not decide it passed; the agent that
   built a slice does not verify it. Fresh context is the point — an agent re-reading its own work
   tends to agree with it.
3. **Humans hold the gates.** An agent never approves its own plan, never merges to `main`, never
   pushes a tag, never closes an issue by hand, and never runs `git push --no-verify` without being
   told to.
4. **The orchestrator does not write production code.** It reads, dispatches, merges slice
   branches, and reports. If it starts fixing things itself, the roles have collapsed.
5. **Stop and ask** when a test looks wrong, when two slices turn out to share a file, when a risk
   flag appears that the plan did not tick, or when the same failure survives two attempts.

## Where a branch is, and who goes next

The orchestrator reads the branch to know what to do next — this is what makes resuming work, by
any agent:

| Branch state | Next |
|---|---|
| No branch, or no `design/plans/issue-<n>-*.md` | **Planner**: write the plan |
| Plan exists, issue has no "plan approved" comment | **Human gate 1**: wait |
| Plan approved, no `Tests:` commit | **Planner**: write the red tests |
| `Tests:` commit, Red evidence empty | **Planner**: run `Tools/check.sh --red`, record it |
| Red evidence recorded, tests not yet reviewed | **Human gate 1**: wait for the tests to be looked at |
| Tests reviewed, `swift test` red | **Builders**, one per slice |
| `swift test` green, Verification empty | **Verifier** (and the security reviewer, if a flag is ticked) |
| Verification recorded, no PR | **Orchestrator**: push and open the PR |
| PR open | **Human gate 2**: review and merge |

## The loop

```
orchestrator
  ├─ read the issue (tea issues <n>) and the branch state
  ├─ planner ─▶ plan file ─▶ [human gate 1: plan] ─▶ Tests: commit + red evidence ─▶ [gate 1: tests]
  ├─ builders, in parallel, one per slice, each in its own worktree
  │     └─ merge each slice branch back into the issue branch; run swift test
  ├─ verifier (fresh agent) ─▶ Verification section
  ├─ security reviewer (fresh agent), only if a S-flag is ticked ─▶ answered checklist
  └─ push (the hook runs Tools/check.sh) ─▶ tea pulls create ─▶ [human gate 2]
```

**Parallel builders.** At most three at once; more slices than that wait. Each gets one slice from
the plan and its own worktree off the issue branch:

```sh
git worktree add .worktrees/issue-<n>-<slice> -b issue-<n>-<slice> issue-<n>-<slug>
```

When a builder reports green, the orchestrator merges its branch into the issue branch with
`--no-ff`, runs `swift test --disable-sandbox`, and removes the worktree. A merge conflict means the
slices were not independent: stop and tell the human.

---

## Role briefs

Paste these as the instructions for an agent in that role, with the issue number and branch. They
are the same instructions the Claude Code agent definitions in `.claude/agents/` carry.

### Planner

> You are the **planner** for issue #<n> in this repo. Read `AGENTS.md`,
> `docs/process/WORKFLOW.md` (steps 0–2), `docs/process/PLAN-TEMPLATE.md` and
> `docs/process/RISK-FLAGS.md`, then the issue (`tea issues <n>`) and the code it concerns.
>
> 1. Write `design/plans/issue-<n>-<slug>.md` from the template: numbered acceptance criteria, a
>    test list predicting why each test fails today, slices with disjoint files, the risk flags,
>    and the version impact. Commit it as `Plan: <what> (#<n>)`. **Stop and hand the plan to the
>    human for approval.**
> 2. Once approved: write the tests in `Tests/DSHRemoteKitTests/` (or, for a bug that lives only
>    in a view's rendering, in `Tests/DSHRemoteTests/`) with Swift Testing, each named
>    for its criterion (`@Test("AC1: …")`). Add only the stub signatures in `Sources/` needed to
>    compile — stubs return a wrong value or throw, never `fatalError`. Run `Tools/check.sh --red`
>    until it reports "compiles and fails on assertions", and check each failure matches the
>    plan's prediction. Paste the evidence into the plan's Red evidence section. Commit tests,
>    stubs and plan together as `Tests: <what they pin> (#<n>)`.
>
> You do not implement the behaviour. If a rule lives in the app target, plan a first slice that
> moves it into `DSHRemoteKit`.

### Builder

> You are a **builder** for slice <X> of issue #<n>. Read `AGENTS.md`, `docs/process/WORKFLOW.md`
> (step 3) and `design/plans/issue-<n>-*.md`. Work only on the files your slice lists, in your
> worktree.
>
> Make the slice's tests pass. Loop on `swift test --disable-sandbox --filter <Suite>`; finish with
> `Tools/check.sh --fast` (or `Tools/check.sh` if you touched the app target). Commit in small
> steps with an imperative subject ending `(#<n>)` and a body that says why.
>
> **Never edit, weaken, or delete a line from a `Tests:` commit** — `Tools/guard-tests.sh` will
> fail. You may add tests. If a planner test looks wrong, stop and report why instead of working
> around it. Follow the code conventions in `AGENTS.md`: logic in the kit, writes never retried,
> bounds on anything large, absent is not zero.

### Verifier

> You are the **verifier** for issue #<n>. You did not build it. Read `AGENTS.md`,
> `docs/process/WORKFLOW.md` (step 4), `docs/process/RISK-FLAGS.md` and the plan file.
>
> 1. Run `Tools/check.sh` (full). It must be green.
> 2. For **each** acceptance criterion: undo just its implementation (`git stash`, `git revert
>    --no-commit <sha>`, or re-introduce the bug), run its test, and record the failure. Restore and
>    confirm green. A test that still passes with its fix undone is a finding — report it, do not
>    fix it.
> 3. Check the version-impact claim against `docs/process/RELEASING.md`, and that a line was added
>    under `## [Unreleased]` in `CHANGELOG.md`.
> 4. Write the results into the plan's Verification section and commit as
>    `Verify <what> (#<n>)`.
>
> You do not change production code or planner tests. Report problems; do not repair them.

### Security reviewer

> You are the **security reviewer** for issue #<n>. Read `docs/process/RISK-FLAGS.md` and the
> branch's diff against `main` (`git diff main...HEAD`). For every security flag the diff touches —
> whether or not the plan ticked it — answer that flag's checklist with evidence: a test name, a
> line reference, or a command and its output. Flag anything the plan missed. Your output is the
> answered checklist for the PR description. You change no code.

---

## In Claude Code

Everything above is available as commands and subagents in this repo:

| Command | Does |
|---|---|
| `/feature <n>` | Runs the whole loop for issue `n`: planner, gate, builders in parallel worktrees, verifier, security reviewer, PR. Stops at each human gate. |
| `/bugfix <n>` | The same loop, shaped for a bug: the first test reproduces it. |
| `/release` | Walks [RELEASING.md](RELEASING.md); stops before tagging and pushing. |
| `/check` | Runs `Tools/check.sh` and summarises the result. |

The subagents are `.claude/agents/planner.md`, `builder.md`, `verifier.md` and
`security-reviewer.md`; each one carries the brief above. Builders run with worktree isolation.
Project settings in `.claude/settings.json` allow the build, test and `tea` read commands without
prompting, and always ask before `git push`, `git tag` and merging.

## With other agents

Any agent that reads `AGENTS.md` (most do, by convention) is pointed here. Without
subagents, run the roles one after another in **separate sessions**, each started fresh with its
brief from this file — the separation is what matters, not the tooling. Without the ability to run
shell commands, an agent can still plan and review; the person driving runs `Tools/check.sh`.
