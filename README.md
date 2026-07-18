# WorldArena

> Evaluate what an LLM does, not only what it says.

WorldArena is a deterministic 3D research benchmark for **LLM agents**. Three independently
configured models receive partial observations, submit high-level plans simultaneously, and live
with the economic, physical, and social consequences inside an authoritative Godot simulation.

The LLM is the strategist; it never controls coordinates, physics, damage, resources, or scoring.
Godot resolves the world, while FastAPI validates plans, enforces budgets, and records evidence.

**Status:** working research prototype. The local demo, live model loop, deterministic simulation,
evaluator, replay artifacts, and season scheduler are implemented. No official model leaderboard or
completed 99-match benchmark season is published yet.

**Rendered showcase:** The local demo recording is a pre-rendered showcase generated through the
full simulation compute path. The recording stays local for upload, while its deterministic replay
source and one-click renderer are published here as the fast presentation path.

> [!NOTE]
> This repository is independent of the 2026 paper
> [*WorldArena: A Unified Benchmark for Evaluating Perception and Functional Utility of Embodied
> World Models*](https://arxiv.org/abs/2602.08971). That work evaluates embodied world models;
> this project evaluates the behaviour of competing LLM agents.

## Why this benchmark exists

Static question-answer evaluations can measure knowledge and reasoning in a single response. They
cannot show whether a model can maintain a plan, recover after failure, manage scarce resources,
coordinate with unfamiliar agents, detect deception, or turn language into useful action over time.

WorldArena tests those capabilities together in one controlled environment. A model must act under
partial observability and fixed budgets while two other models change the world at the same time.
Every claim can be checked against typed actions and simulator events rather than an LLM judge.

This makes the benchmark useful for studying:

| Capability | Observable evidence |
|---|---|
| Long-horizon planning | Objective completion, multi-round coherence, preparation, and recovery |
| Resource and combat decisions | Productive spending, waste, supply uptime, losses, and retreats |
| Social intelligence | Executed trades, honoured pacts, calibrated trust, coordination, and betrayal outcomes |
| Delegation | Specialist use, accepted advice, contradictions, token cost, and progress per budget |
| Reliability | Valid actions, timeouts, fallbacks, impossible orders, and protocol compliance |

WorldArena evaluates **strategic agent behaviour**, not visual perception or robot safety. Models
currently receive structured semantic observations rather than pixels; “embodied” means their
decisions are grounded in a persistent simulated world with irreversible consequences.

## How a match works

1. Godot freezes a world state and gives each faction a private, visibility-filtered observation.
2. Eligible specialist advisors run, then all three Commanders plan concurrently.
3. Plans are canonicalized and sealed with commit hashes before any plan is revealed.
4. Godot verifies and resolves all accepted actions through the same fixed-tick round.
5. Events, receipts, usage, state hashes, and evidence are written for scoring and replay.

This commit/lock/reveal protocol prevents provider latency from granting initiative. Rendering,
camera movement, and playback speed cannot change a result.

The arena contains 13 districts, finite resources, wildlife, construction, supply lines, territory
capture, combat, public/private messages, atomic trades, non-binding pacts, and visible pact
violations. A match ends by Core elimination or after 40 rounds plus deterministic tie-break rules.

## Evaluation methodology

The competitive result is the Godot-derived placement. A separate, versioned **WorldArena Score**
explains behaviour and never changes the winner:

| Category | Weight |
|---|---:|
| Objective control | 35% |
| Planning and adaptation | 20% |
| Resource and combat efficiency | 15% |
| Social intelligence | 15% |
| Delegation and cognition | 10% |
| Reliability and safety | 5% |

Scores fail closed when required evidence is missing. Each category retains its measurements and
supporting action/event IDs; best decisions and largest failures are selected by deterministic
three-round outcome deltas. **No LLM judge is used.**

Results from different cognition tracks are kept separate:

| Track | Model access | Use |
|---|---|---|
| Standard | One Commander call per faction per round | Direct model comparison |
| Agentic | Commander plus bounded same-model specialists under one shared budget | Delegation and context management |
| Open Teams | Configurable or mixed-model teams | Experiments only; no shared leaderboard |

The included season scheduler freezes the model snapshot, prompt, rules, map, tools, budgets, and
deadlines. It creates 33 deterministic seeds with all three seat rotations: **99 scored matches plus
one unscored championship showcase**. Aggregation reports per-seed results, pairwise outcomes,
placement, category scores, and 95% win-rate confidence intervals. Batch execution of the schedule
is not yet included.

## Research foundations and differences

WorldArena combines lessons from prior work rather than treating any one final score as sufficient:

| Research | Lesson adopted here | WorldArena's focus |
|---|---|---|
| [ALEM](https://arxiv.org/abs/2606.08340) | Separate coordination from base task skill | Mixed cooperation and competition between independently scored Commanders |
| [Melting Pot 2.0](https://arxiv.org/abs/2211.13746) | Test generalization to unfamiliar social partners | Natural-language negotiation whose value is tied to later physical outcomes |
| [Neural MMO](https://arxiv.org/abs/2308.15802) | Vary opponents and test robustness | Seat-balanced schedules and per-opponent aggregates |
| [BALROG](https://arxiv.org/abs/2411.13543) | Keep fine-grained agentic metrics beyond success | Evidence-linked planning, economy, social, cognition, and reliability measures |
| [Cattle Trade](https://arxiv.org/abs/2605.14537) | Preserve behavioural traces beyond wins | Negotiation coupled to territory, logistics, construction, and combat |

The distinctive question is not simply “can the model win a game?” It is: **can an LLM deploy
planning, adaptation, negotiation, delegation, and resource discipline together—and can every
consequence be reproduced and audited?**

## Run locally

Requirements:

- Python 3.9+
- Godot 4.5 stable or a compatible Godot 4 build
- macOS for the included double-click launcher; the Python backend and Godot project are portable

From the repository root:

```bash
./run_worldarena.command
```

Leave the API-key field blank for the deterministic, no-cost demo policy. For live runs, enter an
API key in the setup screen and configure each Commander independently. The key remains in process
memory and is not written to source, logs, replays, or `.env`.

To start the processes manually:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e ".[dev]"
genesis-arena
```

Then, in another terminal:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path godot
```

The Arena uses `ws://127.0.0.1:8000/ws/arena`. The preserved survival prototype uses `/ws/world`.

## Export the 90-second demo

Double-click `render_highlight_replay.command` in Finder. It renders the deterministic showcase,
directs the camera toward exploration, negotiation, and battle moments, then writes an
upload-ready 1920×1080 H.264 MP4 to `exports/`. The first export may download a project-local
encoder into the ignored `.video-tools/` folder; it never uploads footage or reads API keys.

See [`docs/HIGHLIGHT_EXPORT.md`](docs/HIGHLIGHT_EXPORT.md) for the command-line options.

## Verify

Run the Python contract, concurrency, privacy, scoring, and scheduling tests:

```bash
.venv/bin/pytest -q
```

Run the deterministic simulation and the credential-free controller loop:

```bash
/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path godot \
  --script res://scripts/arena/simulation/arena_headless_runner.gd

/Applications/Godot.app/Contents/MacOS/Godot \
  --headless --path godot \
  --quit-after 8000 -- \
  --arena-offline-demo --arena-test-rounds=4 --arena-quit-after-test
```

Generate a frozen season schedule after replacing the example model IDs and hashes with resolved
production metadata:

```bash
genesis-season-schedule docs/season-spec.example.json runs/season-schedule.json
```

## Architecture

```text
LLM Commanders / deterministic demo policy
                 ↓
FastAPI: isolation · validation · budgets · commit/reveal · artifacts
                 ↓  world-arena/0.2
Godot controller: private observations · verification · receipts
                 ↓
Deterministic simulation: economy · movement · combat · diplomacy · score
                 ↓
Presentation-only 3D world · HUD · replay · evidence podium
```

Only the deterministic simulation changes world state. Python may reject malformed output but
cannot award territory, resources, damage, or victory.

## Repository guide

| Path | Purpose |
|---|---|
| [`backend/genesis_arena/arena/`](backend/genesis_arena/arena/) | Protocol, runtime, artifacts, evaluator, and season scheduler |
| [`godot/scripts/arena/`](godot/scripts/arena/) | Authoritative simulation, controller, and presentation |
| [`godot/data/arena/`](godot/data/arena/) | Versioned map and benchmark contract |
| [`game/arena_actions.json`](game/arena_actions.json) | Typed action and cognition contract |
| [`tests/`](tests/) | Unit, adversarial, privacy, concurrency, protocol, and scoring tests |
| [`docs/architecture.md`](docs/architecture.md) | Authority boundaries and round protocol |
| [`feature.md`](feature.md) | Full product, rules, evaluation, and implementation specification |

WorldArena is a controlled test of foundational agent behaviour. Strong performance does not show
that a model is safe to control a real robot or operate without human oversight.
