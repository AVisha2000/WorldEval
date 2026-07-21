# Duel action boundary

This directory is the Godot authority boundary for the frozen
`actions.hybrid-v1` controller. `DuelActionValidator.validate_and_compile(batch,
legal_context)` accepts already parsed, integer-normalized JSON data. The Python
gateway still owns raw-byte, UTF-8, duplicate-key, and JSON parsing checks.

The validator repeats the strict envelope and all 37 command shapes, prices the
batch exactly like `backend/genesis_arena/duel/budget.py`, validates commands in
model array order against one immutable application-tick context, and returns
canonical intents plus an action-receipt-shaped dictionary. A malformed
envelope produces no intents. An unavailable or illegal command produces one
rejected command receipt without discarding legal siblings.

## Frozen legal-context input

The simulation integration layer supplies a JSON-safe dictionary with these
required fields:

- boundary: `match_id`, `observation_seq`, `observation_hash`,
  `received_tick`, `application_tick`, `controller_valid_until_tick`,
  `accepted_batch_ids`, and `player_seat`;
- coordinate frame: `world_max_inclusive_mt` (exactly `[191999,127999]`),
  `self_rotates_to_world` (false for seat 0, true for seat 1), and optional
  `self_to_world_public_ids`;
- knowledge/application state: `entities`, `known_regions`, `known_sites`,
  `squads`, `squad_sizes`, and `transport_passenger_counts`;
- optional legality data: `catalog_ids`, `all_points_explored`, and
  `explored_points`.

Each `entities[public_alias]` record maps the legal observation alias to an
`internal_id` and carries `owner_seat`, `known`, `visible`, `alive`,
`available`, tick bounds, tags, queue counts, and operation-specific legal ID
sets. The simulation/economy/combat subsystem may attach a stable code in
`rejection_codes[operation]` or `rejection_codes["operation:qualifier"]` after
performing its frozen-state resource, food, prerequisite, placement, cooldown,
or capability check. The validator never asks hidden state to distinguish an
enemy alias: missing, hidden, dead, and untargetable enemy targets all return
`target_unavailable`.

## Compiled-intent contract

Every accepted atomic claim emits one dictionary in command order and actor
array order:

```text
{
  intent_id: "ci_" + 64 lowercase SHA-256 hex,
  intent_digest: 64 lowercase SHA-256 hex,
  intent_type: order | economy | ability | item | transport | squad_state | tactics,
  operation: explicit primitive operation,
  owner_seat: 0 | 1,
  apply_tick: integer,
  queue_policy: none | replace | append | front,
  subject: {kind: entity, public_id, internal_id} | {kind: controller, seat},
  target: canonical world-relative target or {},
  parameters: operation-specific canonical data,
  source: {
    match_id, batch_id, observation_seq, command_id,
    command_index, expansion_index, command_digest
  }
}
```

`intent_digest` hashes the entire body before `intent_id` and `intent_digest`
are added. The full digest is used in the ID, so no truncated-hash collision
policy is needed. Group, squad, quantity, build-helper, and transport commands
expand to one intent per charged atomic claim. Build intents share a deterministic
`construction_group_id`; only the intent marked `is_primary_builder` may reserve
the building cost, while the others become construction assists.

The returned top-level dictionary contains `intents`, `receipt`, canonical
projected `squads`, projected order-queue sizes, exact `atomic_cost`, and the
canonical `batch_digest`.

## Integration hook

At the `activate_accepted_orders` tick phase, `DuelSimulation` should build the
immutable legal context from its authoritative snapshot, call the validator,
persist the receipt and raw compiled intents in replay order, and hand each
intent to an explicit `intent_type`/`operation` switch. The integration switch
may create `DuelOrder` instances or call economy/combat application APIs; it
must not reinterpret protocol aliases, change queue policy, choose a target, or
recompile squad strategy. Later completion/interruption/failure events retain
the intent ID and its source command digest.
