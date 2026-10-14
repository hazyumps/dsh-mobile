# iOS primer for this repo

For someone who knows how to program but has not shipped an iOS app. It explains only what you
need to work here, and why the repo is shaped the way it is. The app's own build-and-run details
are in `Apps/DSHRemote/README.md`.

## Two halves: a package and an app

| | `DSHRemoteKit` (the kit) | `Apps/DSHRemote` (the app) |
|---|---|---|
| What | A Swift Package: plain Swift, Foundation, CoreGraphics/ImageIO. No UI. | A SwiftUI iOS app that uses the kit. |
| Where | `Sources/DSHRemoteKit/`, tests in `Tests/DSHRemoteKitTests/` | `Apps/DSHRemote/Sources/` |
| Builds with | `swift build` / `swift test` — on your Mac, no simulator | Xcode / `xcodebuild`, for the iOS Simulator or a device |
| Tests | ~500, run in under a second | none, on purpose |

`Package.swift` declares the kit for **both iOS 18 and macOS 14**. That is the trick that makes
`swift test` fast: the kit's tests run as an ordinary macOS process. The price is that kit code
cannot import `UIKit` or `SwiftUI` — which is also the point, because anything that can be tested
without a screen belongs there (`AGENTS.md`).

So when you are about to put an `if` in a view, ask whether it is a *rule* (ordering, filtering,
what state follows what event). If it is, it goes in the kit, with a test, and the view just reads
the answer.

App tests would mean XCTest UI tests: they boot a simulator, drive it by accessibility labels, take
minutes, and fail intermittently. Agents are bad at them, and so are laptops on battery. Issue #30
tracks adding a small target later; until then, the kit is where tests go.

## The Xcode project is generated

An iOS app normally lives in an `.xcodeproj`, a large machine-written file that conflicts in every
merge. This repo does not commit one. `Apps/DSHRemote/project.yml` describes the app, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) writes the `.xcodeproj` from it:

```sh
cd Apps/DSHRemote && xcodegen generate     # after pulling, and after changing project.yml
open DSHRemote.xcodeproj                   # if you want Xcode's UI
```

Settings changed in Xcode's UI are lost the next time someone regenerates. Change `project.yml`.

## Info.plist and the version

`Info.plist` is the app's manifest: its name, version, and the sentences iOS shows when the app
asks for a permission. XcodeGen writes it from the `info:` section of `project.yml`; it is committed
so the version is visible in a diff, and `Tools/check-version.sh` fails if the two disagree.

- `CFBundleShortVersionString` is the version people see (`0.2.0`); `CFBundleVersion` is the build
  number, which must always increase. See [RELEASING.md](RELEASING.md).
- **Privacy usage strings** (`NSCameraUsageDescription`, `NSLocalNetworkUsageDescription`, …): if
  the app touches the camera, photo library, local network and so on without the matching key, iOS
  terminates it on the spot. The text is what the user reads in the permission prompt. The QR
  scanner (#18) will need `NSCameraUsageDescription`. Changing these is risk flag S8.

## Debug and Release

Every build is either **Debug** (what you run while developing: no optimisation, assertions on) or
**Release** (what ships: optimised). Code inside `#if DEBUG … #endif` does not exist in Release —
not "turned off", absent from the binary.

This repo uses that for the `DSH_*` launch variables: test affordances that open a screen, seed a
draft or even answer an approval at launch, because a simulator driven from the command line cannot
tap. They must never reach a shipping build, so each one is inside `#if DEBUG` (`Tools/lint.sh`
checks), and `Tools/check.sh` builds Release to prove that nothing outside depends on them. Until
#64, nothing did build Release, and it had quietly stopped compiling.

Pass a launch variable to the simulator with the `SIMCTL_CHILD_` prefix:

```sh
SIMCTL_CHILD_DSH_TRACE=1 xcrun simctl launch --console-pty booted net.fernlabs.dshremote
```

## Simulator and device

The simulator runs the app as a Mac process pretending to be an iPhone. It is close, not the same.
Only a physical device tells the truth about: the Keychain's iOS behaviour, notifications, the
camera, background execution, and real network conditions (Wi-Fi to cellular, sleep). Work that
depends on those gets the `device` label (RISK-FLAGS.md, C4) and says what was checked on a phone.

**Signing.** A simulator build needs no identity. A device build must be signed by an Apple
developer team; `project.yml` carries the team that builds today (`DEVELOPMENT_TEAM`). To build for
your own phone without changing the committed file, override it on the command line:

```sh
xcodebuild -project Apps/DSHRemote/DSHRemote.xcodeproj -scheme DSHRemote \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<your team id> build
```

A free Apple ID can sign for your own device; the app then expires after seven days.
`Apps/DSHRemote/README.md` has the full device walkthrough.

## The Keychain

The Keychain is the operating system's encrypted store for secrets. The relay's device token lives
there (`Persistence/KeychainStore.swift`), with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
readable once the phone has been unlocked after boot, never copied to another device or a backup.
Everything else (`hosts.json`, drafts) is a plain file in the app's sandbox.

On macOS, the kit's tests use the real login Keychain for one suite and `InMemorySecretStore` for
the rest. SwiftPM's sandbox blocks Keychain access (error `-34018`), which is one reason the suite
runs with `--disable-sandbox`.

## Files from the Files app: security-scoped URLs

An iOS app can read only its own sandbox. When the user picks a file in the system picker
(`.fileImporter`), the app gets a *security-scoped* URL: readable only between
`url.startAccessingSecurityScopedResource()` and `stopAccessingSecurityScopedResource()`. Reading it
outside that window fails, or works by accident when the file happens to be local. The safe pattern
is to copy the file into the app's own storage while access is held, then work on the copy (#66,
RISK-FLAGS.md S6).

