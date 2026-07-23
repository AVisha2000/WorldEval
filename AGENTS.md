# WorldEval repository agent rules

These rules apply to every coding agent in this checkout. Product-specific
`AGENTS.md` files may narrow them further but may not weaken the safety and
evidence requirements below.

## Claim work before editing

1. Read `worldeval.workspace.json`, the target feature's `feature.json`, plan,
   progress log, decision records, and every applicable `AGENTS.md`.
2. Run `worldeval feature validate` and `worldeval feature list`.
3. Create or switch the checkout to `codex/wev-nnnn-<slug>`, then claim one
   backlog record with `worldeval feature claim WEV-NNNN --owner <agent>`.
   The claim command checks dependencies, affected-path collisions, and exclusive
   shared surfaces before atomically moving the record to `features/in-progress`.
4. Work only on the affected paths declared by the claim. Coordinate and amend
   the feature record before expanding scope. Never discard or overwrite another
   agent's dirty work.
5. Keep the 24-hour lease current. Use `renew` while active, `block` with a reason
   and concrete next action when externally blocked, or `release` to return the
   complete feature directory to backlog without losing its progress history.

Do not hand-move lifecycle directories or add a `status` property to
`feature.json`. Directory placement is the only lifecycle authority.

## Evidence and replay discipline

- Map every acceptance criterion to verified evidence in
  `evidence/manifest.json`; record exact test commands, exit codes, timestamps,
  and report paths or hashes.
- Run privacy, secret, migration, and compatibility checks and record their
  outcomes. Behavioral or visual features need recorded human approval.
- Every demo attempt must seal and save its authoritative replay before it is
  called complete. Accepted deterministic demos must include a credential-free,
  offline-verifiable replay bundle. Video is derived output and cannot replace a
  replay.
- Commit implementation and evidence first. `worldeval feature ready` checks the
  gates; `worldeval feature complete` creates the completion receipt and performs
  the separate lifecycle move to `features/implemented`.

## Contracts and authority

- Released protocol packages and historical replay bytes are immutable. Make
  public-contract changes through additive versions and record the decision in
  the active feature.
- Godot is the only WorldArena gameplay authority. Adapters may validate and
  transport commands, but may not invent gameplay decisions or hidden state.
- Missing or invalid model output is a neutral no-op; silence never means
  continue. Environment initialization is authoritative JSON; generated Markdown
  and agent `SKILL.md` files are explanatory or reasoning aids only.
- Never expose credentials, private observations, raw provider output, protected
  authority state, or participant-private artifacts through public evidence.

## Recovery

Use `worldeval feature doctor` after an interrupted lifecycle operation. Review
its report before using `--repair`. Recovery journals and expired claims preserve
work and ownership history; never resolve workflow damage by deleting a feature
directory. Reclaim an expired feature only after inspecting and recording the
preserved revision.
