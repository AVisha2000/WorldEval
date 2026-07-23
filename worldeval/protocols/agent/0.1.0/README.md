# WorldEval Agent Protocol 0.1.0

This immutable package defines additive, semantic agent-to-world contracts. It
does not change the frozen WorldArena controller or Duel protocols.

The authored environment manifest is the source of truth. An authority
materializes an `environment-init.v1` value for an episode, and the agent must
acknowledge its canonical `initialization_hash` before scored time advances.
Plans expose intent but authorize only one step for one bounded lease. Missing,
invalid, timed-out, or stale responses are neutral no-ops. Skills are visible
agent-side plan templates; they are never opaque world commands. Native replays
carry authority-derived forbidden-autonomy and hostile-attack counters, and both
counters participate in the terminal state hash.
