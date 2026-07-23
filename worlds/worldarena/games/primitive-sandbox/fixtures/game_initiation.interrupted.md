# Game initiation (generated, non-authoritative)

> This document is generated from `environment-init.v1.json`. The JSON contract is authoritative.

- Protocol: `worldeval-agent/0.1.0`
- Environment: `worldarena-primitive-sandbox-v0`
- Session: `demo-interrupted-v0`
- Initialization hash: `sha256:43e7be1cf81ad9c23ee3c91e116df5f37f2bd69804c8030d1829dfec81add6ea`
- Role: You control worker-1 and make every navigation, equipment, and interaction decision.
- Objective: Destroy tree-7 only while uncontested; if a hostile enters the tree safety radius, leave the tree intact and return to base-1.
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
