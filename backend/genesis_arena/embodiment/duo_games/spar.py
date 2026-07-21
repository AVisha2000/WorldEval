"""Deterministic visible-only Demo policies and safe evaluation for a simple spar."""

from __future__ import annotations

from typing import Any, Mapping

from ..contracts import ControllerButtons, ControllerState
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
    neutral_control,
    parse_visible_observation,
    participant_window_projection,
    select_visible_entity,
    validate_completion_tick,
    validate_match_outcomes,
    validate_two_participant_summaries,
)

SPAR_SCENARIO_ID = "duo-spar-v0"
SPAR_MODELS = frozen_specs(
    {
        "sparring-alpha-v1": DuoPolicySpec(
            SPAR_SCENARIO_ID,
            "sparring-alpha-visible-v1",
            "sparring-alpha-v1",
            "pressure",
        ),
        "sparring-bravo-v1": DuoPolicySpec(
            SPAR_SCENARIO_ID,
            "sparring-bravo-visible-v1",
            "sparring-bravo-v1",
            "counter-guard",
        ),
    }
)

_SPAR_FIELDS = frozenset(("completion_tick", "terminal_outcome", "terminal_reason", "participants"))


def build_spar_demo_provider(
    *,
    model: str,
    participant_id: str,
    seed: int,
    decision_budget: int,
    fixture_mode: DuoFixtureMode = "valid",
) -> DemoProvider:
    try:
        spec = SPAR_MODELS[model]
    except KeyError as error:
        raise ValueError("unsupported spar Demo model") from error
    return build_demo_provider(
        spec=spec,
        participant_id=participant_id,
        seed=seed,
        decision_budget=decision_budget,
        behavior=_spar_behavior,
        fixture_mode=fixture_mode,
    )


def _spar_behavior(request: ProviderRequest, lock: DemoPolicyLock, call_index: int) -> bytes:
    spec = SPAR_MODELS.get(request.model)
    if spec is None or lock.scenario_id != SPAR_SCENARIO_ID or lock.policy_id != spec.policy_id:
        raise ValueError("spar policy lock is incompatible")
    entities = parse_visible_observation(request)
    hostile = select_visible_entity(
        entities,
        kinds=("operator",),
        required_affordance="hostile",
        states=frozenset(("active", "guarding", "attacking", "staggered")),
    )
    if hostile is None:
        control = neutral_control()
        intent = "Demo: wait for a visible sparring rival"
    elif hostile["bearing"] != "front":
        control = move_or_turn_toward(hostile)
        intent = "Demo: face the visible sparring rival"
    elif hostile["distance"] in {"medium", "far"}:
        control = move_or_turn_toward(hostile)
        intent = "Demo: approach the visible sparring rival"
    elif spec.variant == "counter-guard" and hostile["state"] == "attacking":
        control = ControllerState(
            0,
            0,
            0,
            0,
            FIXED_DUO_WINDOW_TICKS,
            ControllerButtons(guard=True),
        )
        intent = "Demo: guard the visible attack"
    else:
        control = ControllerState(
            0,
            200,
            0,
            0,
            FIXED_DUO_WINDOW_TICKS,
            ControllerButtons(primary=True),
        )
        intent = "Demo: strike the visible sparring rival"
    return direct_action(
        request,
        call_index=call_index,
        action_prefix="spar",
        control=control,
        intent=intent,
    )


def evaluate_spar(authority_aggregates: Mapping[str, Any]) -> dict[str, Any]:
    """Project public combat totals without health, transforms, or opponent-private state."""

    if not isinstance(authority_aggregates, Mapping) or set(authority_aggregates) != _SPAR_FIELDS:
        raise ValueError("spar authority aggregates have invalid fields")
    completion_tick = validate_completion_tick(authority_aggregates["completion_tick"])
    summaries = validate_two_participant_summaries(
        authority_aggregates["participants"],
        extra_fields=frozenset(("hits_landed", "hits_received", "knockouts")),
    )
    terminal_outcome = authority_aggregates["terminal_outcome"]
    terminal_reason = authority_aggregates["terminal_reason"]
    validate_match_outcomes(summaries, terminal_outcome)
    if not isinstance(terminal_reason, str) or terminal_reason not in {
        "knockout",
        "time_limit",
        "simultaneous_terminal",
        "void",
    }:
        raise ValueError("spar terminal reason is invalid")
    if terminal_outcome == "win" and (terminal_reason != "knockout" or completion_tick is None):
        raise ValueError("winning spar completion is inconsistent")
    if terminal_outcome == "draw" and terminal_reason not in {
        "time_limit",
        "simultaneous_terminal",
    }:
        raise ValueError("drawn spar completion is inconsistent")
    if terminal_outcome == "void" and terminal_reason != "void":
        raise ValueError("void spar completion is inconsistent")
    if (
        summaries[0][1]["hits_landed"] != summaries[1][1]["hits_received"]
        or summaries[1][1]["hits_landed"] != summaries[0][1]["hits_received"]
    ):
        raise ValueError("spar hit totals are not authority-symmetric")
    knockouts = sum(summary["knockouts"] for _, summary in summaries)
    if any(summary["knockouts"] > 1 for _, summary in summaries):
        raise ValueError("participant knockout count exceeds one")
    if (terminal_reason == "knockout") != (knockouts == 1):
        raise ValueError("spar knockout totals differ from terminal reason")
    if terminal_reason == "knockout":
        winner = next(summary for _, summary in summaries if summary["outcome"] == "win")
        if winner["knockouts"] != 1:
            raise ValueError("spar knockout is not assigned to the winner")

    participants, symmetry = participant_window_projection(
        summaries, extra_fields=("hits_landed", "hits_received", "knockouts")
    )
    symmetry["hit_delta"] = abs(summaries[0][1]["hits_landed"] - summaries[1][1]["hits_landed"])
    return {
        "schema_version": "duo-spar-evaluation/1",
        "scope": "duo_game",
        "task_id": SPAR_SCENARIO_ID,
        "completion": {
            "tick": completion_tick,
            "outcome": terminal_outcome,
            "reason": terminal_reason,
        },
        "participants": participants,
        "symmetry": symmetry,
    }


__all__ = [
    "SPAR_MODELS",
    "SPAR_SCENARIO_ID",
    "build_spar_demo_provider",
    "evaluate_spar",
]
