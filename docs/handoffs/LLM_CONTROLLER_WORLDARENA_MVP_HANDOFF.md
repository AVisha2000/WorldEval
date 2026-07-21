# Handoff Prompt — LLM Controller × WorldArena MVP

Copy the prompt below into a new Codex chat.

---

You are taking over implementation of the approved **LLM Controller × WorldArena MVP** in the
repository `/Users/arlind/Documents/WorldEval`.

Read these documents first, in full:

1. `docs/features/LLM_CONTROLLER_WORLDARENA_MVP_FEATURE.md` — approved product and phase plan.
2. `docs/LLM_CONTROLLER_WORLDARENA_MVP.md` — original embodiment design rationale.
3. `game/embodiment_protocol/worldarena.environment.json` and its schemas.
4. `backend/genesis_arena/embodiment/` — current Python contracts and validator.
5. `godot/scripts/embodiment/embodiment_solo_simulation.gd` and
   `godot/tests/embodiment/embodiment_solo_headless_runner.gd` — current Stage-A authority.

Important current state:

- The worktree is intentionally dirty. Preserve all unrelated user work. Do not reset, checkout,
  delete, or rewrite unrelated files.
- Existing frozen WorldArena Duel (`worldeval-rts/1.0.0`) is a reference implementation only. Do
  not modify its locked protocol artifacts or claim the embodiment format is interchangeable.
- The embodiment prototype currently has a Stage-A solo headless simulation, schemas, Python
  contracts, and passing focused tests. It is not yet a real multi-participant or hybrid runtime.
- The approved MVP is: hybrid solo Stages A–D plus symmetric two-leg live model 1v1, backed by
  OpenAI, Anthropic, and Gemini adapters and a local React/Vite dashboard.
- Use third-person camera control, Mixamo Y Bot after manual approved intake, fixed 10-tick 1v1
  decision windows, a 2 KB episode-only scratchpad, and relay-hold-or-knockout victory.
- Provider keys are session-only backend memory. Never persist, log, expose, or send them to Godot.
- Do not use Remotion. Native video must be Godot Movie Maker plus FFmpeg.

Start with **Phase 0 only**. Do not jump to UI, live providers, or 1v1 implementation.

Phase-0 deliverables:

1. Make observation schemas mutually exclusive:
   - hybrid requires both visible text and a participant frame;
   - text excludes a frame;
   - RGB excludes semantic entity/self payloads;
   - unimplemented profiles/modes fail before reset.
2. Replace singular step results with participant-indexed observations and receipts.
3. Introduce an explicit joint `DecisionWindow` and `no_input` fallback policy.
4. Enforce fixed 10-tick scored-duel horizons while retaining 1–20 solo windows.
5. Align Python/Godot UTF-8 byte limits, strict types, integer arithmetic, canonical JSON, and
   checkpoint hashing.
6. Add typed authority event and capability-status contracts.
7. Add conformance fixtures proving both runtimes accept/reject identical payloads.

Acceptance criteria for this turn:

- Python and Godot focused embodiment tests pass.
- Existing full Duel tests remain unaffected.
- Invalid duel input cannot stall time: it produces a recorded neutral window.
- No new provider call, asset download, or UI framework is required for Phase 0.
- Report changed files, tests run, and any assumptions.

Workflow requirements:

- Inspect `AGENTS.md` instructions if present before editing.
- Use `apply_patch` for file edits.
- Keep authority, presentation, provider, and shared-protocol code in separate namespaces.
- Never expose exact hidden state or spectator-only data through player observations.
- Use skills when relevant: `openai-docs` before OpenAI adapter work; frontend skills only once the
  dashboard phase starts; no Remotion skill.
- Send concise progress updates and validate every completed slice.

After Phase 0 is accepted, proceed in plan order: authority/managed session, solo mechanics,
hybrid presentation, provider/live solo, 1v1, then certification/export.

---
