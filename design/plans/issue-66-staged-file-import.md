# Issue #66: file import releases security-scoped access before upload; raw upload unbounded

**Status:** red tests written; awaiting gate 1 (tests). The plan was approved by Dan on 2026-10-15
as written (`7aec420`), including the new `AttachmentUploadFailure.unreadable(reason:)` case and the
PATCH version impact; the approval is posted on #66 ("Plan approved"). Tests written 2026-10-15 by
the planner agent.
**Branch:** `issue-66-staged-file-import`
**Version impact:** PATCH. This is a hardening fix: an oversized or unreadable file is now refused
instead of sent. The kit's public API only grows. `upload(…byteCount:)` keeps its signature and
ignores the argument, so no caller breaks. The two new `AttachmentUploadFailure` cases do break an
exhaustive `switch` in a caller. The only such caller is the app, and this PR updates it. We read
that as additive. If the reviewer applies RELEASING.md's "public kit API changes incompatibly" row
strictly, it is MINOR; say so at gate 1. The PR adds a line under `## [Unreleased]` → Fixed.

## Context

When a file is picked from Files, iOS grants the app a *security scope*: permission to read the
file that lasts only from `startAccessingSecurityScopedResource()` to
`stopAccessingSecurityScopedResource()`. `ConversationView.swift:159-169` starts the scope, `defer`s
the stop, and hands the URL to a `Task`. The `defer` runs when the closure returns, which is before
the Task's upload reads the file. So the upload reads a file the app no longer has permission to
read. It works only by accident, for a local file that happens to be cached. Nothing is ever
copied, although `DraftStore.swift:5-7` and the doc comment on
`DshBareEndpointClient.uploadFileBinary(…fileURL:)` both say a copy is made. SPEC §3.6 (l.137)
says "copy selected files into protected app staging storage; release security-scoped access
promptly". It also sets a 20 MiB per-file cap and says that cap is the app's limit, not the
harness's (l.149). `AttachmentUploader` enforces that cap only on the base64 fallback, and only
from the `byteCount` its caller supplies. `AppModel.attachFile` passes `0` when it cannot stat the
file, and the fallback treats 0 as "measure it yourself".

## Acceptance criteria

- **AC1 (the reproduction): the raw route refuses an oversized file before sending anything.**
  `AttachmentUploader.upload` measures the file and refuses it before any request when the file is
  larger than `byteLimit`. It throws `.tooLarge(byteCount:limit:)` and records zero requests. A
  file exactly at the limit is still sent. The default `byteLimit` is
  `AttachmentUploader.byteLimit` = 20 MiB, and both routes use it (SPEC §3.6).
- **AC2: the size comes from the file on disk, never from the caller.** A caller that passes a
  `byteCount` smaller than the file cannot get the file past either cap: not the new one, and not
  the fallback's `fallbackLimit`. The parameter stays in the signature and is ignored (see
  "API shape").
- **AC3: if the size cannot be read, the file is refused, not treated as 0.** A URL that cannot be
  measured as a regular file (missing, or a directory) is refused before any request.
- **AC4 (the scope reproduction): a staged copy outlives its source.**
  `AttachmentStaging.stage(_:byteLimit:)` copies the file to `<directory>/<UUID>/<name>` inside the
  one synchronous call that also starts and stops the security scope. The copy is still readable
  after the source is deleted. It keeps the source's file name, and the staging directory is
  created if it is missing.
- **AC5: staging checks size and type before it copies.** A file over the limit throws
  `.tooLarge`, and a non-regular file throws `.unreadable`. In both cases nothing is left in the
  staging directory. A file exactly at the limit is staged.
- **AC6: staged copies do not accumulate.** `discard(_:)` removes a staged copy together with its
  UUID folder. `sweep()` removes everything in the staging directory, so copies left behind by a
  killed launch are cleared.
