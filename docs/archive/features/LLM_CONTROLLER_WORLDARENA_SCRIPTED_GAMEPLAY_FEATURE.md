# Feature Plan: LLM Controller × WorldArena scripted gameplay expansion

**Status:** Approved next-phase implementation plan

**Execution mode:** Offline-first and credential-free

**Foundation:** `llm-controller/0.1.0` embodiment MVP

**Target outcome:** A finished local product that demonstrates, evaluates, replays, and presents
deterministic solo, two-agent, and three-agent gameplay without requiring a provider API key.

## Product decision

Finish the product with deterministic mock agents before returning to live-provider testing. The
mock path must exercise the same provider-shaped request, strict JSON validation, authority,
participant visibility, evidence, evaluation, replay, and dashboard boundaries that a live model
uses. It is not a shortcut around the runtime and it must never consume hidden coordinates,
spectator state, prompts from another participant, or authority internals.

The work proceeds in increasing complexity:

1. finish and polish all four solo curriculum stages;
2. ship one continuous multi-action solo showcase;
3. add simple solo control-validation games and per-run evaluation;
4. productize simple credential-free two-agent games, then layer in combat and resource mechanics;
5. design and implement a symmetric three-agent free-for-all;
6. publish verified solo, 1v1, and three-agent videos through the README and GitHub Pages site.

Live OpenAI, Anthropic, and Gemini calls remain supported code paths, but live calls and credential
smoke tests are deferred. No phase in this plan may require a key, network provider call, existing
browser session, or pre-running local portal.

## Current implementation baseline

The credential-free product path is implemented across the planned gameplay layers:

- a reusable strict-JSON Demo provider with immutable policy locks, deterministic failure fixtures,
  bounded decisions, neutral fallback, audit/evidence binding, and non-certifying classification;
- managed solo Stages A–D, the separate `multi-action-demo-v0` showcase, Movement Maze, and
  Operator Action Course;
- participant-only hybrid observations and authenticated 30 FPS newest-frame-only presentation;
- authority-derived, allow-listed evaluation plus sealed, version-aware replay and native playback;
- credential-free two-agent Central Relay, Checkpoint Race, Relay Control, Sparring, and Resource
  Relay with fixed 10-tick windows and paired seat swaps;
- exactly-three-participant Relay and Free-for-All with Sol/Luna/Terra Demo policies, three cyclic
  legs, per-seat fallback, participant cameras, safe evaluation, and replay;
- immutable additive `llm-controller/0.2.0` and `0.3.0` packages beside frozen `0.1.0`;
- a React/Vite Controller Lab and a static Pages gallery for solo, 1v1, and trio evidence.

Remaining publication work is external-media-bound: produce and visually approve final native
showcase exports, then configure real user-authorized video IDs. Missing IDs intentionally retain
local poster fallbacks and make no third-party request.

## Implementation status — 2026-07-21

This table is an implementation checkpoint, not a relaxation of any exit gate below. A phase is
only marked complete when its production path and required automated evidence exist; native visual
acceptance remains pending wherever the required renderer or FFmpeg is unavailable.

