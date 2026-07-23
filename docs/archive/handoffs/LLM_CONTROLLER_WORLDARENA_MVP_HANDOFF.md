# Handoff Prompt — WorldArena scripted gameplay expansion

> **Status (2026-07-21): superseded implementation handoff.** The baseline and “important gaps”
> below describe the repository before the completed local implementation wave. Do not restart
> work from them. The authoritative current status is the checkpoint table in
> `docs/features/LLM_CONTROLLER_WORLDARENA_SCRIPTED_GAMEPLAY_FEATURE.md`: the credential-free solo,
> duo, and trio product paths are implemented; final native showcase approval/publication remains.
> This file is retained only as historical rationale and constraints.

Copy the prompt below into a new Codex chat.

---

You are taking over implementation of the **LLM Controller × WorldArena scripted gameplay
expansion** in the WorldEval repository.

This is intended for a cloud agent. Work from the repository root returned by `pwd`; do not assume
the prior local path `/Users/arlind/Documents/WorldEval`, a pre-running backend, an open portal, an
interactive browser session, or access to the previous chat.

## Read first, in full

1. `docs/features/LLM_CONTROLLER_WORLDARENA_SCRIPTED_GAMEPLAY_FEATURE.md` — current approved
   offline-first feature plan and delivery order.
2. `docs/features/LLM_CONTROLLER_WORLDARENA_MVP_FEATURE.md` — historical MVP architecture,
   authority, privacy, fairness, and protocol constraints.
3. `docs/LLM_CONTROLLER_WORLDARENA_MANAGED_AUTHORITY.md`.
4. `docs/LLM_CONTROLLER_WORLDARENA_SOLO_MECHANICS.md`.
5. `docs/LLM_CONTROLLER_WORLDARENA_HYBRID_PRESENTATION.md`.
6. `docs/LLM_CONTROLLER_WORLDARENA_LIVE_SOLO.md` and
   `docs/LLM_CONTROLLER_WORLDARENA_CERTIFICATION.md` for implemented provider/replay/dashboard
   context; live-provider gates in those documents are deferred by the new plan.
7. `game/embodiment_protocol/worldarena.environment.json`, its schemas, fixtures, and
   `protocol-lock.json`.
8. `backend/genesis_arena/embodiment/`, especially:
   - `scripted_solo_demo.py`, `scripted_construction_demo.py`, and
     `construction_task_provider.py`;
   - `episode_service.py`, `live_runtime.py`, `live_solo.py`, `evaluation.py`, and
     `replay_archive.py`;
   - `duel/`.
9. `godot/scripts/embodiment/`, especially the authority, presentation, preview, transport, duel,
   and replay namespaces, plus the focused runners in `godot/tests/embodiment/`.
10. `dashboard/src/App.tsx`, `dashboard/src/api.ts`, `dashboard/src/components/`, and
    `dashboard/src/marketing/`, plus `.github/workflows/pages.yml`.

Inspect every applicable `AGENTS.md` before editing. Check `git status` and recent history first.
The worktree may contain user or agent changes; preserve unrelated work and never reset, checkout,
delete, or rewrite it to simplify integration.

## Current repository state

Do not restart from the old Phase-0 handoff. The repository already has:

- deterministic Godot authority for all solo stages:
  - Stage A `orientation-v0`;
  - Stage B `interaction-v0`;
  - Stage C `construction-v0`;
  - Stage D `neutral-encounter-v0`;
- participant-visible hybrid observations, typed actions/receipts/events, deterministic
  checkpoints, a third-person Y Bot presentation, and offline replay verification;
- credential-free provider-shaped scripted controllers for A–D. A/B/D emit strict direct-control
  JSON; Construction emits bounded milestone-task JSON that Godot expands continuously;
- a long Construction scenario that walks, turns, gathers, carries, deposits, builds, celebrates,
  and normally completes near tick 1194, but is not yet exposed as its own multi-action showcase;
- safe preview/snapshot plumbing, a stable dashboard canvas, saved solo replay archive, native
  Godot Movie Maker + FFmpeg playback, and public replay routes;
- authority-derived solo and paired-duel evaluation sealed into public evidence, but no dedicated
  evaluation API or dashboard page;
- substantial 1v1 infrastructure: two-participant Godot authority, fixed 10-tick joint windows,
  relay-hold-or-knockout victory, participant-local observations, scripted baseline, paired two-leg
  scheduling, symmetry checks, evaluation, independent replay verification, service/API scaffolding,
  and focused tests;
