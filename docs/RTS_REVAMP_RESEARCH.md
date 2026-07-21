# WorldArena RTS revamp research

## Product decision

WorldArena should remain a Godot application, but the Arena implementation should be rebuilt as
an RTS simulation with a separate spectator projection. The current backend/evaluator concepts are
worth preserving: simultaneous decisions, typed actions, private observations, deterministic
resolution, audit logs, and separate cognition tracks. The main mismatch is that gameplay is
resolved as coarse round snapshots and then illustrated by a presentation layer. That cannot make
one-second gathering, worker-scaled construction, continuous movement, or hit-by-hit combat feel
truthful.

The new product is therefore:

> A deterministic, agent-controlled miniature RTS that can compute headlessly at maximum speed and
> replay the same authoritative tick stream as a readable, polished spectator match.

This is closer to Warcraft III in mechanics and to Clash Royale broadcasts in readability. It is
not a pixel-control clone and it should not make model latency part of the physics.

## Findings from the current repository

The repo already has strong foundations:

- Strict Pydantic plans and OpenAI tool schemas.
- Concurrent commander planning and commit/lock/reveal.
- Per-faction private observations and private/public messages.
- A deterministic Godot simulation with a seeded PRNG.
- Evidence-linked evaluation, season scheduling, and secret-free replay artifacts.

The implementation gaps are structural:

- `ArenaSimulation.resolve_round()` computes all 150 ticks before presentation receives the next
  snapshot.
- Movement is one district hop per round, not continuous position along a route.
- Gathering pays once per round; there is no timed interaction with a physical node.
- Construction queues count rounds and do not store builders, work completed, or pause reasons.
- Training queues do not identify a producer or expose progress.
- Combat runs tick-by-tick internally but emits mostly terminal deaths, so the renderer cannot show
  wind-up, impact, damage, retreat, and recovery beats.
- Presentation fabricates character geometry and world props instead of instancing production game
  assets and animation state machines.
- The setup UI hard-codes three specialists even though the backend already accepts zero through
  three per faction.
- The spectator HUD presents internal orchestration detail before it explains the physical match.

## Engine and package recommendation

### Keep Godot and use built-in systems first

The current machine has Godot 4.5 stable and the project uses the Compatibility renderer. Godot is
cross-platform and supports macOS/Apple Silicon. The small, fixed benchmark arena does not need an
open-world engine.

Use these engine-native systems:

- `GridMap` or authored modular scenes for the compact terrain and buildable cells.
- `NavigationRegion3D` plus `NavigationServer3D` paths for routes; use `NavigationAgent3D`
  avoidance only for actively moving squads because Godot documents a meaningful cost for large
  numbers of registered avoidance agents.
- `AnimationPlayer` + `AnimationTree` for idle, walk, run, attack, gather, build, carry, hit,
  defeat, and celebrate states.
- `GPUParticles3D` for wood chips, dust, sparks, coins, healing, and capture effects.
- `MultiMeshInstance3D` for repeated grass, rocks, trees, and non-interactive decoration.
- Resource-driven scenes for units, structures, work sites, projectiles, and resource nodes.

