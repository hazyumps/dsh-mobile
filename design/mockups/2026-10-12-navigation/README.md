# Navigation proposal — drawer becomes the harness, Home becomes your work
Date: 2026-10-12 · Status: **approved and implemented in issue #61**

A visual proposal for the mobile navigation shape, made after using the app on the phone.
Reference for the composer arrangement: Patrick's Codex iOS screenshots (list + opened composer).
Rendered from one HTML source; the numbers are the illustration's, not host data.

- [Board — all four screens with the change table](board.png)
- [1 · Home](01-home.png) — recents, then projects, floating composer
- [2 · Harness panel](02-harness-panel.png) — the drawer, harness administration only
- [3 · New session](03-new-session.png) — host / project / preset / model above the composer
- [4 · A project](04-project.png) — the workspace tree as a destination, newest first
- Source: [proposal.html](proposal.html) — also serves the four single-screen PNGs via `#home`, `#panel`, `#new`, `#project`

## The diagnosis

The drawer does three jobs at once: harness administration, workspace navigation, and the session
list, the last two as a two-level tree behind a modal. Reaching a session is open drawer → find
workspace → expand → scroll, and the expand state is lost every time. Meanwhile Home stacks six
sections — host, heading, workspace, mode, composer, recents — before the first session appears.

## The proposal

Swap which job gets which surface. Administration is rare and wide, so it keeps the slide-over.
Work is frequent and deep, so it gets the full screen.

- **Home**: recents (last four, cross-project, with live state), then projects. The composer floats
  over the list instead of sitting in the scroll.
- **Drawer**: host card, then Harness / Host / About rows. No workspaces, no sessions, no separate
  Settings screen.
- **New session**: opened from the composer pill, carrying host, project, preset and model as
  context rows — the four things that decide where the work runs.
- **Project**: the same tree as a pushed screen, grouped by date, with a filter and New session.

## Open calls

1. **Whale / "Into the Unknown" heading** — proposal is empty-state only; that deviates from UX spec
   §Home item 4, so it is Patrick's call.
2. **Recents count** — four fills one screen at this density.
3. **Pinned** — not drawn; no pin concept exists today and it would need a store.
4. **New session as a screen or a sheet** — drawn as a pushed screen, matching the reference.
5. **Host in the toolbar** — kept the wordmark per the UX spec; host lives in the drawer and the
   new-session row. The alternative is the reference's own arrangement, host name in the title.

Implemented in #61 on `issue-61-navigation-rework`. The five calls above were taken as the
recommendations written here: whale on the empty state only (a correction now recorded in the UX
spec), four recents, no pins, a pushed new-session screen, and the wordmark in the toolbar. The one
departure from these images is the toolbar's search control, which is issue #10's work and is not
drawn in the app until it does something. Screenshots of the built screens are in the issue.
