# Issue #68: Test the TLS/SPKI pinning decision without a live relay

**Status:** verified. Plan approved by Dan, 2026-10-15; AC8 was added after the first verification, with scope approved by Dan the same day; dsh-smoke run 2026-10-15.
**Branch:** `issue-68-tls-trust-decision`
**Version impact:** PATCH. No API change, no persisted format, no generated model. The one change in
behaviour (AC4) is a policy that no caller builds, now refused instead of trusted. That is
fail-closed hardening, not new behaviour. No bump in this PR; a Security line goes under
`## [Unreleased]`.

## Context

The app decides whether to trust a relay in `TransportDelegate.urlSession(_:didReceive:)` and
`spkiPin(of:)`, in `Sources/DSHRemoteKit/Network/RelayTransport.swift:468–517`. This is the most
security-critical code in the app. Only `dsh-smoke`, run against a live relay (`Smoke/README.md`),
exercises it. The file's coverage is 40.7%. It is not in `Tools/must-test.txt` either; that file's
header says it joins "once #68 gives it unit tests". This plan pulls the decision out into a pure
function, keeps the delegate as a thin adapter around it, and tests the function offline against
certificates built over the relay's captured key (SPEC §3.2, §6.3).

Decisions made with Dan (2026-10-15):

1. **Test certificates are stand-ins.** They are generated around the relay's committed public key
   (`rawPublicKeyBase64` in `Fixtures/relay-spki-pin.json`) and signed by a throwaway key that is
   deleted afterwards. Their SPKI pin is therefore the relay's published pin `7pcXvn2K…`. They
   carry no host data, and nothing is deployed.
2. **`(pin: nil, requiresPlatformTrust: false)` is rejected by the decision**, with no API change.
   No caller builds that policy. `AppModel.swift:368` and `:1655` set
   `requiresPlatformTrust = pin == nil`, Smoke uses `.pinned`, and `ConnectionCoordinator`
   defaults to `.platformTrust`.
3. **A pin together with `requiresPlatformTrust: true` stays pin-only**, as it is today. AC5 records
   this, and a follow-up issue asks whether "both" should mean both.

## Acceptance criteria

The decision's caller is the delegate, so the criteria are stated as what `decide(serverTrust:)`
returns for a `SecTrust` built offline, and what the delegate passes to `URLSession`.

- **AC1** — A certificate whose key is the relay's captured key is accepted under the relay's
  published pin. It is rejected under any other pin, including a hash of the whole certificate. The
  pin is read from the leaf, never from the issuer.
- **AC2** — A leaf whose key is not P-256 (P-384, RSA) fails closed, even under that key's own
  correct SPKI pin. The rejection is for the key type, not a pin mismatch (SPEC §6.3).
- **AC3** — With no pin and `requiresPlatformTrust`, the decision defers to the system's chain and
  hostname check (SPEC §3.2).
- **AC4** — With no pin and no platform trust, the connection is rejected. Today it is accepted.
- **AC5** — With a pin and `requiresPlatformTrust` both set, only the pin is checked (today's
  behaviour, kept on purpose; follow-up #86).
- **AC6** — Each decision maps to one disposition: accepted → `.useCredential` (the only one with a
  `URLCredential(trust:)`), deferred → `.performDefaultHandling`, rejected →
  `.cancelAuthenticationChallenge`.
- **AC7** — `Network/RelayTransport.swift` is in `Tools/must-test.txt` with a floor. Enforced by
  `Tools/check.sh`, not by a test of its own.
- **AC8** (added after verification) — the challenge handler URLSession calls answers from the
  decision, for both of the transport's sessions (requests, and the mux socket's upgrade):
  - pinned, matching stand-in certificate → `.useCredential` with a credential
  - pinned, wrong pin → `.cancelAuthenticationChallenge`, no credential
  - `.platformTrust` → `.performDefaultHandling`, no credential
  - `(nil, false)` → `.cancelAuthenticationChallenge`, no credential
  - an HTTP Basic challenge under a pinned policy → `.performDefaultHandling`, no credential
  - a server-trust challenge with a nil `serverTrust` → `.performDefaultHandling`. This is today's
    behaviour, kept and documented. The security reviewer noted that cancelling would be stricter.

## Design (one slice)

These are added to `RelayTransport.swift` as `internal`; the tests use `@testable import`:

