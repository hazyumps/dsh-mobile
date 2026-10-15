# Plan template

Copy to `design/plans/issue-<n>-<slug>.md`. Delete the guidance in *italics* as you fill it in.
A bug fix with one criterion can be short; every heading still gets an answer, even if it is
"none". Keep it reviewable — a few hundred lines at most: evidence is the failing line, not the
whole log, and a long probe script goes in the commit body rather than the plan.

---

# Issue #<n>: <title>

**Status:** draft | approved (by whom, date) | building | verified | merged
**Branch:** `issue-<n>-<slug>`
**Version impact:** none | PATCH | MINOR — *why, per docs/process/RELEASING.md*

## Context

*What is wrong or missing, who notices, and what prompted it. Link the issue, the spec section
(`SPEC §n`, `design/...`), and any capture or probe. Two to six sentences.*

## Acceptance criteria

*Numbered, observable, each one able to fail. Write them from the caller's side — what a screen,
a store subscriber, or the relay would see — not the object's internals.*

- **AC1** — …
- **AC2** — …

## Test list

*One row per test. "Fails today because" is the prediction the red run must confirm; if the red
run fails for a different reason, the test or the prediction is wrong.*

| AC | Suite / file | Test name | Fails today because |
|---|---|---|---|
| AC1 | `NetworkTests.swift` | `"AC1: an approval is sent once on a 502"` | `submitEventResult` retries: 3 requests recorded |

*Fakes to use: `StubRelayTransport`, `StubRelaySocket`, `InMemorySecretStore`, `FixedEpochClock`,
`Fixtures`. Stubs needed in `Sources/` so the tests compile: list them.*

## Slices

*Groups of ACs that touch disjoint files, so builders can work in parallel. One slice is fine.*

| Slice | ACs | Files | Notes |
|---|---|---|---|
| A | AC1, AC2 | `Sources/DSHRemoteKit/Network/DshBareEndpointClient.swift` | |

## Risk flags

*From docs/process/RISK-FLAGS.md. For each ticked flag, what the change does there.*

- [ ] none
- [ ] S1 writes / retries — …

## Out of scope

*What this deliberately does not do, and where it went instead (another issue, a `relay` issue).*

## Red evidence

*Filled in by the planner with the `Tests:` commit: the `Tools/check.sh --red` result, and each
failing test with its message.*

```
```

## Verification

*Filled in by the verifier. For each AC: what was undone, the test's failure with it undone, and
that it passes again once restored. Then the full check and the risk checklist.*

| AC | Undone how | Test failure with it undone |
|---|---|---|
| AC1 | `git revert --no-commit <sha>` | `Expectation failed: (sent.count → 3) == 1` |

- `Tools/check.sh`: green / red
- Risk checklist: in the PR / not applicable

## Notes for the next person

*Anything learned that is not obvious from the code: a host quirk, a rejected approach and why.*
