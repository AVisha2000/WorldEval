# WorldEval feature lifecycle

Feature state is determined exclusively by the directory containing the whole
feature record:

```text
backlog -> in-progress -> implemented
              |
              +---------> backlog
```

Use `worldeval feature` commands rather than moving directories by hand. A
claim acquires the checkout-local lock in `.git/worldeval-feature-locks`, checks
implemented dependencies and active scope collisions, writes a recoverable
transition journal, and grants a 24-hour lease. `doctor` reports interrupted
operations; `doctor --repair` completes only unambiguous transitions and never
deletes feature work.

Every feature carries its acceptance criteria, plan, progress, decisions, and
evidence manifest. Implementation and evidence must be committed before
`complete` creates the separately committable lifecycle receipt. Demos require
saved, verified replay evidence; behavioral and visual work also requires a
recorded human approval.

Run `worldeval feature --help` for the full command surface.
