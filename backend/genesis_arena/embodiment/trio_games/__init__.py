"""Isolated protocol-v3 backend foundation for three-participant WorldArena games."""

from .common import FIXED_TRIO_WINDOW_TICKS, PROTOCOL_VERSION
from .demo_provider import TRIO_POLICY_SPECS, TrioDemoSeatController, build_trio_demo_controller
from .evaluation import PlacementGroup, evaluate_trio_series, validate_public_trio_evaluation
from .scheduling import TRIO_DEMO_ENTRANTS, TrioSeriesPlan, build_cyclic_trio_plan

__all__ = [
    "FIXED_TRIO_WINDOW_TICKS",
    "PROTOCOL_VERSION",
    "TRIO_DEMO_ENTRANTS",
    "TRIO_POLICY_SPECS",
    "PlacementGroup",
    "TrioDemoSeatController",
    "TrioSeriesPlan",
    "build_cyclic_trio_plan",
    "build_trio_demo_controller",
    "evaluate_trio_series",
    "validate_public_trio_evaluation",
]
