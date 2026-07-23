# Promoted WorldArena demos

Each version directory is an immutable `worldeval/replay-bundle/1.0.0`. A promoted demo contains
the authority-native replay, public evaluation, onboarding, objective, timeline, result, and sealed
manifest. Media is optional and derived from a verified replay.

Primitive Sandbox demos are provider-free and can be regenerated into a new version with
`worlds/worldarena/scripts/build_primitive_sandbox_demos.py`. Existing versions must never be
overwritten; use `--check` to independently re-execute the checked-in replay in a second Godot
process. The native verifier fails closed when Godot is unavailable and measures zero provider
calls rather than trusting the outer manifest's claim.

The accepted Waypoint Maze adoption is
`waypoint-maze-beacon-route/1.0.0`. It is generated with
`worlds/worldarena/scripts/build_waypoint_maze_demo.py` and verified with the
same command plus `--check`. Its replay records only ordinary `move_to`
actions expanded from the portable agent-side waypoint skill; its distinct
Godot verifier re-executes the fixed-wall route with provider credentials
removed. On macOS, `/usr/bin/sandbox-exec` supplies an additional deny-network
boundary. Other platforms currently have no supported OS network-isolation
adapter: callers that require that capability must set the verifier's
`require_network_isolation` gate, which fails closed when unavailable. A
provider-free replay verification must not be reported as OS-network-isolated
on those platforms.
