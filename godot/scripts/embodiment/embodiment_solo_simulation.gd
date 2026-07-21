class_name EmbodimentSoloSimulation
extends "res://scripts/embodiment/authority/authority_orchestrator.gd"

## Backwards-compatible Stage-A façade.
##
## All deterministic authority behavior lives in the embodiment/authority namespace. Keeping this
## class intentionally empty preserves the prototype's public construction and method surface for
## callers while managed sessions use the same authority orchestrator directly.
