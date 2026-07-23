# Duel phase-12 knowledge boundary

This directory is the deterministic fog and per-player knowledge foundation. It has no dependency
on rendering, physics, `WorldState`, provider code, or a mutable random-number generator.

`DuelKnowledgeProjector.project_phase_12(...)` consumes deep-copied, canonical dictionaries:

- a current grid snapshot with `width`, `height`, `cell_size_mt`, `elevations`,
  `los_block_heights`, `terrain_ids`, and `region_ids` arrays in row-major node-ID order;
- entity snapshots with positive `internal_id`, `owner_seat`, `alive`, integer `position_mt`,
  catalog sight/detection radii, occupied cells for multi-cell structures, and the legally public
  fields used by the projection;
- typed replay-event candidates with protected entity references and public/player payloads.

The grid snapshot supplied at phase 12 must already include phase-10 terrain/destructible changes
and the maximum LOS block height of live ordinary buildings for every occupied cell. Optional
`los_block_kinds` freezes the authored `cliff` exception for air-to-air rays. Catalog resolution
must supply day/night sight and detection radii on each source; no catalog lookup occurs here.

The exact integration hook is tick phase 12, after deaths/destruction/inventory in phases 10-11 and
before terminal testing in phase 13:

1. freeze canonical grid, entity, and event-candidate dictionaries from the post-phase-11 state;
2. call `project_phase_12` once for each player's persistent `DuelAgentKnowledgeState`, using the
   same frozen tick snapshot;
3. give only `DuelAgentKnowledgeState.public_projection()` to a future `ObservationBuilder`;
4. put `to_protected_canonical_dict()` in protected checkpoints/replays, never model messages.

Aliases are full HMAC-SHA256 values scoped by match salt and observer. Remembered records are frozen
copies, destroyed IDs are permanently tombstoned, and per-audience event sequence numbers advance
only for events actually emitted to that audience.