| Phase | Status | Current evidence and remaining gate |
| --- | --- | --- |
| M0 — Demo provider | Complete | Credential-free deterministic strict-JSON policies, immutable policy locks, bounded decisions, failure fixtures, audit/evidence binding, neutral fallback, and non-certifying run classification are implemented and tested. |
| S1 — solo A–D | Complete in the managed product path | All four stages launch through managed Godot with Demo provider, participant-only hybrid frames, evaluation, replay, and dashboard lifecycle coverage. The shared preview uses authenticated JPEG ingress, newest-frame-only backpressure, and a stable canvas. |
| S2 — multi-action showcase | Complete in the managed product path | `multi-action-demo-v0` is a separate scenario over Construction, enforces the ordered gather/deposit/build/success sequence and 900–1,200 tick acceptance window, and records deterministic evidence. |
| E1 — evaluation product | Complete for solo and saved solo replays | Strict allow-listed projections, sealed-run readiness, durable evaluation sidecars, API routes, and the Evaluation dashboard view are implemented. Multiplayer durability expands with D1/T2. |
| S3 — solo control games | Complete in the managed product path | The `llm-controller/0.2.0` package, registry, versioned transport/verifier, Movement Maze, Operator Action Course, trusted map evaluation, Demo policy loops, participant presentation, and managed API-to-replay tests are integrated. |
| D1 — credential-free duo | Complete in the managed product path | Independent Alpha/Bravo Demo entrants, two-leg scheduling, safe timeline/evaluation, durable restart-readable archives, per-seat 30 FPS newest-only previews, participant PNGs, and verified native per-leg render dispatch are implemented. |
| D2 — simple duo ladder | Complete in the managed product path | Checkpoint race, relay control, and sparring are selectable keyless two-leg games with locked `0.2.0` schemas, participant viewports, safe evaluation, durable replay, dashboard support, and full API-to-managed-Godot restart acceptance. |
| D3 — richer duo mechanics | Complete in the managed product path | `duo-resource-relay-v0` adds independently tested gather/carry/deposit/build/defend/combat behavior while the simpler regression games remain available. |
| T1/T2 — trio | Complete in the managed product path | Immutable `0.3.0`, exactly-three authority, Demo policies, cyclic series, evaluation, replay, participant presentation, dashboard, Relay, and Free-for-All are integrated. |
| P1 — product/media | Export-ready; external publication pending | README and Pages describe actual no-key capabilities and provide solo/1v1/trio slots with local fallbacks. The verified, visually inspected 1920×1080/30 FPS participant-view solo multi-action, 1v1 spar, and Sol/Luna/Terra Free-for-All exports are locally ready. Uploading them and setting real user-authorized video IDs remains intentionally external. |

The frozen `llm-controller/0.1.0` and `worldeval-rts/1.0.0` artifacts remain unchanged. No phase
uses a live provider credential as an implementation or release dependency.

## Non-negotiable boundaries

- Godot remains the only gameplay authority. Python and mock providers may propose controls or
  validated tasks, but cannot award progress, damage, resources, score, or victory.
- Player observations expose only participant-visible pixels and semantic fields. Never expose
  exact hidden coordinates, spectator pixels, opponent-private observations, prompts, raw provider
  output, credentials, protected evidence, or authority checkpoints.
- Every evaluated multiplayer game in this plan uses fixed 10-authority-tick joint windows. Invalid,
  missing, stale, or timed-out input becomes a recorded neutral window and cannot stall time.
- Demo runs are evidence-backed evaluations but are explicitly `certification_eligible=false`; they
  must never be reported as certified live-model scores.
- Keep provider credentials session-only even though this plan does not use them. Do not create
  `.env` key files, fixtures containing live keys, or browser persistence.
- Preserve the 2,048 UTF-8-byte episode-only Python scratchpad boundary. Reset it between duel/trio
  legs and never send it to Godot or include it in public evidence.
- Preserve replay compatibility. Do not rename existing sealed `scripted` provider identities in
  old artifacts.
- Do not modify frozen `game/duel_protocol/**` (`worldeval-rts/1.0.0`) or claim it is
  interchangeable with the embodiment protocol.
- Preserve the current `llm-controller/0.1.0` package bytes and lock. Add a multi-version registry
  and a separate immutable `0.2.0` package for new authoritative solo/duo game IDs, then a separate
  `0.3.0` package for three-participant contracts. Select schemas and verifiers by replay protocol
  version; do not regenerate the existing `0.1.0` lock in place.
- Native video is generated from verified replay using Godot Movie Maker and FFmpeg. Do not use
  Remotion.
- Sol, Luna, and Terra are the requested WorldArena entrant identities for the final demo. Treat
  them as demo labels and versioned mock policies until official live-provider model IDs are
  explicitly verified in a later live-testing phase; do not market an unverified provider claim.

## Shared mock LLM core

Add a first-class `DemoProvider` with the internal provider ID `demo` and the display name
**Demo provider (no API key)**. Preserve `scripted` for existing replay compatibility and baseline
semantics. The new adapter may reuse existing solo and duel policies, but all new flows should pass
through one provider-neutral contract:

```text
participant-visible observation
        -> immutable ProviderRequest
        -> versioned demo scenario/policy
        -> raw strict JSON bytes
        -> normal parser and schema validation
        -> accepted control/task or recorded no_input
        -> Godot authority window
```

Construct the adapter with an immutable, versioned `DemoPolicyLock` containing scenario ID, policy
ID, fixture hash, seed, decision budget, and participant assignment. Integrity-bind that lock into
run configuration, audit evidence, and multiplayer fairness locks. Keep `ProviderRequest` unchanged:
the provider decides from participant-visible request data plus bounded private policy memory; the
scenario lock is configuration, not an observation field.

