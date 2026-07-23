# ruff: noqa: UP045
"""Cross-game metrics for agent-side expansion of portable skill templates."""

from __future__ import annotations

from typing import List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field

from worldeval.contracts.models import (
    ActionPlan,
    ActionReceipt,
    Observation,
    SkillManifest,
)


class _StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class PortableSkillEvaluationInput(_StrictModel):
    """Authority evidence and authored constraints needed for generic scoring."""

    objective_id: str = Field(min_length=1)
    expected_outcome: str = Field(min_length=1)
    terminal_outcome: Optional[str]
    skill: SkillManifest
    action_profile: str = Field(min_length=1)
    action_catalog_ids: List[str] = Field(min_length=1)
    expanded_plan: ActionPlan
    receipts: List[ActionReceipt]
    observations: List[Observation] = Field(min_length=1)
    material_event_kinds: List[str] = Field(default_factory=list)
    optimal_path_distance: int = Field(ge=0)
    path_distance: int = Field(ge=0)
    forbidden_autonomy_count: int = Field(ge=0)
    replay_saved: bool = False
    replay_offline_verified: bool = False


class PortableSkillEvaluation(_StrictModel):
    """Environment-neutral, deterministic skill-transfer report."""

    schema_version: Literal["portable-skill-evaluation.v1"]
    judge: Literal["authority_only"]
    objective_id: str
    passed: bool
    outcome: str
    skill_id: str
    skill_execution: Literal["agent_expands_to_visible_actions"]
    compatible_action_profile: bool
    skill_expanded_to_visible_actions: bool
    expanded_action_count: int
    expanded_actions: List[str]
    opaque_skill_commands: int
    valid_response_rate_numerator: int
    valid_response_rate_denominator: int
    stale_attempts: int
    unauthorized_attempts: int
    material_event_boundaries: int
    adaptation_required_boundaries: int
    successful_adaptations: int
    adaptation_success: bool
    optimal_path_distance: int
    path_distance: int
    path_efficiency_numerator: int
    path_efficiency_denominator: int
    model_calls: int
    forbidden_autonomy_count: int
    replay_saved: bool
    replay_offline_verified: bool


def evaluate_portable_skill(
    value: PortableSkillEvaluationInput,
) -> PortableSkillEvaluation:
    """Score visible skill expansion using receipts and observations only."""

    expanded_actions = [
        step.action.action for step in value.expanded_plan.steps
    ]
    compatible_profile = (
        value.action_profile in value.skill.compatible_action_profiles
    )
    actions_are_visible = (
        value.skill.execution == "agent_expands_to_visible_actions"
        and compatible_profile
        and all(action in value.action_catalog_ids for action in expanded_actions)
        and all(action in value.skill.suggested_actions for action in expanded_actions)
        and "execute_skill" not in expanded_actions
    )
    valid = sum(1 for receipt in value.receipts if receipt.accepted)
    stale_reasons = {
        "stale_observation",
        "stale_tick",
        "stale_state",
    }
    stale = sum(
        1
        for receipt in value.receipts
        if receipt.no_input_reason in stale_reasons
    )
    unauthorized_codes = {
        "invalid_plan",
        "invalid_continuation",
        "plan_revoked",
        "unknown_action",
        "replacement_plan_mismatch",
    }
    unauthorized = sum(
        1
        for receipt in value.receipts
        if any(code in unauthorized_codes for code in receipt.codes)
    )
    material_kinds = set(value.material_event_kinds)
    material_boundaries = [
        observation
        for observation in value.observations[1:]
        if any(event.kind in material_kinds for event in observation.events)
    ]
    adaptation_boundaries = [
        observation
        for observation in material_boundaries
        if not observation.terminal
    ]
    successful_adaptations = sum(
        1
        for observation in adaptation_boundaries
        if any(
            receipt.observation_seq == observation.observation_seq
            and receipt.accepted
            for receipt in value.receipts
        )
    )
    adaptation_success = successful_adaptations == len(adaptation_boundaries)
    passed = (
        value.terminal_outcome == value.expected_outcome
        and actions_are_visible
        and unauthorized == 0
        and value.forbidden_autonomy_count == 0
        and adaptation_success
        and value.replay_saved
        and value.replay_offline_verified
    )
    return PortableSkillEvaluation(
        schema_version="portable-skill-evaluation.v1",
        judge="authority_only",
        objective_id=value.objective_id,
        passed=passed,
        outcome=value.terminal_outcome or "incomplete",
        skill_id=value.skill.skill_id,
        skill_execution=value.skill.execution,
        compatible_action_profile=compatible_profile,
        skill_expanded_to_visible_actions=actions_are_visible,
        expanded_action_count=len(expanded_actions),
        expanded_actions=expanded_actions,
        opaque_skill_commands=expanded_actions.count("execute_skill"),
        valid_response_rate_numerator=valid,
        valid_response_rate_denominator=len(value.receipts),
        stale_attempts=stale,
        unauthorized_attempts=unauthorized,
        material_event_boundaries=len(material_boundaries),
        adaptation_required_boundaries=len(adaptation_boundaries),
        successful_adaptations=successful_adaptations,
        adaptation_success=adaptation_success,
        optimal_path_distance=value.optimal_path_distance,
        path_distance=value.path_distance,
        path_efficiency_numerator=value.optimal_path_distance,
        path_efficiency_denominator=value.path_distance,
        model_calls=len(value.receipts),
        forbidden_autonomy_count=value.forbidden_autonomy_count,
        replay_saved=value.replay_saved,
        replay_offline_verified=value.replay_offline_verified,
    )


__all__ = [
    "PortableSkillEvaluation",
    "PortableSkillEvaluationInput",
    "evaluate_portable_skill",
]
