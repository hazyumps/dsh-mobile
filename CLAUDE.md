@AGENTS.md

## Claude Code in this repo

The rules above apply to Claude exactly as to anyone else. The procedure is in `docs/process/`,
and everything Claude-specific is also described there (`docs/process/ORCHESTRATION.md`), so other
agents and humans can follow the same steps.

- **Commands:** `/feature <issue>` runs plan → red tests → parallel builders → verify → PR, stopping
  at both human gates; `/bugfix <issue>` is the same, reproduction-first; `/release` walks
  `docs/process/RELEASING.md` and stops before tagging; `/check` runs `Tools/check.sh` and
  explains it.
- **Agents:** `planner`, `builder`, `verifier`, `security-reviewer` in `.claude/agents/`. Each one's
  brief is a section of `docs/process/ORCHESTRATION.md`; change the brief there, not in the agent
  file.
- **Several issues at once:** each issue runs in its own git worktree. Start a session per issue
  with `claude -w issue-<n>` (or let `/feature`/`/bugfix` make one under `.claude/worktrees/`), and
  never switch branches in the shared checkout, which stays on `main`. What the worktrees still
  share — the test simulator's lock (a check may wait), the review simulator (one at a time),
  `git stash`, `CHANGELOG.md` merges, the cold first build, cleanup — is in WORKFLOW.md, "Several
  issues at once".
- Never `git push --no-verify`, never merge to `main`, never push a tag, never close an issue by
  hand — those belong to a human (`docs/process/ORCHESTRATION.md`, "Principles").
- `Tools/check.sh` in full mode builds the app twice and can take several minutes cold; give it a
  long timeout rather than falling back to `--fast` before a push.
- Explain iOS-specific causes in a sentence when they come up; `docs/process/IOS-PRIMER.md` is the
  shared vocabulary.
