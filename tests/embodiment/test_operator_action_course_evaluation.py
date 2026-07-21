from __future__ import annotations

import pytest
from genesis_arena.embodiment.control_games.operator_action_course_evaluation import (
    STATION_IDS,
    evaluate_operator_action_course,
)


def _aggregates(**updates: object) -> dict[str, object]:
    value: dict[str, object] = {
        "stations_completed": 12,
        "stations_total": 12,
        "station_passes": {station: True for station in STATION_IDS},
        "command_attempts": 15,
        "command_successes": 12,
        "invalid_windows": 1,
        "damage_taken": 200,
        "travelled_distance_mt": 4000,
        "terminal_outcome": "success",
        "terminal_reason": "course_complete",
    }
    value.update(updates)
    return value


def test_evaluator_projects_safe_control_matrix_and_aggregates() -> None:
    result = evaluate_operator_action_course(_aggregates())

    assert result["metrics"] == {
        "stations": {station: True for station in STATION_IDS},
        "stations_completed": 12,
        "stations_total": 12,
        "control_accuracy": {
            "supported": True,
            "ratio_per_mille": 800,
            "reason": None,
        },
        "invalid_windows": 1,
        "damage_taken": 200,
        "travelled_distance_mt": 4000,
    }
    serialized = repr(result).casefold()
    for forbidden in ("position", "heading", "active_interaction", "checkpoint_hash"):
        assert forbidden not in serialized


def test_evaluator_reports_unsupported_accuracy_without_commands() -> None:
    result = evaluate_operator_action_course(
        _aggregates(command_attempts=0, command_successes=0)
    )

    assert result["metrics"]["control_accuracy"] == {
        "supported": False,
        "ratio_per_mille": None,
        "reason": "no_commands_recorded",
    }


@pytest.mark.parametrize(
    "value",
    (
        _aggregates(position_mt={"x": 0, "y": 0}),
        _aggregates(damage_taken=True),
        _aggregates(command_attempts=1, command_successes=2),
        _aggregates(station_passes={"walk": True}),
        _aggregates(stations_total=11),
    ),
)
def test_evaluator_rejects_hidden_or_malformed_aggregates(value) -> None:
    with pytest.raises(ValueError):
        evaluate_operator_action_course(value)
