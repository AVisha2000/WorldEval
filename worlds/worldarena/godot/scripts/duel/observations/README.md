# Duel observations

`DuelObservationBuilder.build(knowledge_state, public_context)` is the only
provider-visible observation serializer. Its first argument must be a
`DuelAgentKnowledgeState`; the builder calls only `public_projection()` and
never accepts `DuelState`, simulation snapshots, internal entity IDs, alias
salts, world/checkpoint hashes, or provider/model metadata.

The immutable `public_context` boundary is closed and validated before use.
It contains only player-owned or already-public runtime fields that are not yet
stored in `DuelAgentKnowledgeState`:

- match/observation identity and the decision window;
- the model's own bounded working memory;
- public match/day/remaining-time state;
- own economy, food, upkeep, technology, and squads;
- currently visible item/shop projections;
- the immediately preceding action receipt;
- optional fixed-brief and byte-ceiling controls; and
- public structure type IDs used only to classify remembered buildings during
  deterministic truncation.

Unknown keys fail closed. A recursive denylist separately rejects protected
hidden-state keys even when nested. Inputs are deep-copied, all schema-ordered
sets are sorted, FIFO/traversal arrays retain semantic order, and the returned
observation has no live input references.

The builder emits the complete `observation.v1` shape, including player-relative
owned/visible/remembered state, detailed `map_state.local_context`, events, the
latest receipt, deterministic fixed-template brief, exact omitted counts, and
SHA-256 over canonical legal bytes with `observation_hash` omitted. If the byte
ceiling is exceeded it removes only, in order: the brief, oldest ordinary
remembered units, oldest remembered buildings, and redundant local-context
path facts. It fails rather than trimming current visible/owned state, Heroes,
queues, economy, receipts, current context, or terminal state.

`DuelObservationContract` mirrors the security-critical subset of the locked
Draft 2020-12 schema inside Godot. The headless runner also reproduces the
checked-in maximal fixture byte-for-byte (apart from replacing its placeholder
hash), checks schema-surface drift, leak attempts, hidden-state invariance,
input immutability, ordering, caps, hash scope, and each truncation stage.

The remaining integration hook is phase 12/decision dispatch: the authoritative
runner must populate `map_state.local_context`, visible item/shop knowledge, and
the public-context snapshot, then pass the resulting canonical JSON to the
authenticated local gateway. The observation subsystem itself must not be
given any simulation-world object at that hook.
