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

This machine has a valid Apple Development identity, and its team matches the one
already committed to [project.yml](project.yml):

```sh
security find-identity -v -p codesigning
#  1) … "Apple Development: ph@dontbuck.com (7JS22WHNBB)"   1 valid identities found
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
#  … OU=U6LC736TBG …
grep DEVELOPMENT_TEAM project.yml
#  DEVELOPMENT_TEAM: "U6LC736TBG"
```

Read the **OU** for the team. The parenthesised value in the certificate's common
name is the certificate ID, not the team, and the two look alike enough to be
mistaken for a mismatch on a certificate that is in fact fine.

So the remaining step is choosing the destination, not creating an identity:

1. Open the project in Xcode and select the `DSHRemote` target.
2. Signing & Capabilities should already show the team from `project.yml`.
3. Select your iPhone and Run.

Verified 2026-10-09: the identity exists and its team matches `project.yml`. A
device install has **not** been re-run since, so that path is unblocked on paper
rather than proven.

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

## Environment state

Both blockers this section used to list are gone, verified 2026-10-09:

- **A code-signing identity exists**, and its team (OU `U6LC736TBG`) matches
  `DEVELOPMENT_TEAM` in `project.yml` — see *Installing on a phone* above.
- **An iOS simulator runtime is installed.** `xcrun simctl runtime list`
  reports `iOS 27.0 (24A434) — Ready`. The simulator can therefore *run*, not
  only build, so `-destination 'platform=iOS Simulator,name=…'` is usable and
  a screen can be looked at rather than merely compiled.

`xcodebuild -showdestinations -project DSHRemote.xcodeproj -scheme DSHRemote`
lists the concrete destinations on this machine, which is the honest answer to
"what can I run" and is cheaper than reading this paragraph.

Still outstanding, and not an environment problem: physical-phone validation of
the recovery behaviour described above. An installed runtime is not a phone.


