Closes #

**Plan:** `design/plans/issue-<n>-<slug>.md`

## What and why

<!-- Two to five sentences: the behaviour before, the behaviour now, and what was rejected. -->

## Red first

<!-- The `Tests:` commit hash, and each test with the failure it showed before the change. -->

| Test | Failure before |
|---|---|
| | |

## Verification

<!-- Done by someone other than the builder: for each acceptance criterion, its fix undone and the
test seen failing. Or link the plan's Verification section. -->

## Risk flags

<!-- From docs/process/RISK-FLAGS.md. For each security flag, paste its checklist answered with
evidence. "None" is an answer. -->

## Version impact

<!-- none / PATCH / MINOR, and the CHANGELOG.md line added under [Unreleased]. -->

## Checks

- [ ] `Tools/check.sh` green in full mode (the pre-push hook ran; not pushed with `--no-verify`)
- [ ] Planner tests untouched by builder commits (`Tools/guard-tests.sh`)
- [ ] Docs updated where behaviour, a `DSH_*` variable or a spec rule changed