- a React/Vite controller dashboard and a static GitHub Pages marketing site with lazy video slots
  for MVP, solo, and duel.

Important gaps:

- current scripted controllers are task-specific; there is no reusable fixture-driven mock LLM
  core for solo/duo/trio;
- production series/API/UI deliberately permit at most one `scripted` entrant, so two credential-free
  agents cannot launch end to end even though lower-level two-fake-provider integration tests pass;
- participant preview currently targets roughly 10 FPS rather than the planned interpolated 30 FPS;
- there is no separately selectable multi-action demo, movement maze, operator action course, or
  per-run Evaluation view;
- duo browser pixels, safe series timeline, and durable native series replay are unfinished;
- the embodiment protocol, authority, scheduler, evaluator, replay, API, and UI do not support a
  third participant.

The previously reported baseline was green for the focused Godot project scan, dashboard tests and
build, full embodiment tests, and existing Duel tests. Re-run relevant tests rather than relying on
that report after changes.

## Product direction

Finish a polished credential-free product before returning to live APIs.

Implement one first-class **Demo provider (no API key)** backed by a deterministic mock LLM core.
Use an additive internal provider ID such as `demo`; preserve existing sealed `scripted` identities
for replay compatibility and baseline semantics. The Demo provider must receive only the normal
participant-visible `ProviderRequest`, emit raw strict JSON bytes, and pass through the same parser,
schema validation, fallback, authority, audit, evidence, evaluation, and replay path as a live
provider. It must support deterministic valid and failure fixtures without network access.

Do not add scenario ID or seed to `ProviderRequest` or participant observations. Construct the
adapter with an immutable evidence-bound `DemoPolicyLock` containing scenario/policy/fixture hashes,
seed, assignment, and a total decision budget. Add explicit provider capabilities such as
`requires_credential=false` and `is_networked=false`, and label Demo runs
`certification_eligible=false`; they are evaluated demonstrations, not certified live-model scores.

There will be no provider API key in this environment. Do not ask for one, search for one, create a
credential file, make a live provider call, or make live smoke tests part of an exit gate. Keep all
existing session-only credential protections intact for later work.

The portal will not already be running. Do not block on computer-use, an in-app browser, or manual
live testing. Start local processes only when useful and available; rely on pytest, headless Godot,
Vitest, typecheck, builds, deterministic replay, and mock-provider end-to-end tests. If Godot,
FFmpeg, or a browser is unavailable in the cloud environment, run everything else, leave correct
commands/fixtures, and report the missing executable honestly.

## Required implementation order

Follow `docs/features/LLM_CONTROLLER_WORLDARENA_SCRIPTED_GAMEPLAY_FEATURE.md` in order. Start with
M0, implement rather than producing another replacement plan, and report each validated gate.
Continue to the next gate only while context/budget permits; leave a green reviewable checkpoint
rather than combining unfinished phases. Do not jump to trio before the solo and duo gates are green.

1. **Build the shared Demo-provider foundation.** Implement `DemoProvider`, `DemoPolicyLock`,
   no-key/non-network provider capabilities, bounded decision budgets, deterministic failure
   fixtures, run classification, and evidence hashes before new scenarios depend on it.
2. **Finish solo A–D.** Add production-service no-key coverage for every stage, make all dashboard
   lifecycle/replay states reliable, finish participant-only 30 FPS interpolated JPEG streaming
   over the separate authenticated preview/WebSocket path with newest-frame-only backpressure, and
   retain the forward-facing movement regression test. Keep provider/evidence/snapshot frames as
   the existing sanitized hash-bound PNG contract; JPEG is preview-only.
3. **Add the `multi-action-demo-v0` scenario.** Map it to existing `construction-v0` authority and
   produce one continuous 900–1,200-tick run showing turning, walking, gathering, carrying,
   depositing, building, and celebration. Call the provider only at milestone boundaries; Godot
   executes movement/interactions continuously.
4. **Add simple solo games.** Start with `movement-maze-v0`, then
   `operator-action-course-v0`, to prove script/controller intent matches Godot movement, facing,
   animation, collision, receipts, and outcomes.
5. **Ship per-run evaluation.** Expose allow-listed active and saved-replay evaluation APIs and an
   Evaluation page. Unsealed runs return not-ready; use authority evidence only, never an LLM judge.
