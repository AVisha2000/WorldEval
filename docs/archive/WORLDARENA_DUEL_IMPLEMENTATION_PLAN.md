# WorldArena Duel implementation plan

**Plan version:** 1.0

**Protocol target:** `worldeval-rts/1.0.0`

**Rules target:** `duel-rules-v1`

**Engine baseline:** `Godot 4.5.stable.official.876b29033`

**Normative product specification:** `docs/WORLDARENA_DUEL_IMPLEMENTATION_SPEC.md`

## 1. Delivery strategy

Build the benchmark in vertical, deterministic slices. Every phase must leave a runnable headless
artifact, automated evidence, and an unchanged result for the preserved arena/survival scenarios.
Do not begin production visuals or live provider integration until the protocol and simulation can
replay scripted matches byte-for-byte.

The implementation has four hard boundaries:

1. `worlds/worldarena/game/duel_protocol/` owns public schemas, catalogs, prompts, maps, fixtures, and locked hashes.
2. `worlds/worldarena/godot/scripts/duel/` owns authoritative game state and consequences.
3. `worlds/worldarena/backend/genesis_arena/duel/` owns provider-neutral orchestration, strict wire validation, timing,
   and artifact management; it never resolves game mechanics.
4. `worlds/worldarena/godot/scripts/duel/presentation/` owns visuals only and must be removable from a headless export.

The old three-player arena and survival prototype remain regression fixtures. Delete or rewrite an
old component only after the duel replacement has equivalent tests and no preserved scenario imports
it. Never mix duel conditionals into the old simulator.

## 2. Dependency order

```text
protocol schemas/catalogs ─┬─> Python validation/gateway
                           ├─> Godot catalog loader
exact map artifact ────────┤
                           └─> deterministic DuelState/ticks/pathing
                                      │
                                      ├─> economy/construction
                                      ├─> combat/Heroes/fog/neutrals
                                      └─> observations/actions/receipts
                                                   │
                                                   ├─> fixed simultaneous mode
                                                   ├─> continuous real-time mode
                                                   ├─> replay/evaluation seasons
                                                   └─> spectator UI and assets
```

No downstream phase may invent a constant that belongs in a versioned catalog. No presentation
component may become an authoritative dependency.

## 3. Workstreams and delegation

### A. Protocol and catalogs

Owns `worlds/worldarena/game/duel_protocol/` except generated map data while the map workstream is active.

- Draft 2020-12 schemas with `additionalProperties:false`.
- Full rules, action, attack/armor, item, neutral, and four faction catalogs.
- Frozen controller prompt, valid/maximal/invalid fixtures, canonical hash fixtures.
- Cross-file identifier/reference validation and `protocol-lock.json` generation.

Acceptance: Python and Godot read the same bytes, reject the same invalid fixtures, and agree on all
locked hashes.

### B. Map and spatial rules

Owns `worlds/worldarena/game/duel_protocol/maps/`, its deterministic generator, and map-specific tests.

- Exact 384×256 logical grid at 500 mt/cell.
- Region graph, terrain/elevation/LOS, resources, camps, neutral buildings, build sites, footprints,
  exits, spawns, tactical slots, and the exact 180-degree transform.
- Connectivity, equal-distance, rotational-equivalence, and deterministic-regeneration tests.

Acceptance: every cell/site has one rotated partner; both seats have transformed-equivalent legal
paths and starting resources.

### C. Godot authoritative core

Owns `worlds/worldarena/godot/scripts/duel/simulation/`, shared duel data types, and headless Godot tests.

- Integer state, entity/order/event IDs, explicit tick phases, delta ledger, occupancy, deterministic
  A*, keyed contests, canonical checkpoints, replay application, and terminal state.
- Economy, construction, combat, Heroes, fog, neutrals, and faction hooks added in later slices.

Acceptance: same map/seed/transcript matches every checkpoint in-process and across fresh processes;
rendering is never initialized.

### D. Agent Gateway and evaluation

Owns `worlds/worldarena/backend/genesis_arena/duel/`, duel API routes, provider adapters, and Python integration tests.

- Strict decoding and restricted-JCS canonicalization.
- Per-player knowledge/observation messages and opaque aliases.
- Action validation, fixed commit/lock/reveal, real-time arrival gates, timeout ownership, receipts,
  protected/public artifacts, baselines, and paired-seed evaluation.

Acceptance: fake delayed agents prove timing invariants; no hidden-state mutation changes opponent
observation bytes; replay requires no provider call.

### E. Presentation and assets

Begins only after an end-to-end scripted mirror match is deterministic.

