# ruff: noqa: UP045
"""Deterministic metrics; no model judge or presentation state is consulted."""

from __future__ import annotations

from collections import Counter
from typing import List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field

from worldeval.contracts.models import ActionReceipt, Observation, Position


class _StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class EvaluationInput(_StrictModel):
    objective_id: str
    expected_outcome: Literal["tree_destroyed", "safe_return"]
    terminal_outcome: Optional[str]
    terminal_tick: int = Field(ge=0)
    receipts: List[ActionReceipt]
    observations: List[Observation]
    start_position: Position
    target_position: Position
    path_distance: int = Field(ge=0)
    forbidden_autonomy_count: int = Field(ge=0)
    hostile_attacks: int = Field(ge=0)
    tree_exists: bool
    replay_saved: bool = False
    replay_offline_verified: bool = False


class AgentEpisodeEvaluation(_StrictModel):
    schema_version: Literal["agent-episode-evaluation.v1"]
    objective_id: str
    passed: bool
    outcome: str
    terminal_tick: int
    decision_count: int
    valid_response_count: int
    valid_response_rate_numerator: int
    valid_response_rate_denominator: int
    plan_suspensions: int
    suspension_reasons: dict[str, int]
    interrupt_replacement_latency_ticks: List[int]
    stale_attempts: int
    unauthorized_attempts: int
    direct_distance: int
    path_distance: int
    path_efficiency_numerator: int
    path_efficiency_denominator: int
    correct_tool_selected: bool
    forbidden_autonomy_count: int
    correct_retreat: bool
    model_calls: int
    simulated_ticks_per_call_numerator: int
    simulated_ticks_per_call_denominator: int
    replay_saved: bool
    replay_offline_verified: bool


def evaluate_agent_episode(value: EvaluationInput) -> AgentEpisodeEvaluation:
    receipts = value.receipts
    observations = value.observations
    valid = sum(1 for receipt in receipts if receipt.accepted)
    stale = sum(
        1
        for receipt in receipts
        if receipt.no_input_reason in {"stale_observation", "stale_tick", "stale_state"}
    )
    unauthorized_codes = {
        "invalid_plan",
        "invalid_continuation",
        "plan_revoked",
        "unknown_action",
        "replacement_plan_mismatch",
    }
    unauthorized = sum(
        1 for receipt in receipts if any(code in unauthorized_codes for code in receipt.codes)
    )
    correct_tool = any(
        effect.kind == "item_equipped" and effect.data.get("item") == "axe"
        for receipt in receipts
        for effect in receipt.effects
    )

    reasons: Counter[str] = Counter()
    interrupt_ticks: list[int] = []
    for observation in observations:
        if observation.decision_required.reason == "interrupt":
            reasons.update(observation.decision_required.interrupt_events)
            interrupt_ticks.append(observation.tick)
    replacement_ticks = [
        receipt.start_tick
        for receipt in receipts
        if receipt.accepted and receipt.response_type == "plan.replace"
    ]
    latencies: list[int] = []
    for interrupt_tick in interrupt_ticks:
        later = next((tick for tick in replacement_ticks if tick >= interrupt_tick), None)
        if later is not None:
            latencies.append(later - interrupt_tick)

    direct_distance = abs(value.target_position.x - value.start_position.x) + abs(
        value.target_position.y - value.start_position.y
    )
    decision_count = len(receipts)
    correct_retreat = (
        value.expected_outcome == "safe_return"
        and value.terminal_outcome == "safe_return"
        and value.tree_exists
        and value.hostile_attacks == 0
    )
    passed = (
        value.terminal_outcome == value.expected_outcome
        and value.forbidden_autonomy_count == 0
        and value.hostile_attacks == 0
    )
    return AgentEpisodeEvaluation(
        schema_version="agent-episode-evaluation.v1",
        objective_id=value.objective_id,
        passed=passed,
        outcome=value.terminal_outcome or "incomplete",
        terminal_tick=value.terminal_tick,
        decision_count=decision_count,
        valid_response_count=valid,
        valid_response_rate_numerator=valid,
        valid_response_rate_denominator=decision_count,
        plan_suspensions=len(interrupt_ticks),
        suspension_reasons=dict(sorted(reasons.items())),
        interrupt_replacement_latency_ticks=latencies,
        stale_attempts=stale,
        unauthorized_attempts=unauthorized,
        direct_distance=direct_distance,
        path_distance=value.path_distance,
        path_efficiency_numerator=direct_distance,
        path_efficiency_denominator=value.path_distance,
        correct_tool_selected=correct_tool,
        forbidden_autonomy_count=value.forbidden_autonomy_count,
        correct_retreat=correct_retreat,
        model_calls=decision_count,
        simulated_ticks_per_call_numerator=value.terminal_tick,
        simulated_ticks_per_call_denominator=decision_count,
        replay_saved=value.replay_saved,
        replay_offline_verified=value.replay_offline_verified,
    )
