# DSHRemoteKit — Stage 1 foundation

Wire types and credential storage for the iPhone companion, as a Swift package: no UI,
no networking, no app target. `swift test` on this Mac builds and exercises everything.

```sh
swift test
```

Swift 6 language mode, strict concurrency, no external dependencies. Every type that can
cross an actor is `Sendable`; nothing here holds mutable global state.

## Verified against captured bytes

Each claim below is checked by a test that decodes the file named beside it. The captures
are the six files in the repository's `Fixtures/` directory, taken from the patched
`dsh-relay` in front of harness `0.2.0-rc.2` (SPEC §12).

| Surface | Fixture | What the tests pin |
|---|---|---|
| `PairingPayload` | `pairing-payload.json` | all seven keys, the `v` ↔ `version` mapping, re-encode back to the captured key set |
| Pairing validation | same, mutated | wrong `kind`, wrong `v`, non-HTTPS `url`, empty `code`, expired `expiresAt` each refused with its own error; expiry judged against a caller-supplied `EpochClock` |
| `PairingClaimResponse` | `pairing-claim-response.json` | `deviceId`, `token`, `expiresAt`, `fingerprint` |
| `RelayErrorResponse` | `forbidden-unpaired.json` | the relay's 403 body, `error` and `message` only |
| `RPCRequest` / `RPCArguments` | `rpc-request.json` | `type`, `rpcId`, `method`, `payload.args`, and the `_request` wrapper this harness generation requires |
| `RPCResponse` / `RPCError` | `rpc-response-typed-error.json` | `result.ok == false` on an HTTP 200, plus `error.code` **and** `error.details.endpoint` together |
| `SessionSummary` | `rpc-response-session-list.json` | the seven row keys, all three rows, `projections.kind`/`asOfSeq`, and every projected field Stage 1 reads |
| Tolerance (SPEC §5) | all, mutated | unknown keys and unrecognised values decode instead of failing; `next-turn`/`next-step` dash keys map correctly |
| `KeychainSecretStore` attributes | — | `kSecClassGenericPassword` + `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, pinned from the query the store builds |
| `SecretStore` behaviour | — | `InMemorySecretStore` store/read/overwrite/delete round-trip keyed by host UUID, instance isolation, idempotent delete |
| Fixture coverage | every file | a capture added to `Fixtures/` without a decode test fails the suite |

## Unverified or assumed

- **The live Keychain round-trip is not exercised in every environment.** On a machine
  or CI sandbox that refuses Security writes, `keychainRelayTokenRoundTrip` prints
  `SKIP: …` and passes without claiming the round-trip ran. The observed refusals here
  were `100001` on the file-based keychain and `-34018` (`errSecMissingEntitlement`) on
  the data-protection keychain. Run the suite from a normal signed context to confirm
  the add/read/update/delete path, and on a physical iPhone before relying on it
  (SPEC §7).
- **`InMemorySecretStore` is the tested store.** Everything above the protocol is
  verified; only the `SecItem` calls themselves depend on the environment.
- **Absent versus JSON `null` is not distinguishable.** `goal`, `subagent`, and `todos`
  are `null` in all three captured rows, and `Decodable` maps both forms to `nil`. Their
  real shapes are unknown, so they are typed `JSONValue` rather than guessed.
- **`projections.kind` is only ever `"sequenced"`.** Decoded as a `String` so another
  kind cannot break the list; what any alternative means is unknown.
- **Element shapes the captures never show.** `subagentCatalog`, `userQuestions.active`
  /`.settled`, and `inbox`'s two queues are empty arrays in every row, so their element
  types stay `JSONValue`. Stage 2 needs the question element shape for SPEC §6.7.
- **Units are stated, not proven.** `expiresAt`, `updatedAt`, and `lastPromptAt` are read
  as epoch milliseconds, per SPEC §6.3 and the magnitude of the captured values. The
  `…Ms`, `…Tokens`, and `contextWindow` numbers carry no unit on the wire, so nothing
  renders them as a user-facing figure yet (SPEC §3.7 gates exactly this).
- **`cwd` is not a workspace key.** SPEC §3.3 groups sessions by the host's workspace
  registry; no capture shows how `cwd` maps to a workspace ID, so the string is kept raw
  and nothing is derived from it.
- **Only `session/list` is captured.** The `_request` wrapper is proven for that method
  alone; SPEC §6.2 also mentions named `request` objects, and per-endpoint argument names
  remain to be resolved against the installed harness.
- **`result.ok` and `result.error` are not assumed exclusive.** A response carrying both
  decodes, because no capture proves it cannot happen.
- **A non-string `type` is a hard decode failure, by choice.** Unknown *values* are
  tolerated; a wrong *kind* is a protocol incompatibility (SPEC §6.9) and is reported as
  one.
- **`isExpired` boundary is `expiresAt <= now`.** Nothing in the captures or SPEC says
  which side of exact equality is safe; the stricter reading is used.
- **`plainUrl` is decoded and ignored,** per SPEC §3.2 step 1. An HTTPS `url` beside an
  HTTP `plainUrl` still validates.
- **Nothing here pins TLS.** The SPKI `fingerprint` is carried as an opaque base64
  `String`; computing and comparing SHA-256 over DER SubjectPublicKeyInfo, and refusing
  a pin mismatch, is Stage 1 task 6 (SPEC §6.3, §8 A02).
- **No stream frames.** `item`/`error`/`end` and the `$events` ready frame (SPEC §6.4)
  are not in any capture, so no type models them yet.

## Layout

```text
Models/JSONValue.swift          lossless JSON for shapes the captures do not prove
Models/EpochClock.swift         caller-supplied time in epoch milliseconds
Models/PairingPayload.swift     QR/pasted payload plus its validation rules
Models/PairingClaimResponse.swift  /relay/pair success and refusal bodies
Models/RPCEnvelope.swift        unary request/response envelopes and the typed error
Models/SessionSummary.swift     session/list rows and their projections
Persistence/KeychainStore.swift SecretStore, KeychainSecretStore, InMemorySecretStore
```

Host identifiers — session IDs, device IDs, endpoints, provider and model names, error
codes — are opaque `String`s everywhere, per SPEC §5.