```swift
enum RelayTrustDecision: Equatable, Sendable {
    case acceptPinned                       // the pin stands in for the chain
    case deferToPlatform                    // system chain + hostname check
    case reject(RelayTrustRejection)
}
enum RelayTrustRejection: Equatable, Sendable {
    case noLeafCertificate                  // empty chain
    case unsupportedKey                     // not P-256: fails closed (SPEC §6.3)
    case pinMismatch
    case noTrustAnchor                      // no pin and no platform trust
}
extension RelayPinningPolicy {
    func decide(serverTrust: SecTrust) -> RelayTrustDecision
}
extension RelayTrustDecision {
    var disposition: URLSession.AuthChallengeDisposition
}
```

- **Order, unchanged from today.** If there is a pin, check it. Otherwise, if
  `requiresPlatformTrust` is set, defer. Otherwise reject with `.noTrustAnchor`. Only that last
  branch is new.
- **How the leaf's pin is computed.** It still goes through `SPKIPin.pin(rawP256PublicKey:)`, so the
  wrapping exists in one place. `spkiPin(of:)` moves out of the private delegate and is split into
  leaf → key → pin. An empty chain gives `.noLeafCertificate`. A key that cannot be wrapped gives
  `.unsupportedKey`.
- **The delegate keeps three steps.** It keeps the non-server-trust guard, calls `decide`, and maps
  the result through `disposition`.
- **Comments.** The SPEC §3.2 and §6.3 citations stay. The "unverified" note goes, because the AC1
  accept test observes `SecKeyCopyExternalRepresentation` through a real `SecTrust`.

## Fixture: `Fixtures/relay-trust-certificates.json`

This file is synthetic, and it is wrapped in a JSON object because `FixtureCoverageTests` requires
one. It holds:

- `description`, and a `source` field with the exact openssl commands, the openssl version and the
  date
- `expectedPin`: `7pcX…`
- base64 DER of the stand-in `leafOverCapturedRelayKey` (built with
  `openssl x509 -new -force_pubkey`), its `leafWholeCertificatePin`, the `throwawayIssuer` and its
  `issuerOwnPin`, `p384Leaf` with `p384OwnPin`, and `rsaLeaf` with `rsaOwnPin`

openssl computes every pin as SHA-256 over the DER SPKI, so each expected value comes from outside
the code under test. The issuer is P-256, so a decision that read the issuer would *accept* under
`issuerOwnPin`, and the test would fail.

The file is registered in two places: as `Fixtures.File.relayTrustCertificates`, and in
`FixtureProvenanceTests` as
`.synthetic(basis: "certificates issued over the captured relay key; SPEC §6.3")`. The redaction
tests limit what it may contain. There is no PEM (`-----BEGIN` is a banned prefix), no `/Users/`
path in `source`, and no key called `privateKey`.

## Test list: `Tests/DSHRemoteKitTests/TLSTrustDecisionTests.swift`

Each test builds its `SecTrust` offline with `SecTrustCreateWithCertificates` and an SSL policy, and
never evaluates it. The stubs in the `Tests:` commit are the two enums,
`decide(serverTrust:)` → `.reject(.noTrustAnchor)`, and `disposition` →
`.cancelAuthenticationChallenge`.