- **AC7: the app wires it up.** `AppModel.importFile(at:to:)` stages the file, then calls
  `attachFile` on the copy, then discards the copy once the upload has settled, whether it
  succeeded or failed. An over-limit pick shows a message that names the 20 MiB as *this app's*
  limit (SPEC §3.6) and leaves nothing staged. `AppModel.init` sweeps the staging directory. Both
  the importer closure and the DEBUG `DSH_ATTACH` seed call `importFile`.
- **AC8: the scope cannot be misused again unnoticed.** `Tools/lint.sh` fails on
  `startAccessingSecurityScopedResource` anywhere in `Sources/` or `Apps/` except
  `Sources/DSHRemoteKit/Persistence/AttachmentStaging.swift`. No allowlist entry is needed, because
  after this change there are no other uses.

Also in the diff, with no test: a comment on `allowedContentTypes: [.item]` saying why it stays
(the host takes arbitrary files, so size is the bound, not type). The `DraftStore.swift` header
comment and the `uploadFileBinary(…fileURL:)` doc comment are corrected to name
`AttachmentStaging` as the place the copy is made. `AttachmentUploader`'s doc comment changes from
"the raw route has no such limit" to the single cap. `AppModel.attachFile`'s comment ("nothing is
discarded on failure") is reconciled with discard-after-settle. `Apps/DSHRemote/README.md` notes
that `DSH_ATTACH` now goes through staging. A CHANGELOG line is added.

## API shape

- `AttachmentUploader`: add `public static let byteLimit = 20 * 1024 * 1024` and an init parameter
  `byteLimit: Int = AttachmentUploader.byteLimit`, which tests inject. **Keep** `fallbackLimit` and
  `fallbackByteLimit` under their current names: existing `Tests:` lines use them, and
  `Tools/guard-tests.sh` would fail a rename.
- `upload(sessionId:name:fileURL:byteCount:)`: **keep and ignore `byteCount`**, and say so in its
  doc comment. Dropping it would be an incompatible public-API change (RELEASING.md: MINOR while
  0.x) and would touch every existing uploader test line. A later MINOR can drop it.
- `AttachmentUploadFailure` gains `.tooLarge(byteCount: Int, limit: Int)` and
  `.unreadable(reason: String)`. **Gate-1 question:** `.unreadable` is the one addition beyond the
  approved design. The alternative is to reuse `.transport(reason:)`, which was rejected because
  `AppModel.describe` renders it as "That upload may not have arrived". That would be false for a
  file that was never sent.
- New `Sources/DSHRemoteKit/Persistence/AttachmentStaging.swift`:
  `public struct AttachmentStaging: Sendable { init(directory: URL); func stage(_ source: URL,
  byteLimit: Int = AttachmentUploader.byteLimit) throws -> StagedFile; func discard(_: StagedFile);
  func sweep() }` and `public struct StagedFile: Sendable, Hashable { url, name, byteCount }`.
  `stage` throws `AttachmentUploadFailure` (`.tooLarge`, `.unreadable`), so the app has one place
  that describes failures. The copy gets `.completeFileProtectionUntilFirstUserAuthentication`, the
  same protection `DraftStore.writeAtomically` uses; on macOS it does nothing. The app's directory
  is `FileManager.default.temporaryDirectory/AttachmentStaging`: it is not backed up, it is
  app-private, and its contents only need to last one upload.
- Two gates, both measured from the file: staging refuses before it copies, so a 2 GB pick is never
  copied, and the uploader re-measures the copy. If the source grows during the copy, the bytes
  actually sent are still bounded.
- The launch sweep runs **synchronously** in `AppModel.init`. A sweep in a detached task could race
  a launch-time `DSH_ATTACH` import and delete its copy.

## Test list

Kit tests go in **new files**, so no earlier `Tests:` lines are touched:
`Tests/DSHRemoteKitTests/AttachmentUploadLimitTests.swift` and `AttachmentStagingTests.swift`. They
use injected limits of 16 bytes, so no 20 MiB file is written. They reuse `StubRelayTransport` and
the 2026-10-09 captured upload body, and each test gets its own temp directory, so no state is
shared. App tests go in `Tests/DSHRemoteTests/FileImportTests.swift`.

