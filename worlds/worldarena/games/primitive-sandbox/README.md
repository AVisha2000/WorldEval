# WorldArena Primitive Sandbox

This package is the first data binding for `worldeval-agent/0.1.0`.
WorldEval owns the reusable contracts and decision runtime; WorldArena/Godot
owns authoritative gameplay. The Python grid implementation is a deterministic
reference and conformance oracle, not a replacement gameplay authority.

The sandbox exposes exact integer coordinates and semantic actions under its
own profiles. It does not change the existing direct-controller embodiment
profile or its leaderboards.

Scenarios:

- `tree-chop-nominal-v0`: select the axe, reach, and destroy `tree-7`.
- `tree-chop-interrupted-v0`: encounter a newly spawned barrier, route with
  explicit waypoints, reconsider when an enemy occupies the tree, and return
  safely to base.

`game_initiation.md` and the initialization fixtures are generated companions.
The JSON environment initialization is authoritative.

`fixtures/decision-conformance.v1.json` is consumed by both Python and Godot.
It distinguishes strict wire-schema validity from action/profile admission,
including dynamic leases capped at five ticks and static leases capped at
50 ticks. A document may therefore be schema-valid but still rejected when its
action arguments delegate forbidden authority or exceed the selected profile.

## Decision-session interface

The Controller Lab and deterministic Demo policy use the same strict session
surface:

1. `POST /api/worldeval/sandbox/sessions` materializes onboarding, the objective,
   and observation zero from the authored JSON.
2. `POST /api/worldeval/sandbox/sessions/{id}/acknowledge` must echo the exact
   initialization hash before any scored boundary.
3. `POST /api/worldeval/sandbox/sessions/{id}/decisions` submits exactly one
   tagged response. The managed Godot runner reconstructs the deterministic
   history and advances only the newly authorized lease.
4. Every nonterminal response returns the next observation and receipt with
   `status: decision_required`. Missing or invalid input becomes a zero-tick
   neutral no-op; it never resumes a plan.
5. Terminal status becomes `ready` only after a separate Godot verifier
   re-executes the native replay with provider calls disabled and the immutable
   outer bundle has been published atomically.

`POST /api/worldeval/sandbox/runs` drives the deterministic Demo agent through
that same interface. A preterminal authority failure saves only the universal,
sealed `worldeval/incomplete-run/1.0.0` diagnostic.
