# WorldArena environment

WorldArena is the first gameplay environment integrated with WorldEval. Godot is its sole
gameplay authority. Python services may validate requests, schedule inference, archive evidence,
and expose safe public projections, but they do not decide movement routes, combat outcomes, or
objective success.

The environment capsule lives under `worlds/worldarena/`:

- `backend/worldarena/` is the public application facade.
- `backend/genesis_arena/` preserves legacy imports and commands.
- `game/` contains frozen compatibility protocols and remains beside the Godot project.
- `games/` contains new environment implementations such as the primitive sandbox.
- `godot/` is the intact Godot project and owns authoritative mechanics.
- `demos/` contains promoted, verified, credential-free replay bundles.
- `legacy/survival/` contains in-game personas and memory, not coding-agent instructions.

New games adopt the WorldEval contracts explicitly without changing existing embodiment
leaderboards or frozen package identities.

The first two additive adopters prove both decision tempos without changing
`worldeval-agent/0.1.0`:

- `games/primitive-sandbox/` uses `dynamic-step-locked-v1` for barrier and hostile
  interruptions, with an explicit model response at every one-to-five-tick window.
- `games/waypoint-maze/` uses `static-event-gated-v1` for longer unchanged-corridor
  leases and expands the shared `navigation.follow-visible-waypoints-v1` skill into
  ordinary visible `move_to` actions.

Both promoted demos are re-executed by distinct Godot verifier identities. The
generic public replay catalog exposes only allow-listed public artifacts from a
bundle that passes its exact `(verifier, native_schema)` registration.

Historical certification evidence continues to verify through
`source-fingerprint-v1` using its original path semantics. New evidence uses
`source-fingerprint-v2`, which hashes stable logical component IDs plus file
bytes so a future directory move does not masquerade as a source change.
