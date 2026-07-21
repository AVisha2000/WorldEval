# Arena v1 presentation adapter

`arena_v1.tscn` is a standalone graybox presentation scene. It renders snapshots and events;
it does not own authoritative rules, choose actions, or infer outcomes from node transforms.
The scene root uses `arena_match_controller.gd` to connect this adapter to the deterministic
`ArenaSimulation` and the local `world-arena/0.4` WebSocket backend.

## Simulation-facing methods

- `configure_from_snapshot(snapshot: Dictionary)` applies a complete projected or canonical
  round snapshot. It is idempotent and accepts arrays or dictionaries for factions, districts,
  and units. Unit positions may be `Vector3`, `[x, y, z]`, `{x, y, z}`, or a `district_id`.
- `apply_events(events: Array)` appends an ordered batch to the diplomacy feed, relationship
  graph, speech bubbles, timeline markers, and event-specific world overlays. Repeated
  `event_id` values are ignored.
- `set_phase(phase: String, statuses: Dictionary)` updates the concurrent-thinking bar.
  Supported status values are `waiting`, `thinking`, `locked`, `timeout`, `fallback`, and
  `executing`.
- `show_message(event: Dictionary)` displays a bubble without adding an event to the feed.
  Call `apply_events` when the message must also be auditable and replayable.
- Persistent `tasks` and `construction` records project world-space progress bars and staged
  scaffolds; the adapter never advances their work itself.
- `mark_setup_accepted(initial_snapshot := {})`, `set_setup_status(message, state)`,
  `set_lobby_visible(value)`, and `set_perspective(id)` let the integration layer control
  setup and projection state.

## Presentation signals

- `setup_submitted(config)` includes the in-memory API key and three commander selections.
  The key field is cleared from the `LineEdit` immediately after synchronous signal delivery;
  the receiver is responsible for sending it to the local backend and never persisting it.
- `perspective_requested(id)` requests `spectator`, `sol`, `terra`, or `luna` projection.
- `pause_requested(paused)` requests a pause at the next authoritative round boundary.
- `playback_speed_requested(speed)` changes presentation speed only.
- `timeline_seek_requested(round)` and `event_focus_requested(event_id)` request replay seeks.

## Minimal snapshot shape

```gdscript
presentation.configure_from_snapshot({
    "round": 12,
    "max_rounds": 40,
    "phase": "thinking",
    "thinking_status": {"sol": "locked", "terra": "thinking", "luna": "thinking"},
    "factions": [{"id": "sol", "model": "...", "core_hp": 1000}],
    "districts": [{"id": "crossroads", "owner": "neutral", "contested": true}],
    "units": [{"id": "sol_commander", "faction_id": "sol", "unit_type": "commander", "district_id": "home_sol"}]
})
```

Events follow the `feature.md` envelope: `event_id`, `round`, `kind`, `actor_id`,
`target_ids`, `visibility`, `visible_to`, `summary`, `state`, and optional `payload`.

Run the standalone mock presentation with:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --path godot godot/scenes/arena_v1.tscn -- --arena-live-preview
```

Run a credential-free backend match or a self-contained authority check with:

```sh
# Local backend commit/lock/reveal loop; backend must already be listening on port 8000.
/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot -- \
  --arena-autostart-demo --arena-test-rounds=8 --arena-quit-after-test

# No backend required; exercises the same typed-plan translation and resolution path.
/Applications/Godot.app/Contents/MacOS/Godot --headless --path godot -- \
  --arena-offline-demo --arena-test-rounds=4 --arena-quit-after-test
```
