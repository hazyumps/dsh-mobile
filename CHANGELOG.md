# Changelog

What changed in each version of DSH Remote (the app and DSHRemoteKit ship together). The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow semantic
versioning as described in `docs/process/RELEASING.md`.

Every PR that a user could notice adds a line under **Unreleased**, in one of Added / Changed /
Fixed / Security, with its issue number. The release renames the section.

## [Unreleased]

### Fixed
- A Release build compiles again; it had been failing on a debug-only trace helper (#64).
- Assistant replies no longer lose the left edge of their first and last letters (#74).
- A parked connection recovers: returning to the app makes one fresh attempt, where a refusal
  used to stop every later attempt until the app was relaunched (#26).
- A slow or failed request no longer rebuilds the connection, so the status chip stops flickering
  on a connection that is working (#82).
- Forgetting a host is saved: it no longer comes back, without its credential, after a relaunch,
  and its drafts and the selected host's staged files and commands go with it. A forget that
  could not be saved keeps the host and says so (#65).

### Added (process, no version impact)
- A written workflow and local CI: `docs/process/`, `Tools/check.sh` with a pre-push hook, a
  coverage ratchet, issue and PR templates, and Claude Code agents and commands (#62).
- An app unit-test target, `Tests/DSHRemoteTests/`, for render tests of view-level bugs;
  `Tools/check.sh` runs it on its own "DSH Remote Tests" simulator, and `--red` judges it with the
  kit suite (#74).
- Several issues can run at once, each in its own worktree: `Tools/check.sh` runs the app tests for
  one checkout at a time, `/feature` and `/bugfix` start in a worktree, and `Tools/setup-dev.sh`
  repairs absolute hook and signer paths (#77).

## [0.2.0] - 2026-10-13

### Added
- Navigation rework: the harness panel in the drawer, and Home organised by project; new-session
  and project screens; settings rewritten (#61).
- Scheduled-task notifications on the phone: the `scheduledTasks` namespace is read, and a local
  reminder opens the right screen (#54). *This was a MINOR change by the rules and shipped without
  its own bump; it is first versioned here.*

### Fixed
- An undecodable mux frame is named by its shape instead of killing the socket silently (#55).
- Phone-layout fixes: composer and keyboard, drawer spacing and footer, attachment button (#33,
  #35, #37, #39, #41, #43, #45, #47, #50, #52). *Shipped without PATCH bumps.*

### Notes
- The `v0.2.0` tag sits on `d3220ac`, whose committed `Info.plist` still said `0.1.0` (build 1);
  it was caught up in `8ab6b3d`. The tag is left in place; `Tools/check-version.sh` now prevents a
  repeat. See `docs/process/RELEASING.md`, "The history, honestly".

## [0.1.0]

The first ~200 commits, before versioning was a rule: the kit (pairing with SPKI pinning, the
relay transport and mux socket, generated protocol models, drafts and host storage), and the
SwiftUI app with conversations, approvals and questions, attachments and images. There is no tag.
