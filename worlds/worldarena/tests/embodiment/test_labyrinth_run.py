from __future__ import annotations

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from genesis_arena.embodiment.api import router
from genesis_arena.embodiment.labyrinth_run import (
    CachedLabyrinthRun,
    MazeTaskPlan,
    build_demo_replay,
    maze_analysis,
    parse_maze_task_plan,
    public_evaluation,
)
from genesis_arena.embodiment.protocol import canonical_json_bytes
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT


def test_fixed_labyrinth_and_visible_only_policies_lock_the_featured_podium() -> None:
    assert maze_analysis() == {
        "map_sha256": "f92bb8e2da8de13337f87630e17a92e354688e19271b6219422d440a5362dc15",
        "walkable_cells": 97,
        "shortest_path_cells": 60,
        "dead_ends": [[1, 3], [1, 13], [5, 5], [9, 11], [13, 1], [13, 13]],
        "junctions": [[1, 9], [5, 1], [5, 11], [7, 1], [13, 11]],
        "reachable": True,
    }
    replay = build_demo_replay()
    racers = sorted(replay["racers"], key=lambda value: value["place"])
    assert [
        (value["display_name"], value["finish_tick"], value["distance_cells"]) for value in racers
    ] == [
        ("Sol", 448, 64),
        ("Terra", 536, 84),
        ("Luna", 584, 104),
    ]
    assert [value["dead_ends_entered"] for value in racers] == [1, 2, 3]
    assert all(value["collisions"] == value["invalid_decisions"] == 0 for value in racers)


def test_maze_task_plan_is_strict_stale_safe_and_scratchpad_bounded() -> None:
    expected = {
        "episode_id": "ep_labyrinth",
        "observation_id": "obs_participant_0_0001",
        "participant_id": "participant_0",
    }
    plan = MazeTaskPlan(**expected, passage_choice="right", scratchpad_update="torch:right")
    assert parse_maze_task_plan(canonical_json_bytes(plan.as_dict()), expected=expected) == plan
    with pytest.raises(ValueError, match="stale"):
        parse_maze_task_plan(
            canonical_json_bytes({**plan.as_dict(), "observation_id": "obs_participant_0_0000"}),
            expected=expected,
        )
    with pytest.raises(ValueError, match="scratchpad"):
        MazeTaskPlan(**expected, passage_choice="wait", scratchpad_update="é" * 1025)


def test_public_evaluation_contains_spatial_metrics_without_private_memory() -> None:
    evaluation = public_evaluation(build_demo_replay())
    assert evaluation["summary"].startswith("Sol won")
    assert [value["place"] for value in evaluation["participants"]] == [1, 2, 3]
    serialized = repr(evaluation).casefold()
    for protected in ("scratchpad", "raw_output", "prompt", "credential", "chain_of_thought"):
        assert protected not in serialized


def test_cached_labyrinth_showcase_serves_video_metrics_and_no_public_replay() -> None:
    app = FastAPI()
    app.state.embodiment_labyrinth_showcase = CachedLabyrinthRun.load(ROOT)
    app.include_router(router)
    with TestClient(app) as client:
        showcase = client.get("/api/embodiment/showcases/trio-maze-race-v0")
        evaluation = client.get("/api/embodiment/showcases/trio-maze-race-v0/evaluation")
        video = client.get(
            "/api/embodiment/showcases/trio-maze-race-v0/video",
            headers={"Range": "bytes=0-7"},
        )
        replay = client.get("/api/embodiment/showcases/trio-maze-race-v0/replay")
    assert showcase.status_code == evaluation.status_code == 200
    assert showcase.json()["winner"]["display_name"] == "Sol"
    assert [value["model"] for value in showcase.json()["entrants"]] == [
        "demo-sol-v1",
        "demo-luna-v1",
        "demo-terra-v1",
    ]
    assert evaluation.json()["verification"]["state"] == "verified"
    assert video.status_code == 206 and len(video.content) == 8
    assert replay.status_code == 404
