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

Once you are signed in (Xcode → Settings → Accounts), the whole remaining step is
two commands:

```sh
# the team id appears beside your Apple ID in Xcode → Settings → Accounts,
# or as IDEProvisioningTeamByIdentifier in the Xcode defaults
perl -pi -e 's/^(\s*DEVELOPMENT_TEAM:).*$/$1 "YOURTEAMID"/' project.yml
xcodegen generate

# build and install straight to a connected phone; -allowProvisioningUpdates
# lets Xcode create the development certificate and profile for you
xcodebuild -project DSHRemote.xcodeproj -scheme DSHRemote \
  -destination 'platform=iOS,name=YOUR_IPHONE' \
  -allowProvisioningUpdates build
```

`xcodebuild -showdestinations -project DSHRemote.xcodeproj -scheme DSHRemote`
lists the exact device names to pass to `-destination` if you would rather not
type one from memory. Without `-allowProvisioningUpdates` the first device build
fails on the missing profile, which reads like a code error and is not one.

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

The app connects to saved hosts, lists sessions, follows conversations, sends
prompts, and answers questions. The status badge carries text and a symbol.

Returning from the background automatically opens a new connection with the
stored credential and refreshes the session list and open conversation. Temporary
failures retry while foregrounded with backoff; there is no reconnect approval.
Backgrounding cancels retries and closes the socket. A revoked credential or
changed certificate stops recovery and shows the reason.

The open screen keeps its messages and draft during reconnection and waits for
a fresh snapshot before enabling sends. It does not replay prompts or answers.
This is in-memory retention, not draft/history restoration after iOS terminates
the app. Session-list errors preserve the cached list and do not relabel a
healthy connection as unavailable.

Recovery is covered by offline transport tests and an iOS simulator build.
Physical-phone validation is still needed: open a conversation, type a draft,
lock/unlock or switch apps, then confirm that new host output appears and the
draft remains. Repeat with a temporarily unavailable network. The independently
diagnosed host session-log inconsistency can still prevent session listing;
reconnection does not repair host files or provide a stable remote hostname.

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


