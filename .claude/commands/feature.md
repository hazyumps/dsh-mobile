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
- **Work in a worktree of your own; never switch the branch of the shared checkout**, where someone
  else may be working (WORKFLOW.md, "Several issues at once"). If the working tree is dirty, stop
  and ask. Then `git fetch origin`, and find out where you are:
  `git rev-parse --path-format=absolute --git-dir --git-common-dir` prints two paths.
  - **Two different paths: you are in a linked worktree** (for example one `claude -w` made).
    - If an `issue-$ARGUMENTS-<slug>` branch is checked out here, resume on it. (A one-letter
      `issue-$ARGUMENTS-<slice>` branch is a builder's slice, not the issue branch.)
    - Otherwise, if this branch has no commits beyond `origin/main`
      (`git rev-list --count origin/main..HEAD` prints 0), switch here:
      `git switch -c issue-$ARGUMENTS-<slug> origin/main`, or `git switch issue-$ARGUMENTS-<slug>` if
      `git branch -a --list "*issue-$ARGUMENTS-*"` shows it already exists. The branch you leave,
      the one `claude -w` made, may be deleted with `git branch -d`.
    - Anything else: stop and ask.
  - **The same path twice: you are in the shared checkout.** Leave its branch alone and make a
    worktree:
    `git worktree add .claude/worktrees/issue-$ARGUMENTS-<slug> -b issue-$ARGUMENTS-<slug> origin/main`.
    - If the branch already exists, the same without `-b`:
      `git worktree add .claude/worktrees/issue-$ARGUMENTS-<slug> issue-$ARGUMENTS-<slug>`.
    - If it is already checked out somewhere, `git worktree list` says where; continue there.
    - From then on, use that worktree's absolute path for every command (`git -C <path>`, or
      `cd <path> && …`), every agent you launch and every slice worktree.
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
