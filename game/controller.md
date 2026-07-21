# WorldArena legacy controller

This contract predates the WorldEval naming hierarchy. Its `genesis-arena/0.1` protocol identifier
remains unchanged for compatibility.

The controller is the only interface between an agent brain and the physical world.
The machine-readable source of truth is `actions.json`.

## Rules

- Select exactly one enabled action per observation.
- Never provide coordinates, velocities, transforms, quantities, or guaranteed results.
- The simulation chooses targets, paths, interaction duration, and consequences.
- An intent explains the decision to an observer; it is not executable world state.
- Python may reject a choice before execution. Godot may still fail it if reality has
  changed by the time the body arrives.

## Movement and exploration

`inspect(area, intent)` moves toward a broad semantic area and reveals it.

## Resources

`collect(resource, intent)` finds the nearest available visible source, moves to it,
and attempts one gathering interaction.

Allowed milestone resources: `wood`, `stone`, `food`.

## Building

`build(structure, intent)` selects a valid nearby site, moves there, pays the cost,
and constructs the structure over time.

Allowed structures: `shelter`, `farm`, `storage`, `wall`, `workshop`.

## Recovery

`rest(intent)` spends a turn recovering. Shelter improves the outcome.

## Reserved competition actions

`craft`, `send_message`, `attack`, and `defend` are present in the catalog but disabled
for milestone one.
