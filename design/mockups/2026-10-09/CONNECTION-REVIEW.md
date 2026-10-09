# DSH Remote connection investigation
Date: 2026-10-09
Scope: source review, read-only live diagnosis, isolated relay identity reproduction, and revised visual concepts. No running service, pairing, credential, session log, DNS, or app implementation was changed during the original investigation.

## Follow-up status on 2026-10-09

Patrick clarified that the phone failure occurs after returning to the app. Foreground recovery, fresh chat subscriptions, accurate connection/data-error separation, and explicit no-retry behavior for prompts/answers were subsequently implemented in the working tree. The package suite reports 193 passing tests, with live Keychain checks skipped, and the iOS simulator target builds. Physical-phone validation remains outstanding. The source defects and line references below describe the pre-fix investigation snapshot.

The two session storage mismatches still exist. A follow-up read-only check decompressed and parsed both files completely. Each contains exactly four valid JSON records: `session`, `permission/preset`, `sandbox/mode`, and `approval/policy`. Neither file contains chat message records. They are misfiled initialization stubs; “damaged conversation logs” would overstate what was found. No session data was moved, edited, or deleted.

The current design contract is [the mobile experience specification](../../MOBILE-UX-SPEC.md).

## Main finding: connecting works, then session listing fails

The existing Swift smoke executable reproduced:
```text
connect: OK
status: connected
clientId: present
sessions: FAILED
session persistence listing failed: corrupt session log [...]
header id [...] and cwd identify a different storage path
```

The offending file is physically under the Mac workspace storage directory, while its header still identifies a Linux working directory. The error calls the log corrupt, but the specific demonstrated fault is the disagreement between metadata and location; this is not proof of damaged conversation text.

Read-only examination of the first line of all 78 compressed v4 session logs found two with this Mac-directory/Linux-header mismatch:

| Session directory under ~/.dsh/sessions/--Users-patrick-repo-homelab--/ | Header cwd |
| --- | --- |
| session-017dd1d3-d661-4443-a265-b8f868cda821 | /home/patrick/repo/homelab |
| session-76242712-e309-46e7-94ff-25220cc3fc7d | /home/patrick/repo/homelab |

Both header IDs match their individual session directory names. All 78 first-line JSON records decoded; the remaining 76 did not have a Linux cwd. This scan did not validate every event or every possible corruption.

The installed app.asar package is 0.2.0-rc.2. Its dsh-session-query implementation wraps persistence.list() in one failure path: a rejected persistence listing becomes SESSION_QUERY_PERSISTENCE_FAILED. SessionListRequest exposes only an optional cursor, so a workspace filter is not available through that endpoint as an obvious workaround.

At the time of the investigation, AppModel.loadSessions(for:) caught this error, emptied the list, and set hostUnavailable (then Apps/DSHRemote/Sources/AppModel.swift:244). That conflated a working connection with failure to load host data. The subsequent app change preserves cached sessions and keeps the connection state independent of this loading error.

**Evidence boundary:** the live check ran the actual Swift transport/coordinator on the Mac through the relay's intentional loopback-operator path with a dummy bearer. It verifies pinned TLS, mux readiness, and the real session-list failure. It does not verify the iPhone's stored token, local-network permission, network route, or current installed build. No pairing was minted and no prompt was sent. The browser serving its shell/workspace list does not establish that the all-session listing endpoint works.

## Connection and recovery defects

| Finding | Evidence | Consequence |
| --- | --- | --- |
| Automatic reconnect is absent | ConnectionCoordinator.swift:1000 explicitly leaves it as the next slice; no foreground recovery in DSHRemoteApp.swift | Locking/unlocking or changing networks can leave a dead stream |
| UI status is copied at discrete operations | AppModel.swift:250–257; no continuous observation of coordinator status | Connected can remain visible after connection loss |
| Chat is marked open before data arrives | ChatView.swift:202–203; ChatSession.start() returns after sending the subscription | Blank chat is possible when the follow stream fails before its snapshot |
| Stream failures are hidden from chat | ChatSession.swift catch clears its pump without surfacing a chat-load error | A failed stream looks like a quiet or empty conversation |
| Normal end is not treated as disconnect | ConnectionCoordinator.drain handles thrown errors only | A logical end can leave connection state stale |
| Streamed text updates are count-gated | ChatView.swift:240 | Existing message text can stay stale as chunks arrive |
| Active host is not compared before connection reuse | AppModel.swift:275 | Selecting another saved host can use the old host |
| Drafts are view-local | ChatView.swift @State draft | Navigation/recreation can lose typed text |
| Prompt/answer retry override is ambiguous | ConnectionCoordinator.swift:497,549 pass .none to an optional; compiler resolves Optional.none | Default 429/502 retry remains enabled |

