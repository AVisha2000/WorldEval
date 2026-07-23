# WorldEval Conversation Protocol 0.1.0

`worldeval-conversation/0.1.0` is an additive, environment-neutral protocol for
turning a human chat instruction into a bounded, inspectable embodied task. It
does not carry controller code, world mutations, hidden state, provider output,
or gameplay authority. Godot (or another declared environment authority) still
validates and executes visible action plans using its own action protocol.

The protocol deliberately separates four facts that are commonly conflated:

1. `chat-command.v1` records exactly what a human asked in a player-visible
   conversation context.
2. `grounding-hypotheses.v1` records visible candidate entities. A command is
   ambiguous until a `referent-binding.v1` records a current, stable entity and
   generation.
3. `grounded-task.v1` compiles the instruction into an immutable task contract
   with explicit constraints. Its `task_hash` is canonical and must match the
   task body.
4. `task-revision.v1`, `task-revocation.v1`, and `task-status.v1` preserve
   corrections, invalidation, and authority-derived progress.

All entity evidence is tied to an observation sequence, tick, state hash, and a
visible entity ID. Bindings expire at a stated observation boundary and never
silently rebind when an entity is recreated. Ambiguity must result in status
`clarification_required`; it cannot authorize movement or manipulation.

`execution.mode` is fixed to `agent_visible_action_plan_only` and
`execution.gameplay_authority` is fixed to `environment_authority`. The task
lists only action identifiers declared by the environment; the game is never
asked to evaluate arbitrary code or infer a strategic route.