| AC | File | Test name | Fails today because |
|---|---|---|---|
| AC1 | `AttachmentUploadLimitTests` | `"AC1: the raw route refuses a file one byte over the limit before sending anything"` | raw route has no cap: `(bare.recordedRequests.count → 1) == 0`, and "an error was expected but none was thrown" (receipt `ee7fc538…` returned) |
| AC1 | `AttachmentUploadLimitTests` | `"AC1: a file exactly at the limit is sent"` | guard: passes today and must keep passing (S5: at the limit) |
| AC2 | `AttachmentUploadLimitTests` | `"AC2: a caller that under-reports the size cannot get an oversized file past the limit"` | 64-byte file, `byteCount: 1`, limit 16: `(count → 1) == 0`, no error thrown |
| AC2 | `AttachmentUploadLimitTests` | `"AC2: the fallback measures the file, not the caller's byteCount"` | raw 404, `fallbackLimit: 16`, `byteCount: 1`: the fallback trusts the 1, so `(rpc.recordedRequests.count → 1) == 0` and `receipt-from-fallback` is returned instead of `.tooLargeForFallback(byteCount: 64, limit: 16)` |
| AC3 | `AttachmentUploadLimitTests` | `"AC3: a file whose size cannot be read is refused, not sent as zero bytes"` | missing file: the stub transport never opens `bodyFile`, so `(count → 1) == 0`, no error thrown |
| AC4 | `AttachmentStagingTests` | `"AC4: a staged copy stays readable after the source is gone"` | stub returns the **source** URL and copies nothing (today's behaviour): `(FileManager.contents(atPath: staged.url.path) → nil) == 6 bytes`; `staged.url` is not inside the staging directory |
| AC5 | `AttachmentStagingTests` | `"AC5: a file one byte over the limit is refused before anything is copied"` | stub does not check size: "an error was expected but none was thrown" |
| AC5 | `AttachmentStagingTests` | `"AC5: a file exactly at the limit is staged"` | stub copies nothing: `staged.url` is not inside the staging directory |
| AC5 | `AttachmentStagingTests` | `"AC5: a directory is refused and nothing is copied"` | stub does not check the type: "an error was expected but none was thrown" |
| AC6 | `AttachmentStagingTests` | `"AC6: discard removes the staged copy and its folder"` | stub `discard` is a no-op: `(fileExists(staged.url) → true) == false` |
| AC6 | `AttachmentStagingTests` | `"AC6: sweep removes copies left by an earlier launch"` | stub `sweep` is a no-op: `(contentsOfDirectory.count → 1) == 0` |
| AC7 | `FileImportTests` (app) | `"AC7: an import that cannot upload leaves nothing staged and says why"` | stub `importFile` does nothing: `(model.attachmentError → nil) == "This phone is not connected to a harness."` |
| AC7 | `FileImportTests` (app) | `"AC7: an import over the app limit is refused with a message naming the app's 20 MiB limit"` | sparse 20 971 521-byte file (`FileHandle.truncate`, so it costs no disk); stub does nothing: `attachmentError → nil`; the test expects it to contain "20 MiB" and "this app" |
| AC7 | `FileImportTests` (app) | `"AC7: launch clears copies an earlier launch left behind"` | stub `init` ignores `stagingDirectory`: `(contentsOfDirectory.count → 1) == 0` |
| AC8 | `Tools/lint.sh` (command, not a test) | the verifier re-adds the call to `ConversationView.swift` and expects `lint: FAIL security-scope …` | the rule does not exist yet; today `grep -rn startAccessingSecurityScopedResource Apps Sources` → 1 hit, `ConversationView.swift:167` |

The first AC4 test is the scope reproduction. A unit test on macOS cannot hold or revoke a real
security scope: for a plain file URL, `startAccessing…` returns `false`. So the test pins what the
scope bug *causes*: the upload reads the source, which can go away, instead of a copy. The ordering
"copy while the scope is held" is guarded by construction: one synchronous function with the stop
in a `defer`, plus the AC8 lint rule. It is also checked on a device (C4).

**Stubs in the `Tests:` commit**, so that both suites compile and fail on assertions instead of
failing to compile:

- Kit (`Sources/`): `AttachmentUploader.byteLimit`; the `byteLimit:` init parameter, stored and
  unused; the two new failure cases; and `AttachmentStaging` / `StagedFile`. The stub `stage`
  returns `StagedFile(url: source, …)` without copying anything, which is exactly today's
  behaviour. The stub `discard` and `sweep` do nothing. No `fatalError`.
- App (an exception to "stubs only in `Sources/`", because `AppModel` lives in the app target and
  `--red` compiles the app tests): `AppModel.init(draftsDirectory:stagingDirectory:)`, with the new
  parameter ignored; an `importFile(at:to:) async` that does nothing; and placeholder `.tooLarge` /
  `.unreadable` arms in `describe`. Without those arms, the new enum cases make its `switch`
  non-exhaustive, and the app would not compile. `guard-tests` covers only `Tests/`, so builders
  replace these freely.

## Slices

| Slice | ACs | Files | Notes |
|---|---|---|---|
| A: uploader | AC1–AC3 | `Sources/DSHRemoteKit/Services/AttachmentUploader.swift`; doc comment of `uploadFileBinary(…fileURL:)` in `Network/DshBareEndpointClient.swift` (~l.200-216 only) | measure once at the top of `upload()` with `.fileSizeKey` and `.isRegularFileKey`; the fallback's guard uses the same measurement |
| B: staging | AC4–AC6 | `Sources/DSHRemoteKit/Persistence/AttachmentStaging.swift` (new); `DraftStore.swift` header comment; `Tools/must-test.txt` (`Persistence/AttachmentStaging.swift  90   # security-scoped copy, S6`; set the floor a few points under what is measured) | |
| C: app + lint | AC7, AC8 | `Apps/DSHRemote/Sources/AppModel.swift` (`attachFile`/`describe` ~l.955-1005, `init` ~l.275); `ConversationView.swift` (importer ~l.159-170, `DSH_ATTACH` seed ~l.678-687); `Tools/lint.sh` (new `security-scope` block plus a header line); `Apps/DSHRemote/README.md`; `CHANGELOG.md` | stage off the main actor (C3); run last, or merge last, because its behaviour depends on A and B being real |

**Coordination with #63**, which is running in parallel. #63 is changing `DshBareEndpointClient.init`
(~l.138-161) and `submitEventResult` (~l.253-273), and adds `WritesAreSentOnceTests.swift`. This
issue **must not touch** those regions, `Tests/DSHRemoteKitTests/NetworkTests.swift`, or
`Tools/lint-allowlist.txt`. Slice A may reword the `uploadFileBinary` bodies and doc comments only.
Slice C also leaves `AppModel.swift` ~l.395-415 (the uploader's construction) alone, because #63
may change its retry policy there. A conflict in `Tools/lint.sh`'s header comment is possible; it
is resolved by keeping both rule descriptions.

## Risk flags

- [x] **S5 size of untrusted input.** One 20 MiB cap (`AttachmentUploader.byteLimit`), measured
  from the file on disk. Staging enforces it before copying, and `upload()` enforces it before any
  request. Tests at the limit and one byte past it, on both routes and in staging.
- [x] **S6 files from outside the app.** The file is copied inside the call that holds the scope,
  and the scope is stopped in that call's `defer`. Type: must be a regular file. `.item` stays, by
  decision. Size is checked before the copy and again before the upload.
- [x] **S1 writes (adjacent).** The upload is a write. This change only adds refusals *before* it.
  It does not touch the send or the retry path, and it adds no retry. The single-send tests for
  429/502 on the upload belong to #63; the checklist answer points there.
- [x] **S7 debug affordances.** The `DSH_ATTACH` seed changes, but stays inside `#if DEBUG`; README
  wording updated.
- [x] **S9 leaving the sandbox.** The new error strings carry byte counts and the limit only: no
  file name, no content.
- [x] **C3 concurrency.** Staging runs off the main actor (a `nonisolated` or detached call from
  `importFile`). Tests observe directory contents and returned values, never `Task.sleep`.
- [x] **C4 device-only.** Real security-scope behaviour and file protection exist only on iOS.
  Before the PR, record one Files pick and one iCloud Drive pick on a physical iPhone, or say they
  were not done.
- [x] **C6 UI glue.** The rules live in the kit (B). The app glue is pinned by `FileImportTests`
  and can be reached without a tap through `DSH_ATTACH`.

## Sibling findings

| Where | Same mistake? | Disposition |
|---|---|---|
| `ConversationView.swift:167-169`: start scope, `defer` stop, `Task` reads later | the bug | AC4, AC7 |
| Other `start/stopAccessingSecurityScopedResource` uses | none: one hit in the repo | AC8 lint keeps it at one, in staging |
| Other `defer` + `Task {` patterns in `Apps/` | none: `grep -B1 -A4 'defer {'` finds only l.169 | AC8 covers the scope case; there is no cheap general lint |
| `ConversationView.swift:686` `DSH_ATTACH` seed uploads the raw path | same path, no staging, no app cap | AC7: it calls `importFile` |
| `AttachmentUploader.uploadAsBase64`: `byteCount > 0 ? byteCount : stat` | trusts the caller's size | AC2 |
| `AppModel.attachFile:974`: `fileSize ?? 0` | "absent is zero" | AC2/AC3: the value is ignored; slice C deletes the stat |
| `ConversationView.swift:153` PhotosPicker `loadTransferable(type: Data.self)` | S5: the whole image is loaded into memory, then `ImageAttachmentValidator` applies the 20 MiB cap, *after* the read | **Out of scope.** It holds no security scope. A bound before the read needs a file-backed `Transferable` and changes the in-memory `ImagePreparation` path. File a follow-up `client security` issue |
| `AttachmentReader` | bounded on the host's *declared* `bytes` before base64 decode. But the transport has already buffered the whole response, and the decoded length is never compared with the declared one | **Out of scope.** It is a response-size bound, which belongs with #67 (mux frame bound) or #23 (request budgets). Add a note to #67 |
| `DshBareEndpointClient.uploadFileBinary(…bytes:)` | no cap; its doc says the caller enforces one | **Out of scope.** No app caller; only `NetworkTests` uses it, and #63 owns that file |
| `seedImageIfAsked` `Data(contentsOf:)` (DEBUG) | unbounded read | **Out of scope.** The path comes from the developer at launch, not from untrusted input, and it is debug-only |
| `DraftAttachment.byteCount = 0` default, `storedRelativePath` never written | a persisted model that claims a copy exists | **Out of scope.** Nothing enforces anything with it, and changing it is C1. The comment is corrected in B |

## Out of scope

- **Keeping a failed upload's copy so the user need not pick it again.** SPEC §3.6 "keep the draft
  and attachments on a refusal" is not met today either: no staged attachment is persisted. The
  approved design discards the copy once the upload settles. Persisting copies so a draft can retry
  belongs with #49 or the drafts work. `attachFile`'s comment is changed so it no longer claims
  otherwise.
- Narrowing `.item`: kept by decision.
- The two follow-ups above (PhotosPicker bound, response-size bound).

## Red evidence

`Tools/check.sh --red`, 2026-10-15, on the `Tests:` commit's tree: lint ok, guard-tests ok,
`kit tests: fail on assertions`, `app tests: fail on assertions`,
`red: ok it compiles and fails on assertions (kit: fail, app: fail)`. Kit: 516 tests, 22 issues,
all in the two new suites; every existing test passes. App: 7 tests, 3 issues, all in
`FileImportTests`. Excerpts from `.build/check/test.log` and `.build/check/app-tests.log`:

```
AC1: the raw route refuses a file one byte over the limit before sending anything
  an error was expected but none was thrown and "UploadedAttachment(receiptId: "ee7fc538-…", …)" was returned
  thrown == .tooLarge(byteCount: limit + 1, limit: limit)   thrown → nil, expected .tooLarge(byteCount: 17, limit: 16)
  sent == 0                                                 sent → 1
AC1: a file exactly at the limit is sent                    passes (guard, as planned)
AC2: a caller that under-reports the size cannot get an oversized file past the limit
  an error was expected but none was thrown and "UploadedAttachment(receiptId: "ee7fc538-…", …)" was returned
  thrown == .tooLarge(byteCount: 64, limit: limit)          thrown → nil
  sent == 0                                                 sent → 1
AC2: the fallback measures the file, not the caller's byteCount
  an error was expected but none was thrown and "UploadedAttachment(receiptId: "receipt-from-fallback", …)" was returned
  thrown == .tooLargeForFallback(byteCount: 64, limit: limit)   thrown → nil
  sent == 0  (rpc)                                          sent → 1
AC3: a file whose size cannot be read is refused, not sent as zero bytes
  an error was expected but none was thrown and "UploadedAttachment(receiptId: "ee7fc538-…", …)" was returned
  sent == 0                                                 sent → 1
  expected .unreadable, got nil
AC4: a staged copy stays readable after the source is gone
  FileManager.default.contents(atPath: staged.url.path) == Data("abcdef".utf8)   → nil vs 6 bytes
  scratch.isStagedCopy(staged.url)   …/source/notes.txt is not <staging>/<UUID>/<name>
  staged.byteCount == 6              staged.byteCount → 0
AC5: a file one byte over the limit is refused before anything is copied
  an error was expected but none was thrown
AC5: a file exactly at the limit is staged
  scratch.isStagedCopy(staged.url)   …/source/edge.bin is not <staging>/<UUID>/<name>
  staged.byteCount == limit          staged.byteCount → 0
AC5: a directory is refused and nothing is copied
  an error was expected but none was thrown
  expected .unreadable, got nil
AC6: discard removes the staged copy and its folder
  !FileManager.default.fileExists(atPath: staged.url.path)   still there: …/source/notes.txt
AC6: sweep removes copies left by an earlier launch
  scratch.stagedEntries.count == 0   left behind: ["AA916DC0-…"]   count → 1
AC7: an import that cannot upload leaves nothing staged and says why
  model.attachmentError == "This phone is not connected to a harness."   model.attachmentError → nil
AC7: an import over the app limit is refused with a message naming the app's 20 MiB limit
  try #require(model.attachmentError)   model.attachmentError → nil
AC7: launch clears copies an earlier launch left behind
  scratch.stagedEntries.count == 0   left behind: ["A718A1D6-…"]   count → 1
```

Every failure is the one the test list predicts. Three things the builder should know:

- The two AC5 refusal tests also assert that nothing is left in staging. That assertion passes
  against the stub (it copies nothing) and guards against a real `stage` that copies first and
  checks after.
- The AC7 over-limit test runs with no host connected. It passes only if `importFile` stages, and so
  refuses the oversized file, **before** `attachFile` checks for a connection; otherwise the
  message would be "not connected". That is the planned order (stage, then upload the copy).
- The "this app" check in that test is case-insensitive, so the message may begin "This app's…".

## Verification

Verified 2026-10-15 by the verifier agent on `0865916`. Each AC was undone alone, its test run,
and the tree restored (`git checkout -- .` / `git revert --abort`). After the last restore, lint,
the kit suite (516) and the app suite (7) were green again and `git status` was clean.

| AC | Undone how | Test failure with it undone |
|---|---|---|
| AC1–3 | `git revert --no-commit 7272cc0` (all of slice A) | all four refusal tests fail: "an error was expected but none was thrown" (receipt `ee7fc538…`/`receipt-from-fallback` returned), `sent == 0` fails. The at-limit guard passes, as it should. |
| AC1 | removed only `guard size <= byteLimit` in `upload()` | AC1 over-limit: `thrown == .tooLarge(byteCount: limit + 1, limit: limit)`, `sent == 0` (also AC2 under-report) |
| AC1 | `<=` → `<` | "AC1: a file exactly at the limit is sent": `Caught error: .tooLarge(byteCount: 16, limit: 16)` |
| AC2 | `let size = byteCount > 0 ? byteCount : try Self.measure(fileURL)` (the old trust-the-caller rule) | both AC2 tests: `thrown == .tooLarge(byteCount: 64, …)` / `thrown == .tooLargeForFallback(byteCount: 64, limit: limit)`, `sent == 0` |
| AC2 | fallback gets the caller's `byteCount` instead of `size` | "AC2: the fallback measures the file…": "receipt-from-fallback" returned, `sent == 0` fails |
| AC3 | `let size = (try? Self.measure(fileURL)) ?? 0` | AC3: no error thrown, `sent == 0` fails, "expected .unreadable" |
| AC3 | removed the uploader's `isRegularFile == true` guard | **nothing fails** (516 pass). See finding 2. |
| AC4–6 | `git revert --no-commit 2445e75` (all of slice B) | all six staging tests fail (10 issues), as in the red evidence |
| AC4 | `stage` returns `url: source` instead of the copy | AC4: `contents(atPath: staged.url.path) == Data("abcdef")`, `isStagedCopy(staged.url)`; AC5 at-limit and AC6 discard fail too |
| AC5 | removed both size guards (before and after the copy) | "AC5: a file one byte over…": no error thrown, `stagedEntries.isEmpty` fails |
| AC5 | removed **only** the pre-copy size guard (copy first, check after) | **nothing fails.** See finding 1. |
| AC5 | `<=` → `<` before the copy | "AC5: a file exactly at the limit is staged": `Caught error: .tooLarge(byteCount: 16, limit: 16)` |
| AC5 | removed `isRegularFile == true` from staging's `measure` | **nothing fails.** See finding 2. |
| AC6 | `discard` no longer removes the folder | "AC6: discard…": `!fileExists(staged.url.path)`, `stagedEntries.isEmpty` |
| AC6 | `sweep` removes nothing | "AC6: sweep…": `stagedEntries.count == 0` |
| AC7 | `git revert --no-commit a85b874` | all three `FileImportTests` fail: `attachmentError == "This phone is not connected…"` (→ nil), `#require(model.attachmentError)`, `stagedEntries.count == 0` |
| AC7 | `importFile` skips the discard | "AC7: an import that cannot upload…": `stagedEntries.isEmpty` |
| AC7 | `AppModel.init` skips `staging.sweep()` | "AC7: launch clears copies…": `stagedEntries.count == 0` |
| AC7 | `importFile` calls `attachFile` on the picked URL, without staging | "AC7: an import over the app limit…": `message.contains("20 MiB")`, `contains("this app")` (the message is "not connected") |
| AC7 | over-limit message reworded without "this app"/"20 MiB" | same test, same two expectations |
| AC7 | importer closure calls `model.attachFile(at: url…)` instead of `importFile` | **nothing fails** (lint ok, app 7/7). See finding 3. |
| AC8 | re-added `startAccessingSecurityScopedResource` + `defer` stop + `Task { attachFile }` in the importer | `lint: FAIL security-scope Apps/DSHRemote/Sources/ConversationView.swift:171: let scoped = url.startAccessingSecurityScopedResource()` (also fires for a hit in `Sources/DSHRemoteKit/Services/`) |

Findings for the reviewer (not fixed; the verifier does not change tests or code):

1. **"Refused before anything is copied" (AC5, S5) is not guarded.** With the pre-copy size check
   removed, the post-copy re-measure throws `.tooLarge` and the catch deletes the folder, so the
   AC5 and AC7 over-limit tests cannot tell "never copied" from "copied, then cleaned up". A 2 GB
   pick would be copied in full before being refused, and nothing would notice. A test that could
   tell them apart: an over-limit source made unreadable (`chmod 000`). It can be measured but not
   copied, so check-first gives `.tooLarge` and copy-first gives `.unreadable`.
2. **The `isRegularFile` check is not independently guarded**, in the uploader or in staging. The
   only non-regular input in a test is a directory, and a directory reports `fileSize == nil` on
   macOS (probed 2026-10-15: `isRegularFile=false fileSize=nil`). The nil-size branch refuses it
   whether or not the type check exists. The uploader has no directory test at all, although AC3
   names "a directory". A FIFO (`mkfifo`) is not a regular file but does report a size, so it would
   guard the check.
3. **The view wiring is unguarded.** If the importer closure (or the `DSH_ATTACH` seed) is pointed
   back at `attachFile`, no test or lint fails. Without the scope call AC8 has nothing to match. The
   plan accepts this under C6. On a device, a pick from outside the sandbox would then fail to read
   rather than leak. It is the residual risk for the device check (C4).

- `Tools/check.sh` (full), 2026-10-15 on `0865916`: **green**, 174 s. Lint, models, version
  0.2.0 (238), guard-tests ok. Kit 516/516. Coverage ok 86.78% (baseline 86.83%). App Debug and
  Release ok. App tests 7/7 on "DSH Remote Tests".
- Coverage: the 86.78% is **not a drop caused by this PR**. `main` (`d5d6478`), measured the same
  way from a `git archive` copy, is **86.74%** (7397 lines, 981 missed); it was already 0.09 under
  the baseline, inside the 0.30 tolerance. The branch adds 97 kit lines with 10 missed (89.7%,
  above the kit average) and raises the total by 0.04. That is under the tolerance, so check.sh does
  not say "rose" and the baseline is not updated. The uncovered new lines:
  `AttachmentStaging.swift` 76 (the iOS-only `setAttributes` protection: `protection` is nil on
  macOS), 82 (the post-copy re-measure's throw), 86-89 (the catch cleanup), which together leave the
  file at 88.61% against its 85 floor; `AttachmentUploader.swift` 201 and 204 (`measure`'s
  not-regular-file and nil-size throws, findings 1–2). The builder named the staging lines; the two
  uploader lines are extra.
- Version impact: PATCH is consistent with RELEASING.md's "hardening fix" row. The two new cases on
  the public, non-frozen `AttachmentUploadFailure` break an exhaustive `switch` in a caller outside
  this repo. Read strictly, that is the "public kit API changes incompatibly" row, which is MINOR
  while 0.x. The plan raises this as a question for the human gate; it is still open.
- CHANGELOG: a line is under `## [Unreleased]` → Fixed (#66). `DSH_ATTACH` README row updated.
- Risk checklist: S5, S6, S1, S7, S9, C3, C6 are evidenced above or in the diff (S7: the seed is
  still inside `#if DEBUG`, and Release builds green). **C4 is not done by the verifier:** the
  physical-iPhone Files and iCloud Drive picks have to be recorded in the PR, or the PR has to say
  they were not done.

## Notes for the next person

- `stage` must stay **synchronous**. The bug was a scope whose lifetime ended at a suspension
  point it could not see. An `async` `stage` would let someone reintroduce that bug inside the
  function that exists to prevent it.
- The SPEC citations in `AttachmentUploader` and `AppModel` say "SPEC §9" for attachment rules, but
  §9 is the build sequence. The rules are in §3.6. Slice A/C fix the citations they touch.
