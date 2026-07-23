# Decision: hash-lock the historical duel-map generator path shim

Date: 2026-07-23

Status: accepted for the cutover

## Context

The released Crossroads map records the raw SHA-256 of
`scripts/build_duel_map.py` as a source-fingerprint-v1 value. The generator moved
intact with WorldArena, and its existing one-parent lookup still resolves the
same WorldArena root from the new sibling `scripts/` directory. Replacing that
lookup with the workspace resolver changes the generator bytes and makes the
unchanged released map appear stale.

## Decision

Preserve the generator byte-for-byte at SHA-256
`7ad26a25cd52de630c0dcd53abbb4fd5f26eaa278d60854a78ef1b69d4c44f35`.
The workspace layout gate treats its exact new logical path and exact hash as the
only allowed `Path.parents[]` compatibility shim. A byte change while the shim
remains immediately fails the gate. All new source fingerprints use the logical
component-based v2 scheme.

## Consequences

- The frozen map remains byte-identical and its currentness check keeps passing.
- The exception is explicit, machine-enforced, and cannot silently expand.
- A future generator change requires an additive artifact/version decision rather
  than silently rewriting historical source identity.
