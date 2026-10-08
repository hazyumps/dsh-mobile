# Generated V1 models — what was generated, and what a reviewer should check

`Tools/generate-models.py` derives the Swift DTOs for the V1 remote surface from
`Protocol/endpoints.json` + `Protocol/schemas/`, and writes every artefact below.
Nothing here is hand-written except this file and `GeneratedModelTests.swift`.

```bash
python3 Tools/generate-models.py            # write (131 files)
python3 Tools/generate-models.py --check    # verify the tree matches (exit 1 on drift)
python3 Tools/generate-models.py --report   # inventory only, writes nothing
swift test --disable-sandbox --scratch-path .build-codegen
```

## Inventory

| | |
|---|---|
| Endpoints kept | **31** |
| Schemas generated | **48** (of 49 the 31 endpoints reference) |
| Schemas excluded | **1** — `SessionFollowFrame`, already hand-modelled |
| Nodes reused from `Models/` | **1** — the `session/list` row |
| Generated declarations | **177** — 134 `struct`, 30 `enum`, 13 `typealias` |
| Generated Swift | 50 files, 5,784 lines |
| Examples | 48 per-schema, 31 per-endpoint argument objects, + `manifest.json` |
| Example mutations | 146 `delete`, 31 `replace`, **0** `none` |
| Compiler warnings from `Generated/` | **0** |

