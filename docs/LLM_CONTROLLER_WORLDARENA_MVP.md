# LLM Controller — WorldArena Embodiment MVP

## 1. Decision

WorldArena will be the first environment adapter for **LLM Controller**. The first benchmark is
not the full three-faction conquest game. It is a staged embodiment curriculum with one physical
body per model:

1. one model, one body, no opponent;
2. one model versus a deterministic scripted opponent;
3. model versus model in a mirrored 1v1;
4. team and multi-agent modes only after the 1v1 is reliable and enjoyable to watch.

The existing `worldeval-rts/1.0.0` Duel authority remains frozen. The embodiment MVP uses a new
protocol namespace so the simpler game can evolve without invalidating Duel replays or locks.

## 2. Product boundary

The MVP proves that a text-producing model can:

- receive a versioned description of an unfamiliar embodied environment;
- perceive only information available to its selected sensor profile;
- emit human-equivalent controller states as strict JSON text;
- observe the consequences over several small deterministic steps;
- retain bounded memory and recover from mistakes;
- complete solo tasks and later compete under symmetric 1v1 conditions; and
- produce replayable evidence and comparable evaluation metrics.

The MVP does not attempt universal virtual-HID injection, robotics, arbitrary third-party games,
large RTS armies, diplomacy, faction asymmetry, or multi-agent teams. Its interfaces must make
those later adapters possible, but WorldArena is the only implemented environment.

## 3. Embodiment model

Each participant controls one visible **Operator** body. An Operator has movement, facing, health,
energy, an inventory with deliberately small capacity, and a fixed controller. It can walk, look,
interact, use a primary tool, guard, and trigger two earned abilities.

The model does not call semantic world methods such as `move_to`, `gather`, `build`, or
`attack_enemy`. It outputs controller state for a bounded duration. Godot decides what that input
means in the current physical situation.

Examples:

- moving the stick toward a tree walks toward it but does not guarantee arrival;
- holding `interact` while close and facing the tree performs gathering;
- pressing `primary` swings the equipped tool, which may hit a resource, neutral, rival, or air;
- holding `guard` reduces frontal damage but consumes energy; and
- pressing an unavailable ability produces a visible rejected receipt and no hidden correction.

Text is the transport, not the control abstraction. A valid model response is a strict JSON object
conforming to `controller-action.v1.schema.json`.

## 4. Gameplay ladder

### Stage A — Orientation

- One Operator spawns in a small enclosed arena.
- Goal: reach a visible beacon.
- Teaches movement, facing, duration, collision, and observation cadence.
- Success requires entering the beacon radius and remaining there for one full step.

### Stage B — Interaction

- Goal: collect one marked resource and deposit it at the home relay.
- The model must approach, face, hold interact, notice inventory change, return, and deposit.
- Resources take multiple interactions; progress is animated and reported in coarse visible bands.

### Stage C — Construction

- Goal: gather enough material and build one barricade on a marked pad.
- Construction requires repeated physical interaction and can be interrupted.
- The world never turns a single model response into an invisible completed building.

### Stage D — Neutral encounter

- Goal: activate a relay defended by one predictable neutral creature.
- Teaches spacing, guarding, tool range, health, retreat, and recovery.
- The neutral has a public deterministic behavior profile but no privileged model-facing state.

### Stage E — Scripted 1v1

- One model and one baseline controller receive identical Operators.
- The map, starting loadout, sensor profile, action budget, and simulation rules are symmetric.
- The baseline has fixed deterministic difficulty tiers used for regression and calibration.

### Stage F — Model 1v1

- Two models play the same role on a 180-degree mirrored map.
- A match is a two-leg series with swapped spawn sides.
- Primary objective: capture and hold the central relay, or disable the rival Operator.
- No economy or army production is required in the first scored ruleset.

### Later expansion

Resource collection, construction, support-unit recruitment, fog, and team play are added one
system at a time only after the previous stage has a clear visual language and stable evaluation.

