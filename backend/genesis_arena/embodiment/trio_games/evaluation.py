"""Authority-derived, allow-listed evaluation for three-leg trio series."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping, Sequence

from .common import PROTOCOL_VERSION, TRIO_PARTICIPANT_IDS
from .scheduling import TRIO_DEMO_ENTRANTS, TRIO_TASK_IDS, TrioSeriesPlan

_LEG_FIELDS = frozenset(("leg_index", "completion_tick", "terminal_reason", "participants"))
_PARTICIPANT_FIELDS = frozenset(
    (
        "placement",
        "objective_points",
        "damage_dealt",
        "damage_taken",
        "decision_windows",
        "fallback_windows",
        "provider_calls",
        "suppressed_eliminated_calls",
        "eliminated_tick",
    )
)
_TERMINAL_REASONS = {
    "trio-relay-v0": frozenset(
        ("relay_hold", "time_limit_ranking", "time_limit_tie", "void")
    ),
    "trio-free-for-all-v0": frozenset(
        (
            "last_standing",
            "simultaneous_knockout",
            "time_limit_ranking",
            "time_limit_tie",
            "void",
        )
    ),
}


@dataclass(frozen=True)
class PlacementGroup:
    """One competition-ranking group; multiple entrants explicitly represent a tie."""

    placement: int
    entrant_ids: tuple[str, ...]

    def __post_init__(self) -> None:
        _integer("placement", self.placement, 1, 3)
        if not isinstance(self.entrant_ids, tuple) or not self.entrant_ids:
            raise TypeError("entrant_ids must be a non-empty tuple")
        if len(self.entrant_ids) != len(set(self.entrant_ids)):
            raise ValueError("placement group entrants must be unique")
        known = {value.entrant_id for value in TRIO_DEMO_ENTRANTS}
        if any(value not in known for value in self.entrant_ids):
            raise ValueError("placement group contains an unknown entrant")

    @property
    def tied(self) -> bool:
        return len(self.entrant_ids) > 1

    def as_dict(self) -> dict[str, Any]:
        return {
            "entrant_ids": list(self.entrant_ids),
            "placement": self.placement,
            "tied": self.tied,
        }


def evaluate_trio_series(
    plan: TrioSeriesPlan, authority_legs: Sequence[Mapping[str, Any]]
) -> dict[str, Any]:
    """Project exact authority aggregates without accepting private state or model material."""

    if not isinstance(plan, TrioSeriesPlan):
        raise TypeError("plan must be a TrioSeriesPlan")
    if plan.task_id not in TRIO_TASK_IDS:
        raise ValueError("unsupported trio evaluation task")
    if not isinstance(authority_legs, (list, tuple)) or len(authority_legs) != 3:
        raise ValueError("trio evaluation requires exactly three authority legs")

    entrant_totals = {
        entrant.entrant_id: {
            "damage_dealt": 0,
            "damage_taken": 0,
            "decision_windows": 0,
            "fallback_windows": 0,
            "objective_points": 0,
            "provider_calls": 0,
            "suppressed_eliminated_calls": 0,
            "placement_sum": 0,
        }
        for entrant in TRIO_DEMO_ENTRANTS
    }
    seat_totals = {
        participant_id: {
            "damage_dealt": 0,
            "objective_points": 0,
            "fallback_windows": 0,
        }
        for participant_id in TRIO_PARTICIPANT_IDS
    }
    projected_legs: list[dict[str, Any]] = []

    for expected_leg, authority_leg in zip(plan.legs, authority_legs):
        if not isinstance(authority_leg, Mapping) or set(authority_leg) != _LEG_FIELDS:
            raise ValueError("trio authority leg has invalid fields")
        if authority_leg["leg_index"] != expected_leg.leg_index:
            raise ValueError("trio authority leg order differs from the locked plan")
        completion_tick = authority_leg["completion_tick"]
        if completion_tick is not None:
            _integer("completion_tick", completion_tick, 0, 9_007_199_254_740_991)
        terminal_reason = authority_leg["terminal_reason"]
        if terminal_reason not in _TERMINAL_REASONS[plan.task_id]:
            raise ValueError("trio terminal reason is invalid")
        if terminal_reason == "void" and completion_tick is not None:
            raise ValueError("void trio leg cannot have a completion tick")
        if terminal_reason != "void" and completion_tick is None:
            raise ValueError("completed trio leg requires a completion tick")

        summaries = _participant_summaries(authority_leg["participants"])
        entrant_by_seat = {
            assignment.participant_id: assignment.entrant_id
            for assignment in expected_leg.assignments
        }
        groups = _placement_groups(
            {
                entrant_by_seat[participant_id]: summary["placement"]
                for participant_id, summary in summaries
            }
        )
        participants: dict[str, Any] = {}
        for participant_id, summary in summaries:
            entrant_id = entrant_by_seat[participant_id]
            decisions = summary["decision_windows"]
            fallbacks = summary["fallback_windows"]
            provider_calls = summary["provider_calls"]
            suppressed = summary["suppressed_eliminated_calls"]
            participants[participant_id] = {
                "damage_dealt": summary["damage_dealt"],
                "damage_taken": summary["damage_taken"],
                "decision_windows": decisions,
                "eliminated": summary["eliminated_tick"] is not None,
                "eliminated_tick": summary["eliminated_tick"],
                "entrant_id": entrant_id,
                "fallback_windows": fallbacks,
                "objective_points": summary["objective_points"],
                "placement": summary["placement"],
                "provider_calls": provider_calls,
                "reliability_per_mille": (
                    1000
                    if decisions == suppressed
                    else (decisions - suppressed - fallbacks)
                    * 1000
                    // (decisions - suppressed)
                ),
                "suppressed_eliminated_calls": suppressed,
            }
            totals = entrant_totals[entrant_id]
            for field in (
                "damage_dealt",
                "damage_taken",
                "decision_windows",
                "fallback_windows",
                "objective_points",
                "provider_calls",
                "suppressed_eliminated_calls",
            ):
                totals[field] += summary[field]
            totals["placement_sum"] += summary["placement"]
            seat_totals[participant_id]["damage_dealt"] += summary["damage_dealt"]
            seat_totals[participant_id]["objective_points"] += summary["objective_points"]
            seat_totals[participant_id]["fallback_windows"] += fallbacks

        projected_legs.append(
            {
                "completion_tick": completion_tick,
                "leg_index": expected_leg.leg_index,
                "participants": participants,
                "placements": [value.as_dict() for value in groups],
                "terminal_reason": terminal_reason,
            }
        )

    entrants: dict[str, Any] = {}
    for entrant in TRIO_DEMO_ENTRANTS:
        totals = entrant_totals[entrant.entrant_id]
        provider_calls = totals["provider_calls"]
        active_windows = (
            totals["decision_windows"] - totals["suppressed_eliminated_calls"]
        )
        entrants[entrant.entrant_id] = {
            "damage": {
                "dealt": totals["damage_dealt"],
                "taken": totals["damage_taken"],
            },
            "display_name": entrant.display_name,
            "normalized_per_leg": {
                "damage_dealt": totals["damage_dealt"] // 3,
                "damage_taken": totals["damage_taken"] // 3,
                "objective_points": totals["objective_points"] // 3,
                "placement_milli": totals["placement_sum"] * 1000 // 3,
            },
            "objective_points": totals["objective_points"],
            "reliability": {
                "decision_windows": totals["decision_windows"],
                "fallback_ratio_per_mille": (
                    0
                    if active_windows == 0
                    else totals["fallback_windows"] * 1000 // active_windows
                ),
                "fallback_windows": totals["fallback_windows"],
                "provider_calls": provider_calls,
                "stopped_calls_after_elimination": totals[
                    "suppressed_eliminated_calls"
                ],
            },
        }

    evaluation = {
        "schema_version": "trio-game-series-evaluation/1",
        "scope": "trio_game_series",
        "protocol_version": PROTOCOL_VERSION,
        "task_id": plan.task_id,
        "series": {
            "leg_count": 3,
            "plan_sha256": plan.plan_sha256,
            "seat_rotations_complete": True,
        },
        "legs": projected_legs,
        "entrants": entrants,
        "cyclic_normalization": {
            "each_entrant_uses_each_seat_once": True,
            "seat_aggregate_ranges": {
                field: _range([seat_totals[seat][field] for seat in TRIO_PARTICIPANT_IDS])
                for field in ("damage_dealt", "fallback_windows", "objective_points")
            },
            "seat_totals": seat_totals,
        },
    }
    validate_public_trio_evaluation(evaluation)
    return evaluation


def validate_public_trio_evaluation(value: Mapping[str, Any]) -> None:
    """Strict output allowlist used by integration code before browser projection."""

    if not isinstance(value, Mapping) or set(value) != {
        "schema_version",
        "scope",
        "protocol_version",
        "task_id",
        "series",
        "legs",
        "entrants",
        "cyclic_normalization",
    }:
        raise ValueError("public trio evaluation has invalid top-level fields")
    if set(value["series"]) != {"leg_count", "plan_sha256", "seat_rotations_complete"}:
        raise ValueError("public trio series fields are invalid")
    if set(value["entrants"]) != {entrant.entrant_id for entrant in TRIO_DEMO_ENTRANTS}:
        raise ValueError("public trio entrant fields are invalid")
    for entrant in value["entrants"].values():
        if set(entrant) != {
            "damage",
            "display_name",
            "normalized_per_leg",
            "objective_points",
            "reliability",
        }:
            raise ValueError("public trio entrant projection is invalid")
        if set(entrant["damage"]) != {"dealt", "taken"} or set(
            entrant["normalized_per_leg"]
        ) != {"damage_dealt", "damage_taken", "objective_points", "placement_milli"}:
            raise ValueError("public trio aggregate projection is invalid")
        if set(entrant["reliability"]) != {
            "decision_windows",
            "fallback_ratio_per_mille",
            "fallback_windows",
            "provider_calls",
            "stopped_calls_after_elimination",
        }:
            raise ValueError("public trio reliability projection is invalid")
    cyclic = value["cyclic_normalization"]
    if set(cyclic) != {
        "each_entrant_uses_each_seat_once",
        "seat_aggregate_ranges",
        "seat_totals",
    }:
        raise ValueError("public trio cyclic normalization is invalid")
    if set(cyclic["seat_totals"]) != set(TRIO_PARTICIPANT_IDS):
        raise ValueError("public trio seat totals are incomplete")
    if set(cyclic["seat_aggregate_ranges"]) != {
        "damage_dealt",
        "fallback_windows",
        "objective_points",
    }:
        raise ValueError("public trio seat ranges are invalid")
    for leg in value["legs"]:
        if set(leg) != {
            "completion_tick",
            "leg_index",
            "participants",
            "placements",
            "terminal_reason",
        }:
            raise ValueError("public trio leg projection is invalid")
        if set(leg["participants"]) != set(TRIO_PARTICIPANT_IDS):
            raise ValueError("public trio leg participant projection is incomplete")
        for participant in leg["participants"].values():
            if set(participant) != {
                "damage_dealt",
                "damage_taken",
                "decision_windows",
                "eliminated",
                "eliminated_tick",
                "entrant_id",
                "fallback_windows",
                "objective_points",
                "placement",
                "provider_calls",
                "reliability_per_mille",
                "suppressed_eliminated_calls",
            }:
                raise ValueError("public trio participant projection is invalid")
        for group in leg["placements"]:
            if set(group) != {"entrant_ids", "placement", "tied"}:
                raise ValueError("public trio placement projection is invalid")


def _participant_summaries(
    value: object,
) -> tuple[tuple[str, Mapping[str, Any]], ...]:
    if not isinstance(value, Mapping) or set(value) != set(TRIO_PARTICIPANT_IDS):
        raise ValueError("trio authority participants must contain exactly three seats")
    values: list[tuple[str, Mapping[str, Any]]] = []
    for participant_id in TRIO_PARTICIPANT_IDS:
        summary = value[participant_id]
        if not isinstance(summary, Mapping) or set(summary) != _PARTICIPANT_FIELDS:
            raise ValueError("trio participant authority aggregate has invalid fields")
        for name in (
            "placement",
            "objective_points",
            "damage_dealt",
            "damage_taken",
            "decision_windows",
            "fallback_windows",
            "provider_calls",
            "suppressed_eliminated_calls",
        ):
            maximum = 3 if name == "placement" else 9_007_199_254_740_991
            minimum = 1 if name == "placement" else 0
            _integer(name, summary[name], minimum, maximum)
        eliminated_tick = summary["eliminated_tick"]
        if eliminated_tick is not None:
            _integer("eliminated_tick", eliminated_tick, 0, 9_007_199_254_740_991)
        active_windows = summary["decision_windows"] - summary[
            "suppressed_eliminated_calls"
        ]
        if active_windows < 0 or summary["fallback_windows"] > active_windows:
            raise ValueError("fallback windows exceed active decision windows")
        uncalled_active = active_windows - summary["provider_calls"]
        if uncalled_active < 0 or uncalled_active > summary["fallback_windows"]:
            raise ValueError("decision accounting is inconsistent")
        if summary["suppressed_eliminated_calls"] and eliminated_tick is None:
            raise ValueError("suppressed calls require an eliminated participant")
        values.append((participant_id, summary))
    _validate_competition_ranking(
        {participant_id: summary["placement"] for participant_id, summary in values}
    )
    return tuple(values)


def _placement_groups(placements: Mapping[str, int]) -> tuple[PlacementGroup, ...]:
    _validate_competition_ranking(placements)
    grouped: dict[int, list[str]] = {}
    for entrant_id, placement in placements.items():
        grouped.setdefault(placement, []).append(entrant_id)
    ordered = sorted(grouped.items())
    groups: list[PlacementGroup] = []
    for placement, entrant_ids in ordered:
        group = PlacementGroup(placement, tuple(sorted(entrant_ids)))
        groups.append(group)
    if sum(len(group.entrant_ids) for group in groups) != 3:
        raise ValueError("placements do not cover exactly three entrants")
    return tuple(groups)


def _validate_competition_ranking(placements: Mapping[str, int]) -> None:
    grouped: dict[int, int] = {}
    for placement in placements.values():
        grouped[placement] = grouped.get(placement, 0) + 1
    expected_placement = 1
    for placement, count in sorted(grouped.items()):
        if placement != expected_placement:
            raise ValueError("placements do not use competition ranking")
        expected_placement += count
    if sum(grouped.values()) != 3:
        raise ValueError("placements do not cover exactly three participants")


def _range(values: Sequence[int]) -> int:
    return max(values) - min(values)


def _integer(name: str, value: object, minimum: int, maximum: int) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer from {minimum} to {maximum}")


__all__ = [
    "PlacementGroup",
    "evaluate_trio_series",
    "validate_public_trio_evaluation",
]
