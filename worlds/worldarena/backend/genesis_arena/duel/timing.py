from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Literal

DecisionMode = Literal["fixed_simultaneous", "continuous_realtime"]
COMMAND_GATE_NS = 100_000_000
CONTINUOUS_MAX_AGE_TICKS = 100


class TimingError(ValueError):
    """Monotonic timing inputs violate the frozen continuous-mode contract."""


def controller_valid_until_tick(observation_tick: int, mode: DecisionMode) -> int:
    if observation_tick < 0:
        raise TimingError("observation_tick must be non-negative")
    if mode == "fixed_simultaneous":
        return observation_tick + 1
    if mode == "continuous_realtime":
        return observation_tick + CONTINUOUS_MAX_AGE_TICKS
    raise TimingError(f"unknown decision mode: {mode}")


def continuous_application_tick(
    *,
    match_start_monotonic_ns: int,
    ready_time_ns: int,
    current_completed_tick: int,
    gate_period_ns: int = COMMAND_GATE_NS,
) -> int:
    """Quantize a validated response to the first strictly later 100-ms gate."""

    if match_start_monotonic_ns < 0 or ready_time_ns < 0:
        raise TimingError("monotonic timestamps must be non-negative")
    if ready_time_ns < match_start_monotonic_ns:
        raise TimingError("ready_time precedes match start")
    if current_completed_tick < -1:
        raise TimingError("current_completed_tick must be at least -1")
    if gate_period_ns <= 0:
        raise TimingError("gate_period_ns must be positive")
    elapsed = ready_time_ns - match_start_monotonic_ns
    quantized_tick = elapsed // gate_period_ns + 1
    return max(quantized_tick, current_completed_tick + 1)


def batch_is_fresh(application_tick: int, valid_until_tick: int) -> bool:
    return application_tick >= 0 and application_tick <= valid_until_tick


class FailureOwner(str, Enum):
    MODEL = "model"
    PARTICIPANT_ENDPOINT = "participant_endpoint"
    ORGANIZER_INFRASTRUCTURE = "organizer_infrastructure"


@dataclass(frozen=True)
class FailureClassification:
    code: str
    owner: FailureOwner
    hard_model_failure: bool


@dataclass
class ModelFailureCounter:
    consecutive: int = 0
    cumulative: int = 0

    def record(self, classification: FailureClassification) -> bool:
        """Record one opportunity and return whether it reaches a forfeit threshold."""

        if classification.owner is FailureOwner.ORGANIZER_INFRASTRUCTURE:
            return False
        if not classification.hard_model_failure:
            self.consecutive = 0
            return False
        self.consecutive += 1
        self.cumulative += 1
        return self.consecutive >= 3 or self.cumulative >= 10

    def record_valid_envelope(self) -> None:
        self.consecutive = 0
