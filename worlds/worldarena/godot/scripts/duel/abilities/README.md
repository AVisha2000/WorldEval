# Deterministic ability authority

This directory implements the executable boundary for all 100 locked faction
abilities. It loads all four official faction catalogs on configuration and
fails closed if any activation kind, target kind, impact schedule, executable
field, or effect kind is outside the explicit contract.

`DuelAbilityRuntime` is intentionally coordinator-owned rather than attached to
`DuelState` yet. Its public integration surface is:

- `configure(selected_faction_id, loaded_result = {})`
- `register_actor(simulation, actor_id, actor_type_id = "", explicit_ranks = {})`
- `execute_cast(simulation, actor_id, ability_id, target, request = {})`
- `set_autocast(...)` and `execute_autocast(...)`
- `trigger_ability(...)` for attack, threshold, conditional, and research gates
- `advance(simulation, phase, context = {})` for activation, commit, and periodic phases
- `interrupt_actor(actor_id, reason)`
- `consume_effect_intents()` and `persistent_effect_snapshot()`
- `to_canonical_dict()`, `checkpoint_hash()`, and `validate()`

Mana and cooldown commit only after the second target/interruption check.
Periodic schedules use integer counters; total-over-time restoration uses a
cumulative integer accumulator, so its emitted per-tick values sum exactly to
the catalog total. Area, chain, and autocast candidate lists must come from a
closed visible-world snapshot and are sorted by integer distance, HP ratio, and
the caller-supplied opaque ordering key. The runtime never queries fog-hidden
candidates and never uses wall time or unkeyed randomness.

Every emitted effect keeps the exact catalog `effect_kind`, values, durations,
stacking key, and dispel class. `primitive_kind` routes it to the future match
coordinator's combat, status, movement, economy, world, summon, vision, Hero,
or neutral adapter. Presentation and animation callbacks are never authority.

The headless runner covers the complete 100/109/26 vocabulary, fail-closed
catalog mutations, all four factions, regular and Hero casts, rank/target/range/
mana/cooldown/tech checks, autocast ordering, triggers, channels, interruption,
toggles, integer accumulators, insertion-order determinism, and a golden hash.
