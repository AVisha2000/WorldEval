# WorldArena Duel replay and audit pipeline

This note describes the implemented Python trust boundary for replay storage and evaluation. The
normative product rules remain in `WORLDARENA_DUEL_IMPLEMENTATION_SPEC.md`.

## Authority flow

1. The Gateway authenticates and sequence-checks each local Godot frame.
2. Only data from an accepted frame is passed to `AuthoritativeReplayRecorder`.
3. The recorder preserves accepted actions and compiled primitive orders at their authoritative
   application ticks. It assigns contiguous transcript indexes and requires every compiled order
   to reference its accepted action.
4. Public events are appended in contiguous `event_seq` order. A checkpoint is appended only after
   all applications and events at that tick.
5. Sealing creates one canonical, content-addressed publishable bundle. The frozen replay-manifest
   schema is validated inside the seal/load boundary, not as an optional caller check.
6. `verify_replay_bundle` cross-checks the manifest, transcript payloads, checkpoint cursors,
   checkpoint payload, decision profile, terminal record, and final hash.
7. `replay_and_verify` runs with no provider or network dependency. It compares regenerated events
   and every state checkpoint, then verifies the terminal state hash.
8. `scored_result_from_verified_replay` compares the verified replay to the frozen scheduled game:
   match and seed, mode/cadence/deadline, map/faction, all environment hashes, model snapshots,
   reasoning settings, provider tier, and terminal tick. The winner/disposition is derived from the
   replay terminal record rather than supplied by a strategy judge.

Every result that can contribute points must carry its replay evidence commitment. An
infrastructure void may lack replay evidence because the authority itself may have crashed; that
game contributes no score and the complete paired seed is scheduled for rerun.

## Publishable layer

The required roles are:

- `accepted_actions`: canonical NDJSON ordered by application tick and `transcript_index`;
- `compiled_orders`: canonical NDJSON with `source_action_index` links;
- `public_events`: frozen-schema-valid omniscient events in one contiguous `event_seq`;
- `state_checkpoints`: canonical JSON exactly mirroring manifest checkpoints, terminal tick, and
  final state hash.

Optional spectator snapshots, perspective knowledge, and aggregate timing remain separate roles.
Opaque binary payloads are rejected from the public layer because their private/credential safety
cannot be proven. Every application tick and every 300-tick interval through terminal must have a
checkpoint. Manifest cursor values must equal the last action/event actually present at that tick.

## Protected audit layer

`seal_match_artifact_layers` creates a separately content-addressed protected bundle. It retains
authorized evidence such as observations, raw responses, parsed batches, working memory,
validation traces, provider request IDs, token usage, and detailed timing. Its manifest commits to
the exact public bundle content hash, index hash, manifest hash, and match ID.

The public bundle cannot contain protected field classes such as raw response, scratchpad, working
memory, request ID, or validation trace. Both layers reject credential-like keys and secret-like
values. Publication consists only of distributing the public bundle; the protected bundle must use
the benchmark's access-controlled retention path.

## Fail-closed behavior

Verification stops on the first invalid canonical byte, unknown/duplicate role, unsafe path,
non-canonical base64, schema violation, payload/hash/size mismatch, transcript time reversal,
missing source link, event gap, checkpoint cursor mismatch, missing periodic/application checkpoint,
event divergence, state-hash divergence, terminal mismatch, audit/public binding mismatch, or
schedule/environment mismatch. There is no repair, best-effort continuation, or provider call in
the replay path.