The core must support:

- scenario ID, policy ID, seed, participant identity, and observation sequence through the frozen
  `DemoPolicyLock` and ordinary request identity;
- one response at a time, derived only from that participant's visible observation;
- controller-action and validated task-plan outputs through the same parsers as live providers;
- fixture-driven valid, malformed, stale, oversized, refused, and timed-out responses;
- deterministic Sol, Luna, and Terra policy labels for later three-agent demonstrations;
- provider audit/evidence records containing safe identity and disposition fields but no invented
  network usage or credentials.

The dashboard should present this as a normal provider choice that never reveals or requires the
API-key field. Existing “Scripted demo” routes may remain as compatibility aliases until saved
replays and tests have migrated.

## Delivery plan

### Phase M0 — Shared Demo-provider foundation

- Implement `DemoProvider` and `DemoPolicyLock` before any new scenario or game depends on them.
- Add provider capabilities such as `requires_credential=false` and `is_networked=false` rather
  than treating every non-`scripted` provider as credentialed or billable.
- Exclude Demo calls from live-network call accounting, but enforce a separate bounded total
  decision budget so a local policy cannot run forever.
- Add `run_class=demo` and `certification_eligible=false` to safe run/evidence projections and
  fairness locks without rewriting prior replay identities.
- Use injected deterministic clocks/adapters for refusal and timeout tests; the production Demo
  policy must not deliberately sleep or introduce wall-clock nondeterminism.
- Preserve the current `scripted` compatibility path while proving equivalent valid Demo outputs
  pass through the normal strict parser, fallback, audit, evidence, and replay flow.

**Exit gate:** every supported current solo task can be driven by a constructed Demo adapter with no
credential or network call; policy-lock hashes reproduce exactly; malformed/stale/oversized/fake
timeout fixtures produce recorded neutral progress; no Demo run is labeled certified.

### Phase S1 — Finish the solo product

- Verify all four existing tasks through the production episode service with the no-key controller,
  not only lower-level golden or injected-provider tests.
- Make task selection, thinking/live/finished/failure states, timeline, result, and replay reliable
  for every stage.
- Finish the participant presentation stream: interpolate copied participant-filtered projections
  between 10 Hz authority ticks and publish 1280×720 participant pixels at 30 FPS.
- Keep preview traffic separate from decisions and replay. Add a versioned signed JPEG ingress over
  one persistent authenticated Godot-to-backend preview channel, relay binary metadata-free
  participant JPEG pixels through a local dashboard WebSocket, keep a maximum queue depth of one,
  and drop stale frames instead of building latency.
- Draw decoded frames on one stable dashboard canvas rather than remounting image elements.
- Preserve the final frame and fall back to the safe snapshot endpoint if streaming disconnects.
- Keep the preview JPEG presentation-only. `hybrid-visible-v1`, `ProviderRequest.frame_png`,
  decision-boundary evidence, and the snapshot/final-frame endpoint remain the existing lossless,
  hash-bound sanitized 1280×720 PNG contract.
- Interpolate only inside the participant-filtered Godot presentation, preferably with a
  one-authority-tick display delay. Browser routes receive pixels, never render transforms, and
  interpolation cannot affect checkpoints, replay, evaluation, score, or authority timing.
- Prove forward movement visually faces the travel direction and retain regression coverage for
  the previously observed backwards-walking error.
- Archive a successful native replay for every stage using the actual verifier, Movie Maker, and
  FFmpeg path when those binaries are available.

**Exit gate:** A–D each launch without a key, visibly complete through managed Godot, expose only
participant-visible data, seal a replay/evaluation, and pass API, privacy, dashboard, Godot, and
offline-verification tests. The viewport has no first-frame flicker or authority-boundary
teleporting. On the local reference run, decoded cadence stays within 28–32 FPS over a 10-second
sample, newest-frame queue depth never exceeds one, p95 frame age stays below 250 ms, JPEGs contain
no EXIF/comment/application metadata, and no blank frame replaces the canvas after its first decode.

### Phase S2 — Continuous multi-action solo showcase

Add a separately selectable `multi-action-demo-v0` **scenario** mapped to the existing
`construction-v0` authority contract. This preserves the `0.1.0` task/replay boundary; scenario,
policy, evaluation profile, and display label live in the evidence-bound Demo policy/run metadata.
It should be one continuous 900–1,200-authority-tick (90–120 authority seconds) participant-view
run rather than a montage or collection of unrelated snapshots. Intro/outro editing time does not
count toward that authority duration.

