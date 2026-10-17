---
description: Fix a gitea bug issue test-first — reproduce in a red test, fix, verify, PR
argument-hint: <issue number>
---

**Triage first, before step 0's worktree** (`AGENTS.md`, "Bugs: triage before you fix"). Read the
issue's labels. If origin or priority is missing, propose both, and the cluster check, to the
user, and apply them only once the user agrees. **Stop**, without making a worktree, when the bug
is `priority/P2`/`P3` or `origin/spec-gap` with no human go-ahead on the issue, or when the
cluster check finds three or more related issues (unless it is P0). In those cases report what
you found and what you would label.

Then run `/feature $ARGUMENTS` (read `.claude/commands/feature.md` and follow it), with these
changes for a bug:

- **The first acceptance criterion is the reproduction.** The planner's first test must fail today
  *because of the bug*, and its failure message must show the bug (for example `3 requests sent,
  expected 1`), not merely that something is missing.
- **Look for the bug's siblings.** Ask the planner to search for the same mistake elsewhere — the
  same call pattern, the same missing guard — and list each one as its own criterion or as out of
  scope with a reason.
- **Prevent the class, not the instance**, where it is cheap: if a grep could have caught the bug,
  the plan includes a `Tools/lint.sh` rule (see "Adding a lint rule" in WORKFLOW.md); if an API
  shape made the bug easy (an optional policy parameter), the plan changes the shape.
- **Version impact is PATCH** unless fixing it changes a persisted format or a public API, which the
  plan must say.
- **Root cause is in the plan before any test.** If the planner cannot name it, stop and bring that
  to the user instead of planning a patch.
- **The PR carries** the root cause, the origin, the production size (and why, if it grew by more
  than ~50 lines), the issues filed along the way, and a "For a reviewer new to Swift" section.
- One plan is usually one slice; that is fine. The two human gates still apply.
