# Feature workflow schemas

These schemas are the public contracts for repository-native feature records.
Lifecycle state is deliberately absent from `feature.json`: `backlog`,
`in-progress`, and `implemented` are derived from the containing directory.

The standard-library validator in `worldeval.features` enforces the bootstrap
invariants even when optional project dependencies are unavailable.