The operator must visibly:

1. idle, turn, and walk to a visible resource;
2. face it and gather a load;
3. carry the load to the visible relay;
4. face and deposit it;
5. move to the build pad;
6. build a barricade through visible progress;
7. finish with an authoritative success and celebration.

Dash, guard, primary, cancel, and hit reactions belong to the isolated action course in Phase S3;
do not broaden the existing Construction milestone contract merely to fit them into this showcase.

Use validated visible milestone names such as `gather_materials`, `deliver_materials`, and
`build_barricade`; never provide coordinates, target transforms, hidden completion flags, or direct
state mutations. Godot owns continuous walking, facing, interaction holds, animation, collision,
progress, completion, and safety timeouts. Reuse the proven long Construction path where sensible,
but give the showcase its own scenario identity, evaluation profile, saved replay label, and
dashboard option.

Request a new Demo-provider milestone only on task completion, task failure, deterministic timeout,
or episode end. Local executor ticks are not provider calls. An invalid task plan records neutral
progress and advances bounded authority time. The dashboard shows “thinking” only while awaiting a
new milestone, not while Godot is walking or interacting.

**Exit gate:** the same seed and scenario produce the same action/task sequence, receipts, events,
terminal hash, evaluation, and verified replay; provider-call counts equal milestone boundaries and
never executor ticks; invalid/timeout fixtures cannot stall; the full run is legible from
participant pixels without reading logs.

### Phase S3 — Solo control-validation games

Build small games before adding another participant. Their purpose is to prove that script intent,
controller JSON, authority motion, animation, collision, and visible results agree.

These new authoritative task IDs begin the separate `llm-controller/0.2.0` embodiment package and
multi-version registry. Leave the current `0.1.0` files and verifier unchanged.

#### `movement-maze-v0`

- One operator, no opponent, combat, economy, or social interaction.
- A compact visible maze/checkpoint course with straight segments, left/right turns, a reversal,
  narrow collision checks, and a final beacon.
- Evaluate deterministic completion, checkpoint order, ticks, collisions, facing corrections,
  invalid/no-input windows, and path efficiency without publishing hidden coordinates.
- Trusted evaluation derives the shortest legal route from the versioned map and publishes only
  aggregate travelled distance, ratio, and support status. It never publishes coordinates or the
  hidden route.

#### `operator-action-course-v0`

- A short single-agent course that isolates controller buttons and held actions at visible stations.
- Cover walk, turn, gather/interact, carry/deposit, build, dash, guard, primary, cancel, hit reaction,
  and terminal celebration where the mechanic is safe and meaningful.
- A deterministic visible hazard applies real authority damage for the hit-reaction station; never
  trigger the animation directly. The cancel station must interrupt a named held gather/build
  interaction and emit its expected receipt and public event.
- Keep each station independently assertable so a control-mapping regression identifies the exact
  failed action.

These are games with success/failure and evaluation, not authored animation reels.

**Exit gate:** a control matrix test proves each scripted command yields the intended Godot state,
transform direction, animation, receipt, and public event; both courses replay identically from
genesis and are launchable from the dashboard with Demo provider.

### Phase E1 — Per-run evaluation product

Promote existing authority-derived evaluation into a first-class product surface for solo, duo,
and later trio runs. Do not use an LLM judge.

Add safe, typed endpoints such as:

```text
GET /api/embodiment/episodes/{episode_id}/evaluation
GET /api/embodiment/series/{series_id}/evaluation
GET /api/embodiment/replays/{replay_id}/evaluation
```

Active runs return `409 evaluation_not_ready` until evidence is sealed; never publish partial or
fabricated metrics. Persist an allow-listed evaluation projection and hash beside each verified
saved replay so it survives backend restart. When durable series archival lands in Phase D1, add
the equivalent saved-series evaluation route and restart coverage.

The browser-safe projection may include only allow-listed aggregates and evidence references:

- evaluation schema/version, task/game, seed, controller/policy labels, and run status;
- success/failure/draw, terminal reason, completion tick, authoritative windows, and fallbacks;
- valid-action rate, controller changes, held actions, collision/alignment failures, damage, and
  task-specific progress;
- replay verification state, final opaque hash, evaluator support status, and an explicit reason
  when a metric is unavailable;
