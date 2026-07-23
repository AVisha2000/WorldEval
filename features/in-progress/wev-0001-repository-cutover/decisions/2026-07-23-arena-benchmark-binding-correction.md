# Decision WEV-0001-D002: correct the Arena benchmark source binding

Decision version: 1

Date: 2026-07-23

Status: accepted

## Context

The checked-in `arena-v0.4` benchmark contract recorded rules SHA-256
`515dd825…`, but that value does not match the rules source in the repository's
baseline revision. The same baseline's authority-generated Crossroads replay
and showcase manifest both bind `arena-v0.4` to the actual source SHA-256
`f47cd46c…`. Consequently, the repository's benchmark integrity test failed
before the cutover even though the rules source and accepted replay agreed.

## Decision

Correct only the erroneous hash value in `benchmark_contract.json` to the
measured and replay-bound value
`f47cd46cf2322b983fca7de4bf7d4e047fdc744cecf789f710c368f602d3025a`.

This is an integrity-data correction, not a rules or protocol revision:

- the `arena-v0.4` rules ID is unchanged;
- the rules source bytes are unchanged;
- the map and action bindings are unchanged;
- historical replay and showcase bytes are unchanged; and
- the corrected value is the value already embedded in accepted authority
  evidence.

Changing the rules implementation or retroactively rewriting replay evidence
would require a separate versioned feature decision. This decision does neither.

## Verification

The benchmark-contract test must hash the source bytes directly, and the
Crossroads showcase verifier must continue accepting the unchanged replay and
manifest.
