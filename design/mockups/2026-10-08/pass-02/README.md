# DSH Remote — second visual pass
Date: 2026-10-08

Concept images only; no app code changed. Activity, edits, and test results shown inside the images are fictional example conversation content.

- [Light: follow the work and approve an action](01-conversation-and-approval-light.png)
- [Dark: switch conversations and continue a saved draft](02-switcher-and-continuation-dark.png)

## Changes from pass one
- Reopen the last conversation; move conversation/host selection into a sheet.
- Give assistant text the full reading width; use subtle bubbles only for user messages.
- Collapse tool activity into a quiet disclosure line.
- Keep approvals in the conversation, beside their context.
- Keep attachments, model choice, and send/stop together in the composer.
- Persist the draft per host/session and let the reader choose when to return to the latest activity.
- Apply the same hierarchy in light and dark appearances.

## Interaction intent
On launch, resume the last accessible conversation on the selected host. A stable reading position survives navigation; new activity does not drag the reader to the bottom. The activity disclosure expands details in place. Approvals settle visibly after acknowledgement. Drafts persist across navigation and reconnects. Animate these changes gently, with Reduce Motion support.

These are intended behaviors to implement, not behavior demonstrated by the static images. The existing v1 scope and review findings in the parent README remain applicable.

## Generation and verification
Built-in image generation used the first-pass sessions/chat image as product context. Both final boards were visually inspected; the dark board received one targeted correction removing unrequested rating controls. Final PNGs verified at 1536 × 1024. The first pass remains intact. Exact prompts are saved in prompts.md.

