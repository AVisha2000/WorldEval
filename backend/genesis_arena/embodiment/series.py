"""Immutable locks, symmetric schedules, and verified paired-duel aggregation."""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, replace
from typing import Any, Dict, Literal, Tuple

from .protocol import canonical_sha256

LegOutcome = Literal["win", "draw", "void"]
PairStatus = Literal["complete", "invalid"]

_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$")
_NONCE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_MAX_INTEGER = 9_007_199_254_740_991


def _integer(name: str, value: object, minimum: int, maximum: int) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer from {minimum} to {maximum}")


def _string(name: str, value: object, pattern: re.Pattern[str] = _IDENTIFIER) -> None:
    if not isinstance(value, str):
        raise TypeError(f"{name} must be a string")
    if unicodedata.normalize("NFC", value) != value or pattern.fullmatch(value) is None:
        raise ValueError(f"{name} has an invalid format")


def _digest(name: str, value: object) -> None:
    if not isinstance(value, str) or _SHA256.fullmatch(value) is None:
        raise ValueError(f"{name} must be a lowercase SHA-256 digest")


@dataclass(frozen=True)
class ModelLock:
    """Provider-specific identity and inference settings for one series entrant."""

    entrant_id: str
    provider: str
    adapter_sha256: str
    model: str
    reasoning: str

    def __post_init__(self) -> None:
        for name in ("entrant_id", "provider", "model", "reasoning"):
            _string(name, getattr(self, name))
        _digest("adapter_sha256", self.adapter_sha256)

    def as_dict(self) -> Dict[str, str]:
        return {
            "adapter_sha256": self.adapter_sha256,
            "entrant_id": self.entrant_id,
            "model": self.model,
            "provider": self.provider,
            "reasoning": self.reasoning,
        }


@dataclass(frozen=True)
class SeriesLock:
    """Every fairness-sensitive input frozen before either leg is reset."""

    protocol_version: str
    protocol_sha256: str
    rules_sha256: str
    map_sha256: str
    body_sha256: str
    controller_sha256: str
    projector_sha256: str
    evaluator_sha256: str
    entrants: Tuple[ModelLock, ModelLock]
    max_input_bytes: int
    max_output_bytes: int
    deadline_ms: int
    observation_profile: str
    timing_track: str
    seed: int
    schedule_nonce: str

    def __post_init__(self) -> None:
        if self.protocol_version != "llm-controller/0.1.0":
            raise ValueError("unsupported protocol_version")
        for name in (
            "protocol_sha256",
            "rules_sha256",
            "map_sha256",
            "body_sha256",
            "controller_sha256",
            "projector_sha256",
            "evaluator_sha256",
        ):
            _digest(name, getattr(self, name))
        if not isinstance(self.entrants, tuple) or len(self.entrants) != 2:
            raise TypeError("entrants must be a two-item tuple")
        if any(not isinstance(entrant, ModelLock) for entrant in self.entrants):
            raise TypeError("entrants must contain ModelLock values")
        if self.entrants[0].entrant_id == self.entrants[1].entrant_id:
            raise ValueError("entrant_id values must be distinct")
        _integer("max_input_bytes", self.max_input_bytes, 1, 67_108_864)
        _integer("max_output_bytes", self.max_output_bytes, 1, 1_048_576)
        _integer("deadline_ms", self.deadline_ms, 1, 3_600_000)
        if self.observation_profile != "hybrid-visible-v1":
            raise ValueError("scored series require hybrid-visible-v1")
        if self.timing_track != "step-locked-v1":
            raise ValueError("scored series require step-locked-v1")
        _integer("seed", self.seed, 0, _MAX_INTEGER)
        _string("schedule_nonce", self.schedule_nonce, _NONCE)

    def as_dict(self) -> Dict[str, Any]:
        return {
            "body_sha256": self.body_sha256,
            "controller_sha256": self.controller_sha256,
            "deadline_ms": self.deadline_ms,
            "entrants": [entrant.as_dict() for entrant in self.entrants],
            "evaluator_sha256": self.evaluator_sha256,
            "map_sha256": self.map_sha256,
            "max_input_bytes": self.max_input_bytes,
            "max_output_bytes": self.max_output_bytes,
            "observation_profile": self.observation_profile,
            "projector_sha256": self.projector_sha256,
            "protocol_sha256": self.protocol_sha256,
            "protocol_version": self.protocol_version,
            "rules_sha256": self.rules_sha256,
            "schedule_nonce": self.schedule_nonce,
            "seed": self.seed,
            "timing_track": self.timing_track,
        }

    @property
    def lock_sha256(self) -> str:
        return canonical_sha256(self.as_dict())


