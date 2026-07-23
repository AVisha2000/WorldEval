"""Materialize Waypoint Maze onboarding from authored protocol inputs."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from worldeval.contracts import (
    ActionCatalog,
    EnvironmentInit,
    EnvironmentManifest,
    ObjectCatalog,
    Objective,
    SkillManifest,
    StaticDecisionProfile,
    materialize_environment_init,
    strict_json_loads,
)
from worldeval.contracts.models import ControlledAsset
from worldeval.workspace import find_workspace

SCENARIO_ID = "beacon-route-v0"


@dataclass(frozen=True)
class WaypointMazeConfiguration:
    root: Path
    scenario_path: Path
    scenario: Mapping[str, Any]
    objective: Objective
    initialization: EnvironmentInit
    action_catalog: ActionCatalog
    object_catalog: ObjectCatalog
    decision_profile: StaticDecisionProfile
    decision_profile_path: Path
    skill: SkillManifest
    skill_path: Path


def default_game_root() -> Path:
    return find_workspace(__file__).path("worldarena_games") / "waypoint-maze"


def load_configuration(
    scenario_id: str = SCENARIO_ID,
    *,
    game_root: Path | None = None,
) -> WaypointMazeConfiguration:
    if scenario_id != SCENARIO_ID:
        raise ValueError(f"unknown Waypoint Maze scenario: {scenario_id}")
    root = Path(game_root or default_game_root()).resolve()
    scenario_path = root / "scenarios" / f"{scenario_id}.json"
    decision_profile_path = (
        root / "decision-profiles" / "static-event-gated-v1.json"
    )
    skill_path = (
        root.parent
        / "shared"
        / "skills"
        / "navigation.follow-visible-waypoints-v1.json"
    )
    manifest = EnvironmentManifest.model_validate(
        _read(root / "environment-manifest.json")
    )
    object_catalog = ObjectCatalog.model_validate(
        _read(root / "catalogs" / "object-catalog.json")
    )
    action_catalog = ActionCatalog.model_validate(
        _read(root / "catalogs" / "action-catalog.json")
    )
    decision_profile = StaticDecisionProfile.model_validate(
        _read(decision_profile_path)
    )
    objective = Objective.model_validate(
        _read(root / "objectives" / f"{scenario_id}.json")
    )
    skill = SkillManifest.model_validate(_read(skill_path))
    scenario = _read(scenario_path)
    agent = dict(scenario["agent"])
    agent.pop("inventory", None)
    controlled = ControlledAsset.model_validate(agent)
    initialization = materialize_environment_init(
        manifest,
        session_id=str(scenario["session_id"]),
        objective=objective,
        object_catalog=object_catalog,
        action_catalog=action_catalog,
        decision_profile=decision_profile,
        controlled_assets=[controlled],
        capabilities=[
            {
                "capability_id": "semantic_actions",
                "available": True,
                "reason": None,
            },
            {
                "capability_id": "exact_coordinates",
                "available": True,
                "reason": None,
            },
            {
                "capability_id": "portable_skill_templates",
                "available": True,
                "reason": None,
            },
        ],
    )
    return WaypointMazeConfiguration(
        root=root,
        scenario_path=scenario_path,
        scenario=scenario,
        objective=objective,
        initialization=initialization,
        action_catalog=action_catalog,
        object_catalog=object_catalog,
        decision_profile=decision_profile,
        decision_profile_path=decision_profile_path,
        skill=skill,
        skill_path=skill_path,
    )


def _read(path: Path) -> Any:
    return strict_json_loads(path.read_bytes())


__all__ = [
    "SCENARIO_ID",
    "WaypointMazeConfiguration",
    "default_game_root",
    "load_configuration",
]
