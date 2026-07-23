"""Materialize authoritative onboarding from versioned source contracts."""

from __future__ import annotations

from typing import Any, Iterable, Mapping

from .canonical import canonical_sha256
from .models import (
    ActionCatalog,
    CapabilityStatus,
    ControlledAsset,
    DecisionProfile,
    EnvironmentInit,
    EnvironmentManifest,
    ObjectCatalog,
    Objective,
)


def _as_model(model_type: Any, value: Any) -> Any:
    return value if isinstance(value, model_type) else model_type.model_validate(value)


def environment_init_hash(value: EnvironmentInit | Mapping[str, Any]) -> str:
    data = value.model_dump(mode="json") if isinstance(value, EnvironmentInit) else dict(value)
    data.pop("initialization_hash", None)
    return canonical_sha256(data)


def materialize_environment_init(
    manifest: EnvironmentManifest | Mapping[str, Any],
    *,
    session_id: str,
    objective: Objective | Mapping[str, Any],
    object_catalog: ObjectCatalog | Mapping[str, Any],
    action_catalog: ActionCatalog | Mapping[str, Any],
    decision_profile: DecisionProfile | Mapping[str, Any],
    controlled_assets: Iterable[ControlledAsset | Mapping[str, Any]],
    capabilities: Iterable[CapabilityStatus | Mapping[str, Any]] = (),
) -> EnvironmentInit:
    manifest_model = _as_model(EnvironmentManifest, manifest)
    objective_model = _as_model(Objective, objective)
    object_model = _as_model(ObjectCatalog, object_catalog)
    action_model = _as_model(ActionCatalog, action_catalog)
    from pydantic import TypeAdapter

    decision_model = TypeAdapter(DecisionProfile).validate_python(decision_profile)
    assets = [_as_model(ControlledAsset, item) for item in controlled_assets]
    capability_models = [_as_model(CapabilityStatus, item) for item in capabilities]

    if objective_model.coordinate_frame not in {
        frame.frame_id for frame in manifest_model.coordinate_frames
    }:
        raise ValueError("objective references a coordinate frame absent from the environment")
    if action_model.action_profile != manifest_model.profiles.action:
        raise ValueError("action catalog does not implement the selected action profile")
    if decision_model.profile_id != manifest_model.profiles.decision:
        raise ValueError("decision profile does not match the environment manifest")

    data = {
        "schema_version": "environment-init.v1",
        "protocol": manifest_model.protocol,
        "environment_id": manifest_model.environment_id,
        "game_id": manifest_model.game_id,
        "session_id": session_id,
        "briefing": manifest_model.briefing.model_dump(mode="json"),
        "authority": manifest_model.authority.model_dump(mode="json"),
        "profiles": manifest_model.profiles.model_dump(mode="json"),
        "coordinate_frames": [
            item.model_dump(mode="json") for item in manifest_model.coordinate_frames
        ],
        "controlled_assets": [item.model_dump(mode="json") for item in assets],
        "object_catalog": object_model.model_dump(mode="json"),
        "action_catalog": action_model.model_dump(mode="json"),
        "decision_profile": decision_model.model_dump(mode="json"),
        "active_objective": objective_model.model_dump(mode="json"),
        "capabilities": [item.model_dump(mode="json") for item in capability_models],
        "contracts": manifest_model.contracts.model_dump(mode="json"),
        "example_traces": list(manifest_model.example_traces),
    }
    data["initialization_hash"] = canonical_sha256(data)
    return EnvironmentInit.model_validate(data)


def verify_environment_init_hash(value: EnvironmentInit | Mapping[str, Any]) -> bool:
    model = value if isinstance(value, EnvironmentInit) else EnvironmentInit.model_validate(value)
    return model.initialization_hash == environment_init_hash(model)


def generate_game_initiation_markdown(value: EnvironmentInit | Mapping[str, Any]) -> str:
    """Create a deterministic human companion; JSON remains authoritative."""

    model = value if isinstance(value, EnvironmentInit) else EnvironmentInit.model_validate(value)
    objective = model.active_objective
    actions = ", ".join(action.action_id for action in model.action_catalog.actions)
    frames = ", ".join(frame.frame_id for frame in model.coordinate_frames)
    rules = "\n".join(f"- {rule}" for rule in model.briefing.rules)
    return (
        "# Game initiation (generated, non-authoritative)\n\n"
        "> This document is generated from `environment-init.v1.json`. The JSON contract is "
        "authoritative.\n\n"
        f"- Protocol: `{model.protocol}`\n"
        f"- Environment: `{model.environment_id}`\n"
        f"- Session: `{model.session_id}`\n"
        f"- Initialization hash: `{model.initialization_hash}`\n"
        f"- Role: {model.briefing.agent_role}\n"
        f"- Objective: {objective.instruction}\n"
        f"- Tick budget: {objective.tick_budget}\n"
        f"- Coordinate frames: {frames}\n"
        f"- Available actions: {actions}\n"
        f"- Decision profile: `{model.decision_profile.profile_id}`\n\n"
        "## Rules\n\n"
        f"{rules}\n"
    )