@dataclass(frozen=True)
class SeatAssignment:
    entrant_id: str
    participant_id: Literal["participant_0", "participant_1"]
    spawn_side: Literal["south", "north"]
    dispatch_precedence: Literal[0, 1]

    def __post_init__(self) -> None:
        _string("entrant_id", self.entrant_id)
        if self.participant_id not in ("participant_0", "participant_1"):
            raise ValueError("invalid participant_id")
        if self.spawn_side not in ("south", "north"):
            raise ValueError("invalid spawn_side")
        _integer("dispatch_precedence", self.dispatch_precedence, 0, 1)

    def as_dict(self) -> Dict[str, Any]:
        return {
            "dispatch_precedence": self.dispatch_precedence,
            "entrant_id": self.entrant_id,
            "participant_id": self.participant_id,
            "spawn_side": self.spawn_side,
        }


@dataclass(frozen=True)
class LegSchedule:
    series_lock_sha256: str
    leg_index: Literal[0, 1]
    assignments: Tuple[SeatAssignment, SeatAssignment]
    scratchpad_epoch: str
    decision_ticks: Literal[10] = 10

    def __post_init__(self) -> None:
        _digest("series_lock_sha256", self.series_lock_sha256)
        _integer("leg_index", self.leg_index, 0, 1)
        if not isinstance(self.assignments, tuple) or len(self.assignments) != 2:
            raise TypeError("assignments must be a two-item tuple")
        if any(not isinstance(value, SeatAssignment) for value in self.assignments):
            raise TypeError("assignments must contain SeatAssignment values")
        if {value.participant_id for value in self.assignments} != {
            "participant_0",
            "participant_1",
        }:
            raise ValueError("each participant seat must be assigned once")
        if {value.spawn_side for value in self.assignments} != {"south", "north"}:
            raise ValueError("each spawn side must be assigned once")
        if {value.dispatch_precedence for value in self.assignments} != {0, 1}:
            raise ValueError("dispatch precedence must be unique")
        _string("scratchpad_epoch", self.scratchpad_epoch, _NONCE)
        _integer("decision_ticks", self.decision_ticks, 10, 10)

    def as_dict(self) -> Dict[str, Any]:
        return {
            "assignments": [value.as_dict() for value in self.assignments],
            "decision_ticks": self.decision_ticks,
            "leg_index": self.leg_index,
            "scratchpad_epoch": self.scratchpad_epoch,
            "series_lock_sha256": self.series_lock_sha256,
        }

    @property
    def schedule_sha256(self) -> str:
        return canonical_sha256(self.as_dict())

    def fresh_scratchpads(self) -> Tuple[bytes, bytes]:
        """Return the mandatory empty episode-only memory state for this leg."""

        return b"", b""


def schedule_pair(lock: SeriesLock) -> Tuple[LegSchedule, LegSchedule]:
    """Build the only allowed pair: all three seat-sensitive dimensions swap."""

    if not isinstance(lock, SeriesLock):
        raise TypeError("lock must be SeriesLock")
    first, second = lock.entrants
    legs = []
    for leg_index in (0, 1):
        entrants = (first, second) if leg_index == 0 else (second, first)
        legs.append(
            LegSchedule(
                series_lock_sha256=lock.lock_sha256,
                leg_index=leg_index,
                assignments=(
                    SeatAssignment(entrants[0].entrant_id, "participant_0", "south", 0),
                    SeatAssignment(entrants[1].entrant_id, "participant_1", "north", 1),
                ),
                scratchpad_epoch=f"leg-{leg_index}-{lock.lock_sha256[:32]}",
            )
        )
    return legs[0], legs[1]