These are source findings, not claims that every defect has been reproduced on the physical phone. The session-list error is an independently reproduced host-data failure. Patrick's subsequent clarification that the problem occurs after returning to the app points to the missing foreground recovery path as a separate explanation for that symptom; the evidence does not establish a single cause for every phone failure.

## IP changes: three different cases

1. **Phone changes Wi-Fi or IP:** relay bearer authentication checks token identity, expiry, and revocation, not the phone's IP. The socket must reconnect, but changing phone IP alone does not require re-pairing. Cellular cannot route to a private LAN address without another network path.
2. **Mac changes IP:** the app saves one literal origin URL and implements no address rediscovery. A saved old address stops reaching the Mac.
3. **Relay reloads after its address set changes:** self-signed certificate loading compares the entire SAN set. A change invokes generate(), which creates a fresh EC key. The new SPKI fingerprint no longer matches the paired phone.

An isolated reproduction directly imported the relay's src/tls.ts, writing only to a new temporary directory:
```json
{
  "same_addresses_preserve_key": true,
  "changed_addresses_rotate_key": true,
  "old_phone_pin_rejects_changed_key": true,
  "live_relay_state_modified": false
}
```

Reproduce with:
```sh
node --experimental-strip-types Tools/diagnostics/relay-identity-probe.mjs /Users/example/repo/deepseek-harness-relay
```

This is a fingerprint comparison using generated certificates, not a simulated iPhone handshake. The app's pin comparison rejects unequal fingerprints. The important timing qualification is relay certificate loading/reloading; a DHCP change does not instantly rewrite a running TLS listener.

The current live listener is inside DeepSeek Harness on the Mac, port 3443, with upstream port 19387. Health responds on loopback and 10.1.0.138. Public certificate metadata still matches the earlier baseline. Health proves a responding relay, not a usable session catalogue. The desktop profile links the local 0.3.0 relay fork and disables compatibility address grants. Actual forwarding behavior comes from src/auth/index.ts and matching built lib/index.js; older memory notes about loopback exemption are inaccurate. Direct loopback remains privileged regardless of addressGrants; forwarded loopback requests must authenticate.

## Recommended order

1. **Repair the two session storage mismatches after preserving them.** A minimal preservation-first proposal is backing up the two directories, then restoring them to the header-derived --home-patrick-repo-homelab-- storage parent if that canonical location is confirmed unoccupied. This leaves historical Linux cwd intact. If these were intended as runnable Mac imports, use an explicit migration that validates workspace and embedded path semantics rather than blindly replacing strings. Both alter live harness data and require Patrick's explicit approval. No repair was performed.
2. **Build recovery into the app.** Observe connection state, own one coordinator per active host, reconnect while foregrounded with bounded jitter/backoff, refresh baselines and the selected conversation, and ignore late frames from an older generation. Stop retrying on real credential or identity failure. Treat normal closure as closure. Add foreground/network-change triggers and a lightweight foreground heartbeat.
3. **Make loading distinct from connectivity.** Show connecting, authenticating, loading workspaces/session data, and ready as separate phases. Await a snapshot or explicit empty result before claiming chat loaded. Surface host data errors without calling the network disconnected.
4. **Persist drafts and useful cached UI state.** Retain drafts by host/session, preserve scroll position and last selection, and show cached messages with a last-update marker. Keep typing available offline, but do not silently queue sends or approvals.
5. **Separate a host's identity from its location.** Keep a stable host identity and key. Reuse the key when renewing a direct relay certificate, or use explicit platform-CA trust for a stable public hostname. Never accept a replacement key just because discovery advertises it.
6. **Add remote reachability once the above works locally.** Keep dsh-relay as the authenticated gateway and use a stable hostname over an outbound tunnel for the desired no-phone-VPN experience.

## Remote path recommendation

