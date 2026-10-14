# Issue #74: Assistant messages lose the first letter of their first and last lines

**Status:** approved (Dan, 2026-10-14, in a Claude Code session; the content was approved before it
was transcribed here, and is not yet recorded as a "plan approved" comment on #74). The planner
raised questions while transcribing; see "Open questions". Question 1 needs an answer before the
tests phase.
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
  first line starts with "T" and whose last line starts with "n", so the corners can be reviewed
  by eye. This closes the gap that made #33 item 4 unreproducible.
- **AC5**: `Tools/check.sh` runs the app tests.
  - **Full mode** has an "app tests" step after the Debug and Release builds. It runs `xcodebuild
    build-for-testing`, then `test-without-building` on a simulator, so a compile error and a
    failing test give different messages.
  - **Simulator choice:** `DSH_TEST_SIMULATOR` if it is set, otherwise the first available iPhone
    from `xcrun simctl list devices available -j`. If there is none, the check fails with a hint.
  - **`--red`** accepts a `Tests:` commit when the kit tests and the app test target both
    **compile**, nothing crashes, and **at least one** of the two suites fails on assertions. It
    reports "every test passed" only when both suites pass.
  - **`--fast`** is unchanged and needs no simulator.

## Test list

| AC | Suite / file | Test name | Fails today because |
|---|---|---|---|
| AC1 | `MessageRowRenderTests`, `Tests/DSHRemoteTests/MessageRowRenderTests.swift` | `@Test("AC1: assistant prose keeps its top-left corner") func assistantProseKeepsItsTopLeftCorner()` | The row's 16pt continuous `clipShape` removes the top-left of the "T". Expected message: "the assistant row lost N px of ink in its top-left 16pt corner (row M, unclipped K)". **With the approved sample `"T\n\nn"` this prediction does not hold (Open question 1).** |
| AC2 | same | `@Test("AC2: assistant prose keeps its bottom-left corner") func assistantProseKeepsItsBottomLeftCorner()` | The same clip removes the lower left of the "n"'s stem. Same message shape, for the bottom-left corner. Same caveat. |
| AC3 | same | `@Test("AC3: a user bubble keeps its rounded, filled corners") func userBubbleKeepsItsRoundedCorners()` | **Does not fail today, by design.** It is the scope guard. The verifier proves it guards something by replacing the bubble's rounded fill with a square one (see Verification). |
| AC4 | none (by eye, per risk flag C6) | none | Today the gallery has no assistant message with a straight-edged glyph in either corner. Checked by eye: `SIMCTL_CHILD_DSH_SCREEN_GALLERY=conversation xcrun simctl launch …`, then `xcrun simctl io booted screenshot`. At 3× magnification the "T" and "n" of the new message have full left edges. The screenshot is shown to Dan, not committed. |
| AC5 | none (tooling, verified by probes as in #62) | none | Today `Tools/check.sh` has no app-tests step, and `--red` judges the kit suite only, so a `Tests:` commit whose only failures are in an app suite reports "every test passed". The probes are under Verification. |

Not a planner test: `Tests/DSHRemoteTests/AppTestTargetTests.swift` is written by the Slice A
builder. It has one smoke `@Test` that renders `MessageBody` from the hosted bundle and gets a
non-empty image. It is green from the start and proves the plumbing before any red test exists.
No `Tests:` commit touches it, so `Tools/guard-tests.sh` does not cover it.

**How the planner tests work (approved design).** Swift Testing, with the suite `@MainActor`
because `ImageRenderer` is main-actor. The helpers live in the test file, so the guard covers them:

- `render(_:width:)` uses `ImageRenderer` with `proposedSize` width 320, `scale` 3 and a dark color
  scheme, and returns a `CGImage`.
- `ink(in:of:)` counts the pixels with alpha > 0 in a rectangle given in points.
- The approved sample text is `"T\n\nn"`: two paragraphs whose straight-edged glyphs reach the
  top-left and bottom-left corners. The reference image is the bare `MessageBody(text:)` at the
  same width, which has the same origin and height as the assistant row's content.
- AC1 and AC2 start with `#require(referenceInk > 0)`, so a font or text change cannot make them
  pass without testing anything. Then `#expect(rowInk >= referenceInk, "<message above>")`.

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
| A | AC5, and it makes AC1–AC3 compilable | `Apps/DSHRemote/project.yml`, `Tools/check.sh`, `Tools/setup-dev.sh`, `Apps/DSHRemote/Sources/ConversationTranscript.swift` (`MessageRow`: `private` → internal, nothing else), `Tests/DSHRemoteTests/AppTestTargetTests.swift`, `AGENTS.md`, `docs/process/WORKFLOW.md`, `CHANGELOG.md`; `Package.swift` only if SwiftPM complains | Builder, **after plan approval and before the `Tests:` commit**. Commit: "Give the app a test target, and run it in Tools/check.sh (#74)". |
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
  - the simulator picker (AC5), parsing the `simctl` JSON with `python3 -I`;
  - the full-mode "app tests" step;
  - the `--red` logic across both suites;
  - `--fast` unchanged;
  - the header comment updated.
- **`Tools/setup-dev.sh`:** check that an iOS simulator runtime is installed.
- **Docs, one line each:**
  - `AGENTS.md` "Before you commit": what `check.sh` runs, and that CI now needs a simulator
    runtime.
  - `WORKFLOW.md` "Local CI": an "App tests" row in the table, and the inner-loop command
    `xcodebuild test … -only-testing:DSHRemoteTests`.
  - `WORKFLOW.md`: view-level bugs get a render test in `Tests/DSHRemoteTests`.
  - Open question 2 lists other docs this will contradict.
- **`CHANGELOG.md`:** a line under `### Added (process, no version impact)`.
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
  first line starts with "T" and whose last line starts with "n" (AC4). Its lines should be wider
  than 32pt, for the reason given in Open question 1.
- **`CHANGELOG.md`:** under `### Fixed`, "Assistant replies no longer lose the left edge of their
  first and last letters (#74)."

## Risk flags

- [ ] none
- [ ] S1–S10: none ticked. The ones I considered:
  - **S7 (debug affordances):** Slice B edits a fixture that is reached only through
    `DSH_SCREEN_GALLERY`, whose read is already inside `#if DEBUG` (`AppModel.swift`). It adds no
    variable, no environment read and nothing new under `#if DEBUG`.
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

## Open questions (raised by the planner while transcribing, 2026-10-14)

These are not changes to the approved plan. They are for Dan to decide.

1. **Blocking for AC1 and AC2: the approved sample `"T\n\nn"` does not reproduce the bug.**
   - **Why:** `MessageRow`'s VStack is as wide as its text, and SwiftUI limits a rounded
     rectangle's corner radius to half its shorter side. With "T" and "n" the clipped box is about
     10pt wide, so the effective radius is about 5pt and no glyph pixel falls outside it.
   - **Measured:** a scratch probe outside the repo used macOS SwiftUI `ImageRenderer` to mimic
     the assistant branch of `MessageRow`, at 17pt, width 320 and scale 3. It counted pixels with
     alpha > 0 in the 16pt corner squares, clipped and unclipped:

     | Sample | Top-left, clipped / unclipped | Bottom-left, clipped / unclipped |
     |---|---|---|
     | `"T\n\nn"` | 359 / 359 | 392 / 392 |
     | `"The\n\nno"` | 588 / 641 | 615 / 668 |
     | `"The step ended.\n\nno more frames."` | 572 / 641 | 598 / 668 |

     With the approved sample, AC1 and AC2 would pass with the bug present, and
     `Tools/check.sh --red` would say "every test passed".
   - **Proposed:** keep the design, but use a sample whose lines are wider than
     `2 × cardCornerRadius`, such as `"The step ended.\n\nno more frames."`. Add
     `#require(reference width > 2 × cardCornerRadius)` so a later edit to the sample cannot
     quietly neuter the tests. The same lesson applies to the AC4 gallery message.
2. **Docs that will contradict the new target unless they change too.** The approved plan edits
   only `AGENTS.md` and `WORKFLOW.md` "Local CI". These still say the opposite:
   - `docs/process/WORKFLOW.md` step 2 rule 5: "Kit, not app … the app has no test target on
     purpose".
   - `docs/process/IOS-PRIMER.md`: the table says app tests are "none, on purpose", and a
     paragraph says "until then, the kit is where tests go" (citing #30).
   - `docs/process/ORCHESTRATION.md`: the planner brief says tests go in `Tests/DSHRemoteKitTests/`
     and app behaviour moves to the kit.
   - `docs/process/RISK-FLAGS.md` C6.

   Proposed: a one-line edit to each, in Slice A.
3. **Hosted tests launch the real app on the chosen simulator.** `DSHRemoteApp`'s `.task` calls
   `model.restoreLastHost()`. On this machine the first available iPhone is "iPhone 18 Pro", the
   simulator the primer uses for `DSH_*` review. If a host is paired there, every
   `Tools/check.sh` run would connect to it while the tests run. Options:
   - document that `DSH_TEST_SIMULATOR` should name a simulator with nothing paired, or have the
     picker prefer a dedicated one;
   - make the app skip launch work when XCTest hosts it. That is a production change outside the
     approved scope.
4. **AC4 has no automated test.** It is checked by eye, which C6 allows. It could be automated by
   making `ScreensGalleryView.conversationFixture` internal and asserting that it holds such a
   message. That is not in the approved plan, so it is not planned.
5. **Gate 1 bookkeeping.** `ORCHESTRATION.md` reads approval from a "plan approved" comment on the
   issue. Dan's approval was given in a session, so #74 does not show it yet.

## Red evidence

To be filled in by the planner with the `Tests:` commit.

```
```

## Verification

To be filled in by the verifier. Planned:

| AC | Undone how | Expected failure with it undone |
|---|---|---|
| AC1 | put the `.clipShape(...)` line back on `MessageRow` (stash the Slice B fix) | AC1 fails with the ink-loss message for the top-left corner |
| AC2 | same | AC2 fails with the ink-loss message for the bottom-left corner |
| AC3 | replace the user bubble's `RoundedRectangle` fill with a square fill (`Rectangle()`, or `.background(DSHPalette.elevatedSurface)` with no clip) | AC3 fails because the corner pixel is filled. With only the clip put back (the AC1 probe), AC3 still passes. |
| AC4 | not applicable | Screenshot of `DSH_SCREEN_GALLERY=conversation`: the new message's "T" and "n" are whole at 3×. Shown to Dan, not committed. |
| AC5 | probes, as in #62 | full mode on Slice A shows "app tests" passing; a scratch failing app test turns full mode red at "app tests"; a scratch app test that does not compile is reported as a compile failure, distinctly; `--red` on the `Tests:` commit gives "red: ok" with the kit green and the app suite failing; `--red` with every test passing gives "every test passed"; a bogus `DSH_TEST_SIMULATOR` fails with a hint; `--fast` runs no app tests |

- `Tools/check.sh`: green / red
- Risk checklist: not applicable (no S-flag). For C6, the by-eye check of AC4 is recorded above.
- Optional, on the phone: the session from the original report no longer cuts letters.

## Notes for the next person

- A clip only cuts content when the clipped box is wider and taller than twice its corner radius.
  Below that, SwiftUI shrinks the radius. A one-letter sample hides a corner clip completely, and
  that is part of why short fixtures did not show this bug (Open question 1).
- Kit coverage (`Tools/coverage.sh`) is unaffected: it measures `swift test` only, and the app
  test target is not part of it.
