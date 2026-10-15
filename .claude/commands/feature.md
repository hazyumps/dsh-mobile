---
description: Run the plan → red tests → build → verify → PR loop for a gitea issue
argument-hint: <issue number>
---

You are the **orchestrator** for gitea issue #$ARGUMENTS in this repo. The procedure is
`docs/process/WORKFLOW.md`; how to run it with agents is `docs/process/ORCHESTRATION.md`. Read both
now, plus `AGENTS.md`. You coordinate; you do not write production code or tests yourself.

## 0. Orient

- `tea issues $ARGUMENTS --comments` — the issue, its labels, and whether a human has approved a
  plan.
- **Work in the issue's own worktree; never switch the shared checkout's branch.** If the tree is
  dirty, stop and ask. `git fetch origin`, then:
  - Already in a worktree (`git rev-parse --git-dir` ≠ `--git-common-dir`, e.g. from `claude -w`):
    resume `issue-$ARGUMENTS-<slug>` if it is checked out; else, if this branch has no commits of
    its own, `git switch -c issue-$ARGUMENTS-<slug> origin/main` (or `git switch` to it if it
    exists). Anything else: stop and ask.
  - In the shared checkout: `git worktree add .claude/worktrees/issue-$ARGUMENTS-<slug>
    -b issue-$ARGUMENTS-<slug> origin/main` (no `-b` if the branch exists; `git worktree list`
    shows where it is checked out), and use that absolute path for every command and agent.
- Read the branch state and pick the next step from the table in ORCHESTRATION.md ("Where a branch
  is, and who goes next"). Resume from there; do not redo finished steps.

## 1. Plan → human gate

Launch the `planner` agent in **plan** phase with the issue number and branch. When it returns, show
the user: the acceptance criteria, the test list, the slices, the risk flags and the version
impact, with the plan file path. Then **stop and ask the user to approve or change the plan**
(AskUserQuestion). On approval, post `Plan approved: <path>` on the issue
(`tea comments $ARGUMENTS "…"`), only if the user agrees to it being posted.

## 2. Red tests → human gate

Launch the `planner` agent in **tests** phase. When it returns, run `Tools/check.sh --red` yourself
to confirm, and show the user each test name with its failure. **Stop and ask the user to approve
the tests** before any building starts.

## 3. Build

For each slice in the plan (at most three at a time), make its worktree from inside the issue
worktree, so it nests under that worktree's ignored `.worktrees/`:

```sh
git -C <issue worktree> worktree add .worktrees/issue-$ARGUMENTS-<slice> -b issue-$ARGUMENTS-<slice> <issue branch>
```

Launch one `builder` agent per slice **in a single message**, so they run in parallel. Give each:
the issue number, the slice letter and its criteria and files, the plan path, and the absolute
worktree path. When each returns green, merge its branch into the issue branch with `--no-ff` (in
the issue worktree, where that branch is checked out), run `swift test --disable-sandbox`, then
`git worktree remove` and `git branch -d` it. If a builder reports a wrong test or a needed file
outside its slice, or a merge conflicts, stop and ask the user.

## 4. Verify

Launch the `verifier` agent on the issue branch. If the plan ticks any S-flag — or `git diff
main...HEAD` touches a path RISK-FLAGS.md lists — also launch the `security-reviewer` agent, in the
same message. If the verifier finds a criterion NOT guarded, go back to the planner (a new `Tests:`
commit); do not merge around it.

## 5. PR → human gate

Show the user a summary: what changed, the verification table, the security checklist if any, the
version impact, and the `CHANGELOG.md` line. Ask before pushing. Then:

```sh
git push -u origin <issue branch>        # the pre-push hook runs Tools/check.sh; never --no-verify
tea pulls create --base main --head <issue branch> --title "<subject> (#$ARGUMENTS)" \
  --description-file <file following .gitea/pull_request_template.md>
```

Report the PR link. Merging is the human's call: do not merge, tag, or close the issue.