Endpoints by group (the brief's grouping, and the manifest records it):

| Group | n | Endpoints |
|---|---|---|
| sessions | 12 | `session/list`, `create`, `follow`, `page`, `prompt`, `cancel`, `rename`, `control`, `projections`, `modelCatalog`, `selectModel`, `attachment` |
| commands | 2 | `commands/list`, `commands/execute` |
| models and presets | 7 | `llm/listProviders`, `llm/listConfigurableProviders`, `llm/discoverModels`, `agentPresets/list`, `agentPresets/read`, `agentPresets/select`, `permissionPresets/catalog` |
| workspace listing | 1 | `workspace/follow` |
| goals | 7 | `goals/get`, `create`, `edit`, `pause`, `resume`, `complete`, `clear` |
| user questions | 2 | `userQuestions/answer`, `userQuestions/attachWait` |

## Files

| Path | What |
|---|---|
| `Tools/generate-models.py` | the generator; standard library only, deterministic |
| `Sources/DSHRemoteKit/Generated/*.swift` | 48 schema files + `Endpoints.swift` + `Support.swift` |
| `Protocol/examples/*.json` | one example instance per generated schema |
| `Protocol/examples/endpoints/*.args.json` | one assembled argument object per endpoint |
| `Protocol/examples/manifest.json` | the index: endpoints, declarations, pointers, mutations, SHA-256 of every generated file |
| `Tests/DSHRemoteKitTests/GeneratedExampleRegistry.swift` | generated bridge from manifest entries to concrete Swift types |
| `Tests/DSHRemoteKitTests/GeneratedModelTests.swift` | hand-written; drives the registry and the manifest |

## `swift test`

`exit 0`. 124 swift-testing tests pass; `GeneratedModelTests` runs 14 XCTest
tests with 0 failures. `--check` reports `up to date: 131 file(s)`, and two
consecutive generator runs are byte-identical.

The guards were probed three ways and each one fails as intended:

1. appended a byte to a generated file → `testEveryGeneratedFileMatchesItsRecordedHash` fails;
2. made the generator emit one required property as optional → `testEveryGeneratedDeclarationDecodesItsExampleAndRejectsItsMutation` fails with *"the mutation delete(pointer: …) still decoded"*;
3. deleted one example file → `testEveryExampleFileDecodesIntoItsRootType` fails.

## Reuse and overlap — what was deliberately *not* regenerated

| Hand-written type | Overlapping schema | What was done |
|---|---|---|
| `MuxFrameValue` (+ `MuxSnapshot`, `DurableEventEnvelope`, `AssistantStreamFrame`) | `SessionFollowFrame`, the result of `session/follow` | **Excluded.** `SessionFollowResponse = MuxFrameValue`. Note: `SessionControlFrame` (the result of `session/control`) is a *different* union — `baseline`/`projection`, not `snapshot`/`event`/`assistant-stream` — and is **not** covered by `StreamFrames.swift`, so it is generated. |
| `SessionSummary` | the `items[]` row of `SessionListValue` | **Reused**, at `REUSED_NODES["…SessionListValue.json", "/items/0"]`. `SessionListValue.items` is `[SessionSummary]`; the row's nested types are not generated. The row schema marks `agentAvailable`, `sessionId`, `updatedAt`, `running`, `blank` required; `SessionSummary` requires only `sessionId`, so the generated `session/list` examples are a subset of what the schema allows. |
| `JSONValue` | every `$ref: #/$defs/JsonValueRemoteCodec*` and the same union written inline | **Reused**, everywhere. |
| `SessionProjectionValues` | the `values` object of `session/projections` | **Not reused, not reused by name.** `SessionProjectionsValue` is generated separately, so the module now has two models of the same object. They agree on the capture (`testCapturedSessionListResponseDecodesIntoTheGeneratedResult` decodes the same bytes through both paths). If only one should survive, delete the generated one and add a reuse entry — the generated one is the open-record version, the hand-written one has typed `plan`/`todos`/`subagent` fields. |
| `DurableEventEnvelope` | `SessionPage.records[].event` | Overlap **noted only**. `SessionPage` is the unary `session/page` result, not a mux frame, so it is generated whole — including its own `SessionPageRecordEvent`. Its `required` set is stricter than `DurableEventEnvelope`'s (the schema requires `type`, `seq`, `time`, `data`; the hand-written type makes `time` optional). |
| `PairingPayload`, `PairingClaimResponse`, `RPCEnvelope` types, `KeychainStore` | — | No descriptor schema reaches them. |
| `RPCEmptyRequest` | endpoints with no wire parameters | Reused for the empty argument object (7 of the 31). |

## Translation decisions a reviewer should check

Each is a choice the schemas do not make; the RISK column is what breaks if the
choice is wrong.

| # | Decision | Why | Risk |
|---|---|---|---|
| 1 | `{"type":"number"}` → `Int64` | Every numeric field on this surface is a counter, epoch-ms stamp, byte count or seq, and `Models/` already chose `Int64` for the same fields (`SessionSummary.updatedAt`, `SessionStats.*`, …). | A genuinely fractional host value fails to decode. `Double` would never fail but would be wrong for `seq`/`updatedAt`. |
| 2 | `{"const": c}` alone → the primitive of `c`; the literal is not enforced | Literal enforcement lives in the discriminated-union decoder, which switches on the very key the `const` pins. A *required* `const` property is still enforced as present. | A host sending `"type":"image"` in a `file` variant is not rejected by the variant struct — only by the union decoder, which is the path that runs. |
| 3 | A required key whose type admits `null` → `T?` | Swift's synthesised `init(from:)` uses `decodeIfPresent` for optionals. | **Absence is tolerated for those keys.** Four V1 fields: `SessionProjectionsValue.values.sessionListMetadata.lastPromptAt`, `.modelSelection.lastUsed`, `.modelSelection.next`, and `SessionControlFrame…value`. The manifest records enforcement as the generated code has it, not as the schema states it, and the mutation search skips these keys. Encoding a `null` is also not forced. |
| 4 | `record(string(), V)` → `[String: V]`; `intersection(object({…}), record(…))` → struct + `additionalProperties: [String: V]` | The projection registry is genuinely open (`plan` is unnamed in the descriptor and appears in the capture). Dropping unknown keys would lose it. | The catch-all is extra surface: the hand-written `SessionProjectionValues` does not have one. |
| 5 | Open enums whose catch-all case is `unrecognized(_:)`, not `unknown(_:)` | `unknown` is a real wire value — `SessionFollowRequest.address.mode` is `one-shot \| continuable \| unknown`, and `subagent.mode` too. | The name diverges from the hand-written `MuxFrameType`/`AssistantStreamFrameType` style. |
| 6 | Discriminated unions → enums with associated values, keyed by the member's string `const` (`type` first, then `kind`) | Matches the hand-written `MuxFrameValue`. A missing discriminator is a hard decode failure; an unrecognised one becomes `.unrecognized(type:value:)`. | A union whose members share a discriminator key but are not distinguishable by a string const is a generation failure, not a silent guess. That is deliberate. |
| 7 | Examples carry **every** declared property, plus one unnamed key (`dshUnnamed`) in each open record | A strictly-minimal instance of an all-optional object is `{}`, which exercises nothing and leaves no key to mutate. | The examples are not minimal in the strictest sense. They are valid instances of the schema; nothing in them is invented. |
| 8 | Names come from the `typeSymbol` alone: `@scope/pkg#a/b:c` → `ABC`, `@scope/pkg#Name` → `Name`; inline declarations append PascalCased JSON-path tokens (`Item`, `AdditionalProperty`, the union case) | Stable across runs and derived, not invented. | Long names for deep schemas (`SessionControlFrameBaselineValueProjectionsAdditionalPropertyValuesUserQuestionsActiveItemState`). Collisions are a hard failure, and one is currently impossible; the generator refuses to write if a generated name would collide with a name in `Models/`. |
| 9 | Per-endpoint `Arguments` and `Response` types are **invented** at the endpoint level | The descriptor has no endpoint-level type: `commands/list` takes a bare `agentId` and `session/create` takes one named `request`. Nothing else can give "a request model for every endpoint". | `argumentsType`/`responseType` are not descriptor names. `Response` is an alias to the schema-derived or hand-written type; `responseAlias` in the manifest is the full text including the `?`. |
| 10 | Wire `_request` → Swift property `request` (with `CodingKeys`) | `_request` is not a usable Swift identifier; SPEC §6.2 separates `_request` from `request` per endpoint. | The mapping is per-endpoint from the descriptor, and `testCapturedSessionListRequestDecodesIntoTheGeneratedArguments` re-encodes the capture to prove the wire key is `_request`. |
| 11 | `{"type":"object","properties":{}} ∩ record(…)` → `[String: V]` | `session/control`'s `projections` is exactly that. | A pure map, so there is no `additionalProperties` property to reach for. |
| 12 | `allOf` members are merged into one field set (properties union, `required` union) | 32 `intersection(object, object)` uses — `commands/execute`'s image attachment is one. | Merging is shape-preserving, not byte-exact; a conflict would silently keep the first member's property. |

## Overlaps and caveats that do **not** reach this surface

Recorded because the brief names them and a reviewer will look for them:

- **`_void()` results.** No V1 endpoint returns one. The generator supports `{"type":"null"}` (`DSHNull`) and `DSHNever` for `never()`, and emitted **neither** — `Support.swift` contains only `DSHDynamicCodingKey`. Evidence: `--report` prints `support types: ['DSHDynamicCodingKey']`.
- **`_instanceof(Uint8Array)` results.** The two (`workspaceFiles/readBytes`, `officeToPdf/render`) are not in the V1 set: `byteAttachments: true` results among the 31 endpoints = **0**.
- **`_undefined()` parameters.** No V1 parameter carries `acceptsUndefined`, so no argument property is optional for that reason. `_undefined()` in a *result* reaches this surface as `x-dsh-mayBeAbsent` on exactly two results: `commands/execute` and `goals/get`. Both aliases are optional (`CommandsExecuteResponse = CommandsExecuteResult?`), which the test pins by name.
- **`null`-admitting results.** `session/projections`'s result schema is `union([literal(null), object({…})])`, so `SessionProjectionsResponse = SessionProjectionsValue?`. Three declarations carry `nullable: true` in the manifest.

## What the schemas leave unresolved

1. **Absence vs `null` for a required nullable key.** `Protocol/README.md` leaves
   this open ("Whether `null` is accepted where the DSL says `_undefined()`"), and
   decision 3 chose the tolerant reading. Four fields are affected; all four are
   inside the projections.
2. **Fractional numbers.** Decision 1 chose `Int64` for `{"type":"number"}` with
   no capture to prove the host never sends a fraction.
3. **The examples are generated from the same schemas the types are.** The
   round-trip proves the translation is faithful to the schema; it does **not**
   prove the schema matches the host. Exactly one V1 result has a live capture
   (`Fixtures/rpc-response-session-list.json`) and exactly one V1 request
   (`Fixtures/rpc-request.json`); both are now decoded through the generated
   types. The other 30 endpoints are validated against the schema only.
   `Protocol/README.md` says the same thing about its own two-fixture check.
4. **Endpoints whose result is a union alternative the example does not
   instantiate.** 38 declarations sit at a `null` `examplePointer` for that
   reason — a JSON instance can only take one branch. Each still has its own
   example and its own decode+mutation test.
5. **Four request objects have no required key at all** — `SessionCreateRequest`,
   `SessionListRequest`, `EditGoalRequest`, `LlmModelDiscoveryRequest`. Their
   mutations are therefore type-confusion (`replace`), not deletion: there is no
   required key to delete, and deleting an optional one must *not* fail. The
   schema is the authority here, and it marks every field `.optional()`.
6. **Mixed primitive/const unions are unmodelled.** `union([number(), literal(-1)])`
   appears in `SessionFollowFrame…startedAfterSeq`, which is excluded. The
   generator raises a `SchemaError` rather than guessing, so a future descriptor
   that puts one of these on a V1 schema fails loudly instead of emitting a
   wrong type.
7. **`Protocol/examples/manifest.json` lives inside the examples directory.** It
   is the generator's index, not an example; the test excludes it explicitly.
8. `.build-codegen/` (the private scratch path this work was told to use) is not
   in `.gitignore`, so it shows up in `git status`. Left alone on purpose to
   avoid racing the agent editing `Sources/DSHRemoteKit/Network/`.
