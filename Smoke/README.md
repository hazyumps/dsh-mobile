# dsh-smoke

Runs the real `ConnectionCoordinator` against a live relay from macOS, where no
simulator is needed. This is the only executable in the package that performs a real
TLS handshake, so it is the only place the SPKI pinning path in
`URLSessionRelayTransport` is exercised at all — the tests use `StubRelayTransport`
and never open a socket.

What it does, in order:

1. builds an `Origin` with `.bearer(token)` and `RelayPinningPolicy.pinned(pin)`, which
   pins the given SPKI and sets `requiresPlatformTrust = false` (SPEC §3.2 step 3);
2. `connect()` — socket establishment, the `$events` open frame, then the ready frame
   (SPEC §6.4);
3. `sessions()` — `session/list` over the same origin, credential, and pin;
4. `shutdown()`.

It prints counts and booleans, never credentials or content: the device token is never
printed (and is scrubbed out of any error text), the server `clientId` is reported by
length only, and sessions are reported as counts rather than titles.

Exit codes: `0` every step succeeded, `1` a step threw, `2` bad arguments.

## Build

```bash
swift build --disable-sandbox --scratch-path .build-smoke
```

Binary: `.build-smoke/debug/dsh-smoke`. `swift run --disable-sandbox --scratch-path
.build-smoke dsh-smoke --help` works too.

## Mint a throwaway device token

A loopback request to `/relay/pair` is the operator and needs no credential (SPEC
§6.3). The pairing code is a one-time code that expires in a few minutes, so mint and
run in one sitting.

```bash
RELAY=https://127.0.0.1:3443

CODE=$(curl -sk "$RELAY/relay/pair" | sed -n 's/.*<div class="code">\([0-9]\{8\}\)<.*/\1/p')
CLAIM=$(curl -sk -X POST "$RELAY/relay/pair" \
  -H 'Content-Type: application/json' \
  -d "{\"code\":\"$CODE\",\"name\":\"smoke-test\"}")

export DSH_DEVICE_TOKEN=$(printf '%s' "$CLAIM" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
DEVICE_ID=$(printf '%s' "$CLAIM" | python3 -c 'import sys,json;print(json.load(sys.stdin)["deviceId"])')
PIN=$(printf '%s' "$CLAIM" | python3 -c 'import sys,json;print(json.load(sys.stdin)["fingerprint"])')
```

The claim answers `{deviceId, token, expiresAt, fingerprint}`. `fingerprint` is the pin
to pass as `--pin`; it equals the SHA-256 over the DER SubjectPublicKeyInfo of
`~/.dsh/relay/relay-cert.pem`, which you can re-derive independently:

```bash
openssl x509 -in ~/.dsh/relay/relay-cert.pem -pubkey -noout \
  | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | openssl base64
```

## Run

```bash
./.build-smoke/debug/dsh-smoke --origin "$RELAY" --pin "$PIN"
```

Expected output against a healthy relay that has sessions:

```
origin: https://127.0.0.1:3443
pinning: expectedSPKIPin=set(44 chars) requiresPlatformTrust=false
credential: bearer token present, 43 chars
connect: OK
status: connected (Connected)
generation: 1
clientId: present (length 36)
sessions: 42 total, 2 running
shutdown: status=offline (Offline)
SMOKE OK
```

## Revoke what you minted

```bash
curl -sk -X POST "$RELAY/relay/devices/revoke" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "deviceId=$DEVICE_ID"

python3 -c "
import json
s = json.load(open('$HOME/.dsh/relay/state.json'))
d = s['devices']['$DEVICE_ID']
print('revokedAt:', d.get('revokedAt'))
print('unrevoked:', [k for k, v in s['devices'].items() if not v.get('revokedAt')])
"
```

Revocation sets `revokedAt` on the entry; it does not delete it. Confirm `revokedAt` is
set and that the device is absent from the unrevoked list. Two things decide whether
that is observable in behaviour:

- **Loopback bypasses credential checks entirely.** From `127.0.0.1` the relay serves
  `/api/session/list` with a garbage token, and with no `Authorization` header at all
  (HTTP 200). So a run against `https://127.0.0.1:3443` proves the pin and the protocol,
  but proves nothing about the token. To exercise the credential, run against the LAN
  address the certificate covers (`https://192.0.2.10:3443` here), where an unpaired
  device gets `403 {"error":"forbidden"}`.
- **A revoked credential fails the WebSocket upgrade as a generic transport error.** A
  run against the LAN origin after revocation exits 1 with
  `error: transport interruption: URLError -1011` and `status: offline`, not
  `pairingRequired` — see the "known defect" note below.

## Negative controls

A well-formed but wrong pin (`32` zero bytes, base64) should never be trusted, which is
the whole point of pinning a self-signed relay:

```bash
./.build-smoke/debug/dsh-smoke --origin "$RELAY" --pin AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
```

**This currently hangs forever and has to be killed.** Expected per SPEC §6.9 is an
immediate `TLS pin mismatch: stop; show certificate changed`. See below.

## Known defect this tool found (2026-10-07)

Against relay `0.2.1` on this machine:

- A refused server-trust challenge never surfaces. With `expectedSPKIPin` set and not
  matching, `URLSessionWebSocketTask` never resumes either the `send` or the `receive`
  continuation, so `connect()` never returns — the establishment and readiness budgets
  (10 s each, SPEC §6.4) never fire, because `ConnectionCoordinator.withBudget` races the
  operation inside a `withThrowingTaskGroup`, and a task group awaits *all* of its
  children before the scope exits. A child parked on an unresumed URLSession
  continuation cannot be cancelled or timed out. The process sits idle with no socket
  work in flight (`sample` shows only the main thread).
- Consequences: SPEC §6.9's "TLS pin mismatch" row is unreachable, and any stall of that
  shape hangs the app's connect instead of ending in `hostUnavailable`.
- A revoked credential takes the same shape one step later: the WebSocket upgrade is
  refused with `403`, URLSession reports `URLError -1011`, and the client classifies it
  as `transport interruption` → `ConnectionStatus.offline`, which
  `isRecoverableWithoutUserAction` reports as retryable. SPEC §6.9 wants a relay 403 to
  explain the rejection and offer re-pair with no endless retry.

Both are client-side. Relaying is not at fault: with the correct pin the run succeeds,
and against a dead port the same code path fails fast with `-1004`.
