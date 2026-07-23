"""Materialize one Primitive Sandbox episode from locked authored inputs."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from pydantic import TypeAdapter
from worldeval.contracts import (
    ActionCatalog,
    DynamicDecisionProfile,
    EnvironmentInit,
    EnvironmentManifest,
    ObjectCatalog,
    Objective,
    StaticDecisionProfile,
    materialize_environment_init,
    strict_json_loads,
)
from worldeval.contracts.models import ControlledAsset, DecisionProfile
from worldeval.workspace import find_workspace

from .grid import GridScenario, load_grid_scenario

SCENARIOS = {
    "tree-chop-nominal-v0": "nominal",
    "tree-chop-interrupted-v0": "interrupted",
}


@dataclass(frozen=True)
class PrimitiveSandboxConfiguration:
    root: Path
    scenario_path: Path
    scenario: GridScenario
    objective: Objective
    initialization: EnvironmentInit
    action_catalog: ActionCatalog
    decision_profile: DynamicDecisionProfile | StaticDecisionProfile
    object_catalog: ObjectCatalog


def default_sandbox_root() -> Path:
    workspace = find_workspace(__file__)
    return workspace.path("worldarena_games") / "primitive-sandbox"


def load_configuration(
    scenario_id: str,
    *,
    sandbox_root: Path | None = None,
) -> PrimitiveSandboxConfiguration:
    if scenario_id not in SCENARIOS:
        raise ValueError(f"unknown Primitive Sandbox scenario: {scenario_id}")
    root = Path(sandbox_root or default_sandbox_root()).resolve()
    scenario_path = root / "scenarios" / f"{scenario_id}.json"
    manifest = EnvironmentManifest.model_validate(_read(root / "environment-manifest.json"))
    objects = ObjectCatalog.model_validate(_read(root / "catalogs/object-catalog.json"))
    actions = ActionCatalog.model_validate(_read(root / "catalogs/action-catalog.json"))
    profile = TypeAdapter(DecisionProfile).validate_python(
        _read(root / "decision-profiles/dynamic-step-locked-v1.json")
    )
    objective = Objective.model_validate(_read(root / "objectives" / f"{scenario_id}.json"))
    scenario = load_grid_scenario(scenario_path)
    controlled_data = scenario.agent.model_dump(mode="json", exclude={"inventory"})
    controlled_data["state"] = {
        **controlled_data["state"],
        "inventory": list(scenario.agent.inventory),
        "equipped": None,
    }
    controlled = ControlledAsset.model_validate(controlled_data)
    initialization = materialize_environment_init(
        manifest,
        session_id=scenario.session_id,
        objective=objective,
        object_catalog=objects,
        action_catalog=actions,
        decision_profile=profile,
        controlled_assets=[controlled],
        capabilities=[
            {"capability_id": "semantic_actions", "available": True, "reason": None},
            {"capability_id": "exact_coordinates", "available": True, "reason": None},
        ],
    )
    return PrimitiveSandboxConfiguration(
        root=root,
        scenario_path=scenario_path,
        scenario=scenario,
        objective=objective,
        initialization=initialization,
        action_catalog=actions,
        decision_profile=profile,
        object_catalog=objects,
    )


def sandbox_catalog() -> Mapping[str, Any]:
    root = default_sandbox_root()
    manifest = _read(root / "environment-manifest.json")
    scenarios = []
    labels = {
        "tree-chop-nominal-v0": "Tree Chop · Nominal",
        "tree-chop-interrupted-v0": "Tree Chop · Interrupted",
    }
    for scenario_id in SCENARIOS:
        objective = _read(root / "objectives" / f"{scenario_id}.json")
        scenarios.append(
            {
                "scenarioId": scenario_id,
                "label": labels[scenario_id],
                "objective": objective["instruction"],
            }
        )
    return {
        "gameId": manifest["game_id"],
        "protocol": manifest["protocol"],
        "actionProfile": manifest["profiles"]["action"],
        "observationProfile": manifest["profiles"]["observation"],
        "decisionProfile": manifest["profiles"]["decision"],
        "scenarios": scenarios,
    }


def _read(path: Path) -> Any:
    return strict_json_loads(path.read_bytes())


__all__ = [
    "SCENARIOS",
    "PrimitiveSandboxConfiguration",
    "default_sandbox_root",
    "load_configuration",
    "sandbox_catalog",
]
