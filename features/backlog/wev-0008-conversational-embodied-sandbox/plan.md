# Implementation plan: Conversational Embodied Sandbox

## Intent

Deliver a chat-driven, replay-first WorldArena environment where free-form
human instruction is never gameplay authority. An intent compiler first
grounds the request against player-visible stable entity IDs, returns a
clarification when necessary, and records a versioned task contract. An
embodied planner then converts that contract into normal leased action plans.
Godot alone applies movement and manipulation.

The initial vertical slice is a warehouse task: select the intended visible
box, pick it up, carry it to a loading bay, and place it. A material block
requires a new explicit plan; a later chat correction revokes older intent and
must never continue its actions.

## Contracts

- `conversation-command.v1`: attributed user instruction and monotonic intent
  revision.
- `referent-binding.v1`: player-visible candidate IDs, binding outcome,
  expiry, and clarification requirement.
- `task-contract.v1`: grounded objective, constraints, declared fallback, and
  authority boundary.
- Existing action plans and decision responses remain the only execution
  interface.

## Verification

- Ambiguous “that box” requests produce no movement, pickup, or action lease.
- A confirmed binding permits only the selected stable object ID.
- A barrier or correction suspends/revokes old work and requires a new plan.
- Godot re-execution, provider-free replay verification, and public API tests
  prove the accepted demo.
- Controller Lab tests prove protected state is not projected.
