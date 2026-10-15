# Issue #99: one unmodelled event field must not kill the connection

**Status:** draft
**Branch:** `issue-99-unmodelled-event-field` (worktree `.claude/worktrees/issue-99`)
**Version impact:** MINOR — `DurableEventEnvelope.surfaceOp` changes type in the kit's public API
(`String?` → `JSONValue?`), which is an incompatible change to a caller. While `0.x` that is MINOR.
No bump in this PR; a line under `## [Unreleased]`.

## Context

The phone reported **Host unavailable — "protocol incompatibility: an inbound frame did not decode as
a mux envelope (text, 633763 bytes, first byte 0x7b)"**, and the app was unusable until relaunched.

Reproduced from the Mac against the live relay, on the session that was open
(`session-4755645d-5216-436e-b438-4564982800f3`):

```
DecodingError.typeMismatch: Expected value of type String.
Path: value.records[26].event.surfaceOp
Expected to decode String but found a dictionary instead.
```

`surfaceOp` is polymorphic. In that session's first 20 messages it is a **string** on the durable
events (records 0, 1, 3, 6, 8, 11) and an **object** on `tool/result` (records 26, 28, 30):
`{"op":"replace","startSeq":17853,"endSeq":17853}`. The hand-modelled
`DurableEventEnvelope.surfaceOp: String?` (`StreamFrames.swift:439`) cannot take that — while the
**generated** model already says `JSONValue?` (`Generated/SessionPage.swift:20`), so the two
disagree and the hand-modelled one is the strict, wrong one.

From there, one field becomes a dead app:

1. `MuxFrameValue.init(from:)` — `case .snapshot: self = .snapshot(try MuxSnapshot(from: decoder))`
   (`StreamFrames.swift:210`) has **no fallback**.
2. That throws, so `MuxFrame` throws, so `MuxClient.deliver` reports *"an inbound frame did not
   decode as a mux envelope"* (`MuxClient.swift:305-313`) — a message that blames the envelope, which
   was fine.
3. `failAllStreams(.protocolIncompatible)` fails **every** stream, and that is non-retryable, so the
   app parks at Host unavailable.

The strictness is backwards: an *unknown* `value.type` is kept whole and survives, while a *known*
type whose body has drifted is fatal.

## Acceptance criteria

- **AC1** — `surfaceOp` decodes in both wire shapes and the object form is **kept whole** rather than
  dropped: `op`, `startSeq` and `endSeq` are readable. A shape this build does not model is preserved
  rather than invented.
- **AC2** — a value body that does not fit this build's model **no longer condemns the connection**.
  The envelope is still parsed and the frame's other fields (`type`, `streamId`) still read; the body
  is kept whole as ``MuxFrameValue/unknown(type:value:)``. The socket and the other streams survive.
- **AC3** — the genuinely fatal cases stay fatal: a frame that is not JSON, not an object, or has no
  string `type` still fails, because there is nothing to classify it by.
- **AC4** — the real captured frame decodes. Verified locally against the 949706-byte capture; the
  committed test uses the existing synthetic fixture, because the capture is session content and host
  data stays local (`AGENTS.md`).

## Test list

| AC | Suite / file | Test name | Fails today because |
|---|---|---|---|
| AC1 | `StreamFrameTests.swift` | `"a surfaceOp in the replace form decodes and is kept whole"` | `typeMismatch` on `value.surfaceOp` |
| AC1 | `StreamFrameTests.swift` | existing `"…the eight durable-event frames…"` (`surfaceOp != nil` twice) | guard — passes today, must keep passing; it is the string-form coverage and it compiles both ways |
| AC2 | `StreamFrameTests.swift` | `"a value body this build cannot decode is kept whole, not fatal"` | the whole `MuxFrame` throws |
| AC3 | `StreamFrameTests.swift` | `"a frame that is not an object still fails"` | guard — passes today |

*Fakes and helpers: the existing `capturedMuxFrame(_:)`, `capturedMuxFrame(_:at:with:)`, `mutating`
and the `snapshot` / `event/user/message` captures in `Fixtures/mux-stream-frames.json`. No new stub.*

## Slices

| Slice | ACs | Files | Notes |
|---|---|---|---|
| A | AC1 | `Models/StreamFrames.swift`, `State/ConnectionCoordinator.swift` | align the hand-modelled field with the generated one; the bridge stops narrowing it |
| B | AC2, AC3 | `Models/StreamFrames.swift` | the three known value types gain a kept-whole fallback |

## Risk flags

- [x] **C2 — the protocol.** `Protocol/` is untouched and no generated model changes, but a
      hand-modelled payload shape does, so the PR states the version impact (MINOR) and the
      descriptor stays the authority: the generated model already said `JSONValue?`, which is the
      point of AC1.
- [ ] S1–S10 — none. No write path changes; this is decode-side only.
- [ ] C1, C3, C4, C5, C6 — none.

## Out of scope

- **The relay and the harness** (`AGENTS.md`, "Boundaries"). The harness may send shapes the client
  has not modelled; the client's job is to survive them and keep the raw value.
- **Why the app parks rather than degrading** — #26/#79 own that classification.
- Any other field the harness may polymorph. AC2 is what makes that survivable rather than fatal;
  this PR fixes the one that was measured.

## Red evidence

*Filled in with the `Tests:` commit.*

## Verification

*Filled in by the verifier.*

## Notes for the next person

- The failure message says "did not decode as a mux envelope", which is misleading: the envelope was
  fine and the *body* failed. `MuxClient` cannot tell the difference from a thrown `DecodingError`
  today; AC2 makes the distinction real rather than cosmetic.
- The generated models are the authority. When a hand-modelled struct in `StreamFrames.swift`
  duplicates one, a mismatch is a bug in the hand-modelled copy — that is exactly what this was.
