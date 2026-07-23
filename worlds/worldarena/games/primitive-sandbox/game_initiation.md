# Game initiation (generated, non-authoritative)

> This document is generated from `environment-init.v1.json`. The JSON contract is authoritative.

- Protocol: `worldeval-agent/0.1.0`
- Environment: `worldarena-primitive-sandbox-v0`
- Session: `demo-nominal-v0`
- Initialization hash: `sha256:5930269147bee3f47393676128d3405837af8002108e664048aa159378497678`
- Role: You control worker-1 and make every navigation, equipment, and interaction decision.
- Objective: Destroy tree-7 at (23,12) before the tick limit.
- Tick budget: 200
- Coordinate frames: world_grid
- Available actions: move_to, equip, use_tool, wait, cancel
- Decision profile: `dynamic-step-locked-v1`

## Rules

- Coordinates use the world_grid frame with x east and y north.
- move_to follows only the direct line to the exact target or waypoint you choose.
- The authority resolves physics and collisions but never chooses a detour or replacement target.
- Every decision boundary requires an explicit continue, replace, abort, or wait response.
- Missing, invalid, timed-out, or stale responses are neutral no-ops.
