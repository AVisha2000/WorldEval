# Duel economy runtime contract

`DuelEconomy` is the render-free Phase-3 authority for resources, food, upkeep, construction,
repair, production, research, and technology tiers. It is configured with one **merged runtime
catalog**, not hard-coded faction constants. The protocol catalog loader is responsible for merging:

- `catalogs/rules.duel-v1.json`: construction, upkeep, shared structures, technology, production,
  and shared-upgrade values;
- `catalogs/factions/<faction-id>.json`: faction type IDs, HP overrides, units, producers, and tags.

The merged dictionary passed to `DuelSimulation.configure_economy()` has these sections:

```text
construction
  work_bp_per_worker_tick, cooperative_speed_bp[1..5], minimum_incomplete_hp_bp,
  repair_hp_per_worker_tick, full_repair_cost_bp_of_original
food_and_upkeep
  maximum_food, upkeep[{minimum_used, maximum_used, tier, gold_delivery_bp}]
structures[type_id]
  semantic_role, max_hp, cost_gold, cost_lumber, build_ticks, required_tier,
  food_provided, radius_mt, worker_range_mt, tags, is_deposit?, exit_offsets_cells?
units[type_id]
  semantic_role, max_hp, max_mana, cost_gold, cost_lumber, train_ticks, required_tier,
  food_cost, radius_mt, tags, is_worker, producer_roles
technology
  tier_2 / tier_3 {cost_gold, cost_lumber, duration_ticks, hero_slots}
upgrades[upgrade_id]
  producer_roles, levels[{required_tier, cost_gold, cost_lumber, research_ticks}]
```

All values are integers, booleans, strings, or recursively canonical arrays/dictionaries. The
runtime validates and hashes the merged bytes before enabling economy. That hash and every economic
record enter the canonical simulation checkpoint.

## Movement boundary

`assign_gather()` receives authoritative integer `travel_to_ticks` and `travel_return_ticks` from
the order/movement layer. Economy owns slot reservation, exact work ticks, extraction, cargo,
depletion, deposit, and looping; it never estimates travel with floats or presentation positions.
When the movement executor lands, its route timing is supplied through this existing boundary, so
the economic rules and replay state do not change.

## Tick integration

- Phase 7 freezes alive contributors and economic work intents.
- Phase 9 applies exact worker, construction, repair, production, research, and tier work.
- Phase 10 processes incomplete-building refunds, producer destruction, food loss, and task cleanup.
- Phase 13 feeds economic progress into the no-progress counter.
- Phase 14 emits the already ordered economic events with the rest of the tick ledger.

Completed unit and Hero production emits one explicit authority handoff. The
simulation registers the new mobile with combat and movement, registers
ability-owning types with the ability runtime, and registers Heroes with the
Hero authority before publishing the completion event. Hero altar queues use
the frozen first/later cost, food, train-time, named-archetype, and tier-slot
rules. Purchased external hires enter economy through `register_external_unit`
so food/upkeep and hired-worker gathering remain authoritative.

The headless fixture in `tests/duel/duel_economy_headless_runner.gd` uses the exact Vanguard launch
values and covers starting state, finite gathering, upkeep flooring, cooperative construction,
food reservation, FIFO production, tier/research queues, repair accumulators, cancellation refunds,
receipts, and a locked checkpoint.
