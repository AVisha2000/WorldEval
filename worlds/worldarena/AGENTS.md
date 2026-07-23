# WorldArena agent rules

- Godot is the sole gameplay authority. Python validates, schedules, records, and presents; it
  must not award gameplay outcomes.
- Preserve the bytes and identities of frozen protocol packages under `game/`.
- Keep the entire Godot project rooted at this directory's `godot/`; do not casually move
  internal `res://` paths, UID files, or imported assets.
- New games live under `games/<stable-id>/` and adapt WorldEval contracts explicitly.
- Every executable demo must save and verify a replay before it is reported complete.