## 5. Temporal model and slower granular play

Godot remains deterministic at 10 simulation ticks per second. The default benchmark track is
step-locked:

- the world pauses while a model reasons;
- a response controls at most 20 ticks (2 simulated seconds);
- the initial curriculum defaults to 10 ticks (1 simulated second);
- controller state is held for the requested duration unless the episode terminates;
- collision, damage, gathering, and interaction resolve every tick;
- an observation is emitted after every action window and on terminal events; and
- model latency is recorded but does not change gameplay in the step-locked leaderboard.

The spectator presentation plays authoritative ticks at 0.75x to 1.0x speed, shows the current
controller state, and pauses briefly on important receipts. This makes the chain
`observation -> model action -> physical result -> updated observation` legible.

A separate real-time track may be added later. Results from step-locked and real-time tracks must
never share a leaderboard.

## 6. Observation profiles

Every episode locks exactly one profile before reset.

### `text-visible-v1` — first implementation

A deterministic description of only currently visible information:

- self health, energy, inventory, facing sector, and current contact;
- goal and public remaining time;
- nearby visible entities described by opaque episode IDs;
- relative bearing sectors and distance bands, never exact world coordinates;
- visible affordances such as `interactable`, `hostile`, `deposit`, or `build_pad`;
- recent public events and the previous action receipt; and
- bounded model scratch memory returned from the previous action.

This is intentionally easier and cheaper than vision while retaining embodiment. The text
projector must derive from the same visibility result used by rendering.

### `rgb-v1`

The model receives the rendered first- or over-shoulder camera frame, the goal, controller
manifest, remaining time, and previous receipt. It receives no object list or hidden telemetry.

### `hybrid-visible-v1`

The model receives both the RGB frame and the deterministic visible text projection. Hybrid,
text-only, and vision-only results are reported separately.

The spectator camera is never a participant sensor. Screenshots, aliases, and observations are
player-scoped and must not leak rival-hidden or authority-only state.

## 7. Controller surface

The launch controller has two signed axes and eight buttons:

| Input | Range | Meaning |
| --- | --- | --- |
| `move_x` | -1000..1000 | strafe left/right |
| `move_y` | -1000..1000 | move backward/forward |
| `look_x` | -1000..1000 | rotate left/right |
| `look_y` | -1000..1000 | reserved for camera pitch; zero in top-down MVP |
| `interact` | boolean | gather, deposit, activate, or construct in facing context |
| `primary` | boolean | use equipped tool/attack |
| `guard` | boolean | guard while held |
| `dash` | boolean | one edge-triggered dash attempt |
| `ability_1` | boolean | first earned ability |
| `ability_2` | boolean | second earned ability |
| `cycle_item` | boolean | cycle one inventory slot |
| `cancel` | boolean | cancel a channel/current interaction |

Buttons marked as edge-triggered activate once at the start of the action window. Held buttons are
applied every tick. The environment manifest is authoritative for this behavior.

The model may add an `intent_label` and bounded `memory_update`. They are non-executable evidence:
the runtime never repairs or replaces controller input based on them.

## 8. Runtime interfaces

The provider-neutral runtime surface is:

```python
manifest() -> EnvironmentManifest
reset(EpisodeConfig) -> Observation
observe() -> Observation
step(ControllerAction) -> StepResult
render(sensor_id) -> Frame
state() -> PublicEpisodeState
close() -> None
```

Responsibilities are separated:

- **Godot authority:** physics, collisions, sensors, visibility, world state, legality, tick
  execution, terminal outcome, deterministic hashes, and replay events.
- **Python runtime:** provider calls, strict byte/JSON/schema validation, memory limits, episode
  orchestration, deadlines, artifact assembly, and evaluation.
- **Provider adapter:** translates one immutable player-scoped request into raw response bytes and
  sanitized telemetry. It cannot access the opponent observation.
- **Presentation:** consumes authority state/events and never mutates simulation.

## 9. Machine-readable package

