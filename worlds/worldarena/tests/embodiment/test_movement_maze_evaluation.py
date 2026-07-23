from __future__ import annotations

from pathlib import Path

import pytest
from genesis_arena.embodiment.control_games import movement_maze_evaluation
from genesis_arena.embodiment.control_games.movement_maze_evaluation import (
    MOVEMENT_MAZE_MAP_SHA256,
    MOVEMENT_MAZE_MAP_VERSION,
    evaluate_movement_maze,
)


def _aggregates(**updates: object) -> dict[str, object]:
    value: dict[str, object] = {
        "completion_tick": 26,
        "checkpoint_count": 4,
        "checkpoint_total": 4,
        "checkpoint_order_valid": True,
        "order_violation_count": 0,
        "collision_count": 2,
        "facing_corrections": 10,
        "invalid_windows": 1,
        "travelled_distance_mt": 20000,
        "terminal_outcome": "success",
        "terminal_reason": "final_beacon",
    }
    value.update(updates)
    return value


def test_evaluator_exposes_only_safe_maze_aggregates() -> None:
    result = evaluate_movement_maze(
        _aggregates(checkpoint_order_valid=False, order_violation_count=1)
    )

    assert result == {
        "schema_version": "movement-maze-evaluation/1",
        "scope": "solo_control_game",
        "task_id": "movement-maze-v0",
        "map_artifact": {
            "version": MOVEMENT_MAZE_MAP_VERSION,
            "sha256": MOVEMENT_MAZE_MAP_SHA256,
        },
        "metrics": {
            "completion_tick": 26,
            "travelled_distance_mt": 20000,
            "collisions": 2,
            "facing_corrections": 10,
            "invalid_windows": 1,
            "checkpoint_order": {
                "reached": 4,
                "total": 4,
                "valid": False,
                "violations": 1,
            },
            "path_efficiency": {
                "supported": True,
                "reason": None,
                "ratio_per_mille": 800,
            },
        },
    }
    serialized = repr(result).casefold()
    for forbidden in ("position", "coordinate", "route", "shortest", "terminal_reason"):
        assert forbidden not in serialized


def test_evaluator_reports_unsupported_efficiency_without_travel() -> None:
    result = evaluate_movement_maze(
        _aggregates(
            checkpoint_count=0,
            checkpoint_order_valid=False,
            completion_tick=None,
            terminal_outcome="failure",
            terminal_reason="time_limit",
            travelled_distance_mt=0,
        )
    )

    assert result["metrics"]["path_efficiency"] == {
        "supported": False,
        "reason": "no_travel_recorded",
        "ratio_per_mille": None,
    }


@pytest.mark.parametrize(
    "value",
    (
        _aggregates(position_mt={"x": 1, "y": 2}),
        _aggregates(shortest_legal_route_mt=1),
        _aggregates(collision_count=True),
        _aggregates(checkpoint_order_valid=1),
        _aggregates(travelled_distance_mt=-1),
        _aggregates(checkpoint_order_valid=True, order_violation_count=1),
    ),
)
def test_evaluator_rejects_extra_hidden_or_malformed_authority_fields(value) -> None:
    with pytest.raises(ValueError):
        evaluate_movement_maze(value)


def test_evaluator_fails_closed_if_the_versioned_map_source_differs(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    tampered = tmp_path / "movement_maze_map.gd"
    source = movement_maze_evaluation._MAP_SOURCE_PATH.read_bytes()  # noqa: SLF001
    tampered.write_bytes(source.replace(b"Vector2i(3, 3)", b"Vector2i(2, 3)", 1))
    monkeypatch.setattr(movement_maze_evaluation, "_MAP_SOURCE_PATH", tampered)

    with pytest.raises(RuntimeError, match="digest differs"):
        evaluate_movement_maze(_aggregates())


def test_evaluator_map_binding_matches_the_checked_in_godot_artifact() -> None:
    source = movement_maze_evaluation._MAP_SOURCE_PATH.read_bytes()  # noqa: SLF001

    assert MOVEMENT_MAZE_MAP_VERSION.encode() in source
    assert movement_maze_evaluation.hashlib.sha256(source).hexdigest() == (
        MOVEMENT_MAZE_MAP_SHA256
    )
    route_mt, checkpoint_total = movement_maze_evaluation._derive_shortest_route_mt(  # noqa: SLF001
        source.decode("utf-8")
    )
    assert route_mt == 16_000
    assert checkpoint_total == 4


def test_route_is_derived_from_trusted_topology_not_a_declared_metric() -> None:
    source = movement_maze_evaluation._MAP_SOURCE_PATH.read_text()  # noqa: SLF001

    assert "SHORTEST_LEGAL_ROUTE" not in source
    longer_topology = source.replace(
        "Vector2i(3, 2), Vector2i(5, 2),", "Vector2i(3, 2),", 1
    )
    route_mt, _ = movement_maze_evaluation._derive_shortest_route_mt(  # noqa: SLF001
        longer_topology
    )
    assert route_mt == 20_000
