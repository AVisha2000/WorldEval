"""Stable WorldArena paths resolved from the workspace marker.

This module is the compatibility boundary for legacy code that still needs the
WorldArena capsule as its logical root.  Callers must not infer the repository
layout from ``Path.parents``.
"""

from __future__ import annotations

from worldeval.workspace import find_workspace

_WORKSPACE = find_workspace(__file__)

WORKSPACE_ROOT = _WORKSPACE.root
WORLDARENA_ROOT = _WORKSPACE.path("worldarena")
WORLDARENA_BACKEND_ROOT = _WORKSPACE.path("worldarena_backend")
WORLDARENA_GAME_ROOT = _WORKSPACE.path("worldarena_game")
WORLDARENA_GODOT_ROOT = _WORKSPACE.path("worldarena_godot")
WORLDARENA_GAMES_ROOT = _WORKSPACE.path("worldarena_games")
RUNS_ROOT = _WORKSPACE.path("runs")
EXPORTS_ROOT = _WORKSPACE.path("exports")

__all__ = [
    "EXPORTS_ROOT",
    "RUNS_ROOT",
    "WORLDARENA_BACKEND_ROOT",
    "WORLDARENA_GAME_ROOT",
    "WORLDARENA_GAMES_ROOT",
    "WORLDARENA_GODOT_ROOT",
    "WORLDARENA_ROOT",
    "WORKSPACE_ROOT",
]