- for duo/trio, per-leg placement/outcome, seat-normalized aggregate, objective control, damage,
  invalid/no-input rate, and symmetry evidence.

Add an **Evaluation** page/tab that works for the current run and saved runs, links metrics to safe
receipts/events, and clearly separates result, behavioral metrics, and replay integrity. It must
never require the browser to download protected evidence.

**Exit gate:** every completed demo/game exposes a deterministic evaluation through API and UI;
privacy tests prove that observations, frames, prompts, raw output, credentials, hidden state, and
spectator data are absent.

### Phase D1 — Credential-free duo vertical slice

- Add two independently configured Demo-provider entrants to the production series API and
  dashboard. Do not weaken the existing restriction on the special `scripted` baseline; use the
  additive `demo` identity.
- Run both requests concurrently from the same pre-window state and submit one joint fixed 10-tick
  decision window.
- Reuse the existing managed two-participant authority, participant-local observations, paired
  two-leg scheduler, independent verifier, evaluation, and public/protected evidence split.
- Key camera selection by both leg and participant seat, and display the entrant-to-seat mapping
  for each leg because entrants swap seats. It may show either scoped participant camera, never a
  combined spectator view or the wrong entrant's pixels.
- Add a safe series timeline and durable archive containing both scoped views, seat mapping,
  allow-listed evaluation/hash, and a native replay for each leg. An optional combined presentation
  may be assembled only from verified participant-view footage.

**Exit gate:** two no-key demo entrants complete and independently verify both seat-swapped legs
through the same API/service path used by a future model-versus-model run. Response arrival order,
provider delay, and dictionary order do not alter hashes. The series is clearly labeled evaluated
Demo evidence and not a certified live-model score.

### Phase D2 — Simple duo game ladder

Add one mechanic at a time and verify it before layering the next:

1. `duo-checkpoint-race-v0` — mirrored movement lanes and finish beacons, no combat;
2. `duo-relay-control-v0` — contest a central objective without attacks;
3. `duo-spar-v0` — basic primary, guard, dash, cooldown, damage, and knockout;
4. `central-relay-v0` — the full existing relay-hold-or-knockout two-leg game;
5. optional `duo-resource-relay-v0` — gather, carry, deposit, build, or defend only after the
   preceding games are deterministic and side-neutral.

The new race/control/spar/resource game IDs extend only the separate `0.2.0` package. Every
evaluated game uses symmetric geometry or explicit paired seat swaps, participant-local
visibility, simultaneous windows, deterministic simultaneous-terminal rules, per-run evaluation,
and verified replay.

**Exit gate:** across at least 20 locked paired seeds per game, identical-policy self-play maps
exactly under the seat swap, the symmetry verifier reports no unexplained side advantage, and replay
verification has zero failures. Each game is usable from setup through evaluation and replay. A 1v1
run is “video ready” only when its participant-view acceptance checklist shows both entrants'
intended actions, correct facing/animation, no blank/flickering canvas, terminal result, evaluation,
and verified evidence sidecar.

### Phase D3 — Add duo complexity carefully

Only after the simple ladder is green, introduce richer resource contention, build/defend choices,
or mixed objectives. Each addition must have its own versioned rules, isolated tests, public metric
definitions, and a simpler game that remains available for regression diagnosis. Do not jump from
basic controls directly to the older RTS economy, diplomacy, or army system.

### Phase T1 — Three-agent design and protocol

Trio is the separate `llm-controller/0.3.0` protocol capability, not a small extension of
two-player tuples. The multi-version registry must continue routing `0.1.0` and `0.2.0` replays to
their immutable schemas and verifiers.

- Introduce exactly three participants, one joint decision boundary, per-participant fallback, and
  participant-indexed observations/receipts/frames/events.
- Freeze fixed 10-authority-tick evaluated trio windows and equal per-active-seat decision budgets.
- Specify placement, elimination, relay ownership, draws, simultaneous terminal events, timeout,
  and disconnect behavior before implementing authority.
- Represent results as typed per-participant outcomes plus ordered tie groups. Freeze the priority
  between simultaneous knockout, objective hold, and time-limit conditions; never infer placement
  from event arrival order.
- Stop provider calls for an eliminated seat, but record a deterministic eliminated disposition on
  every remaining common window. Preserve its last participant-visible frame for replay and never
  promote it to spectator vision.
