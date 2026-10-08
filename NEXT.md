# What is left for v1

State as of 2026-10-07, round 13 of the goal "get a usable v1 iphone app".
Everything here is committed and the suite is green (162 Swift Testing + 14
XCTest). Read `SPEC.md` for the contract; this file is only the work list.

## Proven against the live harness

`swift run --disable-sandbox --scratch-path .build-smoke dsh-smoke --origin https://10.1.0.138:3443 --pin <pin>`
with a device token in `DSH_DEVICE_TOKEN` connected from a non-loopback
address and reported `SMOKE OK`: SPKI pinning accepted the self-signed
certificate without a trust chain, the bearer token authenticated, the mux
readiness handshake returned a `clientId`, the session list came back with 41
sessions, and shutdown was clean. That covers TLS, auth, mux, RPC, and
decoding below the UI.

## Three known defects, all small and all specified

1. **`MuxClient` discards the transport error kind.** Confirmed by inspection
   on 2026-10-07, not taken on trust:
   - `MuxStreamError.socketFailed(detail: String)` — `Network/MuxClient.swift:61`;
   - the kind is thrown away at both throw sites, `MuxClient.swift:194` and
     `MuxClient.swift:369`, each calling `RelayTransportError.classify(error).safeDescription`;
   - `ConnectionCoordinator.swift:232` reconstructs it by matching the literal
     prefix `"TLS pin mismatch: "`, and the comment at :676 admits this is a
     "long" shot that only works because that prefix construction is unique.

   SPEC §6.4 requires a pin failure to stop retrying and offer re-pairing, so
   the distinction is load-bearing. Fix: make the case carry
   `RelayTransportError` instead of a `String`, update both throw sites, then
   delete the prefix match. Expect `StateTests` to construct
   `.socketFailed(detail:)` and need updating with it.
2. **The `$events` ready frame is decoded as `.unknown`.** No fixture contains
   one, so `ConnectionCoordinator` matches on `value.typeName`. It is a real
   captured shape: `{"type":"item","streamId":"1","value":{"type":"ready","clientId":"<36>","host":{"home":"<path>"}}}`.
   Fix: add it to `Fixtures/`, register it in `Tests/DSHRemoteKitTests/Fixtures.swift`
   (the coverage test insists), model `.ready` in `Models/StreamFrames.swift`,
   and let the coordinator read it properly.
3. **The establishment budget is tested through a test-local stall transport**
   because `StubRelayTransport.openSocket` cannot hang. A stub knob would
   remove the last non-stub double in `StateTests.swift`.

## Then the chat screen

**One open decision first.** Two reducers exist. The committed one
(`State/ConversationBuilder.swift`, 190 lines, 8 tests) wins rule 3: a chunk
whose revision goes backwards is dropped as a frame, while the other drops the
whole attempt on a single out-of-order frame, which over-reacts. But the parked
one (`wip/ConversationBuilder2.swift.wip`, 241 lines, 9 tests) wins rule 4: it
holds a preview until the durable `seq` its `end` named actually exists, so a
`committed` end arriving *before* its durable record shows neither briefly. The
committed one has that gap. Either port that ordering handling into the
committed builder, or promote the parked one with the recipe its author gave
(delete both committed files, `git mv` the `.wip` into place, rename the type).
Nothing depends on either yet, so this is cheap to settle now and awkward later.

`Sources/DSHRemoteKit/State/ConversationBuilder.swift` is done and tested
(190 lines, eight tests). What it needs from the UI:

- `messages` gives ordered `ConversationMessage`s with `role`, `text`,
  `isProvisional`, and `reasoning` kept apart from the answer;
- `isStreaming` drives a live indicator — a provisional message carries **no
  text** on purpose, because nothing proves where stream text deltas live;
- `hasGap` should surface as a visible note rather than being swallowed;
- `unmodelledEvents` is where tool calls, plan updates, and permission
  presets live; render them as generic cards, never drop them.

The screen itself is `Apps/DSHRemote/Sources/` — add `ChatView.swift`, a
`$events` subscription through `ConnectionCoordinator`, and a `session/follow`
stream opened for the selected session. SPEC §3.4 governs the composer and
§3.6 the attachments; neither exists yet.

## Then the app has to leave this machine

- **No signing identity**: `security find-identity -v -p codesigning` is empty,
  so open `Apps/DSHRemote/DSHRemote.xcodeproj` in Xcode, pick a Team, and put
  the id in `project.yml` (`DEVELOPMENT_TEAM`) so a regenerate keeps it.
- **No simulator runtime**: `xcrun simctl runtime list -v` reports zero images,
  so running locally needs `xcodebuild -downloadPlatform iOS` (several GB).
  Building for `generic/platform=iOS Simulator` works without it.

## Things deliberately not built

Reconnect with jittered backoff (`ConnectionCoordinator` has a marked seam),
the other three reactor streams in SPEC §4, workspace grouping in the session
list (it groups by `cwd` meanwhile), drafts, attachments, approvals, and the
question cards. `wip/ConversationBuilder-*.swift.wip` is a dead 1,519-line
attempt; delete it whenever.
