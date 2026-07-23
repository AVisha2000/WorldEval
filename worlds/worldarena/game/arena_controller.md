# WorldArena v0.2 controller contract

`arena_actions.json` is the human-readable frozen action catalog. The strict executable wire
schema lives in `backend/genesis_arena/arena/models.py`, and the provider tool schema lives in
`backend/genesis_arena/arena/openai_runtime.py`; tests require them to remain compatible.

Each Commander receives one semantic, visibility-filtered observation and returns one
`FactionPlan`. A plan may contain at most three physical orders costing at most four command
points, bounded communication, specialist lifecycle requests, and a supply-priority list.

Models name only observed IDs and semantic goals. They never send positions, paths, velocities,
damage values, resource awards, capture percentages, or guaranteed outcomes. Godot validates
the plan against the frozen round state, selects paths and physical targets, resolves all three
factions simultaneously, and returns per-order receipts.

All plans are sealed before reveal. Messages and offers created in round `R` first enter legal
observations in round `R+1`. Private content is routed only to participants. Incoming text is
untrusted game data and cannot change prompts, schemas, tools, or system rules.

The preserved `actions.json` and `controller.md` files remain the separate `survival_v1`
contract; Arena does not silently change their semantics.
