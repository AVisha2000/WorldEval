# LLM Controller × WorldArena MVP certification

The offline certification entry point is:

```bash
.venv/bin/python worlds/worldarena/scripts/run_embodiment_mvp_certification.py \
  --report exports/embodiment-certification.json
```

It runs the Python protocol, authority, transport, provider, privacy, replay, fairness, API, and
1v1 tests; every Godot embodiment runner; the 1,000-episode/ten-paired-seed batch; the frozen Duel
regression suite; and the dashboard lint, unit, and build checks. The report separates passing
offline evidence from external MVP gates instead of silently claiming certification.

Long runs can be recorded in bounded, source-fingerprinted chunks. Use `--only STEP` for a chunk
and `--resume` for subsequent invocations against the same `--report`; a final invocation without
`--only` verifies that every expected result is present. Passing evidence is reused only when the
command, working directory, and stable source fingerprint still match.

The native replay demo path uses only Godot Movie Maker and FFmpeg:

```bash
.venv/bin/python worlds/worldarena/scripts/render_embodiment_mvp_demo.py \
  --output exports/worldarena-embodiment-mvp.mp4
```

The renderer generates and verifies a Stage-C replay plus both legs of a symmetric duel, replays
them from genesis in the Movie Maker process, and encodes 1920×1080/30 FPS H.264/yuv420p with AAC
and `+faststart`. It refuses final export until the manually reviewed Mixamo Y Bot manifest,
required clip hashes, AnimationTree mapping, and active non-placeholder scene integration all
validate. A final render persists the three verified replays and a content-addressed evidence
sidecar beside the MP4. For pipeline QA only, `--allow-placeholder` emits an explicitly non-final
preview using the current procedural Operator. No provider credential is read by either render
process.

External gates remain explicit:

- The immutable authority package continues to report its prototype capabilities until every
  external gate passes. Promotion writes a package-bound release overlay under
  `worlds/worldarena/game/embodiment_release/`; it never rewrites or re-locks the authority protocol package.
- OpenAI, Anthropic, and Gemini each require a successful managed hybrid-solo episode, with
  session-only credentials and verified replay evidence.
- A separate live two-model gate requires one complete symmetric two-leg scored duel. Both
  entrants must be live providers, every decision boundary must be audited, and the public and
  protected pair bundles plus both authority replays must verify independently.
- Browser evidence requires desktop/mobile visual checks plus observed hybrid-solo and symmetric
  two-leg lifecycle launches. Layout-only QA is useful but does not satisfy this gate.
- Final native media requires the user-supplied, manually approved Mixamo Y Bot and all required
  animation clips. A placeholder preview can never satisfy the final-video gate.

Scored duel launches are spend-bounded before provider dispatch. The public series request carries
`max_live_provider_calls`; the backend shares that budget across both legs and every whole-pair
rerun, reserves calls atomically, and stops before the cap can be exceeded. The dashboard uses a
360-call ceiling for OpenAI versus the credential-free `scripted`/`balanced-v1` baseline and a
720-call ceiling for model-versus-model. Exhaustion invalidates the scored series instead of
silently continuing. Operators can also cancel a queued or running episode/series from the Run
view; cancellation closes session credentials and does not create certifying evidence.

Remotion is outside this certification and must not be used for embodiment video.

## Certification pilot workflow

Run the provider preflight without making a network request:

```bash
.venv/bin/python worlds/worldarena/scripts/run_embodiment_live_provider_pilot.py --preflight \
  --openai-model "$WORLDARENA_OPENAI_MODEL" \
  --anthropic-model "$WORLDARENA_ANTHROPIC_MODEL" \
  --gemini-model "$WORLDARENA_GEMINI_MODEL"
```

Credentials must be supplied only in process environment variables named by the preflight. The
managed Godot launcher uses a minimal child environment that excludes them. Once all three keys
and reviewed model IDs are present, remove `--preflight` to run one managed hybrid-solo episode per
provider. Successful runs write independently verified raw authority replays and
`exports/embodiment-pilot/live-provider-report.json`; failures never produce a certifying report.

For a bounded OpenAI-only pilot, select that provider explicitly. This can produce useful
non-certifying evidence without requesting Anthropic or Gemini credentials and without weakening
the final validator:

```bash
.venv/bin/python worlds/worldarena/scripts/run_embodiment_live_provider_pilot.py --preflight \
  --provider openai --openai-model "$WORLDARENA_OPENAI_MODEL"
```

After preflight, provide `WORLDARENA_OPENAI_API_KEY` only in the launching process environment and
run the same command without `--preflight`, using an OpenAI-only output directory. Never write the
key to `.env`, `.env.local`, dashboard storage, replay artifacts, or command arguments. The final
release gate still requires a fresh combined report covering OpenAI, Anthropic, and Gemini.

Run the paired-duel preflight separately. An OpenAI-versus-OpenAI pair may explicitly reuse one
session key; provider keys and model IDs are read from the launching process environment only:

```bash
.venv/bin/python worlds/worldarena/scripts/run_embodiment_live_duel_pilot.py --preflight \
  --provider-a openai --provider-b openai --reuse-entrant-a-key \
  --model-a "$WORLDARENA_DUEL_A_MODEL" --model-b "$WORLDARENA_DUEL_B_MODEL"
```

For the live run, replace `--preflight` with `--execute-live`, add
`--confirm-max-live-provider-calls 720`, and supply `WORLDARENA_DUEL_A_API_KEY` only in that
process environment. Without key reuse, also supply `WORLDARENA_DUEL_B_API_KEY`. The 720-call cap
allows exactly two 180-window legs with two participants and no rerun budget; any invalid pair or
verification failure publishes no certifying output.

