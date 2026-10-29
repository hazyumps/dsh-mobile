# dsh-mobile

An iPhone client for a DeepSeek Harness relay: pair with the harness running on your computer,
then read and drive your sessions from the phone.

Native SwiftUI, iOS 18+, no third-party dependencies. The transport, state and persistence live
in a Swift package (`DSHRemoteKit`) that is testable on its own; the app target is the UI.

<p align="center">
  <img src="design/mockups/2026-10-09/01-home-and-workspaces.png" width="240" alt="Home">
  <img src="design/mockups/2026-10-09/02-conversation-and-recovery.png" width="240" alt="Conversation">
</p>

## Status: development has stopped

This is published as-is, and it works. I built it for my own phone, used it every day, and
stopped because keeping up with a moving harness protocol turned into more than I could carry
alongside a full-time job and other hobbies — not because it is broken or half-finished. `main`
is green and the last device build came from it.

**If you want to pick it up, please do.** Fork it, or open an issue here, and I will answer when
I can. The honest state of the work is in [`NEXT.md`](NEXT.md): what was verified against a live
harness, what was only ever covered by unit tests, what was never tested on a physical device,
and what was deliberately not built. [`AGENTS.md`](AGENTS.md) has the conventions if you want to
work the same way — semantic versioning, tests first, signed commits.

Two things worth knowing before you start:

- **The issue references mean nothing to you.** Every `#123` in a commit message, the changelog
  and the plan files points at a private Gitea instance this repo used to live on. The reasoning
  behind each change is in `design/plans/` and `NEXT.md` instead.
- **The relay is a separate project.** This is the client half; it needs a `dsh-relay` in front
  of a harness to talk to. `Protocol/` holds the endpoint descriptor it was written against, and
  `SPEC.md` §6 records where the two disagreed.

## What works

- **Pairing** with a relay by code or pasted payload, TLS pinned to the host's key, credential
  in the Keychain.
- **Home**: workspaces and sessions from the host's registry, recent cards with real titles and
  live state ("Running", "Needs your input"), a composer that creates a session on first send.
- **Conversation**: bounded live stream, markdown (headings, lists, tables, quotes, code),
  tool and activity rows, older-history paging, inline images and file attachments read back
  from the host, slash commands from the host's own catalogue.
- **Approvals and questions**: cards fed by the host's `$events` waterfalls, answered through
  `$events/result`; the timed-question claim is owned by the conversation screen.
- **Secondary screens**: session-scoped usage, plugin inventory, scheduled tasks (capability
  gated — see *Known gaps*), Settings with a previewable diagnostics export.

## Known gaps

These are real, and they are the reason the issue list is long rather than empty:

- **Not at parity with the desktop app.** The desktop reads a usage ledger (balance, by-model,
  by-day) and a scheduled-tasks service that the relay does not expose to remote clients —
  `schedule/catalog` and `schedule/list` return 404 over the relay, and no usage endpoint exists
  in the descriptor at all. Phone-side screens cannot fix that; the relay has to expose it.
- **Approvals and the timed claim are covered by unit tests only.** No host we have access to
  raises an approval or a timed wait, so those paths have never run against a real one.
- **Physical-device checks outstanding**: the photo and file pickers, background recovery, and
  the timed claim under a lock.

## Building

Requires Xcode 16 or newer (iOS 18 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
# The app project is generated; it is not checked in.
cd Apps/DSHRemote
xcodegen generate
open DSHRemote.xcodeproj
```

`Apps/DSHRemote/project.yml` sets a `DEVELOPMENT_TEAM`, which is the maintainer's. **Set it to
your own team** (or pick one in Xcode's Signing pane) before building for a device — a simulator
build needs no identity.

Tests run without Xcode:

```sh
swift test --disable-sandbox     # the kit suite; Tools/check.sh runs everything
```

`--disable-sandbox` is needed because SwiftPM's manifest cache lives outside the working tree.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/DSHRemoteKit/` | Transport, state stores, persistence, presentation logic. All the testable parts. |
| `Sources/DSHRemoteKit/Generated/` | Protocol models generated from `Protocol/` by `Tools/generate-models.py`. Do not edit by hand. |
| `Apps/DSHRemote/` | The SwiftUI app: screens, design system, debug affordances. |
| `Protocol/` | The relay's endpoint descriptor, schemas and examples, extracted by `Protocol/extract.py`. |
| `Tests/DSHRemoteKitTests/` | The test suite, including fixtures captured from a live host. |
| `design/` | The implementation spec and the UX mockups this app was built against. |
| `Tools/` | Probes, capture scripts and the model generator. |

## Debug affordances

A simulator cannot tap, so interactive paths are reachable by environment variable in debug
builds — `DSH_PAIRING_PAYLOAD`, `DSH_OPEN_HOST`, `DSH_OPEN_SESSION`, `DSH_SESSION_ID`,
`DSH_SEND_MESSAGE`, `DSH_NEW_SESSION_MESSAGE`, `DSH_MODE`, `DSH_MODEL`, `DSH_DESTINATION`,
`DSH_ATTACH`, `DSH_IMAGE`, `DSH_ANSWER`, `DSH_DRAFT`, `DSH_SETTINGS`, `DSH_DIAGNOSTICS`,
`DSH_SCREEN_GALLERY`, `DSH_DESIGN_GALLERY`, `DSH_TRACE`. `Apps/DSHRemote/README.md` describes
each one; `DSH_TRACE=1` with `xcrun simctl launch --console-pty` prints a decisions trace.

## Contributing

Read [AGENTS.md](AGENTS.md) first — it carries the conventions: semantic versioning, test-driven
development with a planner who writes the tests and a builder who passes them, signed commits,
and the rules for working against a real harness. The procedure is in
[docs/process/](docs/process/WORKFLOW.md); new to iOS? Start with the
[primer](docs/process/IOS-PRIMER.md).

```sh
Tools/setup-dev.sh      # once: git hook, signers file, toolchain check
Tools/check.sh          # what "green" means; the pre-push hook runs it
```

Issues are the front door: features, host gaps and papercuts all belong there — in your fork if
you take this somewhere, since the original tracker is gone. If you are changing the transport or
a store, run `swift test` and expect a fixture to be the right place for protocol shapes — several
of them were captured from a live host and the comments say so.

`Tools/setup-dev.sh` wants a signing key and the `.gitsigners` entry to match it, because the
pre-push hook runs `Tools/check.sh` in full. If you would rather not sign, remove your key from
`.gitsigners` and use `git push --no-verify`.

## Licence

MIT — see [LICENSE](LICENSE). The app icon is derived from DeepSeek's logo and is included for
personal builds; fork it with your own mark if you ship it anywhere public.
