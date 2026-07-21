# LLM Controller × WorldArena solo mechanics

Phase 2 extends the deterministic integer authority from orientation through the complete solo
curriculum. Every action remains a bounded controller state; the authority never accepts semantic
gather, build, attack, or activate commands.

## Stage B — interaction

- Interaction range is 1,400 millitres and requires the exact one-of-eight facing sector.
- A material unit requires four held-interact ticks. Progress survives release, movement out of
  range, misalignment, and explicit cancellation; each interruption is public evidence.
- The Operator carries at most two units. The resource begins with four units.
- A facing, in-range relay interaction deposits all carried units atomically. Stage B succeeds
  after at least one unit is deposited.

## Stage C — construction

- The resource, carry, and relay rules are identical to Stage B.
- A barricade requires two deposited material units and six held-interact ticks at the marked pad.
- Construction progress is repeated and resumable. Material is checked throughout but spent
  atomically only when the barricade completes.
- Stage C succeeds only on authoritative barricade completion. Its golden path includes an
  alignment miss and correction, two gathers, a deposit, an interrupted build, and resumed
  completion.

## Stage D — neutral encounter

- Operator health and energy are integer values from 0 to 1,000. Energy recovers by 25 per idle
  tick.
- Primary attacks deal 250 damage within 1,600 millitres and a 45-degree facing cone, with a
  five-tick cooldown. Misses and cooldown attempts are recorded without correction.
- Guard costs 40 energy per tick and halves frontal damage using division toward zero.
- Dash is an edge-triggered 900-millitre move costing 300 energy with a ten-tick cooldown.
- The 750-health neutral follows a public deterministic state machine: idle, chase, telegraph,
  attack, recovery, retreat, and defeated. Its attack telegraphs for three ticks and deals 180
  damage. At 250 health it retreats and recovers to 500 at home after five recovery ticks.
- The relay requires three consecutive interact ticks while the neutral is retreating, recovering,
  or defeated. Operator knockout fails the episode; relay activation succeeds it.

## Evidence and determinism

Task state enters the checkpoint only for the selected task, preserving the Stage-A checkpoint
shape and hash. Observations expose coarse player-visible bearings, ranges, progress, inventory,
health, energy, and public neutral state; they never expose exact positions or checkpoint state.
Receipts contain stable codes and integer effects, and all gameplay events use the typed public
event envelope.

Golden transcripts contain only participant observations, joint decision windows, receipts,
public events, opaque state hashes, and terminal boundaries. Each transcript has per-window event
digests and a canonical whole-transcript SHA-256 seal; Godot replays every window from genesis.