`worlds/worldarena/game/embodiment_protocol/` is the executable contract:

- `VERSION` — protocol version;
- `worldarena.environment.json` — sensors, controls, modes, timing, constraints, and curricula;
- `schemas/environment-manifest.v1.schema.json`;
- `schemas/controller-action.v1.schema.json`;
- `schemas/observation.v1.schema.json`; and
- `schemas/action-receipt.v1.schema.json`.

`controller.md` is not an API. Human documentation may be generated from or checked against the
manifest, but scored execution accepts only the versioned machine contracts.

## 10. Fairness contract

Every scored 1v1 must lock and publish:

- protocol, environment, rules, map, body, controller, observation, and evaluator hashes;
- the same Operator body, loadout, cooldowns, and action limits for both seats;
- one seed and a map with exhaustive 180-degree symmetry checks;
- simultaneous step boundaries and identical simulated action horizons;
- equal input/output byte ceilings and provider deadlines;
- player-relative opaque entity aliases;
- no model-specific prompts beyond provider formatting requirements;
- no retries or silent action repair;
- all rejected, timed-out, and no-op decisions in the replay;
- a two-leg side-swapped series for a reportable head-to-head result; and
- separate leaderboards for observation and timing profiles.

Provider wall-clock latency is evidence in step-locked mode, not a combat advantage. Token usage is
reported as an efficiency metric but does not alter the world.

## 11. Evaluation

### Solo metrics

- task success and completion tick;
- progress checkpoints reached;
- valid action rate;
- controller changes and total held ticks;
- path efficiency against the shortest legal route;
- unnecessary collisions;
- interaction alignment failures;
- damage taken and recovery quality;
- repeated ineffective action windows;
- memory consistency; and
- model tokens and wall-clock latency.

### 1v1 metrics

- series win/draw/loss and objective control time;
- damage dealt/taken and guard efficiency;
- positional advantage and disengagement success;
- adaptation after losing an exchange;
- action validity, idle time, and oscillation;
- side-normalized performance across both legs; and
- deterministic replay verification.

Evaluation scores must be computed from authority events, never from model prose or spectator UI.

## 12. Presentation requirements

The playable demo must make agency obvious:

- close enough camera framing to see the Operator and target;
- visible movement, turning, impact, interaction, and construction animation;
- a compact panel containing observation number, current controller state, duration, and receipt;
- a short readable model intent label, clearly marked non-authoritative;
- progress bars that advance over multiple action windows;
- distinct telegraphs for accepted, blocked, missed, cooldown, and completed actions;
- no large empty map overview as the default shot; and
- optional split-screen/player-relative views for 1v1, with an omniscient spectator minimap.

## 13. Repository implementation order

1. Freeze this MVP contract and validate the machine-readable package in Python tests.
2. Add provider-neutral `EnvironmentAdapter`, `EpisodeConfig`, `ControllerAction`, `StepResult`,
   and runtime validation types under `worlds/worldarena/backend/genesis_arena/embodiment/`.
3. Build the Godot orientation arena and one Operator body with deterministic controller input.
4. Implement text-visible observation projection and action receipts.
5. Complete Stages A through D with scripted regression episodes.
6. Add the deterministic baseline opponent and symmetric two-leg 1v1 series.
7. Connect existing provider adapters through a generic participant boundary.
8. Add replay/evaluation artifacts and the pregame profile switches.
9. Render a native Godot demo only after the actions in the replay are produced by the same adapter
   path used by live models.

## 14. Acceptance gate for the first demo

The next demo is acceptable only if it shows an actual adapter-driven Stage C episode in which one
agent visibly:

1. receives an observation;
2. turns and walks toward a resource over multiple action windows;
3. misses or corrects alignment at least once;
4. gathers through repeated interactions;
5. returns to a construction pad;
6. builds through multiple visible progress steps; and
7. receives a terminal success receipt and evaluation summary.

An authored showcase that directly changes snapshots does not satisfy this gate.
