# AGENTS.md

Conventions for anyone — human or agent — changing this repo. Read this before your first
commit; it is short on purpose, and the parts that look pedantic are the parts that were learned
the hard way.

## Before you commit

```sh
swift test --disable-sandbox                       # 450 tests, 31 suites, no simulator needed

cd Apps/DSHRemote
xcodegen generate                                  # the project is generated, never edited
xcodebuild -project DSHRemote.xcodeproj -scheme DSHRemote \
  -destination 'generic/platform=iOS Simulator' build
```

`--disable-sandbox` is required: SwiftPM's manifest cache lives outside the working tree.

Never hand-edit `Sources/DSHRemoteKit/Generated/` or `Apps/DSHRemote/DSHRemote.xcodeproj/`.
Regenerate them (`Tools/generate-models.py`, `xcodegen generate`) and commit the result.

A change is not done because it compiles. It is done when a test would fail without it.

## Test-driven development

**The planner writes the tests; the builder makes them pass.** Three roles, and the important
part is that they are not the same person's judgement applied twice.

1. **Planner** turns the request into a contract: acceptance criteria, then the tests. Tests land
   **first** and must be shown failing *for the right reason* before implementation starts. The
   failure message is part of the work — `#expect(commands.count == 4)` failing with `0` is
   information; a compile error is not.
2. **Builder** implements until they pass. **The builder does not edit, weaken, or delete the
   planner's tests.** If a test is wrong, say so in the commit or PR and let the planner change
   it. Silently relaxing an assertion is how a suite stops meaning anything.
3. **Verifier** checks the test actually guards something: reinstate the bug (or stash the fix)
   and confirm the test fails. This repo has a precedent — a guard test written for a
   suspected ordering bug **passed with the bug reinstated**, because it asserted values that
   were always consistent by the time it looked. That test was a liability until it was rewritten.

### The one exception

**Discovery work runs the other way.** When you are learning what the host actually does — a new
endpoint, a payload shape, a permission rule — probe first, then pin what you observed in a test
that says so: the capture date, the command, and an excerpt of the answer, as in
`Tests/DSHRemoteKitTests/AttachmentUploaderTests.swift`. Discovery ends in a test; it does not end
in a paragraph of prose.

### Test smells this repo has already paid for

- **No `Task.sleep` to establish that something is "in flight."** Observe the signal instead
  (record the request and wait for the count). A sleep is a bet on the scheduler, and it loses
  under load: that is what made an intermittent, unreproducible failure in this suite.
- **No shared mutable state between tests.** Swift Testing runs them in parallel; two suites
  appending to one singleton sink is a race *between tests*, not a test of the code.
- **Assert on the caller's surface, not the object's internals.** The bug that kept an answered
  question card on screen was invisible to a test that checked the store's own state; it was
  found by watching a subscriber.
- **A fixture captured from a live host must say so**, with the date and the command. Invented
  shapes are how a client ends up correct against a schema and wrong against a server.
- Prefer many small `@Test` cases over one table with a sentence for a name. The name is the
  failure message.

## Versioning: semantic versioning

One version for the whole project — the app and the kit ship together.

- **Single source of truth**: `Apps/DSHRemote/project.yml`.
  `CFBundleShortVersionString` is the semver; `CFBundleVersion` is a monotonically increasing
  integer build number.
- **While `0.x`**, anything that breaks a caller or a saved payload bumps **MINOR**. A `1.0.0`
  says the pairing format, the on-disk state and the public kit API are stable; we are not there.
- **PATCH** for fixes and behaviour-preserving changes. **MINOR** for new behaviour, new screens,
  new endpoints. **MAJOR** for incompatible change — including a change to the persisted formats
  (drafts, host store) that older builds could not read.
- **Build number always increases**, including for a rebuild of an unchanged version:
  `git rev-list --count HEAD` is the honest default.
- A **release** is one commit that bumps the version and carries a signed, annotated tag
  `vX.Y.Z`. No tag without a bump, no bump without a tag.
- Regenerated protocol models count: if a descriptor change alters a decoded shape, that is at
  least a MINOR.
- Documentation-only changes do not bump. The version tracks what the app *is*.

## Commits and pull requests

- Subject in the imperative; body explains **why** — what the bug was, what the trade-off was,
  what was rejected. `Fix timeouts` says nothing; `Stop leaving a spinner where a failure
  belongs` says what changed and what it was before.
- **Sign every commit.** One logical change per commit; plumbing and behaviour in separate
  commits when it helps a reviewer see the behaviour.
- Reference the issue (`#12`). Issues are the front door for features, host gaps and papercuts —
  labels are `relay`, `parity`, `client`, `ux`, `device`, `blocked`.
- If you discovered something you could not fix, write it down — an issue, a comment next to the
  code, or a line in the commit body. A silent near-miss is found again by the next person.

## Code conventions

- **Swift 6, strict concurrency, no third-party dependencies.** The kit is iOS/macOS Foundation
  plus CoreGraphics/ImageIO; the app is SwiftUI.
- **Logic in `DSHRemoteKit`, views in the app target.** If it can be tested without a screen, it
  belongs in the kit — that split is why this suite runs in 0.3 seconds with no simulator.
- **Colour and typography through the design system's semantic tokens**, never inline hex. A new
  surface reuses `DSHPalette`/`DSHMetrics` or adds a token.
- **Cite the spec where a rule comes from it** (`SPEC §8`, `SPEC §10`). Those comments are why a
  later reader can tell a deliberate constraint from an accident — and where the spec turned out
  to be wrong, say so in the comment.
- **Absent is not zero.** A value the host did not report is *unknown*: render nothing, or say so.
  A zero reads as a measurement, and inventing one is a bug, not a nicety. This applies to token
  counts, cache-hit ratios, decode speeds and limits alike.
- **Writes are never retried.** Prompts, uploads, answers, approvals and form submissions go once;
  an uncertain outcome is reported, not replayed. Reads may retry.
- **Bound anything that can be large.** The mux socket dies on an oversized frame, and an
  attachment endpoint hands you the whole file base64-encoded inside one JSON body.
- **Publish state only once its dependencies exist.** A screen's `.task` runs the moment its
  inputs appear; a store or host published one line early is read as `nil` forever.

## Working against a real harness

- `Apps/DSHRemote/README.md` lists the `DSH_*` launch variables, including `DSH_TRACE=1`, which
  prints a decisions trace to `xcrun simctl launch --console-pty`. A simulator cannot tap: when
  you add an interactive path, add an affordance for it rather than verifying by hand once.
- **Host data stays local.** Never commit session logs, screenshots of real sessions, credentials,
  pairing payloads or certificates. Fixtures must be redacted
  (`Fixtures/pairing-claim-response.json` shows the convention).
- **Do not repair host files** — session logs, relay config, DNS, credentials. Those are separate,
  explicitly approved operations, not side effects of a client change.

## Boundaries

- Do not change the relay, the tunnel or the host as part of a client change. If a feature needs
  the relay to expose something, file it under `relay` and say so in the app (an honest "not
  available on this harness" beats a screen that pretends).
- The app icon is derived from DeepSeek's logo. It is here for personal builds; do not present it
  as your own mark, and swap it before shipping anywhere public.
