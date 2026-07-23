"""Non-authoritative Python conformance oracle for the Primitive Sandbox."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from pydantic import TypeAdapter
from worldeval.contracts.materialization import materialize_environment_init
from worldeval.contracts.models import (
    ActionCatalog,
    ActionPlan,
    ControlledAsset,
    DecisionProfile,
    EnvironmentInit,
    EnvironmentManifest,
    ObjectCatalog,
    Objective,
    Position,
    SourceObservation,
)
from worldeval.evaluation import AgentEpisodeEvaluation, EvaluationInput, evaluate_agent_episode

from .grid import AgentEpisode, load_grid_scenario


@dataclass(frozen=True)
class PrimitiveDemoResult:
    initialization: EnvironmentInit
    replay: dict[str, Any]
    evaluation: AgentEpisodeEvaluation


class ReplayVerificationError(ValueError):
    """A primitive replay cannot be reproduced from its locked inputs."""


def default_primitive_sandbox_root() -> Path:
    for parent in Path(__file__).resolve().parents:
        candidate = parent / "worlds" / "worldarena" / "games" / "primitive-sandbox"
        if candidate.is_dir():
            return candidate
    raise FileNotFoundError(
        "primitive sandbox data is not installed with WorldArena; pass sandbox_root explicitly"
    )


def run_primitive_sandbox_demo(
    scenario: Literal["nominal", "interrupted"],
    *,
    sandbox_root: Path | None = None,
) -> PrimitiveDemoResult:
    """Run, replay offline, and return deterministic protocol/evaluation payloads.

    This is a conformance oracle for provider adapters and the Godot headless
    runner. Production WorldArena gameplay must use the Godot authority.
    """

    root = (sandbox_root or default_primitive_sandbox_root()).resolve()
    first = _execute_demo(scenario, root)
    offline_verified = verify_primitive_sandbox_replay(first.replay, sandbox_root=root)
    replay = dict(first.replay)
    replay["offline_verified"] = offline_verified
    evaluation_data = first.evaluation.model_dump(mode="json")
    evaluation_data["replay_offline_verified"] = offline_verified
    return PrimitiveDemoResult(
        initialization=first.initialization,
        replay=replay,
        evaluation=AgentEpisodeEvaluation.model_validate(evaluation_data),
    )


def verify_primitive_sandbox_replay(
    payload: dict[str, Any],
    *,
    sandbox_root: Path | None = None,
) -> bool:
    """Compare boundaries in protocol tests; never authorize replay acceptance."""

    root = (sandbox_root or default_primitive_sandbox_root()).resolve()
    if payload.get("provider_calls") != 0:
        raise ReplayVerificationError("offline replay must declare provider_calls=0")
    scenario_id = payload.get("scenario_id")
    names = {
        "tree-chop-nominal-v0": "nominal",
        "tree-chop-interrupted-v0": "interrupted",
    }
    scenario_name = names.get(scenario_id)
    if scenario_name is None:
        raise ReplayVerificationError(f"unknown primitive scenario: {scenario_id!r}")
    inputs = _load_demo_inputs(scenario_name, root)
    initialization = inputs[0]
    scenario = inputs[1]
    profile = inputs[2]
    actions = inputs[3]
    if payload.get("initialization_hash") != initialization.initialization_hash:
        raise ReplayVerificationError("initialization hash does not match locked scenario inputs")
    decisions = payload.get("decisions")
    receipts = payload.get("receipts")
    observations = payload.get("observations")
    if not isinstance(decisions, list) or not isinstance(receipts, list) or not isinstance(
        observations, list
    ):
        raise ReplayVerificationError("replay decisions, receipts, and observations must be arrays")
    if len(decisions) != len(receipts) or len(observations) != len(decisions) + 1:
        raise ReplayVerificationError("replay boundary arrays have inconsistent lengths")

    episode = AgentEpisode(
        scenario,
        profile,
        actions,
        initialization_hash=initialization.initialization_hash,
    )
    episode.acknowledge_initialization(initialization.initialization_hash)
    if episode.observation.model_dump(mode="json") != observations[0]:
        raise ReplayVerificationError("initial observation does not reproduce")
    try:
        for index, decision in enumerate(decisions):
            missing_reason = receipts[index].get("no_input_reason") or "missing"
            actual_receipt, actual_observation = episode.respond(
                decision,
                missing_reason=missing_reason,
            )
            if actual_receipt.model_dump(mode="json") != receipts[index]:
                raise ReplayVerificationError(f"receipt {index} does not reproduce")
            if actual_observation.model_dump(mode="json") != observations[index + 1]:
                raise ReplayVerificationError(f"observation {index + 1} does not reproduce")
    except ReplayVerificationError:
        raise
    except Exception as exc:
        raise ReplayVerificationError("recorded decision could not be executed") from exc

    checks = {
        "initial_state_hash": observations[0]["state_hash"],
        "terminal_state_hash": episode.observation.state_hash,
        "terminal_outcome": episode.authority.outcome or "incomplete",
        "terminal_tick": episode.authority.tick,
        "authority_metrics": {
            "forbidden_autonomy_count": episode.authority.forbidden_autonomy_count,
            "hostile_attacks": episode.authority.hostile_attacks,
        },
    }
    for field, actual in checks.items():
        if payload.get(field) != actual:
            raise ReplayVerificationError(f"{field} does not reproduce")
    return True


def _execute_demo(scenario_name: str, root: Path) -> PrimitiveDemoResult:
    initialization, scenario, profile, actions = _load_demo_inputs(scenario_name, root)

    episode = AgentEpisode(
        scenario,
        profile,
        actions,
        initialization_hash=initialization.initialization_hash,
    )
    episode.acknowledge_initialization(initialization.initialization_hash)
    initial_hash = episode.observation.state_hash
    phase = "initial"
    calls = 0
    while not episode.observation.terminal:
        calls += 1
        if calls > 100:
            raise RuntimeError("deterministic demo policy exceeded 100 decision boundaries")
        observation = episode.observation
        event_kinds = {item.kind for item in observation.events}
        if phase == "initial":
            plan = _primary_plan(observation, interrupted=scenario_name == "interrupted")
            response: dict[str, Any] = {
                "type": "plan.replace",
                "replaces_plan_id": None,
                "plan": plan.model_dump(mode="json"),
            }
            phase = "primary"
        elif scenario_name == "interrupted" and "movement_blocked" in event_kinds:
            active = observation.active_plan
            if active is None:
                raise RuntimeError("barrier interrupt lost its active plan")
            plan = _detour_plan(observation)
            response = {
                "type": "plan.replace",
                "replaces_plan_id": active.plan_id,
                "plan": plan.model_dump(mode="json"),
            }
            phase = "detour"
        elif scenario_name == "interrupted" and "hostile_near_target" in event_kinds:
            active = observation.active_plan
            if active is None:
                raise RuntimeError("hostile interrupt lost its active plan")
            response = {
                "type": "plan.abort",
                "plan_id": active.plan_id,
                "source": _source(observation).model_dump(mode="json"),
                "reason": "Hostile entered the protected tree safety radius.",
            }
            phase = "after-hostile-abort"
        elif scenario_name == "interrupted" and phase == "after-hostile-abort":
            plan = _return_plan(observation)
            response = {
                "type": "plan.replace",
                "replaces_plan_id": None,
                "plan": plan.model_dump(mode="json"),
            }
            phase = "return"
        else:
            active = observation.active_plan
            if active is None:
                raise RuntimeError(f"demo policy has no active plan in phase {phase}")
            response = {
                "type": "plan.continue",
                "plan_id": active.plan_id,
                "source": _source(observation).model_dump(mode="json"),
                "lease_ticks": 3 if phase != "return" else 5,
            }
        episode.respond(response)

    replay = {
        "schema_version": "replay-bundle.v1",
        "protocol": "worldeval-agent/0.1.0",
        "run_id": f"primitive-{scenario_name}-v0",
        "environment_id": scenario.environment_id,
        "scenario_id": scenario.scenario_id,
        "initialization_hash": initialization.initialization_hash,
        "initial_state_hash": initial_hash,
        "terminal_state_hash": episode.observation.state_hash,
        "terminal_outcome": episode.authority.outcome or "incomplete",
        "terminal_tick": episode.authority.tick,
        "authority_metrics": {
            "forbidden_autonomy_count": episode.authority.forbidden_autonomy_count,
            "hostile_attacks": episode.authority.hostile_attacks,
        },
        "decisions": episode.decisions,
        "observations": [item.model_dump(mode="json") for item in episode.observations],
        "receipts": [item.model_dump(mode="json") for item in episode.receipts],
        "provider_calls": 0,
        "offline_verified": False,
    }
    evaluation = evaluate_agent_episode(
        EvaluationInput(
            objective_id=scenario.objective_id,
            expected_outcome=scenario.expected_outcome,
            terminal_outcome=episode.authority.outcome,
            terminal_tick=episode.authority.tick,
            receipts=episode.receipts,
            observations=episode.observations,
            start_position=Position(x=2, y=12),
            target_position=Position(x=23, y=12),
            path_distance=episode.authority.path_distance,
            forbidden_autonomy_count=episode.authority.forbidden_autonomy_count,
            hostile_attacks=episode.authority.hostile_attacks,
            tree_exists=episode.authority.registry.contains("tree-7"),
            replay_saved=False,
            replay_offline_verified=False,
        )
    )
    return PrimitiveDemoResult(initialization=initialization, replay=replay, evaluation=evaluation)


def _load_demo_inputs(
    scenario_name: str,
    root: Path,
) -> tuple[EnvironmentInit, Any, DecisionProfile, ActionCatalog]:
    suffix = (
        "tree-chop-nominal-v0"
        if scenario_name == "nominal"
        else "tree-chop-interrupted-v0"
    )
    manifest = EnvironmentManifest.model_validate(_read_json(root / "environment-manifest.json"))
    objects = ObjectCatalog.model_validate(_read_json(root / "catalogs" / "object-catalog.json"))
    actions = ActionCatalog.model_validate(_read_json(root / "catalogs" / "action-catalog.json"))
    profile = TypeAdapter(DecisionProfile).validate_python(
        _read_json(root / "decision-profiles" / "dynamic-step-locked-v1.json")
    )
    objective = Objective.model_validate(_read_json(root / "objectives" / f"{suffix}.json"))
    scenario = load_grid_scenario(root / "scenarios" / f"{suffix}.json")
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
    return initialization, scenario, profile, actions


def _source(observation: Any) -> SourceObservation:
    return SourceObservation(
        observation_seq=observation.observation_seq,
        tick=observation.tick,
        state_hash=observation.state_hash,
    )


def _primary_plan(observation: Any, *, interrupted: bool) -> ActionPlan:
    source = _source(observation).model_dump(mode="json")
    return ActionPlan.model_validate(
        {
            "schema_version": "action-plan.v1",
            "protocol": "worldeval-agent/0.1.0",
            "plan_id": "plan-primary-interrupted" if interrupted else "plan-primary-nominal",
            "source": source,
            "lease_ticks": 3,
            "execution_policy": "confirm_each_boundary",
            "steps": [
                _step(
                    "approach-tree",
                    "move_to",
                    {
                        "target": {"object_id": "tree-7", "generation": 1},
                        "navigation": "direct_only",
                    },
                    "agent_at_target",
                    ["movement_blocked", "target_disappeared", "hostile_near_target"],
                ),
                _step(
                    "equip-axe",
                    "equip",
                    {"item": "axe"},
                    "item_equipped",
                    ["inventory_changed"],
                ),
                _step(
                    "chop-tree",
                    "use_tool",
                    {"tool": "axe", "target": {"object_id": "tree-7", "generation": 1}},
                    "object_destroyed",
                    ["target_disappeared", "hostile_near_target"],
                ),
            ],
            "abort_behavior": "cancel_current_action",
        }
    )


def _detour_plan(observation: Any) -> ActionPlan:
    return ActionPlan.model_validate(
        {
            "schema_version": "action-plan.v1",
            "protocol": "worldeval-agent/0.1.0",
            "plan_id": "plan-explicit-detour",
            "source": _source(observation).model_dump(mode="json"),
            "lease_ticks": 3,
            "execution_policy": "confirm_each_boundary",
            "steps": [
                _step(
                    "step-south",
                    "move_to",
                    {
                        "target": {"position": {"x": 11, "y": 11}},
                        "navigation": "direct_only",
                    },
                    "agent_at_coordinate",
                    ["movement_blocked", "hostile_near_target"],
                ),
                _step(
                    "step-east",
                    "move_to",
                    {
                        "target": {"position": {"x": 14, "y": 11}},
                        "navigation": "direct_only",
                    },
                    "agent_at_coordinate",
                    ["movement_blocked", "hostile_near_target"],
                ),
            ],
            "abort_behavior": "cancel_current_action",
        }
    )


def _return_plan(observation: Any) -> ActionPlan:
    return ActionPlan.model_validate(
        {
            "schema_version": "action-plan.v1",
            "protocol": "worldeval-agent/0.1.0",
            "plan_id": "plan-safe-return",
            "source": _source(observation).model_dump(mode="json"),
            "lease_ticks": 5,
            "execution_policy": "confirm_each_boundary",
            "steps": [
                _step(
                    "return-base",
                    "move_to",
                    {
                        "target": {"object_id": "base-1", "generation": 1},
                        "navigation": "direct_only",
                    },
                    "agent_at_base",
                    ["movement_blocked", "health_threshold_crossed"],
                )
            ],
            "abort_behavior": "cancel_current_action",
        }
    )


def _step(
    step_id: str,
    action: str,
    arguments: dict[str, Any],
    completion: str,
    interrupts: list[str],
) -> dict[str, Any]:
    return {
        "step_id": step_id,
        "action": {"action": action, "arguments": arguments},
        "preconditions": [],
        "expected_completion": {"kind": completion, "subject": None, "parameters": {}},
        "interrupt_on": interrupts,
    }


def _read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))