6. **Productize duo with two Demo agents.** Reuse the managed paired scheduler and begin with
   simple credential-free games: checkpoint race, relay control, sparring, then the full
   `central-relay-v0` relay-or-knockout game. Add participant-selected pixels, timeline, evaluation,
   and verified native replay.
7. **Layer duo complexity only after basics pass.** Resource relay/build/defend mechanics come
   later and remain separately diagnosable.
8. **Design and implement trio as a new versioned protocol capability.** Add exactly three
   participants, exact three-way symmetry, three cyclic seat rotations, participant-local pixels,
   per-seat neutral fallbacks, evaluation, and replay. Start with `trio-relay-v0`, then
   `trio-free-for-all-v0`.
9. **Finish the product and publish evidence.** Render verified solo multi-action, scripted 1v1,
   and scripted Sol/Luna/Terra free-for-all videos with Godot Movie Maker + FFmpeg. Update README
   capabilities/instructions and the GitHub Pages YouTube facade, including
   `VITE_YOUTUBE_TRIO_ID`/`YOUTUBE_TRIO_ID`, a deliberate latest-demo featured card, and the correct
   `/WorldEval/` Pages base path. Do not invent IDs, upload externally, or change repository
   variables without user authorization.

Sol, Luna, and Terra are the requested WorldArena entrant identities and mock-policy labels for the
three-agent demo. Do not claim they are released provider model IDs until official live mapping is
explicitly verified in a later phase.

## Workflow and delegation

- Use subagents proactively for independent bounded work.
- **Subagents may implement and integrate work**, including protocol, API, service, dashboard,
  replay, and test wiring. Integration is not reserved to the root agent.
- Assign one owner per shared file/surface during a wave; coordinate before touching manifests,
  protocol locks, dependency files, route tables, or dashboard roots.
- Agents share a worktree: never overwrite or discard another agent's changes. Inspect combined
  diffs and run cross-suite validation after integration.
- Use `apply_patch` for file edits.
- Keep authority, presentation, provider, evaluation, and shared-protocol code in separate
  namespaces with explicit dependencies.
- Validate every completed slice before moving to the next gate. Continue autonomously in plan
  order while safe; do not pause merely because live credentials are absent.

## Safety and compatibility requirements

- Never expose hidden state, spectator-only pixels/data, exact hidden coordinates, opponent-private
  observations, prompts, raw model/mock output, credentials, or protected evidence through public
  APIs or the dashboard.
- Invalid input must advance a recorded neutral window; it cannot freeze authority time.
- Keep fixed 10-tick evaluated duo and trio windows and participant-indexed results. Demo runs are
  explicitly non-certifying until a later scored profile is certified.
- Preserve the existing `llm-controller/0.1.0` package bytes, lock, and replay verifier. Add a
  multi-version registry plus an immutable `0.2.0` package for new solo/duo authoritative game IDs
  and an immutable `0.3.0` package for trio. Select schemas/verifiers by replay version; never
  regenerate the `0.1.0` lock in place.
- Preserve the 2,048 UTF-8-byte episode-only Python scratchpad, reset it between multiplayer legs,
  and never send it to Godot or public evidence.
- Never modify frozen `game/duel_protocol/**` (`worldeval-rts/1.0.0`) or imply protocol
  interchangeability.
- Do not use Remotion. Native videos must come from verified replay through Godot Movie Maker and
  FFmpeg.
- Keep exports, credentials, protected bundles, and local run artifacts out of git.

## Validation expectations

On a fresh cloud checkout, bootstrap only the committed project dependencies if they are absent:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -e ".[dev]"

cd dashboard
pnpm install --frozen-lockfile
cd ..
```

Do not recreate a healthy environment unnecessarily. Run the narrow tests for each slice, then the
broad suites before handoff or publication:

```bash
.venv/bin/pytest -q tests/embodiment
.venv/bin/pytest -q tests/duel

cd dashboard
pnpm lint
pnpm test
pnpm typecheck
pnpm build
pnpm build:pages
```

Also run the Godot project parse and every relevant headless runner when Godot is available. Add
tests for mock-provider strictness/failures, cross-runtime conformance, deterministic replay,
participant privacy, frame backpressure, evaluation allow-lists, duo/trio symmetry, and dashboard
Setup/Live/Timeline/Result/Evaluation/Replay states.

At each checkpoint report:

- the completed behavior and remaining phase;
- changed files grouped by authority/provider/API/evaluation/presentation/dashboard/docs;
- exact tests and commands run;
- unavailable tools or unverified assumptions;
- confirmation that no credential or protected participant data was introduced.

---