## Swift Testing

New tests use **Swift Testing**, not the older XCTest:

```swift
import Testing
@testable import DSHRemoteKit

@Suite("Retried writes")
struct RetriedWriteTests {
    @Test("AC1: an approval is sent once on a 502")
    func approvalSentOnce() async throws {
        let transport = StubRelayTransport(responses: [
            .json(status: 502, Data(#"{"error":"bad gateway"}"#.utf8)),
            .json(status: 200, Data(#"{"ok":true}"#.utf8)),
        ])
        // ... build the client on `transport`, send the approval, expect the failure ...
        let sent = await transport.recordedRequests
        #expect(sent.count == 1)    // a retry would have sent 2
    }
}
```

- `#expect` records a failure and carries on; `#require` stops the test (use it to unwrap).
- Tests run **in parallel, in one process**, by default. Two tests sharing a singleton race each
  other, and one test that crashes (`fatalError`, a force-unwrap of `nil`) ends the whole run.
- `swift test --disable-sandbox --filter RetriedWriteTests` runs one suite.

`GeneratedModelTests.swift` is still XCTest; both kinds run under `swift test`.

## Swift 6 strict concurrency

The project compiles with Swift 6's complete concurrency checking: the compiler refuses code that
could let two threads touch the same mutable state. In practice:

- An `actor` protects its own state; calling into it is `await`.
- `@MainActor` means "only on the main thread" — SwiftUI views and `AppModel` are main-actor.
- `Sendable` marks a type safe to hand between threads.

When the compiler complains, the fix is almost always to move state behind an actor or make a
value type `Sendable`. `@unchecked Sendable` and `nonisolated(unsafe)` tell the compiler to stop
checking; they need a comment that proves safety, and a reviewer who reads it (RISK-FLAGS.md, C3).

## SwiftUI in one paragraph

A view is a `struct` whose `body` describes the screen as a function of state; SwiftUI re-runs
`body` when the state it read changes. `AppModel` is an `@Observable` class holding app-wide state.
`.task { }` on a view starts async work when the view appears and cancels it when it goes —
which is why `AGENTS.md` says to publish state only once its dependencies exist: a `.task` that
runs before a store is set reads `nil` and does not run again.

## Commands you will use

| | |
|---|---|
| `Tools/setup-dev.sh` | once per machine |
| `Tools/check.sh` / `--fast` | before pushing (the hook runs it anyway) |
| `swift test --disable-sandbox --filter <Suite>` | the inner loop |
| `cd Apps/DSHRemote && xcodegen generate` | after pulling or editing `project.yml` |
| `xcrun simctl list devices` / `xcrun simctl boot "iPhone 18 Pro"` | find and start a simulator |
| `xcrun simctl install booted <path to .app>` | install a simulator build |
| `tea issues` / `tea pulls` | gitea from the terminal |
