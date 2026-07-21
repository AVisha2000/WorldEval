# Feature: LLM Controller × WorldArena MVP

**Status:** Historical approved MVP plan; foundation substantially implemented

**Protocol:** `llm-controller/0.1.0`  
**Primary environment:** WorldArena / Godot 4.5  
**MVP outcome:** A local researcher can run a hybrid-perception solo curriculum and a
verified, symmetric two-leg model-versus-model 1v1 through a web dashboard.

> **Continuation:** Remaining offline-first product work, the Demo provider, solo control games,
> per-run evaluation UI, scripted duo progression, trio, and final media publication now follow
> [`LLM_CONTROLLER_WORLDARENA_SCRIPTED_GAMEPLAY_FEATURE.md`](LLM_CONTROLLER_WORLDARENA_SCRIPTED_GAMEPLAY_FEATURE.md).
> That plan supersedes this document's remaining delivery order and delegation rule while
> preserving its authority, privacy, fairness, replay, and credential boundaries.

## Product decision

WorldArena is the first environment adapter for the future universal LLM Controller runtime.
The MVP deliberately starts with one LLM controlling one physical third-person Operator, then
extends to an identical scripted opponent and finally two competing models.

The MVP does **not** include RTS armies, faction asymmetry, diplomacy, teams, robotics, browser
environments, persistent cross-episode memory, virtual HID injection, or additional games.
Existing frozen `worldeval-rts/1.0.0` Duel work must remain untouched.

## Fixed MVP choices

- MVP contains solo Stages A–D plus live model-versus-model 1v1.
- The only scored MVP perception profile is `hybrid-visible-v1`: player-visible text plus one
  1280×720 lossless PNG from a third-person participant camera at every decision boundary.
- Text-only and RGB-only modes remain unavailable until separately certified; do not advertise
  them as implemented merely because their schemas exist.
- Operators use a shared manually reviewed Mixamo **Y Bot** rig and clips. Until approved assets
  arrive, use a procedural placeholder only.
- Live provider support is OpenAI, Anthropic, and Gemini behind one provider-neutral interface.
- Researchers configure episodes in a local React/Vite dashboard served alongside FastAPI.
- Provider API keys are entered through a masked session form and held only in backend process
  memory; they are never persisted, returned to the browser, sent to Godot, logged, or replayed.
- Solo windows may last 1–20 simulation ticks. Scored 1v1 uses simultaneous fixed 10-tick windows.
- Writable model memory is a 2,048 UTF-8-byte Python-owned scratchpad and resets between duel legs.
- 1v1 uses central-relay capture or knockout: hold the relay uncontested for 100 consecutive ticks
  or reduce the rival to zero health; simultaneous terminal conditions draw; unresolved matches
  draw at 1,800 ticks.
- Native video uses Godot Movie Maker plus FFmpeg. Do not use Remotion.

## Target architecture

```text
React/Vite dashboard
        |
FastAPI Episode/Series service
        |
EmbodimentEpisodeRunner
  |-- OpenAI / Anthropic / Gemini adapters
  |-- Python-owned memory, deadlines, audit, evidence, evaluation
  '-- AsyncWorldArenaSession
           '-- authenticated loopback WebSocket
                    '-- one managed Godot authority process per episode
```

Godot owns integer world authority, visibility, simulation, receipts, events, checkpoints, and
terminal results. Python owns provider calls, validation, memory, lifecycle, public/protected
artifacts, evaluation, and dashboard APIs. Presentation consumes immutable authority projections
only.

The runtime must publish participant-indexed results:

```python
MultiParticipantStepResult(
    observations: Mapping[participant_id, Observation],
    receipts: Mapping[participant_id, ActionReceipt],
    public_events: tuple[Event, ...],
    state_hash: str,
    terminal: TerminalState,
)
```

Both seats receive player-scoped observations from the same pre-window state. If a response is
invalid, missing, or times out, Python records a `no_input` disposition and Godot applies neutral
controller state for the common window. This is not semantic repair and prevents a participant
from freezing a duel.

## Delivery phases

### Phase 0 — Contract hardening

- Correct profile-specific observation schemas and reject unsupported profiles/modes before reset.
- Replace singular results with participant-indexed results and joint decision windows.
- Freeze no-input, failure, fixed-duel-horizon, UTF-8 byte-limit, typed-event, canonical JSON,
  HMAC, and integer rounding rules.
- Make Python and Godot conformance fixtures identical.

**Exit gate:** invalid actions, duplicate keys, floats, stale observations, semantic shortcuts, and
multibyte boundary cases fail identically in both runtimes; a rejected duel action advances one
neutral joint window; existing Duel tests remain clean.

### Phase 1 — Deterministic authority kernel and managed session

- Refactor Stage A into authority state, controller execution, collision/map, visibility,
  observations, event ledger, checkpoints, and terminal evaluator modules.
- Remove authority floating-point arithmetic.
- Introduce a managed one-Godot-process-per-episode runner using bounded canonical stdin bootstrap
  and authenticated loopback WebSocket frames.
- Implement `AsyncEnvironmentSession`, process lifecycle, cancellation, timeout, and replay ledger.

**Exit gate:** scripted Stage A completes through the managed process; independent replay produces
the terminal hash with no provider or network access; process cleanup succeeds on all exits.

### Phase 2 — Solo mechanics A–D

- Stage A: orientation, collision, turning, beacon hold.
- Stage B: approach/facing checks, repeated gathering, inventory, carry, deposit, interruption.
- Stage C: material requirements, build pad, repeated/resumable barricade construction.
- Stage D: deterministic neutral, primary attack, guard, dash, energy, cooldown, damage, retreat,
  and recovery.
