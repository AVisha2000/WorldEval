# Duel phase-12 perception runtime

`DuelPerceptionRuntime` is the single phase-12 bridge from the authoritative
kernel to provider-visible `observation.v1` messages. It owns two persistent,
independent `DuelAgentKnowledgeState` instances and applies observer-scoped
HMAC aliases plus the official 180-degree seat transform.

The runtime accepts only the exact plain-data shape checked by
`DuelPerceptionContract`; it never accepts `DuelState`, a simulation object,
provider/model metadata, checkpoint hashes, or arbitrary dictionaries. The
frozen input contains the visibility grid, public entity facets, observable
event candidates, global clock/terminal facts, and one own-state snapshot per
seat. Unknown fields fail before projection.

For each seat the runtime performs, in order:

1. convert protected references in owned orders, statuses, builders,
   technology, and squads to already-known observer aliases;
2. update visibility, exploration, frozen memory, tombstones, and the legal
   audience event stream from the shared post-phase-11 snapshot;
3. emit items and shops only when their candidate position is currently
   visible, with player-relative coordinates and public IDs;
4. derive local visible-contact and remembered-threat context from the seat's
   legal knowledge rather than from live hidden state;
5. derive the seat-relative terminal result and assemble the closed public
   context; and
6. call `DuelObservationBuilder`, retaining its deterministic truncation,
   canonical bytes, byte count, and observation hash.

## Integration hook

At tick-ledger phase 12, after phase-11 inventory/stock/revival resolution and
before phase-13 terminal tests, freeze one canonical snapshot and call
`phase_12(snapshot)` exactly once. The required keys are listed in
`DuelPerceptionContract.PHASE_REQUIRED`; each of the two seat snapshots must
contain only that player's economy, food, upkeep, technology, squads, working
memory, latest receipt, and decision metadata. `owned_observation` carries own
Hero, queue, order, inventory, and status facets. Item/shop/local-context
candidates use protected IDs only inside this bridge and are visibility/owner
checked before aliases are emitted.

Send only `result.canonical_json["0"]` or `["1"]` to the corresponding model.
The knowledge objects exposed by `knowledge_state_for_checkpoint` belong only
in protected deterministic checkpoints/replays.
