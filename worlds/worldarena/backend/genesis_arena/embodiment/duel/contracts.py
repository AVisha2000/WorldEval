"""Immutable contracts for a symmetric two-leg model duel."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Literal, Tuple

from ..protocol import canonical_sha256, strict_json_loads
from ..series import SeriesLock

SpawnSide = Literal["south", "north"]
PairStatus = Literal["complete", "invalid"]
LegOutcome = Literal["win", "draw", "void"]

_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_EPISODE_ID = re.compile(r"^ep_[A-Za-z0-9._-]{1,120}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


def _identifier(name: str, value: object, *, episode: bool = False) -> None:
    pattern = _EPISODE_ID if episode else _ID
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise ValueError(f"{name} has an invalid format")


def _integer(name: str, value: object, minimum: int, maximum: int) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer from {minimum} to {maximum}")


def _digest(name: str, value: object) -> None:
    if not isinstance(value, str) or _SHA256.fullmatch(value) is None:
        raise ValueError(f"{name} must be a lowercase SHA-256")


@dataclass(frozen=True)
class DuelEntrant:
    """One provider/model identity locked for both legs."""

    entrant_id: str
    provider: str
    model: str

    def __post_init__(self) -> None:
        _identifier("entrant_id", self.entrant_id)
        _identifier("provider", self.provider)
        _identifier("model", self.model)

    def as_dict(self) -> dict[str, str]:
        return {
            "entrant_id": self.entrant_id,
            "provider": self.provider,
            "model": self.model,
        }


@dataclass(frozen=True)
class DuelCallSettings:
    """The equal inference envelope applied to both seats and both legs."""

    system_prompt: str
    action_schema_json: bytes
    timeout_ms: int
    max_input_bytes: int
    max_output_bytes: int

    def __post_init__(self) -> None:
        if not isinstance(self.system_prompt, str) or not self.system_prompt:
            raise ValueError("system_prompt is required")
        if not isinstance(self.action_schema_json, bytes):
            raise TypeError("action_schema_json must be immutable bytes")
        schema = strict_json_loads(self.action_schema_json)
        if not isinstance(schema, dict):
            raise ValueError("action_schema_json must contain an object")
        _integer("timeout_ms", self.timeout_ms, 1, 3_600_000)
        _integer("max_input_bytes", self.max_input_bytes, 1, 67_108_864)
        _integer("max_output_bytes", self.max_output_bytes, 1, 1_048_576)

    @property
    def action_schema_sha256(self) -> str:
        return canonical_sha256(strict_json_loads(self.action_schema_json))

    def as_dict(self) -> dict[str, Any]:
        return {
            "action_schema_sha256": self.action_schema_sha256,
            "max_input_bytes": self.max_input_bytes,
            "max_output_bytes": self.max_output_bytes,
            "system_prompt_sha256": canonical_sha256({"prompt": self.system_prompt}),
            "timeout_ms": self.timeout_ms,
        }


@dataclass(frozen=True)
class SeatAssignment:
    """Entrant placement and deterministic task-creation precedence for one leg."""

    entrant_id: str
    participant_id: Literal["participant_0", "participant_1"]
    spawn_side: SpawnSide
    dispatch_precedence: Literal[0, 1]

    def __post_init__(self) -> None:
        _identifier("entrant_id", self.entrant_id)
        if self.participant_id not in ("participant_0", "participant_1"):
            raise ValueError("participant_id must be a duel seat")
        if self.spawn_side not in ("south", "north"):
            raise ValueError("spawn_side must be south or north")
        _integer("dispatch_precedence", self.dispatch_precedence, 0, 1)

    def as_dict(self) -> dict[str, Any]:
        return {
            "dispatch_precedence": self.dispatch_precedence,
            "entrant_id": self.entrant_id,
            "participant_id": self.participant_id,
            "spawn_side": self.spawn_side,
        }


@dataclass(frozen=True)
class DuelLegPlan:
    """A fully bound authority leg; every seat-sensitive dimension is explicit."""

    series_id: str
    episode_id: str
    leg_index: Literal[0, 1]
    seed: int
    schedule_nonce: str
    fairness_lock_sha256: str
    assignments: Tuple[SeatAssignment, SeatAssignment]
    mode: Literal["scripted-duel-v0", "model-duel-v0"] = "model-duel-v0"
    decision_ticks: Literal[10] = 10

    def __post_init__(self) -> None:
        _identifier("series_id", self.series_id)
        _identifier("episode_id", self.episode_id, episode=True)
        _integer("leg_index", self.leg_index, 0, 1)
        _integer("seed", self.seed, 0, 9_007_199_254_740_991)
        _identifier("schedule_nonce", self.schedule_nonce)
        _digest("fairness_lock_sha256", self.fairness_lock_sha256)
        if not isinstance(self.assignments, tuple) or len(self.assignments) != 2:
            raise TypeError("assignments must be a two-item tuple")
        if any(not isinstance(value, SeatAssignment) for value in self.assignments):
            raise TypeError("assignments must contain SeatAssignment values")
        if {value.participant_id for value in self.assignments} != {
            "participant_0",
            "participant_1",
        }:
            raise ValueError("each participant seat must be assigned exactly once")
        if {value.spawn_side for value in self.assignments} != {"south", "north"}:
            raise ValueError("each spawn side must be assigned exactly once")
        if {value.dispatch_precedence for value in self.assignments} != {0, 1}:
            raise ValueError("dispatch precedence must be unique")
        if self.mode not in ("scripted-duel-v0", "model-duel-v0"):
            raise ValueError("duel leg mode is invalid")
        _integer("decision_ticks", self.decision_ticks, 10, 10)

    @property
    def plan_sha256(self) -> str:
        return canonical_sha256(self.as_dict())

    def as_dict(self) -> dict[str, Any]:
        return {
            "assignments": [value.as_dict() for value in self.assignments],
            "decision_ticks": self.decision_ticks,
            "episode_id": self.episode_id,
            "fairness_lock_sha256": self.fairness_lock_sha256,
            "leg_index": self.leg_index,
            "mode": self.mode,
            "schedule_nonce": self.schedule_nonce,
            "seed": self.seed,
            "series_id": self.series_id,
        }


@dataclass(frozen=True)
class PairedDuelPlan:
    """The immutable two-entrant series input from which both legs are derived."""

    series_id: str
    episode_ids: Tuple[str, str]
    entrants: Tuple[DuelEntrant, DuelEntrant]
    seed: int
    schedule_nonce: str
    settings: DuelCallSettings
    fairness_lock: SeriesLock
    max_live_provider_calls: int = 2160

    def __post_init__(self) -> None:
        _identifier("series_id", self.series_id)
        if not isinstance(self.episode_ids, tuple) or len(self.episode_ids) != 2:
            raise TypeError("episode_ids must be a two-item tuple")
        for episode_id in self.episode_ids:
            _identifier("episode_id", episode_id, episode=True)
        if self.episode_ids[0] == self.episode_ids[1]:
            raise ValueError("leg episode_ids must be distinct")
        if not isinstance(self.entrants, tuple) or len(self.entrants) != 2:
            raise TypeError("entrants must be a two-item tuple")
        if any(not isinstance(value, DuelEntrant) for value in self.entrants):
            raise TypeError("entrants must contain DuelEntrant values")
        if self.entrants[0].entrant_id == self.entrants[1].entrant_id:
            raise ValueError("entrant_id values must be distinct")
        _integer("seed", self.seed, 0, 9_007_199_254_740_991)
        _identifier("schedule_nonce", self.schedule_nonce)
        if not isinstance(self.settings, DuelCallSettings):
            raise TypeError("settings must be DuelCallSettings")
        if not isinstance(self.fairness_lock, SeriesLock):
            raise TypeError("fairness_lock must be SeriesLock")
        lock_entrants = tuple(
            (entrant.entrant_id, entrant.provider, entrant.model)
            for entrant in self.fairness_lock.entrants
        )
        plan_entrants = tuple(
            (entrant.entrant_id, entrant.provider, entrant.model) for entrant in self.entrants
        )
        if lock_entrants != plan_entrants:
            raise ValueError("fairness_lock entrants must exactly match the paired entrants")
        if self.fairness_lock.seed != self.seed:
            raise ValueError("fairness_lock seed must match the paired seed")
        if self.fairness_lock.schedule_nonce != self.schedule_nonce:
            raise ValueError("fairness_lock schedule_nonce must match the paired schedule")
        if self.fairness_lock.deadline_ms != self.settings.timeout_ms:
            raise ValueError("fairness_lock deadline must match the call settings")
        if self.fairness_lock.max_input_bytes != self.settings.max_input_bytes:
            raise ValueError("fairness_lock input ceiling must match the call settings")
        if self.fairness_lock.max_output_bytes != self.settings.max_output_bytes:
            raise ValueError("fairness_lock output ceiling must match the call settings")
        _integer("max_live_provider_calls", self.max_live_provider_calls, 1, 2160)

    @property
    def mode(self) -> Literal["scripted-duel-v0", "model-duel-v0"]:
        scripted = sum(entrant.provider == "scripted" for entrant in self.entrants)
        if scripted > 1:
            raise ValueError("a paired duel may contain at most one scripted entrant")
        return "scripted-duel-v0" if scripted == 1 else "model-duel-v0"

    @property
    def legs(self) -> Tuple[DuelLegPlan, DuelLegPlan]:
        first, second = self.entrants
        leg_a = DuelLegPlan(
            self.series_id,
            self.episode_ids[0],
            0,
            self.seed,
            self.schedule_nonce,
            self.fairness_lock.lock_sha256,
            (
                SeatAssignment(first.entrant_id, "participant_0", "south", 0),
                SeatAssignment(second.entrant_id, "participant_1", "north", 1),
            ),
            mode=self.mode,
        )
        leg_b = DuelLegPlan(
            self.series_id,
            self.episode_ids[1],
            1,
            self.seed,
            self.schedule_nonce,
            self.fairness_lock.lock_sha256,
            (
                SeatAssignment(second.entrant_id, "participant_0", "south", 0),
                SeatAssignment(first.entrant_id, "participant_1", "north", 1),
            ),
            mode=self.mode,
        )
        return leg_a, leg_b

    @property
    def plan_sha256(self) -> str:
        return canonical_sha256(
            {
                "fairness_lock": self.fairness_lock.as_dict(),
                "legs": [leg.as_dict() for leg in self.legs],
                "mode": self.mode,
                "max_live_provider_calls": self.max_live_provider_calls,
                "settings": self.settings.as_dict(),
            }
        )


@dataclass(frozen=True)
class DuelLegVerification:
    """Independent replay result returned by the injected authority session."""

    plan_sha256: str
    replay_sha256: str
    terminal_state_sha256: str
    complete: bool
    verified: bool
    outcome: LegOutcome
    winner_participant_id: Literal["participant_0", "participant_1"] | None = None

    def __post_init__(self) -> None:
        for name in ("plan_sha256", "replay_sha256", "terminal_state_sha256"):
            _digest(name, getattr(self, name))
        if not isinstance(self.complete, bool) or not isinstance(self.verified, bool):
            raise TypeError("verification flags must be booleans")
        if self.outcome not in ("win", "draw", "void"):
            raise ValueError("unsupported leg outcome")
        if self.outcome == "win":
            if self.winner_participant_id not in ("participant_0", "participant_1"):
                raise ValueError("winning leg must name one participant")
        elif self.winner_participant_id is not None:
            raise ValueError("draw and void legs cannot name a winner")


@dataclass(frozen=True)
class DuelLegResult:
    plan: DuelLegPlan
    verification: DuelLegVerification
    winner_entrant_id: str | None
    windows: int
    provider_failures: int

    def __post_init__(self) -> None:
        if not isinstance(self.plan, DuelLegPlan):
            raise TypeError("plan must be DuelLegPlan")
        if not isinstance(self.verification, DuelLegVerification):
            raise TypeError("verification must be DuelLegVerification")
        if self.verification.plan_sha256 != self.plan.plan_sha256:
            raise ValueError("verification does not belong to this leg plan")
        _integer("windows", self.windows, 0, 180)
        _integer("provider_failures", self.provider_failures, 0, 360)
        if self.verification.outcome == "win":
            _identifier("winner_entrant_id", self.winner_entrant_id)
            entrant_ids = {assignment.entrant_id for assignment in self.plan.assignments}
            if self.winner_entrant_id not in entrant_ids:
                raise ValueError("winner is not assigned to this leg")
        elif self.winner_entrant_id is not None:
            raise ValueError("non-winning leg cannot name an entrant winner")


@dataclass(frozen=True)
class PairedDuelResult:
    plan_sha256: str
    status: PairStatus
    legs: Tuple[DuelLegResult, DuelLegResult]
    entrant_wins: Tuple[int, int]
    draws: int
    winner_entrant_id: str | None
    rerun_required: bool

    def __post_init__(self) -> None:
        _digest("plan_sha256", self.plan_sha256)
        if self.status not in ("complete", "invalid"):
            raise ValueError("unsupported pair status")
        if not isinstance(self.legs, tuple) or len(self.legs) != 2:
            raise TypeError("legs must be a two-item tuple")
        if any(not isinstance(value, DuelLegResult) for value in self.legs):
            raise TypeError("legs must contain DuelLegResult values")
        if not isinstance(self.entrant_wins, tuple) or len(self.entrant_wins) != 2:
            raise TypeError("entrant_wins must be a two-item tuple")
        for wins in self.entrant_wins:
            _integer("entrant win count", wins, 0, 2)
        _integer("draws", self.draws, 0, 2)
        if not isinstance(self.rerun_required, bool):
            raise TypeError("rerun_required must be a boolean")
        if self.status == "invalid":
            if self.entrant_wins != (0, 0) or self.draws != 0:
                raise ValueError("invalid pairs cannot expose aggregate scores")
            if self.winner_entrant_id is not None or not self.rerun_required:
                raise ValueError("invalid pair result is inconsistent")
        elif self.rerun_required:
            raise ValueError("complete pair cannot require a rerun")


def aggregate_verified_pair(
    plan: PairedDuelPlan,
    legs: Tuple[DuelLegResult, DuelLegResult],
) -> PairedDuelResult:
    """Aggregate only the exact two complete, independently verified non-void legs."""

    if not isinstance(plan, PairedDuelPlan):
        raise TypeError("plan must be PairedDuelPlan")
    if not isinstance(legs, tuple) or len(legs) != 2:
        raise TypeError("legs must be a two-item tuple")
    expected = plan.legs
    if any(legs[index].plan != expected[index] for index in (0, 1)):
        raise ValueError("leg results do not match the paired schedule")
    valid = all(
        leg.verification.complete
        and leg.verification.verified
        and leg.verification.outcome != "void"
        for leg in legs
    )
    if not valid:
        return PairedDuelResult(plan.plan_sha256, "invalid", legs, (0, 0), 0, None, True)

    entrant_ids = (plan.entrants[0].entrant_id, plan.entrants[1].entrant_id)
    wins = [0, 0]
    draws = 0
    for leg in legs:
        if leg.verification.outcome == "draw":
            draws += 1
        else:
            assert leg.winner_entrant_id is not None
            wins[entrant_ids.index(leg.winner_entrant_id)] += 1
    winner = None
    if wins[0] != wins[1]:
        winner = entrant_ids[0] if wins[0] > wins[1] else entrant_ids[1]
    return PairedDuelResult(
        plan.plan_sha256,
        "complete",
        legs,
        (wins[0], wins[1]),
        draws,
        winner,
        False,
    )


__all__ = [
    "DuelCallSettings",
    "DuelEntrant",
    "DuelLegPlan",
    "DuelLegResult",
    "DuelLegVerification",
    "PairedDuelPlan",
    "PairedDuelResult",
    "SeatAssignment",
    "aggregate_verified_pair",
]