For the product Patrick described, prefer a stable HTTPS hostname backed by an outbound tunnel from the machine running the harness. Cloudflare Tunnel is a practical candidate: its documented model maps a public hostname to a local service using outbound connections, without requiring a public origin IP. This is an architecture recommendation, not a deployment performed or an audit of Patrick's Cloudflare account. [Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/)

Conceptual path:
```text
iPhone native app
  → stable HTTPS/WSS hostname
  → authenticated public edge
  → outbound connector on the harness host
  → dsh-relay
  → the existing harness and workspaces
```

Keep per-device relay authentication and revocation. Do not treat the public hostname or the tunnel itself as authentication. If Cloudflare Access is added, the native app needs an explicit compatible login/session flow; an HTML login redirect is not a working native API authentication mechanism. Do not embed a shared administrative service token in the app.

Important implementation boundaries:
- A TLS-terminating proxy presents its own certificate, not the relay's certificate. Existing QR/claim payloads supply the relay fingerprint, and AppModel.swift:214 persists it. Therefore this is **not** a URL-only change: introduce an explicit endpoint trust mode and pairing contract appropriate for CA-validated remote HTTPS. Do not pin an automatically rotating edge key.
- Preserve forwarding headers and prove unauthenticated proxied HTTP and WebSocket requests receive no operator privilege. The relay's loopback exemption must never authorize an external tunnel client.
- Validate the allowed hostname, WebSocket upgrade, authentication, uploads, and reconnect before cutover. Verify the connector's HTTPS origin rather than turning certificate validation off.
- Cloudflare documents that edge restarts and idle timeout can terminate WebSockets; foreground heartbeat and reconnect remain necessary. [WebSocket behavior](https://developers.cloudflare.com/network/websockets/)
- If the connector runs on the Mac and targets loopback, changing the Mac's LAN IP does not change that local target. It still requires the Mac awake, network available, and the harness process running.
- A sleep-proof service would require an always-on harness host and its workspace files. A tunnel cannot execute work on a sleeping Mac; moving execution to Linux is a separate project.

| Option | What it solves | Tradeoff |
| --- | --- | --- |
| Stable local DNS/mDNS with persistent relay key | LAN address changes | Does not provide cellular/away-from-home access; iOS discovery is not implemented |
| Tailscale stable address/MagicDNS | Private reachability across networks | Requires the phone's Tailscale/VPN connection; does not itself fix app recovery or relay key rotation |
| Stable HTTPS hostname with outbound tunnel | No phone VPN; no dependence on the host's public/LAN address in the phone | Needs native-compatible authentication, corrected trust/pairing, and host connector lifecycle |

Tailscale documents that a registered node keeps its address across physical-network moves, so it is the simpler private-access alternative if a phone VPN is acceptable. [Tailscale address behavior](https://tailscale.com/docs/concepts/ip-and-dns-addresses)

## iOS background expectations

The app should remember the relationship and resume it automatically. It cannot promise a forever-live generic WebSocket while suspended. Apple describes limited time to finish work after backgrounding, followed by suspension. Save state, let the connection go when appropriate, and catch up when active. Background alerts require APNs plus a host-side sender, not a keep-connected toggle. [Apple background execution](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)

## Verification and limits

- Live relay health: successful on LAN address and loopback.
- Existing Swift smoke: pinned handshake and mux ready succeeded; session.list returned the exact persistence-path failure.
- Session headers: 78 inspected, two specific Mac-directory/Linux-header mismatches; no conversation body contents printed.
- Relay identity probe: same address set preserves key; changed set rotates key, reproduced with temporary state only.
- Swift package suite: 177 tests passed in the pre-fix snapshot this section describes; the follow-up foreground-recovery change took it to 193, matching the count in the status note above. Live Keychain round-trip/delete checks explicitly skipped in the restricted environment.
- No physical iPhone reproduction, live host migration, new pairing, session repair, or remote tunnel deployment.
- Visuals are proposals, not screenshots of implemented changes.

Acceptance for the next implementation: cold launch on LAN; an explicit session-data failure while transport remains connected; foreground return after lock; Wi-Fi/cellular transition over the selected remote path; relay restart; safe certificate renewal; denied local-network permission; expired/revoked credential; switching saved hosts; stream failure before first snapshot; draft retention; no duplicate submissions.

