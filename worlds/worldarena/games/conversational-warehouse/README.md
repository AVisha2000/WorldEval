# Conversational Warehouse

`worldarena-conversational-warehouse-v0` is a deterministic, player-visible
warehouse slice for conversational embodied control.  A chat adapter grounds a
human request to the stable visible IDs in `scenario.json`; the Godot authority
then accepts only typed, source-bound commands.

The authority never chooses a route, substitutes a box, or converts a failed
instruction into a new task.  Ambiguous candidate sets require clarification.
After the material barrier event, the current command is suspended and a
source-fresh `replan` command is required before movement resumes.

The headless session entry point is
`res://scripts/conversational_sandbox/conversational_warehouse_session_runner.gd`.
It accepts `--scenario`, `--history=<canonical JSON>` (or a JSON file path),
`--initialization-hash`, `--run-id`, and `--output`, matching the one-shot
history/replay pattern used by the Primitive Sandbox session runner. Its
snapshot has `scenario_id`, `terminal`, `observation`, `receipt`, `replay`, and
`history_count`. The backend's native verifier replays the typed history through
this runner offline and fails closed if its terminal scenario, outcome, tick,
state hash, or provider-call count differs.

The declared effectful command surface is deliberately small: `move`, `pickup`,
`place`, and `replan`. Every effectful command includes a fresh observation
source plus the active `intent_id` and `binding_id`; the only non-effectful
grounding operations are `intent.begin`, `binding.request`, `binding.resolve`,
and `intent.revise`.

By default the deterministic demo interpreter and action planner make the
accepted replay reproducible. Set `GENESIS_CONVERSATION_MODE=openai` with
`OPENAI_API_KEY` to use OpenAI structured output instead: the model is called
once to ground each chat message against visible objects and once at every
authority decision boundary to choose one semantic action. Both outputs are
validated before they reach Godot; neither may create IDs, access hidden state,
or implicitly continue a suspended plan.
