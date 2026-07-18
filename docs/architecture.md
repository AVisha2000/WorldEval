# Genesis Arena architecture

## The boundary that matters

The language model is a planner, never a world editor. It receives a compact semantic
observation and chooses exactly one tool. Python checks that choice against the public
action catalog and the current observed state. Godot alone resolves targets, paths,
animation, costs, collisions, depletion, time, damage, and success or failure.

```text
OpenAI Responses API          Deterministic demo brain
          \                         /
           \                       /
            Agent brain interface
                     |
        policy + state validation
                     |
          FastAPI WebSocket server
                     |
       observation / action_command
                     |
                Godot 4 world
       movement, resources, construction,
          time, events, and consequences
```

An action command says `collect(resource="wood")`; it never says "teleport to
(18, 0, -42)". The engine finds a reachable visible source, moves the body, performs
the interaction, and reports the result on the following turn.

## Runtime turn

1. Godot emits an `observation` only when the previous physical action has completed.
2. Python validates and normalises the observation.
3. The configured brain chooses one function tool.
4. Python validates parameters, inventory costs, and target availability.
5. Godot receives an `action_command` and displays its intent.
6. Godot executes the action over simulation time and changes the world.
7. Important result events are compacted into persistent memory.
8. The next observation begins the next turn.

There is deliberately no model-driven sub-action loop in Godot. This keeps the
benchmark honest: planning latency is separated from embodied execution time, and a
model cannot bypass the rules with coordinates or invented state.

## Providers

`Brain` is a small async interface. `DemoBrain` is deterministic and exists for demo
reliability and regression tests. `OpenAIBrain` exposes only enabled actions as strict
Responses API function tools and requests exactly one call. The initial live default
is `gpt-5.6-sol` at low reasoning effort; this is configuration, not a dependency of
the simulation protocol.

The prompt is intentionally lean: identity, objective, hard boundaries, priorities,
and the latest observation. Memory is a short list of strategic facts rather than a
transcript.

## World authority and duplicated checks

Python performs optimistic policy validation so malformed or impossible actions do
not reach the renderer. Godot repeats resource and cost checks at execution time. The
duplication is intentional: state may change between decision and arrival, and the
world remains authoritative.

## Scope of milestone one

Implemented actions are `collect`, `build`, `inspect`, and `rest`. The action catalog
also reserves `craft`, `send_message`, `attack`, and `defend`, but they remain disabled
until the three-agent phase. All five requested building types have costs and a simple
visual representation; shelter is the survival-critical structure used by the first
agent policy.

The designed world size is 500 × 500 metres. The playable island occupies the central
area so decisions remain readable from the strategy camera and a full run completes
quickly.

## Three-agent expansion

Each arena entrant will own an independent body, memory file, prompt, inventory, and
brain session. The server will schedule observations concurrently but commit actions
through the single authoritative world clock. Communication becomes a delayed,
observable action; alliances are state inferred from offers and behavior, not a forced
team flag.

Sol, Terra, and Luna are independent competitors. Sol's `delegate_task` concept is
therefore represented as a task proposal sent through communication; the recipient
may accept, refuse, exploit, or betray it. This resolves the apparent tension between
the commander archetype and the requirement that only one agent can win.

Future phases add:

- per-agent fog of war and asymmetric observations;
- trade proposals and temporary treaties;
- storms, winter, and rare crystal events;
- simple strength-based combat with retreat and terrain bonuses;
- action traces and replay files for reproducible evaluation;
- comparative Sol/Terra/Luna model routing by workload and cost.

## Evaluation

The score is a weighted 0–100 composite: survival 30%, resource efficiency 20%,
strategic planning 20%, adaptation 15%, and social intelligence 15%. Milestone one
records the first four; social intelligence is neutral until communication exists.
Raw metrics remain available alongside the composite so leaderboard scores are
auditable.