Relevant Godot documentation: [NavigationAgent3D](https://docs.godotengine.org/en/4.4/classes/class_navigationagent3d.html),
[using navigation agents](https://docs.godotengine.org/en/4.3/tutorials/navigation/navigation_using_navigationagents.html),
and [AnimationTree](https://docs.godotengine.org/en/stable/tutorials/animation/animation_tree.html).

### Art pack choice

Choose one coherent family rather than mixing several low-poly styles.

Recommended initial stack:

1. [KayKit Adventurers](https://kaylousberg.itch.io/kaykit) for optimized, rigged, animated
   characters and weapons. It is CC0 and explicitly supports Godot.
2. [KayKit Medieval Builder](https://kaylousberg.itch.io/kaykit-medieval-builder-pack) or the
   newer Medieval Hexagon pack for buildings, roads, walls, and scenery. The legacy pack is CC0.
3. [KayKit Character Animations](https://kaylousberg.itch.io/kaykit-animations) for locomotion,
   attacks, interaction, pickup, throw, defeat, and celebration. It is CC0.

Alternative coherent stack:

- [Quaternius Medieval Village](https://quaternius.com/packs/medievalvillage.html),
  [Universal Base Characters](https://quaternius.com/packs/universalbasecharacters.html), and
  [Universal Animation Library](https://quaternius.com/packs/universalanimationlibrary.html).
  These are CC0, Godot-compatible, and the animation library provides 120+ retargetable actions.

Do not commit paid/source-tier content without an explicit asset decision. Store every imported
pack's source URL, version, checksum, license, and attribution requirement in an asset manifest.

### Packages to adopt selectively

- [Terrain3D](https://github.com/TokisanGames/Terrain3D) is mature and MIT-licensed. Its docs say
  macOS and the Compatibility renderer are supported. It is useful if the map becomes organic and
  sculpted, but it is not required for the first compact arena. It adds a native GDExtension and
  macOS quarantine/signing friction. Pin the Godot-4.5-compatible release if adopted; do not pull
  the latest blindly.
- [LimboAI](https://github.com/limbonaut/limboai) is a capable MIT behavior-tree/state-machine
  plugin, but it should not own benchmark decisions or authoritative worker behavior. Deterministic
  task executors are smaller, easier to audit, and easier to replay. LimboAI is appropriate only
  for non-scored wildlife or cosmetic NPC behavior.
- [Beehave](https://godotengine.org/asset-library/asset/1349) is the GDScript alternative, with the
  same boundary: presentation/cosmetic AI only.
- [GdUnit4](https://github.com/godot-gdunit-labs/gdUnit4) is a good later addition for scene and
  GDScript component tests.
- [Godot RL Agents](https://github.com/edbeeching/godot_rl_agents) is useful for a future RL-facing
  adapter. It should not replace the LLM commander protocol.

### Implemented package status

- Kenney UI Pack Adventure 1.1: reviewed CC0 vector subset installed and used by the HUD, buttons,
  and minimap frame.
- Quaternius Medieval Village (December 2020): ten reviewed CC0 FBX buildings installed from the
  official public distribution with per-file SHA-256 provenance. Bell Tower, Inn, and Blacksmith
  are resolved into strongholds, settlements, and resource works with procedural fallbacks.
- Terrain3D 1.0.1-stable and LimboAI 1.6.0: pinned, licensed, installed, and guarded so neither can
  mutate authoritative benchmark state.
- NavigationAgent3D, FastNoiseLite, and WorldEnvironment lighting: engine-native presentation hooks
  are active.
- Mixamo: the import/retarget contract is present, but Adobe's interactive account flow prevents a
  reproducible unattended clip download. Procedural walk/work/attack beats remain active until
  reviewed clips are imported.
- Quaternius Medieval Village MegaKit Standard (2025): still requires the official interactive $0
  itch flow. The installed 2020 village subset provides real Quaternius art without bypassing it.

## Simulation architecture

### One authoritative tick stream

Use a 10 Hz deterministic simulation. A commander decision window remains a macro action interval,
not a rendering frame. Plans create or update persistent orders; engine-owned executors perform the
physical work over subsequent ticks.

Each tick produces ordered `WorldEvent` values with:

- `event_id`, `tick`, `round`, and `kind`;
- actor and target entity IDs;
- start/progress/impact/complete/cancel state;
- authoritative resource, health, and work deltas;
- visibility/audience;
- positions expressed as deterministic waypoint + fixed-point local progress;
- links back to plan, order, and validation receipt IDs.

Headless mode consumes the tick stream immediately. Spectator mode buffers and plays it at 0.5x,
1x, 2x, 4x, or “key moments” speed. Rendering never feeds back into results.

### Continuous task model

Every physical action becomes a persistent `Task`:

| Task | Authoritative progression | Presentation |
|---|---|---|
| Move | fixed-point progress along named route segments | walk/run blend and formation steering |
| Gather wood | 10 ticks per chop cycle, node stock decremented on impact | axe wind-up, tree hit, wood chips, carry bundle |
| Mine | timed swing cycle, deposit decremented on impact | pickaxe impact, sparks, coin/ore burst |
| Build | work units per tick from assigned workers | scaffolding stages, hammer loop, dust |
| Train | producer queue work units | building pulse, queue/progress UI, spawn celebration |
| Attack | wind-up, impact tick, cooldown, simultaneous damage | attack animation, projectile/impact, health feedback |
| Capture | uncontested control work per tick | ring fill, banner stages, contested pulse |

Construction stores `required_work`, `completed_work`, `builder_ids`, `reserved_cost`, and pause/
cancel reason. Worker contribution is linear up to the job's staffing cap, so two workers complete a
two-worker-cap job in half the time. Builders must be alive, present, and not reassigned.

### Starting state and economy

For the readable economy-first mode requested here, each faction starts with:

- one Core Keep;
- one Commander;
- one Worker;
- a small starting stockpile sufficient for an initial Worker or basic resource structure;
- no free army.

The first meaningful decision is whether to grow workers, secure food/wood, scout, or rush a combat
unit. Starting armies can remain a separate “advanced start” scenario, not the default benchmark.

## Agent/environment contract

### Observation modes

The benchmark should expose three explicit tracks:

1. `semantic` (default): structured state, legal action masks, delta events, chat inbox, active task
   progress, uncertainty/last-seen fields, and validation receipts.
2. `vision`: a faction-camera screenshot plus only minimal game metadata. This is a VLM/perception
   benchmark and must not share a leaderboard with semantic agents.
3. `hybrid` (experimental): semantic state plus screenshot, useful for demos and ablations.

Do not send screenshots in the default reasoning track. BALROG reports models performing worse with
visual representations, so pixels introduce a major perception confound when the desired measure is
planning and social strategy. Structured observations also make privacy, determinism, token cost,
and action legality auditable. See [BALROG](https://arxiv.org/abs/2411.13543) and
[TextArena](https://www.textarena.ai/docs/overview).

The external environment adapter should follow a parallel multi-agent shape inspired by PettingZoo
and Gymnasium:

```text
reset(seed, scenario) -> observations, info
step(joint_plans) -> observations, reward_vectors, terminated, truncated, info
render(mode = human | rgb_array | replay)
```

PettingZoo explicitly supports simultaneous-action games and action masking; Gymnasium separates
natural termination from time-limit truncation. See the [PettingZoo AEC/parallel discussion](https://pettingzoo.farama.org/main/api/aec/)
and [Gymnasium Env API](https://gymnasium.farama.org/api/env/).

### Commander and specialists

Advisor count must be configurable per faction from 0 through 3. In the fair Agentic track,
specialists are separate calls to the same model snapshot as the Commander and share one faction
cognition budget. They share:

- the same faction objective;
- a structured blackboard of durable facts and open questions;
- legal faction observation subsets;
- concise recommendations and confidence;
- no hidden chain-of-thought or direct action authority.

The Commander alone submits the final plan. This answers the “two Sol APIs” question: yes, they are
distinct model calls with isolated roles and a shared audited blackboard, not two actors mutating the
world independently.

The existing strict Responses API adapter remains a good benchmark default because exact call counts,
schemas, deadlines, and commit/reveal are explicit. OpenAI documents the Responses API as supporting
structured tool use and state chaining. The Agents SDK adds built-in agents-as-tools, handoffs,
sessions, guardrails, and traces; it is appropriate as an optional orchestration adapter or demo mode,
not a silent replacement for the frozen benchmark runtime. See [Responses API benefits](https://developers.openai.com/api/docs/guides/migrate-to-responses#responses-benefits)
and [Responses API vs Agents SDK](https://developers.openai.com/api/docs/guides/agents#compare-the-responses-api-and-agents-sdk).

## Reward and evaluation policy

Keep competitive outcome separate from behavioral explanation.

- Primary outcome: placement/win derived only from game rules.
- Training reward vector: objective control, economy delta, army value preserved, technology
  progress, exploration information gain, valid-plan reliability, and optionally social outcomes.
- Benchmark report: planning/adaptation, resource efficiency, combat efficiency, social intelligence,
  delegation efficiency, and reliability, each backed by events and receipts.

Do not collapse the training reward vector into one permanently fixed scalar in the core engine.
Weights belong to a versioned scenario/track wrapper. Do not expose dense diagnostic rewards to
black-box LLM competitors during a benchmark; doing so encourages reward gaming and changes the task.

Evaluation should rotate seats, seeds, and opponent populations. Melting Pot's substrate/scenario
split is useful: one physical map/rules substrate can be paired with different resource scarcity,
visibility, opponent, and diplomacy scenarios to measure generalization to unfamiliar social
partners. See [Melting Pot 2.0](https://arxiv.org/abs/2211.13746).

## Spectator UX

The default view should answer “what is happening?” before “how was the model called?”

- Full compact arena visible at the default camera.
- Top centre: current objective and control progress.
- Left: three compact faction rows with model, resources, population, army value, and active task.
- Right: a short physical event feed; communication appears only when relevant.
- Bottom: selected entity/task detail and replay speed controls.
- World-space feedback: task icon, progress bar, resource gain, health loss, and target line.
- Auto-director may zoom to a key event only if the minimap/overview remains available and the shot
  never hides the objective for long.

Setup becomes a short wizard: API key, scenario/track, per-faction model and reasoning effort,
advisor count 0–3, observation mode, decision interval, and spectator speed.

## Implementation sequence

1. Preserve v0.2/v0.3 replay compatibility and make v0.4 the live conquest protocol.
2. Introduce deterministic entity positions, persistent tasks, work units, and tick events.
3. Add the parallel environment adapter and semantic observation v2.
4. Replace fabricated presentation actors with asset-backed unit/structure scenes and AnimationTrees.
5. Build the readable spectator HUD and setup wizard.
6. Add one vertical slice: one Worker chops a tree, deposits wood, and trains a second Worker.
7. Add worker-scaled construction, then mining, then combat, then capture/supply/diplomacy.
8. Add replay parity checks: state hash and event hash must match headless execution.
9. Add optional vision/hybrid tracks, RL adapter, and Terrain3D only after the semantic RTS is stable.

## Non-negotiable constraints

- Game art and camera state never determine authoritative outcomes.
- Model latency never determines initiative.
- No package may own hidden world state outside the simulation.
- No visual-only event may enter an agent observation.
- Every external asset and native addon must be pinned, checksummed, licensed, and reproducible.
- Semantic, vision, standard, agentic, and open-team results remain separate.