| AC | Test name | Expect | Fails today because |
|---|---|---|---|
| AC1 | `"AC1: the certificate over the captured relay key is accepted with the relay's published pin"` | `.acceptPinned` | stub returns `.reject(.noTrustAnchor)` |
| AC1 | `"AC1: the same certificate is rejected under a different pin"` | `.reject(.pinMismatch)` | stub returns `.reject(.noTrustAnchor)` |
| AC1 | `"AC1: a pin over the whole certificate is not accepted"` (`leafWholeCertificatePin`) | `.reject(.pinMismatch)` | stub returns `.reject(.noTrustAnchor)` |
| AC1 | `"AC1: the pin is taken from the leaf, not the issuer"` (chain `[leaf, issuer]`, `issuerOwnPin`) | `.reject(.pinMismatch)` | stub returns `.reject(.noTrustAnchor)` |
| AC2 | `"AC2: a P-384 leaf fails closed even under its own SPKI pin"` | `.reject(.unsupportedKey)` | stub returns `.reject(.noTrustAnchor)` |
| AC2 | `"AC2: an RSA leaf fails closed even under its own SPKI pin"` | `.reject(.unsupportedKey)` | stub returns `.reject(.noTrustAnchor)` |
| AC3 | `"AC3: no pin with platform trust required defers to the system's check"` | `.deferToPlatform` | stub returns `.reject(.noTrustAnchor)` |
| AC4 | `"AC4: no pin and no platform trust is rejected"` | `.reject(.noTrustAnchor)` | **passes by construction** against the stub |
| AC5 | `"AC5: a pin with platform trust also required checks only the pin (follow-up #86)"` | `.acceptPinned` | stub returns `.reject(.noTrustAnchor)` |
| AC6 | `"AC6: an accepted decision maps to useCredential"` | `.useCredential` | stub returns `.cancelAuthenticationChallenge` |
| AC6 | `"AC6: a deferred decision maps to performDefaultHandling"` | `.performDefaultHandling` | stub returns `.cancelAuthenticationChallenge` |
| AC6 | `"AC6: a rejected decision maps to cancelAuthenticationChallenge"` | `.cancelAuthenticationChallenge` | **passes by construction** against the stub |

Expected red: 10 of the 12 fail with a value mismatch. The red evidence must name the two that pass
by construction. The verifier's undo table is what shows that AC4 and the reject mapping guard
something.

**Discovery risk, resolved.** `SecTrustCopyCertificateChain` on an *unevaluated* trust does return
`[leaf, issuer]` in that order (macOS, 2026-10-15). The AC1 issuer test checks this before it looks
at the decision, so a platform change would fail there and not show up as a confusing pin result.

## Slices

| Slice | ACs | Files | Notes |
|---|---|---|---|
| A | AC1–AC6 | `Sources/DSHRemoteKit/Network/RelayTransport.swift` | the decision, the disposition mapping, the delegate as an adapter |
| A | AC7 | `Tools/must-test.txt`, `Tools/coverage-baseline.txt`, `CHANGELOG.md` | the floor is set a few points under the measured value, and the "joins once #68" note is removed. The baseline goes up if the kit total rises. Security line: "A relay connection with neither a pin nor platform validation is refused instead of trusted (#68)." |

| B | AC8 | `Sources/DSHRemoteKit/Network/RelayTransport.swift` | `challengeDelegates` returns `(session.delegate, socketSession.delegate)`. No change to `TransportDelegate`. |

The planner (tests phase) owns the fixture, `Fixtures.swift`, `FixtureProvenanceTests.swift` and
the new test files.

## AC8: the handler URLSession calls (added after verification)

**Why.** The verifier found that if `TransportDelegate.urlSession(_:didReceive:)` ignored `decide`
and always answered `.useCredential` with `URLCredential(trust:)`, all 517 kit tests would pass.
AC1–AC6 prove the decision. Nothing proved the handler uses it.

**The seam: the delegates URLSession holds, not a copy of their logic.** The test stub is
`URLSessionRelayTransport.challengeDelegates`, an internal, read-only property:
`(request: (any URLSessionDelegate)?, socket: (any URLSessionDelegate)?)`. It returns `(nil, nil)`.
The builder makes it return `session.delegate` and `socketSession.delegate`, the objects URLSession
itself calls. The tests send a fake challenge to each delegate's
`urlSession(_:didReceive:completionHandler:)` and record what reaches the completion handler.

The coordinator suggested a different seam: a static `respond(to:pinning:)` that the delegate
calls in one line. It was rejected because it moves the gap rather than closing it. A `didReceive`
that skipped `respond` and answered `.useCredential` would still pass every test. Going through
`session.delegate` turns that exact mutation red. It also covers the socket session, which has its
own `URLSession` and so its own delegate slot. The cost is the same either way: the handler is
already correct, so the red comes from the stub, not from a defect.

**The fake challenge, with no network.** The challenge's protection space is a test-only
`URLProtectionSpace` subclass whose `serverTrust` returns a `SecTrust` over the fixture
certificates; the stub `URLAuthenticationChallengeSender` is never called. Observed on macOS
(2026-10-15, a scratch program, before writing the tests):
- the subclass survives into `URLAuthenticationChallenge.protectionSpace`
- the override is what `serverTrust` returns
- a delegate reached through `URLSession.delegate` receives the challenge

The first test also asserts that the fake carries its trust, so a platform change there would show.

