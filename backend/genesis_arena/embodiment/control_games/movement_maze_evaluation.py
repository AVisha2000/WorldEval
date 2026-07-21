"""Allow-listed public aggregate evaluation for ``movement-maze-v0``."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import Any, Mapping

MOVEMENT_MAZE_MAP_VERSION = "movement-maze-map/1.0.0"
MOVEMENT_MAZE_MAP_SHA256 = "9ff4376b7ba0839e334af7eea39bff7a2aa0879b7007c59bb629b63c2552bf68"
_MAP_SOURCE_PATH = (
    Path(__file__).resolve().parents[4]
    / "godot"
    / "scripts"
    / "embodiment"
    / "control_games"
    / "movement_maze_map.gd"
)
_MAP_VERSION_LINE = re.compile(r'^const MAP_VERSION := "([^"]+)"$', re.MULTILINE)
_INTEGER_CONSTANT = r"^const {name} := ([0-9_]+)$"
_VECTOR_CONSTANT = r"^const {name} := Vector2i\((-?[0-9]+),\s*(-?[0-9]+)\)$"
_VECTOR_BLOCK = r"^const {name} := \[(.*?)^\]$"
_VECTOR = re.compile(r"Vector2i\((-?[0-9]+),\s*(-?[0-9]+)\)")


def _integer_constant(source: str, name: str) -> int:
    match = re.search(_INTEGER_CONSTANT.format(name=re.escape(name)), source, re.MULTILINE)
    if match is None:
        raise RuntimeError(f"trusted movement-maze {name} is absent")
    return int(match.group(1).replace("_", ""))


def _vector_constant(source: str, name: str) -> tuple[int, int]:
    match = re.search(_VECTOR_CONSTANT.format(name=re.escape(name)), source, re.MULTILINE)
    if match is None:
        raise RuntimeError(f"trusted movement-maze {name} is absent")
    return int(match.group(1)), int(match.group(2))


def _vector_block(source: str, name: str) -> tuple[tuple[int, int], ...]:
    match = re.search(
        _VECTOR_BLOCK.format(name=re.escape(name)), source, re.MULTILINE | re.DOTALL
    )
    if match is None:
        raise RuntimeError(f"trusted movement-maze {name} is absent")
    values = tuple((int(x), int(y)) for x, y in _VECTOR.findall(match.group(1)))
    if not values:
        raise RuntimeError(f"trusted movement-maze {name} is empty")
    return values

_INPUT_FIELDS = frozenset(
    {
        "completion_tick",
        "checkpoint_count",
        "checkpoint_total",
        "checkpoint_order_valid",
        "order_violation_count",
        "collision_count",
        "facing_corrections",
        "invalid_windows",
        "travelled_distance_mt",
        "terminal_outcome",
        "terminal_reason",
    }
)


def evaluate_movement_maze(authority_aggregates: Mapping[str, Any]) -> dict[str, Any]:
    """Project protected authority aggregates into the narrow browser-safe metric set.

    The trusted shortest-route length participates in integer ratio calculation but is deliberately
    omitted from the result.  Neither exact positions nor a route can be represented by this API.
    """

    if not isinstance(authority_aggregates, Mapping) or set(authority_aggregates) != _INPUT_FIELDS:
        raise ValueError("movement-maze authority aggregates have invalid fields")
    integer_fields = (
        "checkpoint_count",
        "checkpoint_total",
        "order_violation_count",
        "collision_count",
        "facing_corrections",
        "invalid_windows",
        "travelled_distance_mt",
    )
    for name in integer_fields:
        value = authority_aggregates[name]
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"{name} must be a non-negative integer")
    if not isinstance(authority_aggregates["checkpoint_order_valid"], bool):
        raise ValueError("checkpoint_order_valid must be boolean")
    completion_tick = authority_aggregates["completion_tick"]
    if completion_tick is not None and (
        isinstance(completion_tick, bool)
        or not isinstance(completion_tick, int)
        or completion_tick < 0
    ):
        raise ValueError("completion_tick must be null or a non-negative integer")
    if authority_aggregates["terminal_outcome"] not in {"success", "failure"}:
        raise ValueError("terminal_outcome is invalid")
    if authority_aggregates["terminal_reason"] not in {"final_beacon", "time_limit"}:
        raise ValueError("terminal_reason is invalid")
    map_version, map_sha256, shortest, trusted_checkpoint_total = _trusted_map()
    if authority_aggregates["checkpoint_total"] != trusted_checkpoint_total:
        raise ValueError("checkpoint_total differs from the trusted map version")
    if authority_aggregates["checkpoint_count"] > authority_aggregates["checkpoint_total"]:
        raise ValueError("checkpoint_count exceeds checkpoint_total")
    expected_order_valid = (
        authority_aggregates["checkpoint_count"] == authority_aggregates["checkpoint_total"]
        and authority_aggregates["order_violation_count"] == 0
    )
    if authority_aggregates["checkpoint_order_valid"] is not expected_order_valid:
        raise ValueError("checkpoint_order_valid differs from authority aggregates")
    if authority_aggregates["terminal_outcome"] == "success":
        if completion_tick is None or authority_aggregates["terminal_reason"] != "final_beacon":
            raise ValueError("successful maze terminal aggregates are inconsistent")
    elif completion_tick is not None or authority_aggregates["terminal_reason"] != "time_limit":
        raise ValueError("failed maze terminal aggregates are inconsistent")

    travelled = authority_aggregates["travelled_distance_mt"]
    if authority_aggregates["terminal_outcome"] == "success" and shortest > travelled:
        raise ValueError("travelled distance is shorter than the trusted legal route")
    path_efficiency = (
        {"supported": False, "reason": "no_travel_recorded", "ratio_per_mille": None}
        if travelled == 0
        else {
            "supported": True,
            "reason": None,
            "ratio_per_mille": min(1000, shortest * 1000 // travelled),
        }
    )
    return {
        "schema_version": "movement-maze-evaluation/1",
        "scope": "solo_control_game",
        "task_id": "movement-maze-v0",
        "map_artifact": {"version": map_version, "sha256": map_sha256},
        "metrics": {
            "completion_tick": completion_tick,
            "travelled_distance_mt": travelled,
            "collisions": authority_aggregates["collision_count"],
            "facing_corrections": authority_aggregates["facing_corrections"],
            "invalid_windows": authority_aggregates["invalid_windows"],
            "checkpoint_order": {
                "reached": authority_aggregates["checkpoint_count"],
                "total": authority_aggregates["checkpoint_total"],
                "valid": authority_aggregates["checkpoint_order_valid"],
                "violations": authority_aggregates["order_violation_count"],
            },
            "path_efficiency": path_efficiency,
        },
    }


def _trusted_map() -> tuple[str, str, int, int]:
    """Verify the pinned Godot map and derive ordered shortest-path length from its topology."""

    try:
        source = _MAP_SOURCE_PATH.read_bytes()
    except OSError as error:
        raise RuntimeError("trusted movement-maze map artifact is unavailable") from error
    digest = hashlib.sha256(source).hexdigest()
    if digest != MOVEMENT_MAZE_MAP_SHA256:
        raise RuntimeError("trusted movement-maze map artifact digest differs")
    try:
        text = source.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise RuntimeError("trusted movement-maze map artifact is not UTF-8") from error
    version_match = _MAP_VERSION_LINE.search(text)
    if version_match is None or version_match.group(1) != MOVEMENT_MAZE_MAP_VERSION:
        raise RuntimeError("trusted movement-maze map artifact identity differs")
    route_length, checkpoint_total = _derive_shortest_route_mt(text)
    return MOVEMENT_MAZE_MAP_VERSION, digest, route_length, checkpoint_total


def _derive_shortest_route_mt(source: str) -> tuple[int, int]:
    tile_mt = _integer_constant(source, "TILE_MT")
    start = _vector_constant(source, "START_TILE")
    checkpoints = _vector_block(source, "CHECKPOINT_TILES")
    beacon = _vector_constant(source, "BEACON_TILE")
    legal_tiles = frozenset(_vector_block(source, "LEGAL_TILES"))
    if tile_mt < 1 or len(checkpoints) != len(set(checkpoints)):
        raise RuntimeError("trusted movement-maze topology is invalid")
    ordered_targets = (*checkpoints, beacon)
    if start not in legal_tiles or any(target not in legal_tiles for target in ordered_targets):
        raise RuntimeError("trusted movement-maze target is not traversable")

    total_tiles = 0
    source_tile = start
    for target in ordered_targets:
        frontier = [source_tile]
        distances = {source_tile: 0}
        for current in frontier:
            if current == target:
                break
            x, y = current
            for candidate in ((x, y - 1), (x + 1, y), (x, y + 1), (x - 1, y)):
                if candidate in legal_tiles and candidate not in distances:
                    distances[candidate] = distances[current] + 1
                    frontier.append(candidate)
        if target not in distances:
            raise RuntimeError("trusted movement-maze ordered target is unreachable")
        total_tiles += distances[target]
        source_tile = target
    if total_tiles < 1:
        raise RuntimeError("trusted movement-maze route length is invalid")
    return total_tiles * tile_mt, len(checkpoints)


__all__ = [
    "MOVEMENT_MAZE_MAP_SHA256",
    "MOVEMENT_MAZE_MAP_VERSION",
    "evaluate_movement_maze",
]
