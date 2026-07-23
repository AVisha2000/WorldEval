# Implementation plan

Use `docs/worldarena/legacy-replay-migration-inventory.md` as the read-only
baseline. Split the work into descendant records for presentation labeling,
historical outer bundles, solo terminal failures, and protected duo/trio legs.
Wrap only recoverable native replay bytes, explicitly record the hash-bound Solo
Multi-Action replay as unavailable, and give every game-internal migration its
own compatibility and rollback boundary.
