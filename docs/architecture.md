# WorldArena architecture

## Authority boundary

The LLM plans; Godot resolves reality. Models receive semantic, visibility-filtered state and
submit typed plans. They cannot access coordinates, physics, arbitrary code, files, network,
Godot nodes, opponent hidden state, or another model's prompt and memory.

```text
Provider or Demo policy
  └─ Commander
      └─ 0–3 bounded same-model specialists (recommendations only)
              │
              ▼
FastAPI ArenaOrchestrator
  schema validation · concurrent calls · cognition · commit/reveal
              │  world-arena/0.2
              ▼
Godot ArenaMatchController
  observation projection · commit verification · validation receipts
              │
              ▼
ArenaSimulation
  seeded state · fixed ticks · economy · wildlife · combat · supply · score
              │
              ▼
Arena presentation
  interpolated meshes · HUD · diplomacy · bubbles · replay · podium
```

`ArenaSimulation` is the only component that awards or removes world resources, ownership,
damage, structures, units, supply, and victory. The presentation consumes snapshots/events and
cannot mutate results. Python can reject malformed plans and account for model compute but
cannot secretly resolve the game.

## Simultaneous round state machine

1. Godot freezes one canonical state hash.
2. It projects three separate `FactionObservation` values.
3. Python runs eligible specialists, then all Commanders concurrently.
4. Python canonicalizes and seals plans, returning only three commit hashes.
5. Godot locks those commits.
6. Python reveals all three plans and salts together.
7. Godot verifies every hash and validates every plan against the frozen state.
8. Godot applies accepted orders through one simultaneous 150-tick round.
9. Godot resolves economy, wildlife, capture, supply, diplomacy, upkeep, and score.
10. Godot sends typed receipts and the new state hash; only then can Python advance.

Per-round phases are atomic. Duplicate concurrent commits/reveals, stale state hashes,
out-of-order rounds, cancellations, and late responses fail closed. Provider latency never
advances simulation time.

## Cognition isolation

- `standard`: one Commander call per faction per round; no specialists.
- `agentic`: up to three defined same-model specialists, at most two calls per round, sharing
  a 120-unit budget while 80 Commander units remain reserved.
- `open`: configurable Open Teams experiments; reported separately.

Specialists are non-recursive and cannot issue actions or speech. They see a narrow brief plus
only their faction's legal observation. The Commander alone submits the final plan. Failed and
timed-out calls consume their scheduled cognition unit; provider-reported input, cached input,
output, reasoning, latency, and optional cost are recorded.

## Diplomacy and privacy

Public messages enter every next-round inbox. Private messages and offers enter only sender and
recipient inboxes; omniscient spectator rendering is a separate projection. Trades are typed
and atomic. Pacts are recorded but never engine-enforced, so a hostile order remains legal and
produces a deterministic betrayal event.

Incoming model text is normalized, rejects control characters, is treated as untrusted game
data, and never enters system instructions. API credentials are accepted only by the local
setup flow and retained in process memory; secret-like artifact keys and values are rejected.

## Determinism and replay

The map, rules, state, PRNG, plans, events, receipts, and checkpoints are versioned. Canonical
plans are SHA-256 committed. Same seed plus the same action stream reproduces the same round and
final hashes independent of API arrival order, frame rate, playback speed, or camera state.
Replay re-executes recorded actions and never calls a model.

## Benchmark outputs

Godot-derived placement remains the competitive result. A separate versioned WorldArena
0–100 score explains behavior through six evidence-linked categories: objective control,
planning/adaptation, resource/combat efficiency, social intelligence, delegation/cognition,
and reliability/safety. No LLM judge is used.

The season scheduler freezes model/prompt/rules/map/tool/budget/deadline metadata, then creates
33 seeds × three complete seat rotations for 99 scored matches plus one unscored championship
replay. Standard, Agentic, and Open results never share a leaderboard.

## Migration

The competitive scene is `godot/scenes/arena_v1.tscn`. The original sequential survival slice
is preserved independently at `godot/scenes/main.tscn` and on the legacy `/ws/world` protocol;
Arena logic is not implemented as conditional branches inside that scenario.
