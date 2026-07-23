from __future__ import annotations

from pathlib import Path

from worldeval.contracts import (
    ActionPlan,
    AgentNativeReplay,
    AgentProtocolValidator,
    SkillManifest,
    strict_json_loads,
)
from worldeval.evaluation import (
    PortableSkillEvaluationInput,
    evaluate_portable_skill,
)


def _fixture(validator: AgentProtocolValidator, name: str) -> object:
    return strict_json_loads((Path(validator.root) / "fixtures" / name).read_bytes())


def test_portable_skill_evaluation_requires_visible_supported_actions() -> None:
    validator = AgentProtocolValidator()
    skill = SkillManifest.model_validate(
        _fixture(validator, "valid.skill-manifest.v1.json")
    )
    plan_value = _fixture(validator, "valid.action-plan.v1.json")
    assert isinstance(plan_value, dict)
    plan = ActionPlan.model_validate(plan_value)
    replay = AgentNativeReplay.model_validate(
        _fixture(validator, "valid.replay-bundle.v1.json")
    )

    accepted = evaluate_portable_skill(
        PortableSkillEvaluationInput(
            objective_id="fixture-objective",
            expected_outcome="incomplete",
            terminal_outcome=replay.terminal_outcome,
            skill=skill,
            action_profile="fixture-actions-v1",
            action_catalog_ids=["wait"],
            expanded_plan=plan,
            receipts=replay.receipts,
            observations=replay.observations,
            material_event_kinds=["movement_blocked"],
            optimal_path_distance=0,
            path_distance=0,
            forbidden_autonomy_count=0,
            replay_saved=True,
            replay_offline_verified=True,
        )
    )
    assert accepted.passed is True
    assert accepted.skill_expanded_to_visible_actions is True
    assert accepted.opaque_skill_commands == 0

    opaque_value = dict(plan_value)
    opaque_value["steps"] = [dict(plan_value["steps"][0])]
    opaque_value["steps"][0]["action"] = {
        "action": "execute_skill",
        "arguments": {},
    }
    opaque = evaluate_portable_skill(
        PortableSkillEvaluationInput(
            objective_id="fixture-objective",
            expected_outcome="incomplete",
            terminal_outcome=replay.terminal_outcome,
            skill=skill,
            action_profile="fixture-actions-v1",
            action_catalog_ids=["wait", "execute_skill"],
            expanded_plan=ActionPlan.model_validate(opaque_value),
            receipts=replay.receipts,
            observations=replay.observations,
            material_event_kinds=[],
            optimal_path_distance=0,
            path_distance=0,
            forbidden_autonomy_count=0,
            replay_saved=True,
            replay_offline_verified=True,
        )
    )
    assert opaque.passed is False
    assert opaque.skill_expanded_to_visible_actions is False
    assert opaque.opaque_skill_commands == 1
