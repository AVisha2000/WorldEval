# Duel compiled-intent execution

This directory owns the explicit boundary between `DuelOrderCompiler` output
and authoritative Godot subsystems.

- `duel_intent_resolution_context.gd` freezes the only public aliases, world
  points, region slots, sites, queue-entry aliases, deposits, and transport
  limits that an application batch may resolve. A compiled internal ID is only
  a claimed hint and must match the public alias mapping before use.
- `duel_contest_resolver.gd` applies the protected HMAC rank rule to finite
  same-tick exclusive claims. Player receipts never include its group key,
  protected object ID, rank digest, or internal actor ID; those remain in the
  protected replay audit.
- `duel_intent_execution_bridge.gd` has named dispatch branches for all 37
  public operations and the compiler-only squad expansions. It owns squads,
  tactics, rally points, transport manifests, autocast mirrors, and public
  per-intent execution receipts. Neutral markets and abilities are closed,
  optional services named `neutral_market` and `abilities`.

The bridge deliberately exposes two future ledger hooks instead of modifying
the shared tick ledger in this isolated slice:

1. Call `activate_pending_appends(simulation)` immediately before phase 1 so a
   durable `append` order is released only after the previous active order is
   finished.
2. Call the ability service's `advance(...)` at its documented phase gates and
   pass the closed visible list as `candidate_entity_ids`; then apply
   `consume_effect_intents()` through the simultaneous ledger.

`attack_ground` routes to Combat's typed fixed-point projectile/area path. It is
accepted only for a catalog profile that explicitly exposes the primitive
(currently Vanguard Bombard); every other actor fails closed with a stable
`requirement_not_met` receipt. Ordinary movement/combat orders, economy
operations, Hero lifecycle/items, squads/tactics, transports, protected
build/item/revival/transport-seat contests, market claims, and ability-service
casts use their authoritative APIs. Hero type IDs route to the dedicated
altar-training path, and accepted Laboratory unit handoffs create fully
registered hired entities without exposing their internal IDs in player
receipts.
