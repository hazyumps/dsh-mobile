# DSH Remote — iOS app target

The app is generated from [project.yml](project.yml) with
[XcodeGen](https://github.com/yonaskolb/XcodeGen), so the project file is not
in git. `DSHRemote` depends on the `DSHRemoteKit` package at the repository
root by local path, which is where the wire models, the transport layer, and
their tests live.

```sh
brew install xcodegen          # once
cd Apps/DSHRemote
xcodegen generate              # writes DSHRemote.xcodeproj
open DSHRemote.xcodeproj
```

Building for a simulator needs no Apple identity:

```sh
xcodebuild -project DSHRemote.xcodeproj -scheme DSHRemote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build-app \
  CODE_SIGNING_ALLOWED=NO build
```

## Installing on a phone

This machine currently has **no code-signing identity** (`security find-identity -v -p codesigning`
reports none), so a device install needs one first:

1. Open the project in Xcode and select the `DSHRemote` target.
2. Signing & Capabilities → choose your Team. A free Apple ID works for a
   personal build; the bundle identifier may need to be unique to your account.
3. Select your iPhone and Run.

Xcode writes the team into the project when you pick it, but since the project
is generated, put it in `project.yml` instead (`DEVELOPMENT_TEAM`) so a
regenerate does not lose it.

Verified on 2026-10-08: `xcodebuild -destination 'generic/platform=iOS'
CODE_SIGNING_ALLOWED=NO build` **succeeds**, so the app compiles for a device
architecture and signing is the only thing standing between it and the phone —
not a code or platform problem. Xcode also carries a team record already
(`IDEProvisioningTeamByIdentifier` in its defaults) from a previous sign-in, so
picking a team again may be quicker than first-time setup.

## What the app does today

`HostsView` is the v1 landing screen. Pairing works end to end: paste the
relay's pairing JSON, see the host and key it pins, claim the one-time code,
and the device token goes into the keychain while the host's nonsensitive
metadata goes to `hosts.json` in Application Support. Forgetting a host
deletes its credential and says plainly that it does not revoke the device at
the relay.

Connecting to a saved host, listing its sessions, and the chat itself are the
next slices. The status badge already carries text as well as a symbol, per
SPEC §3.1.

## Two environment blockers on this machine

- **No code-signing identity** (`security find-identity -v -p codesigning`
  reports none), so a device install needs an Apple ID in Xcode first — see
  above.
- **No iOS simulator runtime is installed.** `xcrun simctl runtime list -v`
  reports zero disk images. The two runtimes `xcodebuild` mentions
  (`iOS-18-5`, `iOS-26-2`) are dangling references to images that are gone,
  which is why it offers no simulator destination at all. The earlier
  "CoreSimulator is out of date" message was a stale service job, and it
  clears the first time `simctl` runs.

  To run locally, install a runtime — several GB:

  ```sh
  xcodebuild -downloadPlatform iOS
  ```

  or Xcode → Settings → Components → iOS Simulator. Until one exists,
  `-destination 'generic/platform=iOS Simulator'` still *builds*; it just
  cannot *run*.


