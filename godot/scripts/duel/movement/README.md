# Deterministic movement slice

`DuelMovement` is the render-free movement authority used by tick phases 3–5. It compiles durable
core orders, computes integer A* routes from static terrain, and commits simultaneous reservations.
It never calls Godot navigation, physics, raycasts, frame delta, floating-point math, or a mutable
random generator.

Configured state includes resolved catalog speed/radius/layer profiles, speed basis-point
remainders, exact route segment origins, ordinary replan offsets, dynamic-blocker avoidance cells,
three-tick conflict records, and four-lane air occupancy. Entity checkpoint state continues to own
the traversal-order route, route index, interpolation numerator/denominator, exact integer position,
and unused arrival budget. The protected tie key is supplied as bytes at match bootstrap; only its
SHA-256 digest enters ordinary canonical state. The key itself belongs in the protected replay
bundle and is revealed only for audit.

The slice directly executes compiled `move`, `attack_move`, `patrol`, `follow`, and `retreat`
orders. A compiled point target may carry `formation_offset_mt: [dx,dy]`; if that slot is closed,
the normal lexicographically nearest fitting-cell rule compresses it deterministically.

The action integration layer still has to perform knowledge/ownership validation and compile:

- opaque public IDs, region slots, sites, and player-relative coordinates into internal point or
  entity targets;
- squad membership and `line`, `compact`, `spread`, or `wedge` slots into per-actor offsets;
- `attack_entity` pursuit, stance-driven acquisition, and attack-move interruption/resumption with
  the combat executor;
- gather/return-cargo/repair/build travel legs with the economy executor;
- automatic HP-threshold retreat policy and transport load/unload approach orders.

Those strategic or protocol decisions are intentionally not invented by movement. Existing durable
orders keep running across model no-ops; `stop` completes immediately, while hold orders clear
motion and remain durable.
