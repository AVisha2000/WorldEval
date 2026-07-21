# LLM Controller × WorldArena live solo

Phase 4 connects the managed Godot authority to OpenAI, Anthropic, and Gemini through one
participant-scoped provider contract and exposes the workflow through the local FastAPI service and
React/Vite dashboard.

When OpenAI is selected, the dashboard offers the controller-compatible GPT-5.6 family: Sol,
Terra, and Luna. OpenAI Responses requests use explicit `low` reasoning effort for the demo; the
same value is sealed into the paired-duel fairness lock. The API key remains an episode/session
credential and is never used to discover models in the browser.

## Run locally

From the repository root:

```bash
.venv/bin/uvicorn genesis_arena.main:app --host 127.0.0.1 --port 8000
cd dashboard
pnpm dev
```

Open the Vite URL, select a provider/model/task, enter a provider key, and start an episode. The
browser keeps the key only in React component state. The backend moves it immediately into an
in-memory `SessionCredential`, never returns it, and erases it when the episode ends or the service
closes. Keys and HTTP headers are excluded from logs, Godot bootstrap data, timelines, replays, and
both evidence layers.

Each live decision uses the same immutable request shape: player-visible text, that participant's
bound 1280×720 PNG, its episode-only scratchpad, the strict controller-action schema, one absolute
deadline, and one output-byte ceiling. Provider adapters do not retry or semantically repair
responses. Timeout, refusal, malformed JSON, schema failure, and oversized output become a recorded
`no_input` decision, so authority time still advances.

## Evidence and replay

The public replay endpoint returns credential-free configuration, dispositions, receipts, public
events, checkpoints, terminal result, and evaluation. Protected bundles additionally contain
participant observations, frames, prompts, raw output, scratchpad, parsing evidence, and telemetry;
they are available only through trusted local certification code, not the HTTP router. Offline
verification begins from genesis and checks every canonical checkpoint and the terminal hash.

## Dashboard fidelity

The implementation follows the approved concept at
`docs/assets/worldarena-controller-dashboard-concept.png`: the three-column setup/live/timeline
structure, typography, restrained neutral palette, open rails, selected timeline state, and replay
controls are retained. The protected-bundle control is intentionally disabled because that evidence
must not cross the public API boundary. The live viewport requests
`GET /api/embodiment/episodes/{episode_id}/frame` while a solo episode is active. The route returns
only the newest active-participant PNG with `Cache-Control: no-store`; it never returns observation
JSON, prompts, model output, credentials, or spectator state. Before publication, the backend
decodes and rebuilds the Godot RGBA scanlines so PNG metadata and trailing payloads cannot cross the
browser boundary. The viewport shows explicit loading, live observation, unavailable, and finished
states and retains the final participant-visible frame after the episode seals.

The same dashboard can launch a symmetric two-leg scored series. Its default opponent is the
credential-free `scripted` entrant with model tier `balanced-v1`; that policy consumes only the
participant-visible observation contract and is fairness-locked with the Godot reference policy.
Keys are requested only for live entrants. Every series has a backend-enforced live-provider-call
ceiling shared across both legs and whole-pair reruns (360 calls for the default mixed series, 720
for two live models), and queued/running work exposes a Cancel run control. Paired camera streams
remain isolated by participant and are not returned through the public series API.

## Validation boundary

Provider behavior is covered with injected mocked transports, including privacy, deadline,
rate-limit, refusal, malformed, non-finite, and byte-limit failures. The managed hybrid integration
test exercises real Godot frame capture and replay without network access. Real provider smoke calls
are opt-in because they require researcher credentials and may incur provider charges; they are not
part of the default test suite.
