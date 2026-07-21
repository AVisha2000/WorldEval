# WorldEval naming conventions

Use these names consistently in public copy, documentation, code comments, and new identifiers.

## Product hierarchy

- **WorldEval** is the umbrella evaluation framework, repository, website, evidence system, and
  scoring/reporting layer.
- **WorldArena** is the interactive 3D arena platform and first environment evaluated by WorldEval.
- **WorldArena Controller Lab** is the operator interface for configuring, running, and observing
  WorldArena sessions.
- **WorldArena Solo**, **WorldArena Duel**, **WorldArena Embodiment**, and **WorldArena Conquest**
  are modes or components of the WorldArena platform.
- **WorldEval Score** is the versioned, evidence-linked behavioural score. It may be qualified as
  “the WorldEval Score for WorldArena” when the environment needs to be explicit.
- **LLM Controller** is a technical controller integration. It is not the repository or umbrella
  product name; WorldArena is its first implemented environment adapter.

## Style

- Write **WorldEval** and **WorldArena** as joined CamelCase names.
- Do not use “World Eval” or “World Arena” as alternate brand spellings.
- Introduce the hierarchy before using a mode name on its own. For example: “WorldArena Duel, a
  WorldArena mode evaluated by WorldEval.”
- Use WorldEval when discussing cross-environment evaluation, evidence, scoring, reporting, or the
  repository as a whole.
- Use WorldArena when discussing the Godot world, arena rules, matches, modes, or platform-specific
  protocols.

## Compatibility identifiers

The Python package namespace `genesis_arena`, the `genesis-*` command names, and the legacy
`genesis-arena/0.1` protocol identifier predate the public naming hierarchy. They remain temporarily
for compatibility and are not public product names. The serialized `worldarena_score` and
`average_worldarena_score` fields likewise remain stable artifact keys while their public label is
**WorldEval Score**. Do not introduce new Genesis Arena branding or use those artifact keys as
display copy.

The `world-arena/0.4` protocol identifier, `WORLD_ARENA_*` environment variables,
`run_worldarena.command`, and the Godot project name are WorldArena platform identifiers and should
remain platform-scoped.