def rerun_lock(lock: SeriesLock, *, schedule_nonce: str) -> SeriesLock:
    """Create an explicit rerun identity; silently recycling a void lock is forbidden."""

    _string("schedule_nonce", schedule_nonce, _NONCE)
    if schedule_nonce == lock.schedule_nonce:
        raise ValueError("rerun schedule_nonce must differ from the void pair")
    return replace(lock, schedule_nonce=schedule_nonce)


@dataclass(frozen=True)
class VerifiedLeg:
    schedule_sha256: str
    replay_sha256: str
    terminal_state_sha256: str
    outcome: LegOutcome
    winner_entrant_id: str | None
    complete: bool
    independently_verified: bool

    def __post_init__(self) -> None:
        for name in ("schedule_sha256", "replay_sha256", "terminal_state_sha256"):
            _digest(name, getattr(self, name))
        if self.outcome not in ("win", "draw", "void"):
            raise ValueError("invalid leg outcome")
        if self.outcome == "win":
            _string("winner_entrant_id", self.winner_entrant_id)
        elif self.winner_entrant_id is not None:
            raise ValueError("draw and void legs cannot name a winner")
        if not isinstance(self.complete, bool) or not isinstance(self.independently_verified, bool):
            raise TypeError("leg verification flags must be booleans")


@dataclass(frozen=True)
class PairResult:
    series_lock_sha256: str
    status: PairStatus
    leg_wins: Tuple[int, int]
    draws: int
    winner_entrant_id: str | None
    rerun_required: bool
    result_sha256: str


def aggregate_pair(
    lock: SeriesLock,
    legs: Tuple[VerifiedLeg, VerifiedLeg],
) -> PairResult:
    """Aggregate exactly two sealed legs; incomplete or unverified evidence is rejected."""

    if not isinstance(legs, tuple) or len(legs) != 2:
        raise TypeError("legs must be a two-item tuple")
    schedules = schedule_pair(lock)
    for index, leg in enumerate(legs):
        if not isinstance(leg, VerifiedLeg):
            raise TypeError("legs must contain VerifiedLeg values")
        if leg.schedule_sha256 != schedules[index].schedule_sha256:
            raise ValueError("leg does not belong to the expected schedule")
        if not leg.complete or not leg.independently_verified:
            raise ValueError("only complete independently verified legs may aggregate")

    if any(leg.outcome == "void" for leg in legs):
        return _pair_result(lock, "invalid", (0, 0), 0, None, True)

    entrant_ids = (lock.entrants[0].entrant_id, lock.entrants[1].entrant_id)
    wins = [0, 0]
    draws = 0
    for leg in legs:
        if leg.outcome == "draw":
            draws += 1
            continue
        if leg.winner_entrant_id not in entrant_ids:
            raise ValueError("leg winner is not a locked entrant")
        wins[entrant_ids.index(leg.winner_entrant_id)] += 1
    winner = None
    if wins[0] != wins[1]:
        winner = entrant_ids[0] if wins[0] > wins[1] else entrant_ids[1]
    return _pair_result(lock, "complete", (wins[0], wins[1]), draws, winner, False)


def _pair_result(
    lock: SeriesLock,
    status: PairStatus,
    leg_wins: Tuple[int, int],
    draws: int,
    winner: str | None,
    rerun_required: bool,
) -> PairResult:
    body = {
        "draws": draws,
        "leg_wins": list(leg_wins),
        "rerun_required": rerun_required,
        "series_lock_sha256": lock.lock_sha256,
        "status": status,
        "winner_entrant_id": winner,
    }
    return PairResult(
        series_lock_sha256=lock.lock_sha256,
        status=status,
        leg_wins=leg_wins,
        draws=draws,
        winner_entrant_id=winner,
        rerun_required=rerun_required,
        result_sha256=canonical_sha256(body),
    )
