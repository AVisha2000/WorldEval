# WorldArena Duel authority

This namespace is the isolated, render-free authority for `duel-rules-v1`. It does not use Nodes,
physics, navigation servers, frame delta, or presentation state.

The implemented authority currently includes:

- frozen 10 Hz integer units and the normative 14 tick phases;
- restricted canonical JSON plus SHA-256 and keyed HMAC/SHA utilities;
- explicit entity, durable-order, event, and simultaneous-delta records;
- an integer occupancy grid and schema-bound map loading interface;
- deterministic eight-neighbor A* with the specified tie key and no corner cutting;
- canonical state/grid checkpoints and a synchronous simulation shell;
- locked-catalog runtime compilation and exact official mirrored-map bootstrap;
- resources, construction, repair, food/upkeep, production, research, and technology tiers;
- typed combat deltas, attack/armor, windups, projectiles, shields, statuses, and lifecycle;
- persistent deterministic movement, static A*, ground reservations, and four air lanes;
- selected-faction Heroes, attributes, XP, ability ranks, inventory, item effects, and revival;
- fog, private knowledge/memory, opaque aliases, and safe full-belief observations;
- strict validation/compilation for all 37 hybrid controller operations;
- neutral camps/markets and the controller/perception integration slices as they land;
- stronghold victory, exact draw clocks, technical forfeits, and infrastructure voids;
- canonical offline replay and provider-neutral Python orchestration/evaluation support.

Each subsystem may collect intents during its assigned phase, but simultaneous mutations pass
through the tick ledger. Presentation remains outside this directory and consumes state/events only.
The remaining authority gates are the complete intent-to-subsystem bridge, every catalogued faction
ability, full official replay restoration, and unattended end-to-end match certification.

Run any focused conformance runner with:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot \
  --script res://tests/duel/duel_core_headless_runner.gd
```

The adjacent runners cover catalogs, bootstrap, economy, combat, movement, Heroes, visibility,
observations, actions, neutrals, terminal outcomes, and replay. Their printed SHA-256 values are
determinism goldens; update one only when the authoritative environment intentionally changes.