**Tests: `Tests/DSHRemoteKitTests/TLSChallengeHandlerTests.swift`.** Each test runs twice, once per
session (`arguments: ChallengeSession.allCases`, which are `request` and `socket`).

| Test name | Expect | Fails today because |
|---|---|---|
| `"AC8: a pinned transport answers the matching certificate with useCredential and a credential"` | `useCredential`, credential present | stub exposes no delegate: answer → `nil` |
| `"AC8: a pinned transport cancels a certificate under a different pin"` | `cancelAuthenticationChallenge`, nil | answer → `nil` |
| `"AC8: a platform-trust transport leaves the server-trust challenge to the system"` | `performDefaultHandling`, nil | answer → `nil` |
| `"AC8: a transport with no pin and no platform trust cancels the challenge"` | `cancelAuthenticationChallenge`, nil | answer → `nil` |
| `"AC8: a pinned transport leaves an HTTP Basic challenge to the system"` | `performDefaultHandling`, nil | answer → `nil` |
| `"AC8: a server-trust challenge without a trust is left to the system (today's behaviour)"` | `performDefaultHandling`, nil | answer → `nil` |

**No AC8 case passes by construction.** The stub provides no handler at all, so the
`performDefaultHandling` cases fail too.

`TrustMaterial` and `serverTrust(_:)` in `TLSTrustDecisionTests.swift` change from `private` to
internal, so the new file reuses them. That is the only change to an earlier planner line.

## Risk flags

- [x] **S2 TLS and pinning.** The challenge handling in `RelayTransport.swift` is restructured
  around a pure decision, and one branch changes from accept to reject (AC4). Accept and reject are
  both tested (AC1–AC4). No policy accepts every certificate after this change; today
  `(nil, false)` does. `dsh-smoke` is run against Dan's local relay (`Smoke/README.md`), and its
  date and result are recorded under Verification.
- [ ] **S3** is not ticked. How a pin reaches a transport (`AppModel`, `PairingPayload`) does not
  change.
- [ ] **C3** is not ticked. The delegate is still `@unchecked Sendable` with immutable state. The
  new types are value types.

## Out of scope

- Whether a pin together with `requiresPlatformTrust` should require both. That is follow-up #86
  (labels `security`, `client`); AC5 records today's answer.
- A real handshake. AC8 tests the handler URLSession calls, using a fake challenge. That the
  system actually delivers a server-trust challenge to it during TLS is still something only
  `dsh-smoke` shows.
- Cancelling a server-trust challenge that has no trust. AC8 records today's
  `.performDefaultHandling`, and changing it would be a behaviour change of its own.
- Any change to how a pin is obtained or stored (S3).

## Corrections to the approved plan

These were found while checking it against the code. The approved decisions are unchanged.

1. **The whole-certificate test needs the stand-in's own hash.**
   `competingPinOverWholeCertificate` in `relay-spki-pin.json` hashes the relay's *real*
   certificate, not the stand-in. Against the stand-in it would be just another wrong pin, and the
   test would duplicate "rejected under a different pin". So the fixture adds
   `leafWholeCertificatePin`, the openssl SHA-256 over the stand-in's DER, and the test uses that.
2. **The issuer test needs `issuerOwnPin`**, which the approved field list left out. The issuer is
   P-256, so reading the wrong certificate would turn into an accept.
3. **openssl version.** `x509 -new -force_pubkey` needs OpenSSL 3 or later. `/usr/bin/openssl` here
   is LibreSSL 3.3.6. Use `/opt/homebrew/bin/openssl` (4.0.3) and record the version in `source`.

## Red evidence

`Tools/check.sh --red` on the working tree of the `Tests:` commit, which holds the tests, the
fixture and the stubs:

```
kit tests: fail on assertions (full log: .build/check/test.log)
app tests: ok
red: ok it compiles and fails on assertions (kit: fail, app: pass; logs in .build/check).
check: ok — red for the right reason (67s)
```

Kit: 517 tests in 37 suites, **10 issues**, all of them assertion failures in
`TLSTrustDecisionTests.swift`. Each failure matches the prediction. The fixture tests pass with the
new file registered.

