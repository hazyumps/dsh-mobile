---
description: Cut a release by docs/process/RELEASING.md — version bump, changelog, plist, release PR; stops before tagging
argument-hint: [X.Y.Z, optional — otherwise proposed from the changelog]
---

Follow `docs/process/RELEASING.md`, "Cutting a release", step by step. Read it now.

1. `git checkout main && git pull --ff-only`. If the tree is dirty or `main` diverged, stop.
2. Run `Tools/check.sh`. If it is red, stop: a release does not start from red.
3. Read `## [Unreleased]` in `CHANGELOG.md` and the merged PRs since the last tag
   (`git log --merges --oneline $(git describe --tags --abbrev=0)..HEAD`). Propose the version
   ($ARGUMENTS if given) using the table in RELEASING.md, and show the user the changelog section
   you will publish — including anything merged that has no changelog line. **Ask the user to confirm
   the version and the text.**
4. On a branch `release-X.Y.Z`: set `CFBundleShortVersionString` and `CFBundleVersion` in
   `Apps/DSHRemote/project.yml` (build = `git rev-list --count HEAD` + 1), run
   `xcodegen generate` in `Apps/DSHRemote`, update `CHANGELOG.md`, run `Tools/check.sh`, and commit
   exactly those three files as `Release X.Y.Z`, signed.
5. **Ask before pushing.** Push and open the PR with `tea pulls create --base main -L release`.
6. Stop. Tell the user the remaining steps, which are theirs: merge (prefer rebase / fast-forward),
   then `git tag -s vX.Y.Z -m "…"`, `git tag -v vX.Y.Z`, `Tools/check-version.sh`, and
   `git push origin vX.Y.Z`. Offer to run them only after the merge, and only one at a time with
   confirmation.
