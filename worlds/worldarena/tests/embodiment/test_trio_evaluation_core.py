from __future__ import annotations

import copy
import json

import pytest
from backend.genesis_arena.embodiment.trio_games.evaluation import (
    evaluate_trio_series,
    validate_public_trio_evaluation,
)
from backend.genesis_arena.embodiment.trio_games.scheduling import build_cyclic_trio_plan


def _summary(
    placement: int,
    *,
    objective: int,
    dealt: int,
    taken: int,
    calls: int,
    fallbacks: int,
    suppressed: int,
    eliminated_tick: int | None,
) -> dict[str, object]:
    return {
        "placement": placement,
        "objective_points": objective,
        "damage_dealt": dealt,
        "damage_taken": taken,
        "decision_windows": calls + suppressed,
        "fallback_windows": fallbacks,
        "provider_calls": calls,
        "suppressed_eliminated_calls": suppressed,
        "eliminated_tick": eliminated_tick,
    }


def _legs(task_id: str, *, reverse_dict_arrival: bool = False) -> list[dict[str, object]]:
    reason = "relay_hold" if task_id == "trio-relay-v0" else "last_standing"
    legs: list[dict[str, object]] = []
    for leg_index in range(3):
        values = [
            (
                "participant_0",
                _summary(
                    1,
                    objective=30 + leg_index,
                    dealt=12,
                    taken=3,
                    calls=10,
                    fallbacks=0,
                    suppressed=0,
                    eliminated_tick=None,
                ),
            ),
            (
                "participant_1",
                _summary(
                    2,
                    objective=20 + leg_index,
                    dealt=8,
                    taken=7,
                    calls=8,
                    fallbacks=1,
                    suppressed=2,
                    eliminated_tick=80,
                ),
            ),
            (
                "participant_2",
                _summary(
                    3,
                    objective=10 + leg_index,
                    dealt=4,
                    taken=14,
                    calls=5,
                    fallbacks=2,
                    suppressed=5,
                    eliminated_tick=50,
                ),
            ),
        ]
        if reverse_dict_arrival:
            values.reverse()
        participants = dict(values)
        leg_values = [
            ("leg_index", leg_index),
            ("completion_tick", 100 + leg_index),
            ("terminal_reason", reason),
            ("participants", participants),
        ]
        if reverse_dict_arrival:
            leg_values.reverse()
        legs.append(dict(leg_values))
    return legs


@pytest.mark.parametrize("task_id", ["trio-relay-v0", "trio-free-for-all-v0"])
def test_evaluation_is_repeatable_and_invariant_to_mapping_arrival_order(task_id: str) -> None:
    plan = build_cyclic_trio_plan(
        series_id="series_eval", task_id=task_id, seed=4, schedule_nonce="eval_nonce"
    )
    first = evaluate_trio_series(plan, _legs(task_id))
    second = evaluate_trio_series(plan, _legs(task_id, reverse_dict_arrival=True))
    assert first == second
    assert first["protocol_version"] == "llm-controller/0.3.0"
    assert first["series"]["seat_rotations_complete"] is True
    assert first["cyclic_normalization"]["each_entrant_uses_each_seat_once"] is True
    assert set(first["entrants"]) == {"sol", "luna", "terra"}
    assert all(
        value["normalized_per_leg"]["placement_milli"] == 2000
        for value in first["entrants"].values()
    )
    assert sum(
        value["reliability"]["stopped_calls_after_elimination"]
        for value in first["entrants"].values()
    ) == 21
    validate_public_trio_evaluation(first)


def test_typed_placement_groups_express_ties_with_competition_ranking() -> None:
    plan = build_cyclic_trio_plan(
        series_id="series_tie",
        task_id="trio-free-for-all-v0",
        seed=4,
        schedule_nonce="tie_nonce",
    )
    legs = _legs("trio-free-for-all-v0")
    for leg in legs:
        leg["participants"]["participant_1"]["placement"] = 1  # type: ignore[index]
    evaluation = evaluate_trio_series(plan, legs)
    assert evaluation["legs"][0]["placements"] == [
        {"entrant_ids": ["luna", "sol"], "placement": 1, "tied": True},
        {"entrant_ids": ["terra"], "placement": 3, "tied": False},
    ]


@pytest.mark.parametrize(
    "mutation, message",
    [
        (lambda legs: legs[0].update({"coordinates": [0, 0]}), "invalid fields"),
        (
            lambda legs: legs[0]["participants"]["participant_0"].update(  # type: ignore[index]
                {"fallback_windows": 11}
            ),
            "fallback windows exceed",
        ),
        (
            lambda legs: legs[0]["participants"]["participant_1"].update(  # type: ignore[index]
                {"decision_windows": 99}
            ),
            "decision accounting",
        ),
        (
            lambda legs: legs[0]["participants"]["participant_1"].update(  # type: ignore[index]
                {"placement": 3}
            ),
            "competition ranking",
        ),
        (
            lambda legs: legs[0]["participants"]["participant_0"].update(  # type: ignore[index]
                {"objective_points": True}
            ),
            "objective_points",
        ),
    ],
)
def test_authority_evaluation_input_is_strictly_allow_listed(mutation, message: str) -> None:
    plan = build_cyclic_trio_plan(
        series_id="series_strict",
        task_id="trio-relay-v0",
        seed=4,
        schedule_nonce="strict_nonce",
    )
    legs = _legs("trio-relay-v0")
    mutation(legs)
    with pytest.raises(ValueError, match=message):
        evaluate_trio_series(plan, legs)


def test_public_projection_contains_no_private_model_or_credential_material() -> None:
    plan = build_cyclic_trio_plan(
        series_id="series_privacy",
        task_id="trio-relay-v0",
        seed=4,
        schedule_nonce="privacy_nonce",
    )
    evaluation = evaluate_trio_series(plan, _legs("trio-relay-v0"))
    serialized = json.dumps(evaluation, sort_keys=True).casefold()
    for protected in (
        "coordinate",
        "credential",
        "api_key",
        "prompt",
        "raw_output",
        "raw_model_output",
        "spectator",
        "hidden_state",
    ):
        assert protected not in serialized

    malformed = copy.deepcopy(evaluation)
    malformed["prompt"] = "protected"
    with pytest.raises(ValueError, match="top-level fields"):
        validate_public_trio_evaluation(malformed)
