# DeepSeek Harness for iPhone — third visual pass
Date: 2026-10-09

The user's actual web-app screenshot is the primary reference. This pass keeps its dark canvas, whale/wordmark identity, workspace navigation, New session entry, Standard mode selector, and muted blue actions. The earlier rounded mobile cards remain.

- [Home and workspace drawer](01-home-and-workspaces.png)
- [Conversation and connection recovery](02-conversation-and-recovery.png)
- [Connection investigation](CONNECTION-REVIEW.md)
- [Detailed mobile experience specification](../../MOBILE-UX-SPEC.md)
- [Engineering wiring specification](../../MOBILE-IMPLEMENTATION-SPEC.md)

## Scope and behavior

These are proposed screens with illustrative text. New session, mode selection, and the Plugins / Scheduled tasks / MCP / Usage entry points expand the earlier v1 scope; they need verified host APIs and native detail views. The drawer is not evidence that all desktop administration already works remotely.

Keep approvals and tool details in thumb-friendly cards. A temporary disconnect preserves cached conversation and draft, labels the last update, disables sending, and reconnects automatically. Do not infer that the Mac is asleep or that work is still running from an unreachable socket. A genuine identity change needs explicit verification, not unlimited retry.

The live investigation also found a different state not drawn here: connected successfully but unable to list sessions because host data is inconsistent. That screen should keep the host marked connected and show a recoverable session-loading error, rather than a generic host-unavailable screen.

Generated with built-in imagegen using the user's screenshot and the second-pass light phone board as references. Both final 1536 × 1024 PNGs were visually inspected. Earlier mockups are preserved. Exact prompts are in prompts.md. The initial visual pass and investigation made no app or infrastructure changes.

Follow-up, 2026-10-09: Patrick confirmed this visual direction and that returning to the app must reconnect automatically without approval. Foreground connection recovery is now implemented separately from the visual redesign; see the app README for behavior and validation limits. The mockups remain concepts, and the live relay/session files have not been changed.

