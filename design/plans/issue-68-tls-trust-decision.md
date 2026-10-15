# Issue #68: Test the TLS/SPKI pinning decision without a live relay

**Status:** approved (Dan, 2026-10-15)
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

The planner (tests phase) owns the fixture, `Fixtures.swift`, `FixtureProvenanceTests.swift` and
the new test file.

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
- Exercising the delegate's `URLSession` plumbing itself, which needs a real handshake. `dsh-smoke`
  remains that test.
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

## Verification

*Filled in by the verifier.* The undos are: accept when there is no anchor (AC4), take the pin
from the issuer (AC1), skip the key-type check (AC2), and swap two dispositions (AC6). Each must turn
a test red.

| AC | Undone how | Test failure with it undone |
|---|---|---|
| | | |

- `Tools/check.sh`: …
- S2 checklist, including `dsh-smoke` against the live relay (date, result): …

## Notes for the next person

The test certificates are synthetic stand-ins around a captured public key. They prove the decision
against the relay's real pin without committing the relay's certificate, its SANs, or any private
key. To regenerate them, follow the commands in the fixture's `source` field with OpenSSL 3 or
later; new keys mean new values for every pin except `expectedPin`. The fixture is base64 DER, not
PEM, because the redaction test in `FixtureProvenanceTests` refuses `-----BEGIN`.
