# WEV-0001-D004: Conversational sandbox candidate on the cutover branch

## Context

The user directed the team to make the proposed conversational sandbox fully
working with sub-agents before the repository cutover has crossed its single
review and merge boundary. The new capability needs the WorldEval and
WorldArena roots that currently live under WEV-0001's active integration
claim. A separate WEV-0008 record cannot be claimed yet because the workflow
correctly requires WEV-0001 to be implemented first.

## Decision

Implement the replay-first conversational warehouse vertical slice as a
candidate on `codex/wev-0001-repository-cutover`, while creating WEV-0008 as
the independent post-cutover lifecycle record. The candidate must use only
additive contracts and a new WorldArena game implementation. It cannot change
released game behavior, frozen package bytes, legacy routes, or replay bytes.

## Consequences

WEV-0001 is returned from `ready` to an active integration state and must
repeat its evidence and review gates before completion. WEV-0008 remains
backlog until the cutover is merged, then receives its own claim, evidence,
human behavioral and visual approval, and completion transition. Every
candidate demo must still seal an offline-verifiable replay.
