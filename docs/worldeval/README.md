# WorldEval framework

WorldEval is the environment-neutral layer of this workspace. It owns versioned contracts,
interruptible-plan orchestration, deterministic evaluation, replay envelopes, and the feature
workflow used by coding agents. It does not resolve WorldArena gameplay.

The public Python package is under `worldeval/src/worldeval/`. Immutable protocol packages are
published under `worldeval/protocols/`; a protocol change is additive and receives a new version.
The workspace layout is discovered through the root `worldeval.workspace.json` marker.

## Core invariants

- Evaluation consumes authority evidence, never a model's prose claim.
- Missing or invalid model output is a neutral no-op and never continues an active plan.
- A demo completes only after its terminal replay bundle is sealed and independently verified.
- Replay media is derived and optional; losing a render cannot invalidate a replay.
- World-specific rules and outcomes stay outside this package.

See the root `AGENTS.md` for the claim-first feature lifecycle and
`worldeval/protocols/agent/0.1.0/README.md` for the reusable agent contract.

Public replay readers use the exact native-verifier registry supplied by an
environment adapter. WorldEval verifies canonical encoding, safe relative paths,
artifact inventory, hashes, the outer seal, and independently measured terminal
state/provider-call facts without importing a gameplay engine. Preterminal
failures use the separately authenticated `worldeval/incomplete-run/1.0.0`
diagnostic and can never satisfy a replay acceptance gate.