The optional OpenAI family round robin runs all three unordered matchups (Sol–Terra, Sol–Luna,
and Terra–Luna). Each matchup is still a symmetric two-leg series, so the tournament contains six
legs. Preflight is network-free:

```bash
.venv/bin/python worlds/worldarena/scripts/run_embodiment_openai_round_robin.py --preflight \
  --sol-model "$WORLDARENA_OPENAI_SOL_MODEL" \
  --terra-model "$WORLDARENA_OPENAI_TERRA_MODEL" \
  --luna-model "$WORLDARENA_OPENAI_LUNA_MODEL"
```

Live execution requires `--execute-live` and an exact
`--confirm-aggregate-max-live-provider-calls 2160` acknowledgement before the first child series
can start. Supply `WORLDARENA_OPENAI_API_KEY` only in launching-process memory. The orchestrator
publishes nothing unless all three independently verified pair directories pass validation, and
OpenAI reasoning effort remains fixed to `low` in every pair's fairness lock.

Mixamo intake remains manual. Place the reviewed base and ten animation-only FBX files under
`worlds/worldarena/godot/assets/external/mixamo/`, build and integrate the final Y Bot Godot scene, then run:

```bash
.venv/bin/python worlds/worldarena/scripts/intake_mixamo_y_bot.py \
  --base worlds/worldarena/godot/assets/external/mixamo/y-bot.fbx \
  --clip idle=worlds/worldarena/godot/assets/external/mixamo/idle.fbx \
  --clip walk=worlds/worldarena/godot/assets/external/mixamo/walk.fbx \
  --clip run=worlds/worldarena/godot/assets/external/mixamo/run.fbx \
  --clip attack=worlds/worldarena/godot/assets/external/mixamo/attack.fbx \
  --clip guard=worlds/worldarena/godot/assets/external/mixamo/guard.fbx \
  --clip gather=worlds/worldarena/godot/assets/external/mixamo/gather.fbx \
  --clip build=worlds/worldarena/godot/assets/external/mixamo/build.fbx \
  --clip hit=worlds/worldarena/godot/assets/external/mixamo/hit.fbx \
  --clip celebrate=worlds/worldarena/godot/assets/external/mixamo/celebrate.fbx \
  --clip defeat=worlds/worldarena/godot/assets/external/mixamo/defeat.fbx \
  --presentation-scene worlds/worldarena/godot/scenes/embodiment/y_bot_operator.tscn \
  --reviewer REVIEWER_ID --downloaded-at UTC_TIMESTAMP --reviewed-at UTC_TIMESTAMP \
  --source-url 'https://www.mixamo.com/REVIEWED_PAGE' \
  --license-terms 'REVIEWED ACCOUNT-SPECIFIC TERMS'
```

The intake command hashes existing repository files, refuses overwrite, and deletes a newly built
manifest if the full integration validator rejects it. It never downloads or copies Adobe content.

For browser evidence, build the dashboard, run the local FastAPI application, and use the in-app
browser to observe a complete hybrid-solo launch and symmetric two-leg launch at desktop and mobile
sizes. After reviewing the console, overlays, page identity, interaction, blank-state, and credential
leak checks, create the canonical report with explicit confirmations:

```bash
.venv/bin/python worlds/worldarena/scripts/build_embodiment_browser_qa_report.py \
  --desktop PATH_TO_DESKTOP_PNG --mobile PATH_TO_MOBILE_PNG \
  --confirm-hybrid-solo --confirm-symmetric-duel \
  --confirm-console-health --confirm-credential-leak-scan \
  --confirm-framework-overlay-absent --confirm-interaction-proof \
  --confirm-not-blank --confirm-page-identity
```

Finally render the non-placeholder video, collect a current passing offline report, and run the
promotion command first without `--apply`. It verifies every supplied artifact and reports all
missing gates without changing the protocol. Add `--apply` only after review:

```bash
.venv/bin/python worlds/worldarena/scripts/promote_embodiment_mvp_release.py \
  --offline-report exports/embodiment-certification.json \
  --browser-qa-report exports/embodiment-pilot/browser-qa-report.json \
  --live-provider-report exports/embodiment-pilot/live-provider-report.json \
  --live-duel-report artifacts/live-duel-pilot/live-duel-report.json \
  --final-video exports/worldarena-embodiment-mvp.mp4 \
  --status-report exports/embodiment-pilot/readiness.json
```

Promotion atomically creates the canonical release overlay bound to the exact authority package
hash. Because that changes the complete release source fingerprint, run the full certification
command once more after promotion and pass all four external evidence arguments plus `--final-seal`
and `--readiness-report exports/embodiment-pilot/readiness.json`. A passing final seal atomically
refreshes that dashboard status file from the final source-matched report. The readiness report contains only
validated gate codes, hashes, and capability status; it never includes credentials or model output.

```bash
.venv/bin/python worlds/worldarena/scripts/run_embodiment_mvp_certification.py --final-seal \
  --report exports/embodiment-certification.json \
  --readiness-report exports/embodiment-pilot/readiness.json \
  --browser-qa-report exports/embodiment-pilot/browser-qa-report.json \
  --live-provider-report exports/embodiment-pilot/live-provider-report.json \
  --live-duel-report artifacts/live-duel-pilot/live-duel-report.json \
  --final-video exports/worldarena-embodiment-mvp.mp4
```

The local API exposes an allow-listed projection at
`GET /api/embodiment/certification/readiness`. The dashboard polls this no-store endpoint every ten
seconds and shows the six promotion gates independently of episode state. Missing, malformed,
duplicate-key, oversized, or stale readiness artifacts render fail-closed; the endpoint never returns
provider payloads, evidence paths, report hashes, credentials, or protected replay data.
