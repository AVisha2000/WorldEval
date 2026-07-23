# Decision: keep dependent capability records in backlog during cutover

Date: 2026-07-23

Status: accepted for this integration branch

## Context

The implementation request covers WEV-0001 through WEV-0007, while the program's
own dependency graph requires WEV-0001 to land before WEV-0002 through WEV-0005
can be claimed. The feature workflow also makes the directory location the sole
lifecycle state. Moving dependent records into `in-progress/` before their
dependency is implemented would make the workflow lie about its own rules.

## Decision

Candidate implementations for the replay standard, agent protocol, decision
runtime, and Primitive Sandbox may be developed and verified on the single
cutover integration branch because the user requested the complete program in
one implementation pass. Their feature records remain in `backlog/` until
WEV-0001 is merged and recorded as implemented. They are not represented as
claimed or complete merely because code and replay evidence exist in this
working tree.

After the cutover merge, each dependent feature must be claimed in dependency
order. Its candidate implementation is then audited against its own acceptance
criteria, evidence is normalized into that feature record, any required human
approval is recorded, and completion is performed through the lifecycle CLI.

The user subsequently requested implementation of the complete program in this
cutover pass, so WEV-0006 now also has a reviewable candidate: the portable
skill evaluator and Waypoint Maze second-game adoption. Its record remains in
backlog pending WEV-0005 and behavioral approval, under the same dependency
rule above. WEV-0007 remains incremental future work; its current deliverable
is an evidence-backed migration inventory, not a claim that missing historical
authority bytes were recreated.

## Consequences

- WEV-0001 remains limited to repository, compatibility, and governance gates.
- Existing candidate code is reviewable without corrupting lifecycle state.
- No dependent feature can be called implemented until its own claim and
  evidence gate succeeds after the cutover dependency is satisfied.
- The final implementation report must distinguish delivered code from
  lifecycle-complete features and remaining backlog work.