- Setup, spectator HUD, minimap, fog, faction perspectives, replay controls, and accessibility.
- Reviewed KayKit/Kenney intake with exact provenance/checksums.
- Animation and audio consume authoritative state/events only.

Acceptance: headless hashes are identical with presentation enabled or absent.

## 4. Ordered phases

### Phase 0 — isolation and regression baseline

1. Create duel-only namespaces and this execution plan.
2. Record the exact Godot build and current deterministic arena hash.
3. Run the existing fast Python and arena headless tests.
4. Keep Terrain3D/LimboAI out of duel authority and eventual server export.

Exit gate: preserved tests pass; an empty duel headless runner boots without touching old scenarios.

### Phase 1 — executable protocol package

1. Implement all schemas and catalogs from the specification.
2. Author the exact map artifact and generator.
3. Implement strict Python loading, canonical bytes, reference checks, and lock verification.
4. Add equivalent Godot loaders and golden fixtures.

Exit gate: the package is self-consistent, locked, and validated byte-for-byte on both runtimes.

### Phase 2 — deterministic simulation kernel

1. Implement `DuelState`, IDs, typed orders/events/deltas, and 14 tick phases.
2. Load the map; implement occupancy, movement budgets, A*, conflict resolution, LOS grid, and keyed
   exclusive claims.
3. Implement checkpoint hashing, transcript replay, and a dedicated headless runner.

Exit gate: a scripted movement/visibility scenario is identical across repeated fresh processes.

### Phase 3 — economy vertical slice

1. Resources, cargo, worker cycles, depletion, deposits, food, and upkeep.
2. Site-based construction, worker variants, repair, cancellation/refunds, queues, rally/exit cells.
3. Tiers, upgrades, Hero slots, expansions, and starting state.

Exit gate: mirrored Vanguard scripts gather, build, train, tech, and expand with exact receipts.

### Phase 4 — combat and world rules

1. Attack/armor pipeline, projectiles, stances, statuses, air/siege/mechanical rules.
2. Heroes, attributes, XP, skills, death/revival, items, all regular and Hero abilities.
3. Fog/knowledge memory, camps, shops, Reveal, day/night, corpses, summons, exclusive contests.
4. Implement and conformance-test Vanguard, Warhost, Grove, and Crypt from data.

Exit gate: every faction completes a deterministic scripted mirror match and every catalog ability
has an executable test at each rank.

### Phase 5 — LLM fixed-simultaneous loop

1. Build match-init and full-belief observations only from `AgentKnowledgeState`.
2. Implement all primitive/hybrid commands, atomic budgets, receipts, working memory, and safe errors.
3. Add provider adapters behind a common interface and fake/scripted baselines.
4. Implement concurrent dispatch and commit/lock/reveal; apply both batches at `T+1`.

Exit gate: arrival order and response speed never change a fixed-mode state hash.

### Phase 6 — continuous mode and evaluation

1. Implement the 100-ms monotonic gate calculation and one-in-flight policy.
2. Implement stale/late responses, endpoint ownership, hard-failure counters, and infrastructure voids.
3. Add replay bundles, paired side/worker swaps, baselines, metrics, confidence intervals, and
   resumable multi-seed series.

Exit gate: both modes complete paired unattended series and replay every scored checkpoint.

### Phase 7 — product UI and production assets

1. Pregame model/mode/faction/map/profile selection and locked official presets.
2. Spectator/faction views, minimap, events, entity panels, decisions, and replay seeking.
3. Intake the specified KayKit/Kenney packs; build rigs, materials, construction stages, effects,
   accessibility, audio, and stripped dedicated-server export.

Exit gate: the match is legible at both target resolutions and rendering cannot alter authority.

### Phase 8 — certification

1. Full protocol, mirror, fog-leak, determinism, security, malformed-input, fuzz, and soak suites.
2. macOS/Linux and ARM64/x86-64 golden replay parity.
3. Headless/live performance targets and provider failure drills.
4. Freeze hashes and publish one candidate benchmark season manifest.

Exit gate: every scored game is reproducible, auditable, fair under its declared track, and backed by
machine-readable evidence.

## 5. Pull-request-sized implementation slices

Keep changes reviewable even while developed in one working tree:

1. protocol package and lock tooling;
2. exact map artifact and validator;
3. Godot state/tick/pathing kernel;
4. replay/checkpoint runner;
5. economy vertical slice;
6. combat/fog vertical slice;
7. Vanguard completion;
8. other three faction data/abilities;
9. observation/action protocol and fixed mode;
10. continuous mode and failure handling;
11. evaluation/baselines;
12. setup/spectator/replay presentation;
13. asset intake and production polish;
14. certification fixes and frozen release.

