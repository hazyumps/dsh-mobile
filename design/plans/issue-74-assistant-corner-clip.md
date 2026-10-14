# Issue #74: Assistant messages lose the first letter of their first and last lines

**Status:** approved (Dan, 2026-10-14, in a Claude Code session; the content was approved before it
was transcribed here, and is not yet recorded as a "plan approved" comment on #74). The planner
raised questions while transcribing. The orchestrator resolved them the same day, consistent with
Dan's intent, and will show Dan the changes at the tests gate (see "Questions raised at
transcription, and their resolutions").
**Branch:** `issue-74-assistant-corner-clip`
**Version impact:** PATCH. A user-visible fix with no change to a persisted format, the pairing
format or the public kit API (`docs/process/RELEASING.md`). The test-target plumbing is process
only and has no version impact of its own.

## Context

On the phone, the first glyph of an assistant reply ("The" reads as "ſhe") and the first glyph of
its last line ("no" reads as "ɿo") are shaved on the left. The cause is in `MessageRow`
(`Apps/DSHRemote/Sources/ConversationTranscript.swift:366-368`). It applies
`.clipShape(RoundedRectangle(cornerRadius: DSHMetrics.cardCornerRadius /* 16 */, style: .continuous))`
to **both** roles, but only the user bubble gets padding (`spaceCard`, 12pt). Assistant prose has
no padding, so the invisible 16pt corner cuts into whatever glyph sits in the top-left and
bottom-left corners. The clip has been there since `e28db72` (2026-10-09).

This bug was reported before, as item 4 of the closed #33, and was closed as "could not reproduce".
That check used the screens-gallery fixture (`ScreensGalleryView.swift:64`), which never puts a
straight-edged glyph in a clipped corner. The long reply opens with the Reasoning row and ends with
a `---` rule; the one-line reply starts with a round "C". The screenshot from the phone shows a
real session, so it is not attached to the issue (host data stays local).

Outcome: assistant prose is never clipped, user bubbles look exactly as they do now, and a render
test fails if the clip comes back.

### Decisions already made (Dan, 2026-10-14): not to be reopened

1. **The tests go in a new iOS app unit-test target, `Tests/DSHRemoteTests/`, and the behaviour is
   not moved into the kit.** This departs from `docs/process/WORKFLOW.md` step 2 rule 5 and from
   the planner brief in `docs/process/ORCHESTRATION.md` ("plan a first slice that moves it into
   `DSHRemoteKit`"). The reason: the bug is a SwiftUI modifier (`.clipShape`) on the view. A
   kit-level flag test would still pass with the `.clipShape` put back on the view. That is the
   "guard that passed with the bug reinstated" precedent in `AGENTS.md`, and only rendering the
   real view catches it. The target lives under top-level `Tests/` so `Tools/guard-tests.sh`,
   which watches `Tests/` only, protects the planner's lines. A lint rule was rejected for the same
   reason: a grep for `.clipShape` cannot tell padded content from unpadded content.
2. **The test-target plumbing ships on this branch, as its own commit, before the `Tests:`
   commit (Slice A, built by a builder)**, rather than as a separate issue. The red tests cannot
   compile without the target, a stub in `Sources/` cannot create a target, and `Tools/check.sh
   --red` has to understand an app suite before it can judge the `Tests:` commit. So the order on
   this branch differs from the branch-state table in `ORCHESTRATION.md`:

   ```
   Plan ─▶ [gate 1: plan] ─▶ Slice A (builder) ─▶ Tests: (planner) ─▶ [gate 1: tests]
        ─▶ Slice B (builder) ─▶ verifier ─▶ PR ─▶ [gate 2]
   ```

## Acceptance criteria

- **AC1** (the reproduction): in an assistant message, the glyph at the start of the first line
  is drawn whole. `MessageRow` for an assistant message whose first line starts with "T" puts at
  least as much ink in its top-left `cardCornerRadius` (16pt) square as the same text drawn by
  `MessageBody` alone.
- **AC2**: in an assistant message, the glyph at the start of the last line is drawn whole. The
  same comparison for the bottom-left 16pt square, with a last line that starts with "n".
- **AC3** (scope guard, green before and after): a user message still sits in a filled bubble with
  rounded corners. In the bounds of the user row's ink (the bubble fill), the corner pixel is
  transparent and the pixel at `(left + cardCornerRadius, top + 1pt)` is filled. This catches a
  fix that drops the rounding along with the clip.
- **AC4**: `DSH_SCREEN_GALLERY=conversation` shows an assistant message with no reasoning whose
  first line starts with "T" and whose last line starts with "n", both lines well over 32pt wide,
  so the corners can be reviewed by eye. This closes the gap that made #33 item 4 unreproducible.
- **AC5**: `Tools/check.sh` runs the app tests.
  - **Full mode** has an "app tests" step after the Debug and Release builds. It runs `xcodebuild
    build-for-testing`, then `test-without-building` on a simulator, so a compile error and a
    failing test give different messages.
  - **Simulator choice:** `DSH_TEST_SIMULATOR` if it is set. Otherwise a **dedicated** simulator
    named "DSH Remote Tests":
    - `xcrun simctl create` makes it on the first run, from an available iPhone device type and
      the newest installed iOS runtime;
    - later runs reuse it;
    - it is never the first available simulator, or any simulator used for review.

    If `DSH_TEST_SIMULATOR` names no available device, or no iOS runtime or iPhone device type is
    installed, the check fails with a hint.
  - **`--red`** accepts a `Tests:` commit when the kit tests and the app test target both
    **compile**, nothing crashes, and **at least one** of the two suites fails on assertions. It
    reports "every test passed" only when both suites pass.
  - **`--fast`** is unchanged and needs no simulator.

## Test list

| AC | Suite / file | Test name | Fails today because |
|---|---|---|---|
| AC1 | `MessageRowRenderTests`, `Tests/DSHRemoteTests/MessageRowRenderTests.swift` | `@Test("AC1: assistant prose keeps its top-left corner") func assistantProseKeepsItsTopLeftCorner()` | The row's 16pt continuous `clipShape` removes the top-left of the "T". Expected message: "the assistant row lost N px of ink in its top-left 16pt corner (row M, unclipped K)". A scratch macOS probe with this sample measured 69 px lost at scale 3; the iOS number will differ. |
| AC2 | same | `@Test("AC2: assistant prose keeps its bottom-left corner") func assistantProseKeepsItsBottomLeftCorner()` | The same clip removes the lower left of the "n"'s stem. Same message shape, for the bottom-left corner. The probe measured 70 px lost. |
| AC3 | same | `@Test("AC3: a user bubble keeps its rounded, filled corners") func userBubbleKeepsItsRoundedCorners()` | **Does not fail today, by design.** It is the scope guard. The verifier proves it guards something by replacing the bubble's rounded fill with a square one (see Verification). |
| AC4 | none (by eye, per risk flag C6) | none | Today the gallery has no assistant message with a straight-edged glyph in either corner. Checked by eye: `SIMCTL_CHILD_DSH_SCREEN_GALLERY=conversation xcrun simctl launch …`, then `xcrun simctl io booted screenshot`. At 3× magnification the "T" and "n" of the new message have full left edges. The screenshot is shown to Dan, not committed. |
| AC5 | none (tooling, verified by probes as in #62) | none | Today `Tools/check.sh` has no app-tests step, and `--red` judges the kit suite only, so a `Tests:` commit whose only failures are in an app suite reports "every test passed". The probes are under Verification. |

Not a planner test: `Tests/DSHRemoteTests/AppTestTargetTests.swift` is written by the Slice A
builder. It has one smoke `@Test` that renders `MessageBody` from the hosted bundle and gets a
non-empty image. It is green from the start and proves the plumbing before any red test exists.
No `Tests:` commit touches it, so `Tools/guard-tests.sh` does not cover it.

**How the planner tests work** (the approved design, with the sample text changed by resolution
1). Swift Testing, with the suite `@MainActor` because `ImageRenderer` is main-actor. The helpers
live in the test file, so the guard covers them:

- `render(_:width:)` uses `ImageRenderer` with `proposedSize` width 320, `scale` 3 and a dark color
  scheme, and returns a `CGImage`.
- `ink(in:of:)` counts the pixels with alpha > 0 in a rectangle given in points.
- The sample text is `"The step ended.\n\nno more frames."`. It has two paragraphs: the first
  starts with a straight-edged "T" in the top-left corner, the last starts with the stem of an "n"
  in the bottom-left corner, and both lines are much wider than `2 × cardCornerRadius` (32pt).
  - The approved sample was `"T\n\nn"`. It was replaced because its box is too narrow: SwiftUI
    shrinks the corner radius to half the shorter side, and then the clip cuts nothing.
  - The reference image is the bare `MessageBody(text:)` at the same width. It has the same origin
    and height as the assistant row's content.
- **Preconditions.** AC1 and AC2 each start with two `#require`s, so that neither a font change nor
  an edit to the sample can make them pass without testing anything:
  - `#require(referenceInk > 0, "the sample no longer puts a glyph in the <top|bottom>-left corner")`
  - `#require(referenceWidth > 2 * DSHMetrics.cardCornerRadius, "the sample is too narrow to be
    clipped: SwiftUI shrinks a corner radius to half the shorter side")`

  A third `#require`, added when the tests were written, checks the design's own premise: the row
  is exactly as tall as its text alone. Otherwise the two bottom-left squares would not line up.
  Then `#expect(rowInk >= referenceInk, "<message above>")`.

Fakes: none; nothing here touches the network or storage. Stubs in `Sources/`: none.
`MessageRow` becomes internal in Slice A (a visibility change, not a stub), and `MessageBody` is
already internal.

Expected `Tools/check.sh --red` on the `Tests:` commit: the kit suite passes, AC1 and AC2 fail on
their assertions, and AC3 and the smoke test pass. Result: "red: ok".

## Slices

The two slices run **in sequence, not in parallel**. Both touch `ConversationTranscript.swift` and
`CHANGELOG.md`, and Slice B cannot start until the `Tests:` commit is approved, which itself needs
Slice A.

| Slice | ACs | Files | Notes |
|---|---|---|---|
| A | AC5, and it makes AC1–AC3 compilable | `Apps/DSHRemote/project.yml`, `Tools/check.sh`, `Tools/setup-dev.sh`, `Apps/DSHRemote/Sources/ConversationTranscript.swift` (`MessageRow`: `private` → internal, nothing else), `Tests/DSHRemoteTests/AppTestTargetTests.swift`, `AGENTS.md`, `docs/process/WORKFLOW.md`, `docs/process/IOS-PRIMER.md`, `docs/process/ORCHESTRATION.md`, `docs/process/RISK-FLAGS.md`, `CHANGELOG.md`; `Package.swift` only if SwiftPM complains | Builder, **after plan approval and before the `Tests:` commit**. Commit: "Give the app a test target, and run it in Tools/check.sh (#74)". |
| B | AC1, AC2, AC4 (AC3 must stay green) | `Apps/DSHRemote/Sources/ConversationTranscript.swift` (`MessageRow` background, clip, doc comment), `Apps/DSHRemote/Sources/ScreensGalleryView.swift` (`conversationFixture`), `CHANGELOG.md` | Builder, after the tests are approved. Commit: "Stop clipping assistant prose to a bubble it does not draw (#74)". |

### Slice A: the app test target

- **`Apps/DSHRemote/project.yml`:** a new target, `DSHRemoteTests`:
  - `type: bundle.unit-test`, `platform: iOS`, sources `../../Tests/DSHRemoteTests`;
  - dependency `target: DSHRemote`, so the bundle is hosted in the app;
  - `GENERATE_INFOPLIST_FILE: YES`, bundle id `net.fernlabs.dshremote.tests`;
  - a scheme `test:` action that lists it.

  Its plist is generated and not committed. `Tools/check-version.sh` checks only the app's plist,
  so it is unaffected.
- **`ConversationTranscript.swift`:** `MessageRow` goes from `private` to internal, so
  `@testable import DSHRemote` can render it.
- **`Tests/DSHRemoteTests/AppTestTargetTests.swift`:** the smoke test described above.
- **`Tools/check.sh`:**
  - the simulator choice (AC5): `DSH_TEST_SIMULATOR` if set, otherwise find or create the
    dedicated "DSH Remote Tests" simulator. It parses the `simctl` JSON with `python3 -I`.
  - the full-mode "app tests" step;
  - the `--red` logic across both suites;
  - `--fast` unchanged;
  - the header comment updated. It names `DSH_TEST_SIMULATOR` and says the dedicated simulator is
    for the tests only (see "Why a dedicated simulator" below).
- **`Tools/setup-dev.sh`:** check that an iOS simulator runtime and an iPhone device type are
  installed, which is what creating the dedicated simulator needs.
- **Docs, one line each:**
  - `AGENTS.md` "Before you commit": what `check.sh` runs, and that CI now needs a simulator
    runtime.
  - `WORKFLOW.md` "Local CI": an "App tests" row in the table, the inner-loop command
    `xcodebuild test … -only-testing:DSHRemoteTests`, and a note that "DSH Remote Tests" is the
    tests' own simulator and is not for review or pairing.
  - `WORKFLOW.md` step 2 rule 5 ("Kit, not app"): rules go in the kit, and a view-level bug
    gets a render test in `Tests/DSHRemoteTests`. This replaces "the app has no test target on
    purpose".
  - `IOS-PRIMER.md`: the table's app "Tests" cell names the render-test target. The paragraph
    citing #30 says the app now has a unit-test target for render tests, and that the UI-test
    target for gestures is still #30.
  - `ORCHESTRATION.md`, the planner brief: tests go in `Tests/DSHRemoteKitTests/`, or for a bug
    that lives only in a view's rendering, in `Tests/DSHRemoteTests/`; the "move it into
    `DSHRemoteKit`" sentence is kept for rules.
  - `RISK-FLAGS.md` C6: when a rule cannot move into the kit, a render test in
    `Tests/DSHRemoteTests` is the alternative, alongside the `DSH_*` affordance.
  - `.claude/agents/planner.md` was checked and needs no change: it points at the brief in
    `ORCHESTRATION.md` and repeats none of the text that changes. The same is true of the other
    files in `.claude/`.
- **`CHANGELOG.md`:** a line under `### Added (process, no version impact)`.
- **Why a dedicated simulator.** The test bundle is hosted in the real app, and the app's
  `.task` calls `model.restoreLastHost()` on launch. So a host paired on the test simulator would
  be reconnected on every `Tools/check.sh` run. The first available simulator on this machine
  ("iPhone 18 Pro") is the one the primer uses for `DSH_*` review, where a host may be paired.
  That is why the tests get a simulator of their own, documented as not for review, and why
  there is no production change to skip launch work under tests.
- **Validate:**
  - `swift build --disable-sandbox --build-tests` ignores `Tests/DSHRemoteTests`, which
    `Package.swift` does not declare. If SwiftPM complains, add an `exclude`.
  - The full `Tools/check.sh` is green.

### Slice B: the fix

- **`MessageRow`:** remove `.background(... Color.clear)` and `.clipShape(...)`, and replace them
  with:

  ```swift
  .background {
      if message.role == .user {
          RoundedRectangle(cornerRadius: DSHMetrics.cardCornerRadius, style: .continuous)
              .fill(DSHPalette.elevatedSurface)
      }
  }
  ```

  Keep the role-conditional `.padding`. Update the doc comment to say that prose sits on the canvas
  and is never clipped. Nothing relied on the row's clip: user-bubble content is already 12pt
  inside the corner, and image thumbnails clip themselves (`AttachmentThumbnail.swift:23`).
- **`ScreensGalleryView.conversationFixture`:** add an assistant message with no reasoning whose
  first line starts with "T" and whose last line starts with "n", both lines well over 32pt wide
  (AC4). A short line would let SwiftUI shrink the corner radius and hide the clip, which is
  resolution 1.
- **`CHANGELOG.md`:** under `### Fixed`, "Assistant replies no longer lose the left edge of their
  first and last letters (#74)."

## Risk flags

- [ ] none
- [ ] S1–S10: none ticked. The ones I considered:
  - **S7 (debug affordances):** Slice B edits a fixture that is reached only through
    `DSH_SCREEN_GALLERY`, whose read is already inside `#if DEBUG` (`AppModel.swift`). It adds no
    app variable, no environment read in Swift and nothing new under `#if DEBUG`.
    `DSH_TEST_SIMULATOR` is read only by `Tools/check.sh`, never by the app, so it is not a
    launch variable. It does not belong in `Apps/DSHRemote/README.md`, and `Tools/lint.sh`, which
    scans `*.swift` under `Apps/`, does not see it.
  - **S8 (permissions):** Slice A edits `project.yml` but not the app's `info:` keys or
    entitlements. The test bundle's plist is generated.
  - **S9 (leaving the sandbox):** nothing is logged or exported, and rendered images stay in
    memory.
- [x] **C6 UI with no kit test.** The behaviour lives only in a SwiftUI view modifier and cannot
  move, because the kit cannot import SwiftUI (Decision 1). Instead of a kit test there is an app
  render test, plus the existing `DSH_SCREEN_GALLERY=conversation` affordance with a new fixture
  message (AC4), checked by eye and recorded under Verification.
- [ ] **C3 (concurrency), considered:** the test suite is `@MainActor` because `ImageRenderer` is.
  There is no production concurrency change and no `Task.sleep`.
- [ ] **C4 (device-only), considered:** this is layout, which the simulator renders faithfully.
  Checking on the phone is optional (Verification).

## Out of scope

- Moving the clip rule into the kit, and a lint rule: both rejected under Decision 1.
- XCUITest and gesture tests. Those are #30, which stays open: this branch adds a hosted
  *unit*-test bundle, not the UI-test target #30 asks for. #30 can sit beside it.
- Every other clip in the app (see "Siblings checked").
- Attaching the original screenshot: it shows a real session.

## Siblings checked

The bugfix rule is to look for the same mistake elsewhere. The approved plan found that every other
`.clipShape` around text pads its content by at least the depth of the corner, so they are out of
scope:

- the code block (`ConversationTranscript.swift:478`: 12pt padding, 12pt radius);
- the table (`:601`: 4pt radius, padded cells);
- command suggestions (`ConversationView.swift:468`);
- `DecisionCard.swift:165`;
- `ProjectSessionsView.swift:108` and `:125`;
- `DrawerView.swift:111`;
- `Composer.swift:177`;
- every `.dshCard()` caller (`DSHCardBackground`, `DSHPrimitives.swift:44`). Each one pads
  `spaceCard` first, and `ToolCard` pads its parts.

`MessageRow` is the only clip with zero padding by design.

The planner also checked the clips the list above does not name. None of them cuts text:

- **Capsule chips** (`ConversationView.swift:414`, `HomeView.swift:378/384`,
  `DSHPrimitives.swift:91`, `ModelModeControls.swift:226`, `Composer.swift:222`): their padding is
  sometimes less than the radius, but the content is centred vertically, where a capsule's edge is
  vertical.
- **Image and icon clips** (`ConversationView.swift:345`, `AttachmentThumbnail.swift:23`,
  `HomeView.swift:365`, `Composer.swift:137`): clipping the image is the intent.
- **The "HARNESS" badge** (`DSHPrimitives.swift:250`): a 4pt radius with 6pt horizontal padding.
- **The design gallery** (`ComponentGalleryView.swift:113/174`): debug-only. The rows are at least
  44pt tall with their content centred, so no glyph reaches the 16pt corner.

## Questions raised at transcription, and their resolutions

The planner raised these while transcribing the approved plan (2026-10-14). The orchestrator
resolved them the same day, consistent with Dan's intent, and will show Dan the changes at the
tests gate.

1. **The approved sample `"T\n\nn"` did not reproduce the bug.** This blocked AC1 and AC2.
   - **Why:** `MessageRow`'s VStack is as wide as its text, and SwiftUI limits a rounded
     rectangle's corner radius to half its shorter side. With "T" and "n" the clipped box is about
     10pt wide, so the effective radius is about 5pt and no glyph pixel falls outside it.
   - **Measured:** a scratch probe used macOS SwiftUI `ImageRenderer` to mimic the assistant
     branch of `MessageRow`, at 17pt, width 320 and scale 3. It ran in the git-ignored `.build/`
     and was deleted afterwards. It counted pixels with alpha > 0 in the 16pt corner squares,
     clipped and unclipped:

     | Sample | Top-left, clipped / unclipped | Bottom-left, clipped / unclipped |
     |---|---|---|
     | `"T\n\nn"` | 359 / 359 | 392 / 392 |
     | `"The\n\nno"` | 588 / 641 | 615 / 668 |
     | `"The step ended.\n\nno more frames."` | 572 / 641 | 598 / 668 |

     With the approved sample, AC1 and AC2 would have passed with the bug present, and
     `Tools/check.sh --red` would have said "every test passed".
   - **Resolved:** the sample becomes `"The step ended.\n\nno more frames."`. Each corner test
     requires `referenceInk > 0` and a reference wider than `2 * DSHMetrics.cardCornerRadius`, with
     messages that say the sample no longer reaches the corner or is too narrow to be clipped. The
     AC4 gallery message gets the same care. Updated in AC4, the test list and Slice B.
2. **Docs that would contradict the new target.** These are `WORKFLOW.md` step 2 rule 5,
   `IOS-PRIMER.md` (the table, and the paragraph citing #30), the planner brief in
   `ORCHESTRATION.md`, and `RISK-FLAGS.md` C6.
   - **Resolved:** Slice A makes a one-line edit to each.
   - `.claude/agents/planner.md` was checked and repeats none of the text that changes, so it is
     not in the slice.
3. **The hosted tests launch the real app**, whose `.task` reconnects any host paired on that
   simulator. The first available iPhone is the one used for review.
   - **Resolved:** `Tools/check.sh` uses `DSH_TEST_SIMULATOR` if it is set. Otherwise it uses a
     dedicated "DSH Remote Tests" simulator, created on the first run and reused after. It never
     uses the first available simulator.
   - There is no production change. The plan states the remaining exposure: a host paired on the
     dedicated simulator would be reconnected by the test host app, which is why that simulator
     is dedicated and documented as not for review. Updated in AC5 and Slice A.
4. **AC4 has no automated test.**
   - **Resolved:** it stays checked by eye, as approved (C6). Making `conversationFixture` internal
     to test its contents is not planned.
5. **The "plan approved" comment on #74.**
   - **Resolved:** the orchestrator will ask Dan to post it. The planner posts nothing.

## Red evidence

`Tools/check.sh --red`, run 2026-10-14 on the tree that became the `Tests:` commit (Slice A at
`7838e59`, plus `Tests/DSHRemoteTests/MessageRowRenderTests.swift`). Output from the step
headings on:

```
== kit tests (red: must compile)
kit tests: all pass

== app tests (red: must compile)
simulator: 355F197E-5390-4BEC-A835-5BDC2D9DFE42 "DSH Remote Tests" (Shutdown)
✘ Test "AC1: assistant prose keeps its top-left corner" recorded an issue at MessageRowRenderTests.swift:97:9: Expectation failed: rowInk >= referenceInk
✘ Test "AC1: assistant prose keeps its top-left corner" failed after 0.496 seconds with 1 issue.
✘ Test "AC2: assistant prose keeps its bottom-left corner" recorded an issue at MessageRowRenderTests.swift:97:9: Expectation failed: rowInk >= referenceInk
✘ Test "AC2: assistant prose keeps its bottom-left corner" failed after 0.009 seconds with 1 issue.
✘ Suite "MessageRow rendering (#74)" failed after 0.563 seconds with 2 issues.
✘ Test run with 4 tests in 2 suites failed after 0.649 seconds with 2 issues.
app tests: fail on assertions (full log: .build/check/app-tests.log)

== red
red: ok it compiles and fails on assertions (kit: pass, app: fail; logs in .build/check).

check: ok — red for the right reason (671s)
```

Each test, from `.build/check/app-tests.log`. The `↳` lines carry the messages with the pixel
counts:

```
✔ Test "the hosted bundle renders an app view to pixels" passed after 0.083 seconds.
✘ Test "AC1: assistant prose keeps its top-left corner" recorded an issue at MessageRowRenderTests.swift:97:9: Expectation failed: rowInk >= referenceInk
↳ the assistant row lost 50 px of ink in its top-left 16pt corner (row 498, unclipped 548)
✘ Test "AC2: assistant prose keeps its bottom-left corner" recorded an issue at MessageRowRenderTests.swift:97:9: Expectation failed: rowInk >= referenceInk
↳ the assistant row lost 54 px of ink in its bottom-left 16pt corner (row 521, unclipped 575)
✔ Test "AC3: a user bubble keeps its rounded, filled corners" passed after 0.057 seconds.
```

- **AC1 and AC2 failed for the predicted reason:** ink lost in the corner square, with every
  precondition met. The sample reaches the corner, is wider than 32pt, and the row is as tall as
  its text.
- **AC3 and the smoke test passed, as planned.**

**Checked by the planner that the tests can pass, and that AC3 can fail.** Both checks used a
temporary, uncommitted edit to `MessageRow`, reverted straight after, and ran
`xcodebuild … -only-testing:DSHRemoteTests test-without-building` on the same simulator:

- **The planned Slice B fix** (rounded fill behind user messages only, no clip): all four tests
  pass (`✔ Test run with 4 tests in 2 suites passed`).
- **An over-reaching fix** (a square `Rectangle()` fill, no clip): AC1 and AC2 pass, and AC3
  fails with `Expectation failed: cornerAlpha == 0` /
  `↳ the user bubble's top-left corner pixel is filled (alpha 255): the bubble lost its rounded corner`.

**Finding for Slice A, not fixed here.** Of the 671 s, about 600 s came after the tests had
finished. On a failing run, `xcodebuild test-without-building` collects simulator diagnostics
into the `.xcresult` (`simctl diagnose … --timeout=600`), so every red or failing app-test run
stalls for up to ten minutes. Adding `-collect-test-diagnostics never` to the
`test-without-building` call in `Tools/check.sh` removed the stall in the planner's over-reach
run, which failed and returned at once. The flag belongs in Slice A's file, so it is reported
rather than changed.

## Verification

Verified 2026-10-14 on `3e1c79a` by a verifier agent (Claude Code) that built neither slice.
Every undo was an uncommitted change, restored with `git revert --abort` or
`git checkout -- <file>`, and followed by a green run. The app tests ran on the dedicated "DSH Remote Tests"
simulator (`355F197E-5390-4BEC-A835-5BDC2D9DFE42`). The undo runs used the inner-loop command in
`WORKFLOW.md` "Local CI", or `Tools/check.sh` where noted.

**`Tools/check.sh` (full): green.** It printed `check: green (full, 76s)` on `3e1c79a`, and
`check: green (full, 78s)` again after every probe below was restored. Each time, 501 kit tests in
36 suites passed, coverage was 86.70% against a baseline of 86.70% (it did not rise, so the
baseline needs no update), and 4 app tests in 2 suites passed.

| AC | Undone how | Observed with it undone | Restored |
|---|---|---|---|
| AC1 | `git revert --no-commit 0e8f16d`, which puts `.background(message.role == .user ? DSHPalette.elevatedSurface : Color.clear)` and `.clipShape(RoundedRectangle(cornerRadius: DSHMetrics.cardCornerRadius, style: .continuous))` back on `MessageRow` | `✘ Test "AC1: assistant prose keeps its top-left corner" recorded an issue at MessageRowRenderTests.swift:97:9: Expectation failed: rowInk >= referenceInk` / `↳ the assistant row lost 50 px of ink in its top-left 16pt corner (row 498, unclipped 548)` | `git revert --abort`; app tests 4/4 pass, `swift test` 501 pass |
| AC2 | the same tree | `✘ Test "AC2: assistant prose keeps its bottom-left corner" … Expectation failed: rowInk >= referenceInk` / `↳ the assistant row lost 54 px of ink in its bottom-left 16pt corner (row 521, unclipped 575)` | the same |
| AC3 | (a) the same tree, with only the clip put back. (b) The rounded fill replaced with `.background(message.role == .user ? DSHPalette.elevatedSurface : Color.clear)` and no clip. (c) Beyond the plan: the user fill removed altogether, to test AC3's second assertion | (a) `✔ AC3`, as planned. (b) `✘ … Expectation failed: cornerAlpha == 0` / `↳ the user bubble's top-left corner pixel is filled (alpha 255): the bubble lost its rounded corner`; AC1 and AC2 pass. (c) `✘ … Expectation failed: edgeAlpha > 0` / `↳ the user bubble is empty 16pt along its top edge (alpha 0): the bubble lost its fill`; AC1 and AC2 pass | `git checkout -- Apps/DSHRemote/Sources/ConversationTranscript.swift`; app tests 4/4 pass, `swift test` 501 pass |
| AC4 | not undone by a test: checked by eye (C6), on the fixed build and with the bug put back | below | below |
| AC5 | probes | below | n/a |

The AC1 and AC2 pixel counts match the Red evidence exactly, so the render is deterministic.

**AC4, checked by eye.** All screenshots are of `DSH_SCREEN_GALLERY=conversation` in light
appearance. They are kept in `/tmp`, not committed.

- **Fixed build.** I checked the builder's screenshot and 3× crop, and took a screenshot of my own
  from the same build. The new message is the first row after the "Some of this conversation is
  missing." notice, with no Reasoning row.
  - Its first line, "The step ended before its durable", starts with a whole "T": the crossbar
    reaches the left edge.
  - Its last line, "no more frames arrived after that one.", starts with an "n" whose left stem is
    whole from top to bottom.
  - Both lines are far wider than 32pt.
- **Bug put back.** I reverted `0e8f16d` without committing, built Debug, installed it on "DSH
  Remote Tests" and launched it with `SIMCTL_CHILD_DSH_SCREEN_GALLERY=conversation`.
  - The same message reads "Ihe", with the left half of the T's crossbar gone, and "ɿo", with the
    top of the n's stem gone.
  - So the fixture shows the bug when it is present, which #33 item 4 could not.
  - Afterwards the simulator was shut down, and the next `Tools/check.sh` reinstalled the fixed
    app on it.

**AC5 probes.**

| Probe | Result |
|---|---|
| `--red` with AC1 and AC2 failing (`0e8f16d` reverted) | `red: ok it compiles and fails on assertions (kit: pass, app: fail; logs in .build/check).` / `check: ok — red for the right reason (70s)`. That run took 671 s for the planner before `67386e0`. This log has no "Failure collecting diagnostics". |
| Full mode with AC1 and AC2 failing | `app tests: FAIL a test failed` / `check: RED (full, 115s)` / `- app tests` |
| `--red` with every test passing (clean `3e1c79a`) | `red: FAIL every test passed. A planner test that passes before the change guards nothing.` / `check: RED (red, 67s)` |
| A scratch app test that does not compile (an untracked file, deleted afterwards) | `error: cannot find 'thisSymbolDoesNotExist' in scope` / `app tests: FAIL the app or Tests/DSHRemoteTests does not compile` / `check: RED (full, 56s)` / `- app tests do not compile` |
| `DSH_TEST_SIMULATOR=00000000-BOGUS-0000-0000-000000000000`, with `--red` | "DSH_TEST_SIMULATOR=… names no available iOS simulator. Pick a UDID from xcrun simctl list devices available, or unset it to use "DSH Remote Tests"." / `check: RED (red, 7s)` |
| `--fast` | `check: green (fast, 20s)`. The output has no line about an app build, app tests, a simulator or xcodebuild. |
| Simulator reuse | Every run printed `simulator: 355F197E-5390-4BEC-A835-5BDC2D9DFE42 "DSH Remote Tests" (Shutdown)`. `xcrun simctl list devices` lists one "DSH Remote Tests". |
| Nothing left booted | After every run, `xcrun simctl list devices` showed no booted device. The script targets the test simulator by UDID, so the review simulator ("iPhone 18 Pro") was never booted. |

Not re-run by the verifier:

- the first run creating the dedicated simulator, because that means deleting it;
- `DSH_TEST_SIMULATOR=<a real UDID>`, because that installs the app on a second simulator.

The other checks:

- **Version impact: PATCH, confirmed.** This is a bug fix, the first row of the table in
  `RELEASING.md`.
  - Against `43cace2`, the branch changes nothing in `Sources/`, `Package.swift`, `Protocol/` or
    `Info.plist`.
  - `project.yml` adds only the test target and a scheme `test:` action. `Tools/check-version.sh`
    reports `0.2.0 (238)`, and there is no bump.
  - Under `## [Unreleased]`, `CHANGELOG.md` has the `### Fixed` line "Assistant replies no longer
    lose the left edge of their first and last letters (#74)." It also has the test-target line
    under "Added (process, no version impact)".
- **Risk flags: no S-flag is touched**, and I agree with the plan.
  - **S7:** the branch's Swift diff adds no `DSH_*` read, no `ProcessInfo` environment read, and
    nothing under `#if DEBUG`. The gallery change is fixture text behind the existing
    `DSH_SCREEN_GALLERY`. `DSH_TEST_SIMULATOR` appears only in `Tools/check.sh` and `WORKFLOW.md`,
    and nothing under `Apps/`, `Sources/` or `Tests/` reads it.
  - **S8:** no `info:` key or entitlement changes.
  - **S9:** the renders stay in memory, and the test logs go to the git-ignored `.build/check/`.
  - **C6:** covered by the render tests and the by-eye AC4 check above.
- **Planner tests:** `guard-tests: ok`. `MessageRowRenderTests.swift` is unchanged since `8e121c7`.
- **Optional, on the phone:** not done.

**Findings.** Every test fails with its fix undone; nothing blocks the merge. For the reviewer:

1. **The clip also cut a right-hand corner.** With the bug back, the gallery message's last line
   lost its trailing period ("that one" instead of "that one."). That line is the widest, so its
   end sits in the bottom-right corner. The fix restores the period.
   - No test watches the right corners. A rounded clip that came back would cut the left corners
     too, which AC1 and AC2 catch.
   - The CHANGELOG line names only the reported symptom.
2. **The plan's Status line is out of date.** It says the approval "is not yet recorded as a 'plan
   approved' comment on #74". Both gate-1 records are now on #74: "Plan approved" and "Tests
   reviewed", by @dan at 18:33, after the `Tests:` commit (18:18) and before Slice B (18:35). The
   verifier edits only this section, so the line is left for the orchestrator. Since an agent
   cannot hold a gate, the reviewer may want to confirm that Dan posted or authorised both.

## Notes for the next person

- A clip only cuts content when the clipped box is wider and taller than twice its corner radius.
  Below that, SwiftUI shrinks the radius. A one-letter sample hides a corner clip completely, and
  that is part of why short fixtures did not show this bug (resolution 1).
- The app tests run inside the real app, which restores its last host on launch. Do not pair a
  host on the "DSH Remote Tests" simulator, and do not use it for `DSH_*` review: anything paired
  there is reconnected by every `Tools/check.sh` run.
- Kit coverage (`Tools/coverage.sh`) is unaffected: it measures `swift test` only, and the app
  test target is not part of it.
