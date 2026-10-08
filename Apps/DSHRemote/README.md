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

`HostsView` is the v1 landing screen, and `PairHarnessView` reads a pasted
pairing payload, validates it against `PairingPayload`, and shows the host it
points at and the key it pins. Claiming the code, listing sessions, and the
chat itself are the next slices; the status badge already carries text as well
as a symbol, per SPEC §3.1.