- Use three cyclic seat/spawn rotations for evaluated comparisons and any later certified scoring.
- Design exact three-way spatial symmetry. Prefer an integer axial/hex representation or explicit
  three-member spawn/feature orbits; do not round floating-point 120-degree rotations into authority.
- Version schemas, locks, fixtures, replay format, evaluator, session transport, and source
  fingerprint together, while keeping older solo/duo replays verifiable.
- Reuse Sol, Luna, and Terra visual identities and cyclic ordering from the project, but not the
  incompatible action/evidence contracts of the older three-faction Arena.

**Exit gate:** Python and Godot accept/reject identical three-participant fixtures; invalid input
from any active seat advances one neutral common window; elimination/tie/terminal permutations,
exact symmetry, cyclic seat mapping, stopped-call accounting, and replay placement tests pass.

### Phase T2 — Scripted trio games

Start simple:

1. `trio-relay-v0` — three agents contest one symmetric objective without combat;
2. `trio-free-for-all-v0` — add primary, guard, dash, knockout, and deterministic last-standing or
   objective-hold resolution;
3. add resource/build mechanics only after the first two games and evaluations are stable.

Run Sol, Luna, and Terra as three separately versioned Demo-provider policies. The UI must allow an
active participant camera selection without exposing a spectator view. Evaluation should report
placement 1–3, draws/ties, objective control, pairwise encounters, reliability, cyclic-seat
normalization, and replay verification.

**Exit gate:** all three cyclic legs complete from setup to evaluation and replay without keys for
at least 20 locked seed cycles; participant isolation, arrival-order invariance,
simultaneous-terminal resolution, placement/tie rules, and deterministic replay pass with zero
verification failures. A free-for-all is video ready only when all three scoped participant views,
entrant/seat mappings, final placement, evaluation, and evidence sidecar pass the acceptance
checklist.

### Phase P1 — Product finish, media, and publication

- Make every implemented solo, duo, and trio demo/game selectable and understandable in the
  dashboard with Setup, Live, Timeline, Result, Evaluation, and Replay views.
- Run deterministic soak, privacy, replay, symmetry, API, and dashboard suites; keep live-provider
  smoke tests opt-in and out of the release gate.
- Produce three evidence-backed 1920×1080/30 FPS H.264/yuv420p `+faststart` videos using Godot Movie
  Maker and FFmpeg:
  1. solo multi-action capability showcase;
  2. scripted 1v1 game;
  3. Sol/Luna/Terra scripted free-for-all.
- Make final benchmark footage participant-view. If a separate spectator marketing cut is ever
  produced, label it clearly and keep it outside observations, public run APIs, and evaluation.
- Add separate versioned `--showcase solo|duo|trio` embodiment export/evidence scripts or wrappers;
  do not silently change the current MVP certifier/renderer, which expects Stage C plus two duel
  legs, and do not use the unrelated older Arena `render_highlight_replay.command`.
- Keep local exports and protected evidence out of git. The current Pages facade accepts YouTube
  IDs, so render export-ready files/posters first and publish only with user-authorized upload
  access. Never invent an ID, upload externally, or mutate repository variables without authority.
- Extend `dashboard/src/marketing/site-data.ts`, its tests, `.github/workflows/pages.yml`, and
  `dashboard/README.md` with `VITE_YOUTUBE_TRIO_ID` and the Pages repository variable
  `YOUTUBE_TRIO_ID`. Keep a local coming-soon poster until a real ID is configured.
- Replace the gallery's final solo card with the multi-action showcase, add the trio card, and
  deliberately choose the latest finished demo as the featured card instead of leaving an older
  MVP overview prominent.
- Update the README with the actual finished capabilities, Demo-provider instructions, evaluation
  method, replay/video commands, and linked poster/GIF previews for the latest solo, 1v1, and trio
  videos. Split the older semantic-only Arena description from the hybrid-pixel embodiment path,
  and keep the Pages base-path documentation aligned with the repository (`WorldEval`). Do not claim
  unfinished workflows or unverified live-model identities.

**Final gate:** a fresh checkout with documented Godot/FFmpeg prerequisites installed and no
credentials can run automated tests and complete the product flow for solo, duo, and trio using
Demo provider; every run has deterministic evaluation and verified replay. The README and Pages
site contain accurate poster/video configuration for all three demos without requiring the local
controller portal to be online. “Export ready” may be accepted without publication when external
upload credentials or approved video IDs are unavailable; never report it as published.

