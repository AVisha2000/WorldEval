"""Typed execution results for a three-leg cyclic trio series."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Mapping

from ..contracts import TrioResult
from .scheduling import TrioLegPlan, TrioSeriesPlan

_SHA256 = re.compile(r"^[0-9a-f]{64}$")


@dataclass(frozen=True)
class TrioLegExecutionResult:
    plan: TrioLegPlan
    terminal_result: TrioResult
    replay_sha256: str
    final_state_hash: str
    decision_windows: int
    fallback_windows: int
    provider_calls: int
    suppressed_eliminated_calls: int

    def __post_init__(self) -> None:
        if not isinstance(self.plan, TrioLegPlan) or not isinstance(
            self.terminal_result, TrioResult
        ):
            raise TypeError("trio leg result requires typed plan and terminal result")
        for name in ("replay_sha256", "final_state_hash"):
            if not isinstance(getattr(self, name), str) or _SHA256.fullmatch(
                getattr(self, name)
            ) is None:
                raise ValueError(f"{name} must be lowercase SHA-256")
        for name in (
            "decision_windows",
            "fallback_windows",
            "provider_calls",
            "suppressed_eliminated_calls",
        ):
            value = getattr(self, name)
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise ValueError(f"{name} must be a non-negative integer")
        if self.fallback_windows > self.decision_windows * 3:
            raise ValueError("trio leg fallback windows exceed participant decisions")

    def public_dict(self) -> Mapping[str, Any]:
        return {
            "decision_windows": self.decision_windows,
            "fallback_windows": self.fallback_windows,
            "final_state_hash": self.final_state_hash,
            "leg_index": self.plan.leg_index,
            "placements": [group.as_dict() for group in self.terminal_result.placements],
            "provider_calls": self.provider_calls,
            "replay_sha256": self.replay_sha256,
            "suppressed_eliminated_calls": self.suppressed_eliminated_calls,
            "terminal": self.terminal_result.as_dict(),
        }


@dataclass(frozen=True)
class TrioSeriesResult:
    plan: TrioSeriesPlan
    legs: tuple[TrioLegExecutionResult, TrioLegExecutionResult, TrioLegExecutionResult]

    def __post_init__(self) -> None:
        if not isinstance(self.plan, TrioSeriesPlan):
            raise TypeError("trio series result requires a TrioSeriesPlan")
        if not isinstance(self.legs, tuple) or len(self.legs) != 3:
            raise TypeError("trio series result requires exactly three legs")
        if any(not isinstance(value, TrioLegExecutionResult) for value in self.legs):
            raise TypeError("trio series legs are invalid")
        if tuple(value.plan for value in self.legs) != self.plan.legs:
            raise ValueError("trio series leg plans differ")

    def public_dict(self) -> Mapping[str, Any]:
        return {
            "certification": {"eligible": False, "reason": "demo_provider"},
            "legs": [value.public_dict() for value in self.legs],
            "plan_sha256": self.plan.plan_sha256,
            "series_id": self.plan.series_id,
            "task_id": self.plan.task_id,
        }


__all__ = ["TrioLegExecutionResult", "TrioSeriesResult"]
