Closes #

**Plan:** `design/plans/issue-<n>-<slug>.md`

## What and why

<!-- Two to five sentences: the behaviour before, the behaviour now, and what was rejected. -->

## Root cause and origin

<!-- Bugs only; otherwise "n/a". The root cause in one sentence, and the origin label:
pre-existing, a regression from PR #…, or a spec gap (which should not reach a PR). -->

## Size

<!-- Production lines added/removed: git diff --shortstat main...HEAD -- Sources Apps
':!Sources/DSHRemoteKit/Generated'. If they grow by more than ~50, say why. -->

## Found along the way

<!-- Issues filed during this work and not fixed here, as links. "None" is an answer. -->

## For a reviewer new to Swift

<!-- What to look at closely, in plain words: concurrency (async/await, actors, @MainActor),
SwiftUI state, object lifetimes. A Python analogy where one fits. -->

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
- [ ] Nothing outside the issue's scope fixed here; anything found is filed and linked above