- Emit stable typed events and receipts for range, alignment, progress, cancellation, completion,
  damage, cooldown, and failure.

**Exit gate:** golden transcripts for A–D reproduce exact event sequences and hashes. A Stage-C
episode visibly includes a miss/correction, repeat gathering, deposit, repeat construction, and a
terminal success receipt.

### Phase 3 — Hybrid presentation and asset intake

- Build a compact third-person arena scene with an immutable projection adapter.
- Capture a 1280×720 PNG from each participant camera at every decision boundary.
- Generate visible-text projection from the same visibility snapshot and bind text/frame hashes.
- Import the manually supplied Y Bot base and animation-only clips: idle, walk, run/dash, attack,
  guard, gather, build, hit, celebrate, and defeat.
- Use Godot `AnimationTree`, Kenney UI, existing Quaternius buildings, particles, decals, progress
  rings, and event-driven audio.

**Exit gate:** hidden-object fixtures are absent in text and pixels; presentation changes do not
alter authority hashes; Stage-C gameplay is legible without logs.

### Phase 4 — Providers, live solo, replay, and dashboard

- Implement immutable provider requests, strict output validation, no retries, usage/latency
  telemetry, and protected audit evidence for OpenAI, Anthropic, and Gemini.
- Implement public and protected episode bundles plus offline replay verification from genesis.
- Add FastAPI episode lifecycle endpoints and React setup, live status, timeline, result, and
  replay views.
- Add session-only credential handling; never use browser storage.

**Exit gate:** mocked provider failures pass for all three adapters, live opt-in smoke calls return
valid hybrid actions, and an actual live Stage-C run follows the same adapter/replay path.

### Phase 5 — Scripted and model 1v1

- Implement two-Operator simultaneous authority and exhaustive 180-degree map symmetry checks.
- Add central relay control, knockout, fixed 10-tick windows, simultaneous terminal resolution,
  deterministic baseline tiers, and paired two-leg scheduling.
- Concurrently dispatch both participant providers with equal prompts, schemas, deadlines, byte
  ceilings, and participant-scoped observations.
- Seal each leg independently and aggregate only complete verified pairs.

**Exit gate:** model-versus-scripted and model-versus-model two-leg series replay exactly; delay,
dictionary order, and response-arrival permutations do not alter authority hashes; baseline self-play
is side-neutral.

### Phase 6 — Certification and native demo

- Run protocol, authority, transport, provider, privacy, replay, fairness, browser, and 1v1
  symmetry suites.
- Complete 1,000 scripted headless episodes without drift, process leaks, or resource growth.
- Run at least ten paired seeds for internal MVP comparisons.
- Render verified solo Stage C and two-leg 1v1 replays at 1920×1080/30 FPS using Godot Movie Maker
  and FFmpeg H.264/yuv420p/AAC with `+faststart`.

**MVP gate:** all three providers can run hybrid solo episodes; any two configured models can run a
verified two-leg duel; the dashboard launches both workflows; no credentials leak; and the MP4 is
generated from verified replay rather than authored snapshots.

## Evidence and fairness

Public artifacts contain frozen configuration hashes, action dispositions/fallbacks, receipts,
typed public events, checkpoints, terminal results, and evaluation. Protected artifacts contain
player observations, PNG frames, prompt/request material, raw provider output, scratch memory,
parsing traces, visibility audits, and telemetry. Neither contains credentials or headers.

1v1 legs must lock protocol, rules, map, body, controller, observation projector, evaluator,
provider adapter, model ID, reasoning settings, byte limits, deadline, profile, timing track, seed,
and schedule nonce. Leg B swaps model seats, spawn sides, and dispatch precedence. A void leg
invalidates the pair and both legs rerun.

## Frameworks and Codex skills

Use Godot 4.5, FastAPI, Pydantic, jsonschema, Uvicorn, HTTPX, pytest, pytest-asyncio, canonical
JSON, HMAC-SHA256, authenticated loopback WebSockets, React, TypeScript, Vite, Tailwind CSS,
shadcn/ui, TanStack Query, Vitest, Playwright, Godot Movie Maker, and FFmpeg.

Use Codex skills as follows:

- `openai-docs` before OpenAI Responses/vision adapter work.
- `build-web-apps:frontend-app-builder`, `react-best-practices`, and `shadcn` for the dashboard.
- `build-web-apps:frontend-testing-debugging` and browser control for dashboard QA.
- `imagegen` only for optional concept/material assets, never authority or the Mixamo rig.
- `computer-use` only if manual Godot/Mixamo UI actions are required.
- Never use `remotion-showcase` for the demo.

## Delegation model

Use four active slots when useful: one final review owner plus three agents. Subagents may own
bounded integration work, including shared manifests, protocol versions, project settings,
dependency files, exports, and public API wiring. Assign one explicit owner per shared surface,
coordinate overlapping edits, and require final cross-suite review of the combined result.

| Wave | Agent A | Agent B | Agent C | Root |
| --- | --- | --- | --- | --- |
| 0 | schemas/conformance | multi-seat contracts/failure policy | typed events/evidence fixtures | protocol freeze |
| 1 | authority kernel | transport/process launcher | assets/Stage-A presentation | cross-language integration |
| 2 | Stages B/C | runner/OpenAI/service | hybrid capture/animation | live Stage-C gate |
| 3 | Stage-D neutral/combat | Anthropic/Gemini | replay/evaluation | provider certification |
| 4 | 1v1 authority | baselines/series scheduler | dashboard | end-to-end 1v1 |
| 5 | concurrent provider duel | evidence/privacy tests | verified replay/export | soak and release |

Agents must have exclusive path ownership. Authority agents do not edit presentation; presentation
only consumes immutable snapshots; provider agents never receive opponent data.
