# Risk flags

Some changes need more than green tests. This list says which, how to recognise them from the
diff, and what each one adds to the work. The planner ticks the flags when the plan is written
(not at review time); the verifier answers the checklist; the reviewer refuses a flagged PR
without it.

Two kinds:

- **Security flags (S1–S10)** add the `security` label and need the matching checklist answered in
  the PR, plus an explicit approval from the human who did not drive the change.
- **Care flags (C1–C6)** do not need a security review, but each carries an extra required step.

Every flag below exists because of something this codebase already has, or already got wrong.

---

## Security flags

| | Flag | You are touching it if the diff… | Extra requirement |
|---|---|---|---|
| **S1** | **A write over the network** | adds or changes a call that changes state on the host: prompt, create, cancel, answer, approval (`$events/result`), upload, select model/preset, pairing claim | A test that scripts a 429 and a 502 and asserts **exactly one** request. The call goes through `DshRpcClient.mutate` or a write API with no retry-policy parameter. `Tools/lint.sh` catches `retryPolicy: .none` (#63). |
| **S2** | **TLS and pinning** | touches `Network/RelayTransport.swift` (the `URLSessionDelegate` challenge handling, `RelayPinningPolicy`), `Network/SPKIPin.swift`, or how a pin reaches a transport | Tests for accept *and* reject. Run `dsh-smoke` against a live relay (`Smoke/README.md`) and record the result. No policy that accepts any certificate. |
| **S3** | **Pairing** | touches `PairingPayload`, `PairingClient`, the claim flow in `AppModel`, or anywhere a fingerprint is read from a response | The payload is validated in the kit, not just the UI. A pin learned from the network is called out in the PR (SPEC §3.2 says it never is). |
| **S4** | **Secrets and the host lifecycle** | touches `KeychainStore` / `SecretStore`, `SavedHostStore`, pair / forget / disconnect | A test that reloads from disk after the operation (forget is persisted, #65). No secret in `hosts.json`, a log, an error string, or a fixture. |
| **S5** | **Size and shape of untrusted input** | parses or buffers anything from the network or a file: mux frames, HTTP bodies, attachments, base64 | A stated bound, enforced *before* the bytes are read, with a test at the limit and one past it. The mux socket dies on an oversized frame. |
| **S6** | **Files from outside the app** | uses `fileImporter`, security-scoped URLs, `PhotosPicker`, attachment staging | The file is copied while the scope is held, and the scope is released after (#66). Type and size are checked. |
| **S7** | **Debug affordances** | adds a `DSH_*` launch variable, a `ProcessInfo...environment` read, or anything under `#if DEBUG` | It is inside `#if DEBUG` (`Tools/lint.sh` checks), it is listed in `Apps/DSHRemote/README.md`, and the Release build passes. `DSH_ANSWER` can approve an approval: nothing like it may reach Release. |
| **S8** | **Platform permissions** | changes `project.yml` `info:` keys or entitlements: privacy usage strings (`NS…UsageDescription`), push, background modes, URL schemes, App Transport Security | Say what the user will be asked and why. No ATS exceptions. A new URL scheme or notification category is S10 too. |
| **S9** | **What leaves the app's sandbox** | logs, diagnostics export, the pasteboard, notification text (it shows on the lock screen), error strings shown in the UI | No tokens, no pairing codes, no session content. `Diagnostics` is content-free by design; keep it that way. |
| **S10** | **Input from outside the app** | handles notification `userInfo`, a deep link, a URL scheme, or a pasted payload | Treat it as untrusted: validate, and route only to things the user could have opened anyway. |

### Security checklist

Copy the rows for the ticked flags into the PR and answer each one. "N/A" needs a reason.

**S1 writes**
- [ ] Every new or changed write is sent exactly once on 429, 502 and a dropped connection — test names: …
- [ ] No write takes a retry-policy parameter; `Tools/lint.sh` is clean without a new allowlist entry
- [ ] An uncertain outcome is reported to the user, not replayed (`AGENTS.md`, "Writes are never retried")

**S2 TLS and pinning**
- [ ] A wrong pin is rejected — test: …
- [ ] A missing pin falls back to platform trust, never to "accept anything" — test: …
- [ ] `dsh-smoke` run against a live relay: date, result

**S3 pairing**
- [ ] `PairingPayload.validate()` runs in the kit before the claim
- [ ] The claim is not retried (it is single-use, and a 429 backoff eats its lifetime)
- [ ] Where the stored pin comes from is stated

**S4 secrets**
- [ ] The token is only in the Keychain (`AfterFirstUnlockThisDeviceOnly`)
- [ ] After forget + relaunch: host gone, token gone, drafts gone — test: …

**S5 bounds**
- [ ] The limit, its value, and where it is enforced (before reading)
- [ ] Tests at the limit and one past it

**S6 files**
- [ ] Copied while the security scope is held; the scope is stopped after the copy
- [ ] Type and size checked before upload

**S7 debug affordances**
- [ ] Inside `#if DEBUG`; `Tools/check.sh` (Release build) green
- [ ] Documented in `Apps/DSHRemote/README.md`

**S8 permissions**
- [ ] The prompt text the user sees, and why the app needs it
- [ ] No ATS exception, no unneeded entitlement

**S9 leaving the sandbox**
- [ ] Nothing secret or session-content in logs, diagnostics, pasteboard, notifications, or error text

**S10 outside input**
- [ ] Malformed input is rejected with a test; routing cannot reach a screen the user could not

---

## Care flags

| | Flag | You are touching it if the diff… | Extra requirement |
|---|---|---|---|
| **C1** | **Persisted formats** | changes what is written to `hosts.json`, `selection.json`, `Drafts/drafts.json`, `Drafts/navigation.json`, or the Keychain item layout | A test that decodes the **previous** format (a fixture written by the old code) and keeps the user's data. While `0.x` this is a **MINOR** bump ([RELEASING.md](RELEASING.md)). Today a file that fails to decode loads as empty and is overwritten — a format change without a migration silently deletes drafts (#67). |
| **C2** | **The protocol** | changes `Protocol/`, regenerates `Sources/DSHRemoteKit/Generated/`, or hand-models a new payload | `python3 Tools/generate-models.py --check` clean; a decoded shape that changed is at least MINOR. A hand-modelled payload has a captured fixture with its date and command. |
| **C3** | **Concurrency** | adds an `actor`, a `Task {}`, `@MainActor` changes, `@unchecked Sendable`, `nonisolated(unsafe)` | Any escape from the compiler's checking (`@unchecked`, `unsafe`) has a comment saying why it is safe, and the reviewer reads it. Tests observe a signal, never `Task.sleep`. |
| **C4** | **Device-only behaviour** | relies on the Keychain on iOS, notifications, the camera, background execution, real network conditions | Add the `device` label; note what was verified on a physical iPhone and what was not. The simulator does not prove these. |
| **C5** | **The relay, host or tunnel** | needs the host to change, or works around a host gap | Out of bounds for a client change (`AGENTS.md`, "Boundaries"). File a `relay` issue; the app says honestly that the feature is not available. |
| **C6** | **UI with no kit test** | changes behaviour that lives only in a SwiftUI view | Move the rule into the kit and test it there (#69). If it truly cannot move, add a `DSH_*` affordance so it can be reached without a tap and record what was checked by eye. |