Each slice must include tests, update hashes only intentionally, and state whether it changes the
benchmark environment ID.

## 6. Immediate first-wave deliverables

Work begins with these concrete outputs:

- `worlds/worldarena/game/duel_protocol/` schemas, catalogs, prompt, fixtures, exact map, and hash tooling;
- `worlds/worldarena/backend/genesis_arena/duel/` strict canonicalization and package validation;
- `worlds/worldarena/godot/scripts/duel/` render-free constants/state/pathing/tick skeleton;
- Python and headless Godot smoke/conformance tests;
- a regression result for the existing test suite and current arena deterministic runner.

After this wave, the next implementation action is Phase 3's Vanguard economy vertical slice—not UI
or asset work—because it exercises the kernel and wire contract with the smallest complete gameplay
loop.

## 7. Execution log

### 2026-07-19 — Phase 0 baseline

- Repository engine confirmed as `Godot 4.5.stable.official.876b29033`.
- Existing Python suite passed in full before duel integration.
- Preserved arena headless runner passed with deterministic hash
  `39b904eb0014941330f6435796ae0a041979802047495eb6fb87d59f327de719`, 1,245 events, and no
  winner in its authority fixture.
- Duel protocol/backend/Godot work was assigned to disjoint paths so current uncommitted arena work
  remains untouched.

### 2026-07-19 — Phase 1 protocol and map lock

- Created the complete `worldeval-rts/1.0.0` package: eight strict schemas, shared rules/actions,
  attack/armor, items, neutrals, four selectable mirrored faction catalogs, the frozen commander
  prompt, valid/maximal/invalid fixtures, and executable conformance cases.
- Generated and validated the exact 384×256 logical launch grid. The compact map artifact is
  117,445 raw bytes with SHA-256
  `8a6b5436b15cc518f8efd03fa0a9b0d0d0b72466d517e0bed802c7d2528aaaba`; its expanded palette-index
  grid hash is `d146d8465e5e3a4f588d6c46c94ba6234f1af8dd17e92255af34a44e11624aec`.
- Frozen `protocol-lock.json` over 35 artifacts. Its aggregate verification digest is
  `ddc4242727ceeb38f3e2e3a63b5916067ce520a52af5251b4897cdfc79706b00` after the visible-shop
  alias contract was frozen.
- The checked-in maximal fixture frame is 238,365 bytes. The production `MatchInit` builder's
  independently measured worst case is 242,833 of 262,144 bytes, leaving 19,311 bytes while still
  including the full map, selected faction, public catalogs, observation, prompt, action schema,
  and framing.
- Python protocol/map conformance passed, and the Godot catalog loader independently reproduced
  catalog bundle hash `edc06db5d7d80ea66ca5d74e7c5ea5bcb565887f9d4a037b58edd5887f49434e`.

### 2026-07-19 — First authoritative vertical slices

- Implemented the render-free integer Godot state, IDs, occupancy, deterministic A*, keyed random
  streams, delta ledger, all 14 tick phases, and canonical checkpoints. The fresh-process core
  golden is `0e13e7bfa235e9e67fe8e549d52470b42c7774d47aca37b05698bd8277f7f0d1`.
- Implemented resources, gathering, finite remainders, upkeep, food, reservations/refunds,
  construction, repair, FIFO production/research, technology tiers, blocked exits, cleanup,
  receipts, and no-progress accounting. The Vanguard economy golden is
  `c6abd88c0850bd1a4187412339e913c69e04fa9b8cb5c5e2268587c9b601edb8`.
- Implemented strict canonical wire models for all 37 operations, action/atomic budgets,
  idempotency, knowledge-safe aliases/events, fixed simultaneous concurrent dispatch,
  commit-lock-reveal, shared deadlines, `T+1` activation, failure ownership/counters, deterministic
  artifact bundles, and offline replay verification hooks.
- Replay execution, continuous scheduling, and the combat vertical slice began in parallel after
  these hashes were frozen; presentation remains deliberately downstream of authority.

### 2026-07-19 — Replay, real-time scheduling, and evaluation infrastructure

- Added an offline Godot replay executor with exact-tick primitive transcripts, event verification,
  decision/application/300-tick/final checkpoints, canonical-byte enforcement, and visible
  fail-closed corruption errors. Its fresh-process document hash is
  `95eb682b3cb015aa671403076fbd5e995e3fce40b7fee0a32695e322a5a336ec`; its fixture final-state
  hash is `1b63812f6b0eb2d6d7876596d692850b6c401292785b7217139af5bac2025011`.
