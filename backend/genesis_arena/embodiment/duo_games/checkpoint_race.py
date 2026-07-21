"""Deterministic visible-only Demo policies and safe evaluation for checkpoint racing."""

from __future__ import annotations

from typing import Any, Mapping

from ..contracts import ControllerState
from ..demo_provider import DemoPolicyLock, DemoProvider
from ..providers.contracts import ProviderRequest
from .common import (
    FIXED_DUO_WINDOW_TICKS,
    DuoFixtureMode,
    DuoPolicySpec,
    build_demo_provider,
    direct_action,
    frozen_specs,
    move_or_turn_toward,
    parse_visible_observation,
    participant_window_projection,
    select_visible_entity,
    validate_completion_tick,
    validate_match_outcomes,
    validate_two_participant_summaries,
)

CHECKPOINT_RACE_SCENARIO_ID = "duo-checkpoint-race-v0"
CHECKPOINT_RACE_MODELS = frozen_specs(
    {
        "checkpoint-racer-alpha-v1": DuoPolicySpec(
            CHECKPOINT_RACE_SCENARIO_ID,
            "checkpoint-racer-alpha-visible-v1",
            "checkpoint-racer-alpha-v1",
            "clockwise-correction",
        ),
        "checkpoint-racer-bravo-v1": DuoPolicySpec(
            CHECKPOINT_RACE_SCENARIO_ID,
            "checkpoint-racer-bravo-visible-v1",
            "checkpoint-racer-bravo-v1",
            "counterclockwise-correction",
        ),
    }
)

_RACE_FIELDS = frozenset(
    ("completion_tick", "terminal_outcome", "terminal_reason", "checkpoint_total", "participants")
)


def build_checkpoint_race_demo_provider(
    *,
    model: str,
    participant_id: str,
    seed: int,
    decision_budget: int,
    fixture_mode: DuoFixtureMode = "valid",
) -> DemoProvider:
    try:
        spec = CHECKPOINT_RACE_MODELS[model]
    except KeyError as error:
        raise ValueError("unsupported checkpoint-race Demo model") from error
    return build_demo_provider(
        spec=spec,
        participant_id=participant_id,
        seed=seed,
        decision_budget=decision_budget,
        behavior=_checkpoint_race_behavior,
        fixture_mode=fixture_mode,
    )


def _checkpoint_race_behavior(
    request: ProviderRequest, lock: DemoPolicyLock, call_index: int
) -> bytes:
    spec = CHECKPOINT_RACE_MODELS.get(request.model)
    if (
        spec is None
        or lock.scenario_id != CHECKPOINT_RACE_SCENARIO_ID
        or lock.policy_id != spec.policy_id
    ):
        raise ValueError("checkpoint-race policy lock is incompatible")
    entities = parse_visible_observation(request)
    target = select_visible_entity(
        entities,
        kinds=("checkpoint", "finish_beacon"),
        required_affordance="race_target",
        states=frozenset(("next_in_order", "finish_open")),
    )
    if target is None:
        turn = 1000 if spec.variant == "clockwise-correction" else -1000
        control = ControllerState(0, 0, turn, 0, FIXED_DUO_WINDOW_TICKS)
        intent = "Demo: scan for the next visible race marker"
    elif target["distance"] == "touching":
        # Crossing is authority-owned; a small forward hold avoids inventing an interaction verb.
        control = ControllerState(0, 400, 0, 0, FIXED_DUO_WINDOW_TICKS)
        intent = "Demo: cross the visible race marker"
    else:
        correction = 1000 if spec.variant == "clockwise-correction" else -1000
        control = move_or_turn_toward(target, blocked_turn=correction)
        intent = "Demo: approach the next visible race marker"
    return direct_action(
        request,
        call_index=call_index,
        action_prefix="race",
        control=control,
        intent=intent,
    )


def evaluate_checkpoint_race(authority_aggregates: Mapping[str, Any]) -> dict[str, Any]:
    """Project race evidence without transforms, route geometry, or private observations."""

    if not isinstance(authority_aggregates, Mapping) or set(authority_aggregates) != _RACE_FIELDS:
        raise ValueError("checkpoint-race authority aggregates have invalid fields")
    completion_tick = validate_completion_tick(authority_aggregates["completion_tick"])
    checkpoint_total = authority_aggregates["checkpoint_total"]
    if (
        isinstance(checkpoint_total, bool)
        or not isinstance(checkpoint_total, int)
        or checkpoint_total < 1
    ):
        raise ValueError("checkpoint_total must be a positive integer")
    summaries = validate_two_participant_summaries(
        authority_aggregates["participants"], extra_fields=frozenset(("checkpoints_reached",))
    )
    if any(summary["checkpoints_reached"] > checkpoint_total for _, summary in summaries):
        raise ValueError("checkpoints reached exceeds the race total")
    terminal_outcome = authority_aggregates["terminal_outcome"]
    terminal_reason = authority_aggregates["terminal_reason"]
    validate_match_outcomes(summaries, terminal_outcome)
    if not isinstance(terminal_reason, str) or terminal_reason not in {
        "finish",
        "time_limit",
        "simultaneous_terminal",
        "void",
    }:
        raise ValueError("checkpoint-race terminal reason is invalid")
    if terminal_outcome == "win" and (terminal_reason != "finish" or completion_tick is None):
        raise ValueError("winning race completion is inconsistent")
    if terminal_outcome == "win":
        winner = next(summary for _, summary in summaries if summary["outcome"] == "win")
        if winner["checkpoints_reached"] != checkpoint_total:
            raise ValueError("race winner did not complete every checkpoint")
    if terminal_outcome == "draw" and terminal_reason not in {
        "time_limit",
        "simultaneous_terminal",
    }:
        raise ValueError("drawn race completion is inconsistent")
    if terminal_outcome == "void" and terminal_reason != "void":
        raise ValueError("void race completion is inconsistent")

    participants, symmetry = participant_window_projection(
        summaries, extra_fields=("checkpoints_reached",)
    )
    symmetry["checkpoint_progress_delta"] = abs(
        summaries[0][1]["checkpoints_reached"] - summaries[1][1]["checkpoints_reached"]
    )
    return {
        "schema_version": "duo-checkpoint-race-evaluation/1",
        "scope": "duo_game",
        "task_id": CHECKPOINT_RACE_SCENARIO_ID,
        "completion": {
            "tick": completion_tick,
            "outcome": terminal_outcome,
            "reason": terminal_reason,
        },
        "participants": participants,
        "symmetry": symmetry,
    }


__all__ = [
    "CHECKPOINT_RACE_MODELS",
    "CHECKPOINT_RACE_SCENARIO_ID",
    "build_checkpoint_race_demo_provider",
    "evaluate_checkpoint_race",
]
