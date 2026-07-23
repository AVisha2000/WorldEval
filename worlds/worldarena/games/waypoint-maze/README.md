# WorldArena Waypoint Maze

`worldarena-waypoint-maze-v0` is the second game adopting the unchanged
`worldeval-agent/0.1.0` contracts. It is a deterministic navigation task rather
than a resource-interaction task.

The navigator starts at `(1,1)` and must visit four visible beacons in declared
order before reaching the exit. Fixed walls make a direct start-to-exit command
collide. The deterministic Demo agent selects
`navigation.follow-visible-waypoints-v1`, reads only the player-scoped initial
observation, and expands the skill into five visible `move_to` steps. The Godot
authority never receives an `execute_skill` command and never chooses a
waypoint, target, path, or detour.

The game uses `static-event-gated-v1`: one lease can cover an unchanged corridor,
while reaching a beacon, colliding, losing a target, or changing the objective
reopens the decision boundary. Silence and invalid output remain neutral
no-ops.

Authoritative inputs:

- `environment-manifest.json`
- `catalogs/object-catalog.json`
- `catalogs/action-catalog.json`
- `decision-profiles/static-event-gated-v1.json`
- `objectives/beacon-route-v0.json`
- `scenarios/beacon-route-v0.json`

`game_initiation.md` is generated explanatory material and is not authoritative.