| Test | Failure (`TLSTrustDecisionTests.swift`) |
|---|---|
| AC1: …accepted with the relay's published pin | `:86` `decision == .acceptPinned`; decision → `.reject(.noTrustAnchor)` |
| AC1: …rejected under a different pin | `:97` `decision == .reject(.pinMismatch)`; decision → `.reject(.noTrustAnchor)` |
| AC1: a pin over the whole certificate is not accepted | `:108` `decision == .reject(.pinMismatch)`; decision → `.reject(.noTrustAnchor)` |
| AC1: the pin is taken from the leaf, not the issuer | `:125` `decision == .reject(.pinMismatch)`; decision → `.reject(.noTrustAnchor)` (the chain check at `:120` passes) |
| AC2: a P-384 leaf fails closed… | `:137` `decision == .reject(.unsupportedKey)`; decision → `.reject(.noTrustAnchor)` |
| AC2: an RSA leaf fails closed… | `:147` `decision == .reject(.unsupportedKey)`; decision → `.reject(.noTrustAnchor)` |
| AC3: no pin with platform trust required defers… | `:159` `decision == .deferToPlatform`; decision → `.reject(.noTrustAnchor)` |
| AC5: …checks only the pin (follow-up #86) | `:183` `decision == .acceptPinned`; decision → `.reject(.noTrustAnchor)` |
| AC6: an accepted decision maps to useCredential | `:192` `disposition == .useCredential`; disposition → `rawValue: 2` (cancel) |
| AC6: a deferred decision maps to performDefaultHandling | `:199` `disposition == .performDefaultHandling`; disposition → `rawValue: 2` (cancel) |

**Two tests pass by construction against the stub, as predicted:** `AC4: no pin and no platform
trust is rejected`, and `AC6: a rejected decision maps to cancelAuthenticationChallenge` (one test
with four cases, one per `RelayTrustRejection`). The verifier's undo table is what shows they guard
something.

**Satisfiability probe, outside the repo.** A throwaway script ran the platform path on the fixture:
`SecCertificateCreateWithData` → `SecCertificateCopyKey` → `SecKeyCopyExternalRepresentation`. It
gave a 65-byte `04…` point for the stand-in, which wraps and hashes to `7pcXvn2K…`. The issuer gave a
65-byte point hashing to `issuerOwnPin`. P-384 gave 97 bytes and RSA gave 270 bytes (PKCS#1), so
`SPKIPin`'s wrapping refuses both. AC1 and AC2 can therefore be met through the real Security API,
and that confirms the "unverified" note in `spkiPin(of:)`.

### AC8 red evidence

`Tools/check.sh --red` on the working tree of the AC8 `Tests:` commit, which is the finished slice A
plus the AC8 tests and the `challengeDelegates` stub:

```
lint: ok
kit tests: fail on assertions (full log: .build/check/test.log)
app tests: ok
red: ok it compiles and fails on assertions (kit: fail, app: pass; logs in .build/check).
check: ok — red for the right reason (61s)
```

Kit: 523 tests in 38 suites, **12 issues**. All 12 are in `TLSChallengeHandlerTests.swift`: six
tests, each failing for both `request` and `socket`. The earlier 12 trust-decision tests stay
green. The fake-trust check at `:140` passes.

| Test | Failure (`TLSChallengeHandlerTests.swift`), both sessions |
|---|---|
| AC8: …the matching certificate with useCredential and a credential | `:144` `answer == ChallengeAnswer(disposition: .useCredential, hasCredential: true)`; answer → `nil` |
| AC8: …cancels a certificate under a different pin | `:158` `answer == …cancelAuthenticationChallenge…`; answer → `nil` |
| AC8: a platform-trust transport leaves the server-trust challenge to the system | `:172` `answer == …performDefaultHandling…`; answer → `nil` |
| AC8: …no pin and no platform trust cancels the challenge | `:188` `answer == …cancelAuthenticationChallenge…`; answer → `nil` |
| AC8: a pinned transport leaves an HTTP Basic challenge to the system | `:206` `answer == …performDefaultHandling…`; answer → `nil` |
| AC8: a server-trust challenge without a trust is left to the system (today's behaviour) | `:223` `answer == …performDefaultHandling…`; answer → `nil` |

None pass by construction.

## Verification

Verified twice on 2026-10-15 by an agent that did not build the branch. Round 1 covered AC1–AC7 at
`501727a`. Round 2, below the first table, covered AC8 and the raised AC7 floor at `ff93079`.
Neither `b0a1821` nor `8620638` touches `decide`, `disposition` or `RelayServerKey`, so the round 1
undos still apply.

**Round 1 (AC1–AC7, at `501727a`).** Each undo is one edit to
`Sources/DSHRemoteKit/Network/RelayTransport.swift`, run with
`swift test --disable-sandbox --filter TLSTrustDecisionTests`. It was then restored with
`git checkout -- .`, and the full kit suite was confirmed green (517 tests) before the next undo.
Line numbers are in `TLSTrustDecisionTests.swift`.

| AC | Undone how | Test failure with it undone |
|---|---|---|
| AC4 | (a) no pin and no platform trust accepts: `.reject(.noTrustAnchor)` → `.acceptPinned` (the old `.useCredential` branch) | **guarded.** `AC4: no pin and no platform trust is rejected` `:170` `decision == .reject(.noTrustAnchor)`; decision → `.acceptPinned` |
| AC1 | (b) the leaf is the last certificate in the chain: `?.first` → `?.last` | **guarded.** `AC1: the pin is taken from the leaf, not the issuer` `:125`, decision → `.acceptPinned`. Also `AC5: …checks only the pin` `:183`, decision → `.reject(.pinMismatch)` |
| AC2 | (c) any leaf key is pinned: if the P-256 wrap fails, hash the raw external representation instead of returning `nil` | **guarded.** `AC2: a P-384 leaf fails closed…` `:137` and `AC2: an RSA leaf fails closed…` `:147`, `decision == .reject(.unsupportedKey)`; decision → `.reject(.pinMismatch)` |
| AC1 | (d) a mismatched pin is accepted: `: .reject(.pinMismatch)` → `: .acceptPinned` | **guarded.** `AC1: the same certificate is rejected under a different pin` `:97`, `AC1: a pin over the whole certificate is not accepted` `:108`, `AC1: the pin is taken from the leaf, not the issuer` `:125`; each gives decision → `.acceptPinned` |
| AC3 | (e) no pin with platform trust accepts with a credential instead of deferring: `.deferToPlatform` → `.acceptPinned` (→ `.useCredential`) | **guarded.** `AC3: no pin with platform trust required defers…` `:159` `decision == .deferToPlatform`; decision → `.acceptPinned` |
| AC5 | (h) "both" means both: a matched pin with `requiresPlatformTrust` gives `.deferToPlatform` | **guarded.** `AC5: …checks only the pin (follow-up #86)` `:183` `decision == .acceptPinned`; decision → `.deferToPlatform` |
| AC6 | (f) a rejection maps to `.performDefaultHandling` instead of cancel | **guarded.** `AC6: a rejected decision maps to cancelAuthenticationChallenge` `:211` fails for all 4 cases (`.noLeafCertificate`, `.unsupportedKey`, `.pinMismatch`, `.noTrustAnchor`); disposition → `rawValue: 1` |
| AC6 | swap the accept and defer dispositions | **guarded.** `AC6: an accepted decision maps to useCredential` `:192`, disposition → `rawValue: 1`. `AC6: a deferred decision maps to performDefaultHandling` `:199`, disposition → `rawValue: 0` |
| AC1–AC6 | `git revert --no-commit 719996c` (back to the stubs), then `git revert --abort` | 10 of 12 fail, the same set as the Red evidence |
| AC7 | Floor line present: `Network/RelayTransport.swift 48` (`Tools/must-test.txt:10`). (1) `TLSTrustDecisionTests.swift` deleted, `Tools/check.sh --fast` | **guarded.** `coverage: FAIL Network/RelayTransport.swift is at 39.19%, below its must-test floor of 48%`. The ratchet also fires (`86.62% is below the baseline 87.08%`); `check: RED … - coverage` |
| AC7 | (2) floor raised to 60 with every test present, `Tools/check.sh --fast`, to show the floor alone turns it red | **guarded.** `coverage: ok 87.08%`, then `coverage: FAIL Network/RelayTransport.swift is at 51.65%, below its must-test floor of 60%`; `check: RED (fast, 21s) - coverage` |

In round 1, the delegate adapter was not guarded: with `TransportDelegate` ignoring the decision
and answering `.useCredential` with `URLCredential(trust:)`, all 517 kit tests passed. AC8 was
added for that gap, and round 2 shows it is now guarded.

**Round 2 (AC8 and the AC7 floor of 64, at `ff93079`).** Each undo is one edit to
`RelayTransport.swift`, run with
`swift test --disable-sandbox --filter "TLSChallengeHandlerTests|TLSTrustDecisionTests"`. It was
restored with `git checkout -- .`, and the full kit suite was confirmed green (523 tests) before and
after each undo. Line numbers are in `TLSChallengeHandlerTests.swift`. "Both sessions" means the
`request` and `socket` cases of the test both fail.

| AC | Undone how | Test failure with it undone |
|---|---|---|
| AC8 | (m1) `didReceive` ignores the decision and always calls `completionHandler(.useCredential, URLCredential(trust: trust))`, the round 1 mutation | **guarded, both sessions, 6 issues.** `…cancels a certificate under a different pin` `:158` and `…no pin and no platform trust cancels the challenge` `:188` give answer → `useCredential, credential: present`, expected `cancelAuthenticationChallenge`, nil. `…platform-trust transport leaves the server-trust challenge to the system` `:172` gives the same answer, expected `performDefaultHandling`, nil |
| AC8 | (m5) a credential with every disposition: `let credential = URLCredential(trust: trust)` | **guarded, both sessions, 6 issues.** `:158` and `:188` give answer → `cancelAuthenticationChallenge, credential: present`. `:172` gives `performDefaultHandling, credential: present` |
| AC8 | (m2) the socket session is built with `delegate: nil` | **guarded, socket only, 6 issues.** Every AC8 test (`:144`, `:158`, `:172`, `:188`, `:206`, `:223`) on `socket` gives answer → `nil` |
| AC8 | (m9) the request session is built with `delegate: nil` | **guarded, request only, 6 issues.** Every AC8 test on `request` gives answer → `nil` |
| AC8 | (m3) the seam returns the request session's delegate for the socket: `(session.delegate, session.delegate)` | **not detected, and harmless alone.** 18 tests pass. Both sessions hold the same `TransportDelegate`, so this is equivalent at runtime |
| AC8 | (m4) m2 and m3 together: the socket session has no delegate, and the seam hides it | **NOT guarded.** 18 tests pass. See below |
| AC8 | (m6) HTTP Basic's own condition removed: the guard becomes `guard let trust = …serverTrust` | **guarded, both sessions.** `AC8: a pinned transport leaves an HTTP Basic challenge to the system` `:206` gives answer → `useCredential, credential: present` |
| AC8 | (m8) HTTP Basic split into its own guard, which cancels; nil trust is unchanged | **guarded, both sessions.** `:206` gives answer → `cancelAuthenticationChallenge, credential: nil`. Only this test fails |
| AC8 | (m7) nil trust split into its own guard, which cancels; HTTP Basic is unchanged | **guarded, both sessions.** `AC8: a server-trust challenge without a trust is left to the system (today's behaviour)` `:223` gives answer → `cancelAuthenticationChallenge, credential: nil`. Only this test fails |
| AC7 | The floor line is `Network/RelayTransport.swift 64` (`Tools/must-test.txt:10`). (1) Delete `TLSChallengeHandlerTests.swift`, then run `Tools/check.sh --fast` | **guarded.** `coverage: FAIL Network/RelayTransport.swift is at 50.72%, below its must-test floor of 64%`. The ratchet also fires (`87.02% is below the baseline 87.67%`). `check: RED (fast) - coverage` |
| AC7 | (2) With every test present, raise the floor to 70 and run `Tools/check.sh --fast` | **guarded.** `coverage: ok 87.67% (baseline 87.67%)`, then `coverage: FAIL Network/RelayTransport.swift is at 67.99%, below its must-test floor of 70%`. `check: RED (fast) - coverage` |

Two undos are still **not guarded by any test**. Both are known, and neither is a regression:

- **The `challengeDelegates` seam can hide a socket session that has no delegate (m4).** The AC8
  tests reach the delegates through `challengeDelegates`, which is production code. If a later
  change both built the socket session without the delegate and pointed the seam at
  `session.delegate`, every test would pass. That takes two coordinated edits, and the seam's
  comment says why it reads back from each session. A reviewer must check that
  `challengeDelegates` stays `(session.delegate, socketSession.delegate)`. If only one of the two
  edits is made, a test fails (m2), or nothing changes in behaviour (m3).
- **The `.noLeafCertificate` branch of `decide`.** Changing `return .reject(.noLeafCertificate)` to
  `return .acceptPinned` leaves all 12 trust tests green. The builder said the branch can't be
  reached offline, because a `SecTrust` can't have an empty chain. **I agree.** I checked with a
  scratch program on macOS (2026-10-15):
  `SecTrustCreateWithCertificates([] as CFArray, SecPolicyCreateSSL(true, …), &trust)` returns
  `-50` (`errSecParam`) and leaves `trust` nil, and `NSNull()` gives the same result. The AC6
  mapping test covers only `RelayTrustDecision.reject(.noLeafCertificate).disposition`. It does not
  cover the `decide` branch that produces it. The branch is defensive code against a platform
  invariant, and it fails closed as written. Nothing would notice if someone made it fail open.

Other checks:

- The fixture's pins were recomputed independently with `/opt/homebrew/bin/openssl` (SHA-256 over
  `x509 -pubkey | pkey -pubin -outform der` for the leaf, issuer, P-384 and RSA certificates, and
  SHA-256 over the leaf's DER). All five match `expectedPin`, `issuerOwnPin`, `p384OwnPin`,
  `rsaOwnPin` and `leafWholeCertificatePin`.
- Version impact: PATCH agrees with RELEASING.md ("a hardening fix"). There is no bump, and the
  Security line is under `## [Unreleased]` in `CHANGELOG.md`. AC8 adds tests and an internal
  property only, so the impact is unchanged. The coverage baseline (87.67) and the measured value
  agree, so nothing needs raising.
- `Tools/check.sh` (full):
  - Round 1, on `501727a`: green in 401s. Kit: 517 tests in 37 suites, coverage 87.08% against a
    baseline of 87.08%.
  - Round 2, on `ff93079`: green in 152s. Kit: 523 tests in 38 suites, coverage 87.67% against a
    baseline of 87.67%.
  - Both rounds: lint, models, version and guard-tests ok; app builds ok in Debug and Release; app
    tests passed (4 tests in 2 suites).
- S2 checklist:
  - [x] A wrong pin is rejected: `AC1: the same certificate is rejected under a different pin`,
    `AC1: a pin over the whole certificate is not accepted` and
    `AC1: the pin is taken from the leaf, not the issuer`.
  - [x] A missing pin falls back to platform trust, never to "accept anything":
    `AC3: no pin with platform trust required defers to the system's check` and
    `AC4: no pin and no platform trust is rejected`.
  - [x] `dsh-smoke` against a live relay, 2026-10-15, built at `ff93079`, run against Dan's local
    relay at `https://127.0.0.1:3443` (harness 0.2.0-rc.2 plus the relay fork). Dan approved running
    it. The steps followed `Smoke/README.md`: mint a throwaway device `smoke-test-68`, run with the
    claim's pin, run with a wrong pin, then revoke.
    - The claim's pin equals the pin re-derived from `~/.dsh/relay/relay-cert.pem`.
    - Right pin: `connect: OK`, `status: connected`, `sessions: 2 total`, `SMOKE OK`, exit 0. A real
      handshake delivers the server-trust challenge to the adapter, on both the request session and
      the socket session, and a matching pin is trusted.
    - Wrong pin (`AAAA…=`): `connect: FAILED`, `status: hostUnavailable`, `error: socket was not
      established within 10.0s`, exit 1 after 10 s. The connection is refused and never trusted. It
      surfaces as an establishment timeout, not as a pin mismatch; #89 tracks that.
    - The device was revoked: HTTP 303, and `revokedAt` is set in the relay's `state.json`.

## Notes for the next person

The test certificates are synthetic stand-ins around a captured public key. They prove the decision
against the relay's real pin without committing the relay's certificate, its SANs, or any private
key. To regenerate them, follow the commands in the fixture's `source` field with OpenSSL 3 or
later; new keys mean new values for every pin except `expectedPin`. The fixture is base64 DER, not
PEM, because the redaction test in `FixtureProvenanceTests` refuses `-----BEGIN`.

Dan's relay has rotated its key since `Fixtures/relay-spki-pin.json` was captured on 2026-10-07: on
2026-10-15 the live pin no longer matched `7pcX…`. That does not invalidate the fixtures. They are a
known vector, a public key and the pin the relay published for it, not a statement about the
current relay.