## Test strategy

### Mock-provider and contract tests

- strict valid JSON for controller actions and task plans;
- fixture-driven refusal, timeout, malformed, stale, duplicate-key, non-finite, and oversized output;
- injected clocks/adapters for deterministic timeout tests, never real sleeps in the Demo policy;
- same validation, fallback, audit, and evidence path as live adapters;
- no credential access and no hidden/spectator fields in requests;
- identical scenario seed and observation history produce identical raw output bytes.

### Godot and replay tests

- movement/facing/animation agreement for every controller input;
- 10 Hz deterministic authority with 30 FPS presentation-only interpolation;
- per-participant projection removal of stale hidden entities;
- identical events, receipts, checkpoints, terminal state, evaluation inputs, and replay hash;
- fixed 10-tick duo/trio evaluated windows and neutral fallback advancement;
- symmetry, cyclic seat rotation, simultaneous terminal, and soak coverage.

### API, privacy, and dashboard tests

- Demo provider never accepts or requests a key;
- presentation WebSockets contain only sanitized binary JPEG pixels; canonical provider/evidence and
  snapshot paths retain sanitized hash-bound PNGs;
- newest-frame-only backpressure, stable canvas, final-frame retention, and snapshot fallback;
- safe evaluation projections reject extra/protected fields;
- Setup, Live, Timeline, Result, Evaluation, Replay, saved-run, and responsive states;
- Pages builds with missing video IDs and shows local coming-soon posters until publication.

### Release validation

- focused tests after each slice;
- full `tests/embodiment` and existing `tests/duel` before integration;
- dashboard lint, Vitest, typecheck, production build, and Pages build;
- Godot project parse plus relevant headless runners;
- credential/secret scan and clean-worktree check before publishing.

The release soak runs at least 1,000 mixed scripted episode/leg executions, including every solo
task/game, paired duo game, and trio cyclic game. Acceptance requires zero checkpoint/replay drift,
zero verification failures, no unreaped owned processes, and no monotonic resource growth beyond
the documented bounded caches.

No release gate depends on an external model API. If Godot, FFmpeg, or a browser is unavailable in a
cloud environment, keep their commands and fixtures correct, run all available automated coverage,
and report the missing executable plainly; never replace verification with an invented success.
Such a phase may be reported “code complete; native verification pending,” but is not fully accepted
until the required binaries have run successfully.

## Delegation and integration

Subagents may implement **and integrate** bounded slices, including shared protocol, API, service,
dashboard, replay, and test wiring. Integration is not reserved to the root agent.

For safe parallel work:

- assign one explicit owner to each shared file or namespace for the duration of a wave;
- tell other agents before changing a shared manifest, schema lock, dependency file, route table, or
  dashboard root;
- allow an integration agent to merge adjacent slices and resolve conflicts when ownership is clear;
- preserve unrelated user work and never reset or overwrite another agent's changes;
- require one final owner to inspect the combined diff and run cross-language/full-suite validation.

Suggested waves:

| Wave | Parallel implementation | Integration gate |
| --- | --- | --- |
| M0 | DemoProvider/lock; capabilities/budgets; strict failure fixtures | credential-free provider path |
| S1 | A–D production-path tests; 30 FPS presentation; dashboard/replay reliability | all solo tasks no-key end to end |
| S2 | multi-action scenario/evidence; task-boundary call tests | continuous showcase gate |
| S3 | maze authority/presentation; action-course stations; control matrix | solo control-game gate |
| E1 | evaluation projection/archive; API; dashboard view | durable per-run evaluation |
| D1 | two-demo series; duel pixels/timeline/archive/replay | credential-free paired duel |
| D2 | simple duo games; evaluation profiles; symmetry suites | scripted 1v1 showcase |
| T1 | protocol/schema; trio authority; three-policy scheduler | three-seat conformance/symmetry |
| T2 | trio UI/evaluation/replay; free-for-all presentation | scripted trio showcase |
| P1 | soak/privacy; native exports; README; Pages gallery | release review |

## Explicitly deferred

- live provider calls, API-key smoke tests, provider billing, and official model comparison claims;
- mapping Sol, Luna, and Terra to provider model IDs;
- unrestricted model-generated multi-task programs before the bounded demo/game contracts are proven;
- complex trio economy, diplomacy, teams, or the older RTS army system;
- official leaderboard or large benchmark season publication.
