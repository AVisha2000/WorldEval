# Deterministic neutral world

This directory owns the isolated neutral-world authority for WorldArena Duel. It reads only the
allowlisted, protocol-locked `rules.duel-v1`, `neutrals.duel-v1`, `items.duel-v1`, and
`crossroads-duel-v1` artifacts. The map's raw bytes are checked against `protocol-lock.json` before
any camp, neutral building, or expansion is registered.

## Authority split

- `duel_neutral_state.gd` stores integer-only canonical state for 16 camps, authored creep members
  and formations, five neutral buildings, four expansions, shop charges, reveal sources, forced
  night effects, ground drops, contests, and neutral events.
- `duel_neutral_world.gd` implements the 2,400-day/2,400-night cycle, sleep/wake rules, target
  selection, the 14-tile leash, return/reset/regeneration, combat damage attribution, camp-clear
  gold and XP handoffs, keyed item rolls, exact map registries, and expansion gates/claims.
- `duel_neutral_market.gd` implements Merchant, Laboratory, Tavern, and registered faction-shop
  offers; tick-based stock and serial charge restocking; purchase/hire/Reveal claims; private
  50-tick Reveal sources; and the Tavern's keyed one-per-tick field-revival slot.

All finite contests use the shared protected HMAC ranking primitive. Item selection uses the
`item_drop` keyed stream with tick zero and the camp ID, so kill order, kill tick, iteration order,
and player identity cannot change the item. Only non-purchasable items in the rolled catalog tier
are eligible for creep drops.

## Simulation integration API

The subsystem returns handoff records instead of mutating another subsystem:

1. Match bootstrap calls `configure_official(match_seed, protected_tie_key)`, then consumes
   `creep_spawn_descriptors()` to create movement/combat entities and binds their opaque IDs with
   `bind_member_entity()`.
2. Phase 2 calls `advance_phase2(tick)` to expire forced night/Reveal sources, activate offers, and
   restock charges using simulation ticks only.
3. Before phase 3, combat/movement copies frozen member facts through `synchronize_member()`.
   Phase 3 consumes `compile_camp_intents()` and routes `attack_entity`, `return_to_spawn`, and
   `regenerate` intents to the normal combat/movement compilers.
4. Post-mitigation camp damage calls `record_camp_damage()`. Neutral summons are attached with
   `register_camp_summon()` so they participate in the all-dead clear gate.
5. Phase 10 calls `mark_member_dead()` for the per-death Hero-XP handoff, then
   `resolve_camp_clear()` after member and summon death resolution. Its handoffs award economy gold
   and create a Hero-system ground item at the authored camp anchor.
6. Phase 11 resolves one collected batch through `resolve_shop_claims()`,
   `resolve_field_revival_claims()`, and (for build-site contention) `resolve_expansion_claims()`.
   Only accepted results carry resource charges and Hero/economy spawn or revival handoffs.
7. Phase 12 passes `active_reveal_sources()` to the ordinary sight/detection rasterizer. Reveal
   never writes knowledge directly and remains private to its buying seat.

`purchase_offer` integration supplies authoritative frozen facts (`buyer_owned`, `buyer_alive`,
`buyer_tags`, `shop_visible`, and `interaction_legal`). For Laboratory Reveal, the action compiler
also resolves a point or public region-slot target to `service_target_xy_mt`; the neutral authority
then independently checks buyer range, map bounds, funds, stock, and per-player cooldown.

## Remaining shared hook

The only intentionally unimplemented piece in this isolated slice is wiring `DuelNeutralState`
into the shared `DuelState` checkpoint and invoking the APIs from the common 14-phase simulation
driver. That integration must also translate returned ground-item, XP, gold, hire, Reveal,
field-revival, and expansion records into the existing Hero, economy, fog, combat, and movement
authorities. No shared simulation file is edited here so this slice can land without conflicting
with those systems.

Run the conformance suite with:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot \
  --script res://tests/duel/duel_neutrals_headless_runner.gd
```

The locked neutral golden is
`fa33238be4bd15397926988a160ada4c29b3b0fb2219ba8be8e1982cd16468df`.
