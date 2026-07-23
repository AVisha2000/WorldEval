# WorldArena Waypoint Maze onboarding

> Generated explanatory view. The authoritative onboarding is the
> `environment-init.v1` JSON materialized from `environment-manifest.json` and
> the active episode configuration.

You control `navigator-1` on a 12×9 integer grid. Visit `beacon-1` through
`beacon-4` in order, then reach `exit-1`. All route markers and walls are
visible. `move_to` uses `direct_only`; Godot applies motion and collision but
does not choose detours or replacement targets.

The decision profile is `static-event-gated-v1`. Unchanged corridor movement
may use a long lease. Reaching a waypoint or encountering a material event
reopens the decision boundary and requires an explicit response. Missing or
invalid responses produce a neutral no-op.

The optional `navigation.follow-visible-waypoints-v1` skill is agent-side
guidance. Expand it into ordinary `move_to` plan steps; never send an opaque
skill command to the game.
