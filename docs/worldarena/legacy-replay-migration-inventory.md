# Legacy replay migration inventory

This inventory is the read-only starting point for `WEV-0007`. It records what
exists after the repository cutover; it is not evidence that a legacy artifact
has been normalized. Frozen inner replay and protocol bytes must remain unchanged.

| Legacy surface | Authority evidence present | Additive work still required |
|---|---|---|
| Crossroads Conquest | Native replay, evaluation, verified showcase manifest, and curated video | Copy the existing bytes into a new outer replay bundle, register its exact historical verifier, and retain the inner manifest unchanged. |
| Labyrinth Run | Native trio replay, evaluation, showcase manifest, and curated video | Add a sealed outer multi-participant bundle and prove provider-free replay after restart. Do not infer protected per-leg evidence from the public broadcast replay. |
| Mini RTS Skirmish | Native replay, evaluation, terminal/final-state binding, and curated video | Add an exact Godot verifier and sealed outer bundle without rewriting the native replay. |
| `demo_highlight` | Authored unverified replay/presentation package | Relabel it as `presentation_script`; it must remain ineligible for authority-replay acceptance. |
| Solo Multi-Action | Curated video plus evidence containing only the historical replay SHA-256 and final-state SHA-256 | The referenced replay bytes are absent. They cannot be recreated or claimed from the video. Record the historical artifact as unrecoverable; a future rerun may create a new replay/version but cannot replace the missing hash-bound run. |
| Managed solo terminal failures | Current service-specific behavior and tests | Preserve every sealable terminal failure as authority replay; use the universal sealed `incomplete-run` diagnostic only when no terminal boundary exists. |
| Managed duo/trio series | Public series evidence and participant-media lifecycle | Audit each leg and retain a protected authority replay for every seat/leg before adding an outer multi-leg manifest. Public routes must continue to expose only allow-listed projections. |

## Descendant feature boundaries

`WEV-0007` must be split before implementation internals are edited:

1. `WEV-0007A` — presentation-only labeling and the unrecoverable Solo
   Multi-Action record.
2. `WEV-0007B` — Crossroads, Labyrinth, and RTS outer bundle adapters with
   exact historical verifier registrations.
3. `WEV-0007C` — managed solo terminal-failure retention.
4. `WEV-0007D` — protected duo/trio per-leg authority retention.
5. Later game-internal migrations, each with its own compatibility facade and
   rollback proof.

No descendant may regenerate, re-sign, or silently substitute historical
evidence. A missing replay is an explicit unavailable outcome, not permission to
create a plausible replacement.
