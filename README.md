# Genesis Arena

Genesis Arena is a 3D embodied-AI survival benchmark. A model chooses constrained,
high-level actions; a Godot simulation turns those choices into movement, resource
use, construction, and survival consequences.

This repository contains the first vertical slice: one autonomous agent must survive
20 days, gather food and materials, and build a shelter. The observer can see the
agent's current observation, decision intent, action, resources, and resulting world
change in real time.

## What works now

- A procedural Godot 4 island with an isometric strategy camera.
- A physical agent that walks to resources, gathers them, and constructs buildings.
- A FastAPI WebSocket controller with strict observation and action validation.
- A deterministic demo brain for a reliable, credential-free five-minute demo.
- An optional GPT-5.6 Sol brain using Responses API function tools.
- Compact persistent memory and benchmark scoring scaffolding.
- A headless 20-turn simulation and Python test suite.

## Run the prototype

Prerequisites: Python 3.9+ and [Godot 4](https://godotengine.org/download/macos/).

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'
cp .env.example .env
genesis-arena
```

Then open `godot/project.godot` in Godot 4 and press **Run Project**. The simulator
connects to `ws://127.0.0.1:8000/ws/world` automatically. Press **Start benchmark**
in the top-right of the simulation.

For live model decisions:

```bash
export OPENAI_API_KEY='your-key'
export GENESIS_BRAIN_MODE=openai
genesis-arena
```

The default remains `demo`, so launching the project never spends API credits by
surprise. `auto` uses OpenAI only when an API key is present.

## Validate without Godot

```bash
pytest
python scripts/simulate.py --days 20
```

The headless simulation exercises the same observation, brain, validation, memory,
and scoring contracts as the Godot client.

## Repository map

```text
agents/                  Agent identities and reasoning policies
backend/genesis_arena/   Brain providers, controller, API, memory, evaluation
docs/                    Architecture and wire-protocol decisions
game/                    LLM-visible action contract
godot/                   Godot 4 world and presentation layer
memory/                  Compact persisted memories
scripts/                 Headless demo utilities
tests/                   Contract and behavior tests
evaluation.py            Standalone evaluation entry point
```

See [docs/architecture.md](docs/architecture.md) for component boundaries and the
path from this milestone to three competitors.

