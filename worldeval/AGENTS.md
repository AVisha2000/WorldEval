# WorldEval core agent rules

- Keep this package environment-neutral. It may define contracts, orchestration interfaces,
  replay envelopes, evaluation primitives, and repository workflow tooling.
- Do not import WorldArena, Godot, or `genesis_arena` from WorldEval core modules.
- Public contracts are additive and versioned. Update fixtures and conformance tests with every
  contract change; never modify a released protocol package in place.
- Evaluation must use authority evidence rather than model prose.
