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
- **CoreSimulator is older than this Xcode** (`1051.50.0` against `1171.7.0`),
  so `xcodebuild` reports "Simulator device support disabled". Building for
  `generic/platform=iOS Simulator` still succeeds, but *running* in a
  simulator needs Xcode or CoreSimulator updated.

