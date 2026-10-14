# Versioning and releases

One version for the whole project — the app and the kit ship together. The rules in
`AGENTS.md` ("Versioning") are the contract; this file is how to apply them.

## Where the version lives

| | |
|---|---|
| `Apps/DSHRemote/project.yml` → `CFBundleShortVersionString` | **The version**, `X.Y.Z`. Single source of truth. |
| `Apps/DSHRemote/project.yml` → `CFBundleVersion` | **The build number**: a positive integer that only goes up. |
| `Apps/DSHRemote/Info.plist` | Generated from `project.yml` by `xcodegen generate`, but committed. Must match; `Tools/check-version.sh` fails if it does not. |
| `CHANGELOG.md` | What changed, per version. |
| A signed, annotated tag `vX.Y.Z` | On the commit that sets that version. |

*iOS background:* the App Store and TestFlight show `CFBundleShortVersionString` to people and
use `CFBundleVersion` to tell uploads apart — an upload whose build number is not higher than the
last one for that version is rejected. That is why the build number only ever goes up, even for a
rebuild of the same version.

## Which number moves

While the version is `0.x`, semver allows anything to change, so a **breaking** change bumps
**MINOR** (not MAJOR). `1.0.0` is a promise that the pairing format, the on-disk state and the
public kit API are stable; we are not there.

| The change | Bump while 0.x | From 1.0 |
|---|---|---|
| A bug fix, a hardening fix, a refactor with no visible behaviour change | PATCH | PATCH |
| A new screen, a new endpoint used, new user-visible behaviour | MINOR | MINOR |
| A persisted format (`hosts.json`, drafts, navigation, Keychain layout) changes — with a migration | MINOR | MINOR (MAJOR if old data cannot be read) |
| The pairing payload format, or a public kit API that callers use, changes incompatibly | MINOR | MAJOR |
| Regenerated protocol models that change a decoded shape | MINOR | MINOR / MAJOR |
| Docs, tests, tooling only | none | none |

A persisted-format change **must** ship with a migration and a test that reads the old format
(RISK-FLAGS.md, C1). The bump does not excuse losing a user's drafts.

**Each PR states its version impact** (the template asks). **The PR does not bump the version**;
it adds a line to `## [Unreleased]` in `CHANGELOG.md`, under Added / Changed / Fixed / Security.
The release decides the number from what has accumulated: any MINOR line makes it a MINOR release.

## Cutting a release

A release is one commit that bumps the version, plus a signed annotated tag on that commit. No tag
without a bump, no bump without a tag.

> Claude Code: `/release` walks this checklist and stops before tagging and pushing.

```sh
git checkout main && git pull --ff-only
Tools/check.sh                                          # green, full mode, before anything else

# 1. Decide X.Y.Z from CHANGELOG.md [Unreleased] and the table above.
# 2. Build number: the commit count, which only goes up.
build=$(( $(git rev-list --count HEAD) + 1 ))           # +1: the release commit itself
# 3. Edit Apps/DSHRemote/project.yml: CFBundleShortVersionString "X.Y.Z", CFBundleVersion "$build"
# 4. Regenerate the plist so it lands in the same commit.
(cd Apps/DSHRemote && xcodegen generate)
# 5. CHANGELOG.md: rename "## [Unreleased]" to "## [X.Y.Z] - YYYY-MM-DD", start a new empty
#    "## [Unreleased]" above it.
Tools/check.sh                                          # check-version now sees the new version

git checkout -b release-X.Y.Z
git add Apps/DSHRemote/project.yml Apps/DSHRemote/Info.plist CHANGELOG.md
git commit -m "Release X.Y.Z" -m "<one paragraph: what this version is>"
git push -u origin release-X.Y.Z && tea pulls create --base main --title "Release X.Y.Z" -L release
# After the PR merges. Prefer gitea's "Rebase then fast-forward" for a release PR, so the tag
# sits on the release commit itself; if it was merged with a merge commit, tag the merge. Either
# way, Tools/check-version.sh on the tagged commit must pass (it checks HEAD's tag).
git checkout main && git pull --ff-only
Tools/check-version.sh
git tag -s vX.Y.Z -m "X.Y.Z: <summary>"                 # signed and annotated
git tag -v vX.Y.Z                                       # verifies against .gitsigners
git push origin vX.Y.Z
```

A release PR changes only those three files and needs no plan or tests: the check is the test.

## Hotfixes

A fix for a released version that cannot wait for the next one: branch from the tag
(`git checkout -b issue-<n>-hotfix vX.Y.Z`), fix it through the normal workflow, release
`X.Y.(Z+1)` from that branch, then merge the branch into `main`.

## The history, honestly

The rules above were written on 2026-10-09 and were not followed consistently at first. Recorded
here, and in `CHANGELOG.md`, rather than rewritten:

- About 200 commits shipped as `0.1.0` (build 1) before versioning was a rule.
- #54 (scheduled-task notifications, merged in PR #57) was a MINOR change by these rules and did
  not bump; its own spec (`design/PUSH-NOTIFICATIONS-SPEC.md` §8) said it should. The bug fixes
  #33–#52 and #55 were PATCH changes and did not bump either.
- `v0.2.0` was tagged on `d3220ac`, a merge whose `Info.plist` still said `0.1.0` (build 1); the
  plist was caught up three minutes later in `8ab6b3d`. The bump itself is in `5bc826f`, so the
  tag is not on the bump commit.

`v0.2.0` stays where it is. Moving a published tag breaks every clone that fetched it, which is
worse than the drift. `Tools/check-version.sh` now makes each of these fail before it can be
pushed.
