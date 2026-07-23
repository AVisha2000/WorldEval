# WorldArena Duel protocol

This directory is the executable protocol contract for WorldArena Duel. The Markdown design
specification explains the game, but scored matches are governed by this versioned package: JSON
Schema Draft 2020-12 envelopes, integer-valued catalogs, the frozen commander prompt, fixtures,
conformance cases, and the canonical launch map.

## Version and authority

- Protocol: `worldeval-rts/1.0.0`
- Rules: `duel-rules-v1`
- Control profile: `hybrid-v1`
- Observation profile: `full-belief-v1`
- Simulation: 10 authoritative ticks per simulated second
- Numeric authority: integers only; position is milli-tiles and percentages are basis points
- Canonical serialization: RFC 8785 JCS, additionally restricted to NFC strings, no duplicate
  keys, explicit defaults, and no floating-point values

Godot owns the world state and game legality. The Python Agent Gateway owns provider calls, byte
limits, strict JSON parsing, schema validation, timing, and transport. Models see only immutable
`match_init` data and their own legal `observation`; they return exactly one `action_batch` object.
The model-facing observation hash is never an omniscient state hash.
Every currently visible shop row carries an observer-scoped opaque `shop_id` for `purchase_offer`
and `sell_item`; its stable map `site_id` is descriptive map knowledge and is never accepted as an
entity reference. The protected alias-to-neutral-building binding never enters model-visible JSON.

## Directory contract

- `schemas/` contains the eight canonical Draft 2020-12 message and manifest schemas.
- `catalogs/` contains public executable balance and action data. Catalog values are resolved; the
  runtime must not parse prose or infer missing attack/ability fields.
- `maps/` contains authoritative map data and is validated by `map-manifest.v1.schema.json`.
- `prompts/commander-system.v1.txt` is frozen input to both competitors.
- `fixtures/` contains passing examples and deliberately failing action envelopes.
- `conformance/` contains expected hashes, visibility invariants, and stable rejection cases.

The launch map uses the frozen positional `row_rle_palette_v1` representation: a fixed nine-field
cell palette plus 256 flat `[palette_index, count, ...]` rows. `mirror_pairs` remains normative;
the exhaustive rotation assertions are executable Python/Godot conformance checks rather than
duplicated manifest prose. `conformance/golden-hashes.json` freezes both palette-index and fully
expanded positional-cell grid hashes so independent decoders must produce identical cells.

`protocol-lock.json` is intentionally assembled only after all package artifacts, including the
launch map, exist. It records the canonical SHA-256 for every scored artifact. Editing a locked
file creates a different benchmark environment and requires regenerated golden replays.

## Validation order

1. Reject invalid UTF-8, more than one JSON value, duplicate keys, forbidden numbers, excessive
   depth/length, or an envelope over the byte limit.
2. Validate the whole envelope against its schema. An envelope failure makes the opportunity a
   no-op; it is never repaired.
3. Validate knowledge-time references and the atomic budget.
4. Godot validates frozen/application-time legality and returns per-command receipts.

Unknown envelope or command properties are errors. Commands are evaluated in model array order.
An empty command array is valid and leaves durable orders running.

## Decision tracks

`fixed_simultaneous` pauses at the shared boundary, commits and reveals both batches, and activates
accepted orders together. Response speed inside the deadline has no gameplay effect.

`continuous_realtime` keeps the simulation at real time and applies a valid response on the first
eligible 100 ms gate. Latency is therefore part of that separate benchmark track. Results from the
two tracks must never share a leaderboard.

## Developer checks

Run `pytest tests/duel/test_protocol_package.py`. The test verifies package structure, Draft
2020-12 schema references and strictness, fixtures, catalog IDs and integer-only authority, prompt
integrity, exact expanded-map hashes, and conformance metadata. It also accounts for the real
provider-neutral input frame: frozen prompt, complete inline `MATCH_INIT`, maximal observation, and
the separately supplied structured-output schema total 238,365 canonical bytes, below the 262,144
byte cap. Runtime implementations must match the same golden canonical hashes.
After an intentional protocol edit, regenerate conformance metadata with
`python scripts/build_duel_conformance_hashes.py`, then regenerate the outer package lock with
`python scripts/build_duel_protocol_lock.py`; both commands support `--check` for CI.