- Added the continuous real-time scheduler: 50-tick paired dispatch grid, one in-flight call per
  player, 100-ms strictly-later application gates, shared deadlines, skew/drift/backwards-clock
  infrastructure handling, stale/late no-ops, delayed failure evaluation, and atomic per-gate
  Godot bridge requests. Fixed and continuous results remain separate track values.
- Added canonical authenticated local transport frames with monotonic per-direction sequences,
  message-specific boundary hashes, provider hidden-hash rejection, byte limits, and single-use
  non-reconnectable local session authentication.
- Added hash-frozen paired-seed manifests and scoring. Seats, continuous inference workers, and
  dispatch precedence swap between legs; infrastructure voids exclude and rerun the complete pair;
  bootstrap intervals sample paired seeds; no LLM judge or material tiebreak can alter Godot's
  outcome.

### 2026-07-19 — Catalog-to-world bootstrap and gameplay authority wave

- Added the official runtime catalog compiler for all four faction presets. It maps the locked
  themed catalogs into one common economy/runtime contract without copying balance constants into
  code. The aggregate runtime hash is
  `de9b8d52f4cbd75280890b612c1b008d9638c8b08502b1f926711fcbccc17a42`.
- Added the fail-closed official match bootstrap: exact locked map, both rotated starts, exact cell
  footprints, faction-specific starting workers, both player economies, resources, combat, Hero
  catalogs, terminal rules, and scored hash-boundary verification. Enabling canonical Hero state
  intentionally advanced its aggregate bootstrap hash to
  `01ba6b28bd7084c2a23ba4246a721d64a44df53902fd3f1c39007e01fad3394c`.
- Added the protected match-runtime attachment boundary. It verifies the private tie key against the
  scored commitment, registers every starting mobile actor, and checkpoints only the key digest;
  the four-faction aggregate protected-runtime hash is
  `231abf9f16bfe91c9854f717b01c313f9aae3873037400825820496e97dcea91`.
- Completed deterministic attack/armor, windups, projectiles, simultaneous typed deltas, healing,
  shields, layers, status expiry, immunities, elevation, and lifecycle cleanup. Combat golden:
  `5b563bfbd2b28a36a63757dd4750dfa38b04da23ab1bd41e5d6a628d0af37372`.
- Completed deterministic movement with integer remainders, static A*, footprint-aware corners,
  scheduled replans, air lanes, simultaneous reservations, protected HMAC conflicts, routes, and
  durable movement orders. Movement golden:
  `ce9d9e262c79ed534fec28dad2d73add01c4745df4fbf00e8a16d9e6f5cce5f3`.
- Completed fog/knowledge authority with integer LOS, elevation/forest/building occlusion,
  day/night, invisibility/detection, exploration, frozen memory, audience events, opaque aliases,
  and player-relative transforms. Visibility golden:
  `5615dcd1bab7066a88f1c89328ab43377e39ecb0628e9ddfdc717f0ec9363c9d`.
- Completed the strict 37-operation Godot action validator/compiler, exact allowlists and budgets,
  per-command rejection, squads/formations/tactics, and canonical receipts/intents. Action golden:
  `e82ca46037a78d7958a1dcbb6fe78e1582cb33e0db12ccf972c4e9e1e168506f`.
- Added an observation builder that accepts only a closed public projection, rejects hidden/internal
  key classes recursively, applies the normative truncation order, and produces the full
  `observation.v1` payload. Observation golden:
  `81746f58deb51686d2fe3e7e5b3715804c34ed61b9f074e6473c95203e2cac8a`.
- Added selected-faction named Heroes, integer attributes, XP/ranks, deterministic XP remainders,
  six-slot inventories, passive and consumable items, ground-item lifecycle, interruption, death,
  integer Strength/Intellect regeneration, and paid altar/Tavern revival in phases 10–11. Hero
  golden: `d1741d966fc25aacfc7ed39f91b1924e0eaf11c50e0525406177858b5a376d13`.
- Added phase-13 stronghold victory, simultaneous destruction draw, exact time/no-progress draws,
  technical forfeits, infrastructure voids, terminal event emission, and hard simulation stop.
  Terminal golden: `a5d8dbca60523613910fae86fe3665650b234f2acdb535a6e05c421bbcf106f6`.
- Active parallel work now joins neutral camps/markets, phase-12 perception, and the validated action
  intents to these systems. Full faction ability execution and the end-to-end unattended match loop
  remain the next authority gates before production UI or asset intake.
