"""Deterministic three-leg cyclic scheduling for the trio prototype."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Literal

from ..protocol import canonical_sha256
from .common import PROTOCOL_VERSION, TRIO_PARTICIPANT_IDS

TrioTaskId = Literal["trio-relay-v0", "trio-free-for-all-v0"]

TRIO_TASK_IDS = frozenset(("trio-relay-v0", "trio-free-for-all-v0"))
TRIO_SPAWN_SLOTS = ("south", "northwest", "northeast")
_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_EPISODE_ID = re.compile(r"^ep_[A-Za-z0-9._-]{1,120}$")


@dataclass(frozen=True)
class TrioEntrant:
    entrant_id: str
    display_name: Literal["Sol", "Luna", "Terra"]
    model: Literal["demo-sol-v1", "demo-luna-v1", "demo-terra-v1"]
    policy_id: str
    policy_version: Literal["1.0.0"] = "1.0.0"
    provider: Literal["demo"] = "demo"

    def __post_init__(self) -> None:
        for name in ("entrant_id", "model", "policy_id"):
            value = getattr(self, name)
            if not isinstance(value, str) or _SAFE_ID.fullmatch(value) is None:
                raise ValueError(f"{name} is invalid")
        expected = {
            "Sol": "demo-sol-v1",
            "Luna": "demo-luna-v1",
            "Terra": "demo-terra-v1",
        }
        if expected.get(self.display_name) != self.model:
            raise ValueError("display_name and demo model identity differ")

    def as_dict(self) -> dict[str, str]:
        return {
            "display_name": self.display_name,
            "entrant_id": self.entrant_id,
            "model": self.model,
            "policy_id": self.policy_id,
            "policy_version": self.policy_version,
            "provider": self.provider,
        }


TRIO_DEMO_ENTRANTS = (
    TrioEntrant("sol", "Sol", "demo-sol-v1", "sol-visible-controller-v1"),
    TrioEntrant("luna", "Luna", "demo-luna-v1", "luna-visible-controller-v1"),
    TrioEntrant("terra", "Terra", "demo-terra-v1", "terra-visible-controller-v1"),
)


@dataclass(frozen=True)
class TrioSeatAssignment:
    entrant_id: str
    participant_id: str
    spawn_slot: str
    dispatch_precedence: int

    def __post_init__(self) -> None:
        if self.entrant_id not in {entrant.entrant_id for entrant in TRIO_DEMO_ENTRANTS}:
            raise ValueError("unknown trio entrant")
        if self.participant_id not in TRIO_PARTICIPANT_IDS:
            raise ValueError("unknown trio participant seat")
        if self.spawn_slot not in TRIO_SPAWN_SLOTS:
            raise ValueError("unknown trio spawn slot")
        _integer("dispatch_precedence", self.dispatch_precedence, 0, 2)

    def as_dict(self) -> dict[str, str | int]:
        return {
            "dispatch_precedence": self.dispatch_precedence,
            "entrant_id": self.entrant_id,
            "participant_id": self.participant_id,
            "spawn_slot": self.spawn_slot,
        }


@dataclass(frozen=True)
class TrioLegPlan:
    series_id: str
    episode_id: str
    task_id: TrioTaskId
    leg_index: int
    seed: int
    schedule_nonce: str
    assignments: tuple[TrioSeatAssignment, TrioSeatAssignment, TrioSeatAssignment]
    protocol_version: Literal["llm-controller/0.3.0"] = PROTOCOL_VERSION
    decision_ticks: Literal[10] = 10

    def __post_init__(self) -> None:
        for name in ("series_id", "schedule_nonce"):
            value = getattr(self, name)
            if not isinstance(value, str) or _SAFE_ID.fullmatch(value) is None:
                raise ValueError(f"{name} is invalid")
        if not isinstance(self.episode_id, str) or _EPISODE_ID.fullmatch(self.episode_id) is None:
            raise ValueError("episode_id is invalid")
        if self.task_id not in TRIO_TASK_IDS:
            raise ValueError("unsupported trio task")
        _integer("leg_index", self.leg_index, 0, 2)
        _integer("seed", self.seed, 0, 9_007_199_254_740_991)
        if self.protocol_version != PROTOCOL_VERSION or self.decision_ticks != 10:
            raise ValueError("trio timing/protocol lock is invalid")
        if not isinstance(self.assignments, tuple) or len(self.assignments) != 3:
            raise TypeError("assignments must be an exact three-item tuple")
        if any(not isinstance(value, TrioSeatAssignment) for value in self.assignments):
            raise TypeError("assignments must contain TrioSeatAssignment values")
        if {value.entrant_id for value in self.assignments} != {
            entrant.entrant_id for entrant in TRIO_DEMO_ENTRANTS
        }:
            raise ValueError("every entrant must be assigned exactly once")
        if {value.participant_id for value in self.assignments} != set(TRIO_PARTICIPANT_IDS):
            raise ValueError("every participant seat must be assigned exactly once")
        if {value.spawn_slot for value in self.assignments} != set(TRIO_SPAWN_SLOTS):
            raise ValueError("every spawn slot must be assigned exactly once")
        if {value.dispatch_precedence for value in self.assignments} != {0, 1, 2}:
            raise ValueError("dispatch precedence must cover all participants")

    @property
    def plan_sha256(self) -> str:
        return canonical_sha256(self.as_dict())

    def as_dict(self) -> dict[str, Any]:
        return {
            "assignments": [value.as_dict() for value in self.assignments],
            "decision_ticks": self.decision_ticks,
            "episode_id": self.episode_id,
            "leg_index": self.leg_index,
            "protocol_version": self.protocol_version,
            "schedule_nonce": self.schedule_nonce,
            "seed": self.seed,
            "series_id": self.series_id,
            "task_id": self.task_id,
        }


@dataclass(frozen=True)
class TrioSeriesPlan:
    series_id: str
    task_id: TrioTaskId
    seed: int
    schedule_nonce: str
    legs: tuple[TrioLegPlan, TrioLegPlan, TrioLegPlan]

    def __post_init__(self) -> None:
        if not isinstance(self.legs, tuple) or len(self.legs) != 3:
            raise TypeError("trio series must contain exactly three legs")
        if any(not isinstance(value, TrioLegPlan) for value in self.legs):
            raise TypeError("legs must contain TrioLegPlan values")
        if tuple(value.leg_index for value in self.legs) != (0, 1, 2):
            raise ValueError("trio leg order must be canonical")
        if any(
            value.series_id != self.series_id
            or value.task_id != self.task_id
            or value.seed != self.seed
            or value.schedule_nonce != self.schedule_nonce
            for value in self.legs
        ):
            raise ValueError("trio leg does not match its series lock")
        if len({value.episode_id for value in self.legs}) != 3:
            raise ValueError("trio leg episode IDs must be unique")
        for entrant in TRIO_DEMO_ENTRANTS:
            seats = {
                assignment.participant_id
                for leg in self.legs
                for assignment in leg.assignments
                if assignment.entrant_id == entrant.entrant_id
            }
            spawns = {
                assignment.spawn_slot
                for leg in self.legs
                for assignment in leg.assignments
                if assignment.entrant_id == entrant.entrant_id
            }
            if seats != set(TRIO_PARTICIPANT_IDS) or spawns != set(TRIO_SPAWN_SLOTS):
                raise ValueError("cyclic schedule does not cover every seat and spawn")

    @property
    def plan_sha256(self) -> str:
        return canonical_sha256(self.as_dict())

    def as_dict(self) -> dict[str, Any]:
        return {
            "entrants": [value.as_dict() for value in TRIO_DEMO_ENTRANTS],
            "legs": [value.as_dict() for value in self.legs],
            "schedule_nonce": self.schedule_nonce,
            "seed": self.seed,
            "series_id": self.series_id,
            "task_id": self.task_id,
        }


def build_cyclic_trio_plan(
    *,
    series_id: str,
    task_id: TrioTaskId,
    seed: int,
    schedule_nonce: str,
) -> TrioSeriesPlan:
    """Give every entrant every participant seat and spawn exactly once."""

    if not isinstance(series_id, str) or len(series_id) > 114:
        raise ValueError("series_id is too long for versioned trio episode identities")
    entrant_ids = tuple(value.entrant_id for value in TRIO_DEMO_ENTRANTS)
    legs: list[TrioLegPlan] = []
    for leg_index in range(3):
        assignments = tuple(
            TrioSeatAssignment(
                entrant_id=entrant_ids[(seat_index - leg_index) % 3],
                participant_id=TRIO_PARTICIPANT_IDS[seat_index],
                spawn_slot=TRIO_SPAWN_SLOTS[seat_index],
                dispatch_precedence=(seat_index + leg_index) % 3,
            )
            for seat_index in range(3)
        )
        legs.append(
            TrioLegPlan(
                series_id=series_id,
                episode_id=f"ep_{series_id}_leg_{leg_index}",
                task_id=task_id,
                leg_index=leg_index,
                seed=seed,
                schedule_nonce=schedule_nonce,
                assignments=assignments,  # type: ignore[arg-type]
            )
        )
    return TrioSeriesPlan(series_id, task_id, seed, schedule_nonce, tuple(legs))  # type: ignore[arg-type]


def _integer(name: str, value: object, minimum: int, maximum: int) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer from {minimum} to {maximum}")


__all__ = [
    "TRIO_DEMO_ENTRANTS",
    "TRIO_SPAWN_SLOTS",
    "TRIO_TASK_IDS",
    "TrioEntrant",
    "TrioLegPlan",
    "TrioSeatAssignment",
    "TrioSeriesPlan",
    "TrioTaskId",
    "build_cyclic_trio_plan",
]
