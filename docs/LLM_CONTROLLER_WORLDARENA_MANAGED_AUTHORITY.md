# LLM Controller × WorldArena managed authority

Phase 1 runs exactly one headless Godot authority process per episode. Python owns lifecycle,
timeouts, replay evidence, and the loopback gateway; Godot owns deterministic integer simulation,
observations, receipts, events, checkpoints, and terminal resolution.

## Trust boundaries

- Python passes one canonical launch object over bounded stdin. It contains the episode config,
  locked protocol-package hash, one-use attachment ticket, connection identity, and a 32-byte
  session secret.
- Godot accepts only the pinned engine build, exact protocol lock, exact episode config hash, and
  an uncredentialed `ws://` loopback URL whose path contains the attachment ticket.
- The WebSocket uses canonical text frames, monotonic per-direction sequences, role-derived
  HMAC-SHA256 tags, and explicit config/checkpoint boundary hashes. It cannot reconnect.
- Secrets and tickets remain process-memory control material. They are scrubbed after handoff and
  never enter observations, authority checkpoints, replays, logs, or Godot control output.

## Episode sequence

1. Python registers an in-memory one-use ticket and launches Godot with canonical stdin.
2. Godot connects to the loopback gateway, sends `hello`, and receives `auth`.
3. Godot sends `episode_ready` with participant-indexed initial observations and the initial
   checkpoint hash.
4. Python sends joint `decision_window` frames. Godot advances authority and returns one
   participant-indexed `step_result` for each window.
5. Python seals a canonical replay after terminal state and sends `close_episode`.
6. Both sides close the socket; Python terminates, kills if necessary, and reaps only its owned
   process.

Every failed, invalid, missing, stale, or timed-out participant decision is represented before the
authority boundary as `no_input`; Godot applies neutral controller state for the bounded window.
Invalid input therefore cannot stall simulation time.

## Replay verification

The replay ledger binds the protocol package, episode config, initial boundary, every joint window
and result, final terminal state, and final checkpoint hash. Its digest covers canonical replay
bytes excluding only the digest field itself. The offline Godot verifier starts from genesis,
re-executes every recorded window without a provider or network connection, and rejects the replay
unless every result and the terminal checkpoint match exactly.
