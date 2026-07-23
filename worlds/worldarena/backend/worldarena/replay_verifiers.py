"""Exact native replay verifier registrations owned by WorldArena.

WorldEval core deliberately knows nothing about Godot. Repository and
application entrypoints import this module lazily when they need to complete a
replay-gated operation.
"""

from __future__ import annotations

import functools
import shutil
from pathlib import Path

from worldeval.replay import NativeVerifierRegistry

from .paths import WORLDARENA_GODOT_ROOT

PRIMITIVE_SANDBOX_NATIVE_SCHEMA = "replay-bundle.v1"
PRIMITIVE_SANDBOX_NATIVE_VERIFIER = "primitive-sandbox-godot-reexecution-v1"
WAYPOINT_MAZE_NATIVE_SCHEMA = "replay-bundle.v1"
WAYPOINT_MAZE_NATIVE_VERIFIER = "waypoint-maze-godot-reexecution-v1"
CONVERSATIONAL_WAREHOUSE_NATIVE_SCHEMA = "conversational-warehouse-replay.v1"
CONVERSATIONAL_WAREHOUSE_NATIVE_VERIFIER = "conversational-warehouse-godot-reexecution-v1"


def default_godot_executable() -> Path:
    """Resolve the conventional local Godot executable without launching it."""

    candidates = (
        Path("/Applications/Godot.app/Contents/MacOS/Godot"),
        Path("/Applications/Godot.app/Godot.app/Contents/MacOS/Godot"),
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    discovered = shutil.which("godot") or shutil.which("Godot")
    return Path(discovered) if discovered else candidates[0]


def default_native_verifiers(
    *,
    godot_executable: Path | None = None,
    godot_project_path: Path | None = None,
    sandbox_root: Path | None = None,
    waypoint_maze_root: Path | None = None,
    conversational_warehouse_root: Path | None = None,
    timeout_seconds: float = 30.0,
    require_network_isolation: bool = False,
) -> NativeVerifierRegistry:
    """Build the fail-closed exact registry for WorldArena native replays."""

    # Import lazily so repository workflow commands can construct their
    # environment-neutral workspace before loading WorldArena's game adapter.
    from .conversational_sandbox.godot import (
        native_replay_verifier as conversational_warehouse_replay_verifier,
    )
    from .primitive_sandbox.godot import (
        native_replay_verifier as primitive_sandbox_replay_verifier,
    )
    from .waypoint_maze.godot import (
        native_replay_verifier as waypoint_maze_replay_verifier,
    )

    selected_executable = Path(godot_executable or default_godot_executable()).resolve()
    selected_project = Path(godot_project_path or WORLDARENA_GODOT_ROOT).resolve()
    primitive_callback = functools.partial(
        primitive_sandbox_replay_verifier,
        executable=selected_executable,
        project_path=selected_project,
        sandbox_root=None if sandbox_root is None else Path(sandbox_root).resolve(),
        timeout_seconds=timeout_seconds,
        require_network_isolation=require_network_isolation,
    )
    waypoint_callback = functools.partial(
        waypoint_maze_replay_verifier,
        executable=selected_executable,
        project_path=selected_project,
        game_root=(None if waypoint_maze_root is None else Path(waypoint_maze_root).resolve()),
        timeout_seconds=timeout_seconds,
        require_network_isolation=require_network_isolation,
    )
    conversation_callback = functools.partial(
        conversational_warehouse_replay_verifier,
        executable=selected_executable,
        project_path=selected_project,
        game_root=(
            None
            if conversational_warehouse_root is None
            else Path(conversational_warehouse_root).resolve()
        ),
        timeout_seconds=timeout_seconds,
        require_network_isolation=require_network_isolation,
    )
    return NativeVerifierRegistry(
        {
            (
                PRIMITIVE_SANDBOX_NATIVE_VERIFIER,
                PRIMITIVE_SANDBOX_NATIVE_SCHEMA,
            ): primitive_callback,
            (
                WAYPOINT_MAZE_NATIVE_VERIFIER,
                WAYPOINT_MAZE_NATIVE_SCHEMA,
            ): waypoint_callback,
            (
                CONVERSATIONAL_WAREHOUSE_NATIVE_VERIFIER,
                CONVERSATIONAL_WAREHOUSE_NATIVE_SCHEMA,
            ): conversation_callback,
        }
    )


__all__ = [
    "PRIMITIVE_SANDBOX_NATIVE_SCHEMA",
    "PRIMITIVE_SANDBOX_NATIVE_VERIFIER",
    "WAYPOINT_MAZE_NATIVE_SCHEMA",
    "WAYPOINT_MAZE_NATIVE_VERIFIER",
    "CONVERSATIONAL_WAREHOUSE_NATIVE_SCHEMA",
    "CONVERSATIONAL_WAREHOUSE_NATIVE_VERIFIER",
    "default_godot_executable",
    "default_native_verifiers",
]
