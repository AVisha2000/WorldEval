"""Safe authority-derived aggregates for ``operator-action-course-v0``."""

from __future__ import annotations

from typing import Any, Mapping

STATION_IDS = (
    "walk",
    "turn",
    "gather",
    "carry",
    "deposit",
    "build",
    "dash",
    "guard",
    "primary",
    "cancel",
    "hazard",
    "celebrate",
)
_FIELDS = frozenset(
    {
        "stations_completed",
        "stations_total",
        "station_passes",
        "command_attempts",
        "command_successes",
        "invalid_windows",
        "damage_taken",
        "travelled_distance_mt",
        "terminal_outcome",
        "terminal_reason",
    }
)


def evaluate_operator_action_course(authority_aggregates: Mapping[str, Any]) -> dict[str, Any]:
    """Return an allow-listed station matrix with no transforms or private state."""

    if not isinstance(authority_aggregates, Mapping) or set(authority_aggregates) != _FIELDS:
        raise ValueError("operator-action authority aggregates have invalid fields")
    integer_fields = (
        "stations_completed",
        "stations_total",
        "command_attempts",
        "command_successes",
        "invalid_windows",
        "damage_taken",
        "travelled_distance_mt",
    )
    for field in integer_fields:
        value = authority_aggregates[field]
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"{field} must be a non-negative integer")
    station_passes = authority_aggregates["station_passes"]
    if (
        not isinstance(station_passes, Mapping)
        or set(station_passes) != set(STATION_IDS)
        or any(not isinstance(value, bool) for value in station_passes.values())
    ):
        raise ValueError("station_passes must contain the exact ordered boolean matrix")
    attempts = authority_aggregates["command_attempts"]
    successes = authority_aggregates["command_successes"]
    if successes > attempts:
        raise ValueError("command successes exceed attempts")
    if authority_aggregates["stations_total"] != len(STATION_IDS):
        raise ValueError("station total does not match evaluator version")
    if authority_aggregates["stations_completed"] > len(STATION_IDS):
        raise ValueError("stations completed exceeds station total")
    if authority_aggregates["terminal_outcome"] not in {"success", "failure"}:
        raise ValueError("terminal outcome is invalid")
    if authority_aggregates["terminal_reason"] not in {"course_complete", "time_limit"}:
        raise ValueError("terminal reason is invalid")

    accuracy = (
        {"supported": False, "ratio_per_mille": None, "reason": "no_commands_recorded"}
        if attempts == 0
        else {
            "supported": True,
            "ratio_per_mille": successes * 1000 // attempts,
            "reason": None,
        }
    )
    return {
        "schema_version": "operator-action-course-evaluation/1",
        "scope": "solo_control_game",
        "task_id": "operator-action-course-v0",
        "metrics": {
            "stations": {station: station_passes[station] for station in STATION_IDS},
            "stations_completed": authority_aggregates["stations_completed"],
            "stations_total": authority_aggregates["stations_total"],
            "control_accuracy": accuracy,
            "invalid_windows": authority_aggregates["invalid_windows"],
            "damage_taken": authority_aggregates["damage_taken"],
            "travelled_distance_mt": authority_aggregates["travelled_distance_mt"],
        },
    }


__all__ = ["STATION_IDS", "evaluate_operator_action_course"]
