# Deterministic Duel combat slice

This directory contains the integer-authoritative Phase-4 combat vertical slice.
`DuelCombat` consumes the checked-in attack/armor and faction catalogs, compiles
resolved combat profiles, and attaches them to ordinary `DuelEntity` records.

The public integration boundary is deliberately small:

- `configure(state, attack_armor_catalog, faction_catalog, rules_catalog)`
- `register_entity(state, entity_id, section, catalog_key, overrides)`
- `issue_attack(state, attacker_id, target_id)` (or an active core `attack` order)
- `issue_ground_attack(state, attacker_id, target_point_mt)` (or an active core
  `attack_ground` order) for catalog-backed fixed-point area projectiles
- `schedule_damage_effect(...)`, `schedule_heal_effect(...)`, and `add_status(...)`

The last three functions are the typed entry points intended for the later
ability/item implementation. They do not interpret prose or animation signals.
All surviving work (wind-ups, projectiles, cooldowns, effects, and statuses) is
stored in `DuelCombatState` and therefore participates in checkpoints.

Ground targeting is deliberately narrower than generic splash inference. A
unit receives it only when its frozen ability is a `passive_attack_modifier`
with `attack_ground_area`, positive cast range/radius, and an authoritative
projectile base attack. The fixed landing point, radius, damage bands, target
layers, and friendly-fire basis points are checkpointed; impacts expand in
internal-entity order and enter the same simultaneous delta ledger as ordinary
attacks. This slice still does not implement generic target acquisition,
pursuit, chain selection, channels, mana, Hero revival/XP, or arbitrary faction
ability interpretation.

Movement/knowledge integration must keep each registered actor's integer
`elevation`, `visible`, `transported`, and immunity flags current. Economy and
Hero systems likewise supply resolved armor, attack-upgrade, and source/target
basis-point modifiers through the actor record; combat never reads presentation
nodes or infers those values from names. Animation and projectile visuals are
non-authoritative consumers of the emitted events.
