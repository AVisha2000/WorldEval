"""WorldArena Primitive Sandbox adapters and provider-free conformance oracle.

Production gameplay remains authoritative in Godot. Python materializes
contracts, transports one decision boundary at a time, verifies replays, and
exposes only safe public projections.
"""

from .demo import PrimitiveSandboxDemoAgent
from .godot import (
    GodotPrimitiveSandboxRunner,
    GodotSandboxError,
    GodotSandboxResult,
    GodotSandboxSnapshot,
)
from .grid import (
    AgentEpisode,
    DeterministicGridAuthority,
    ExecutionResult,
    GridScenario,
    load_grid_scenario,
)
from .reference import (
    PrimitiveDemoResult,
    ReplayVerificationError,
    run_primitive_sandbox_demo,
    verify_primitive_sandbox_replay,
)
from .service import (
    PrimitiveSandboxRun,
    PrimitiveSandboxService,
    PrimitiveSandboxServiceError,
    PrimitiveSandboxSession,
    PrimitiveSandboxSessionConflict,
    PrimitiveSandboxSessionNotFound,
)

__all__ = [
    "AgentEpisode",
    "DeterministicGridAuthority",
    "ExecutionResult",
    "GridScenario",
    "PrimitiveDemoResult",
    "PrimitiveSandboxDemoAgent",
    "PrimitiveSandboxRun",
    "PrimitiveSandboxService",
    "PrimitiveSandboxServiceError",
    "PrimitiveSandboxSession",
    "PrimitiveSandboxSessionConflict",
    "PrimitiveSandboxSessionNotFound",
    "ReplayVerificationError",
    "GodotPrimitiveSandboxRunner",
    "GodotSandboxError",
    "GodotSandboxResult",
    "GodotSandboxSnapshot",
    "load_grid_scenario",
    "run_primitive_sandbox_demo",
    "verify_primitive_sandbox_replay",
]
