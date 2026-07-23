#!/usr/bin/env python3
"""Build or independently verify the accepted Waypoint Maze replay bundle."""

from __future__ import annotations

import argparse
import os
import shutil
import tempfile
from pathlib import Path
from typing import Sequence

from worldarena.replay_verifiers import default_godot_executable
from worldarena.waypoint_maze import GodotWaypointMazeRunner, WaypointMazeService
from worldeval.replay import verify_replay_bundle
from worldeval.workspace import find_workspace

DEMO_ID = "waypoint-maze-beacon-route"
VERSION = "1.0.0"
SCENARIO_ID = "beacon-route-v0"
RUN_ID = "waypoint-maze-beacon-route-accepted-v1"


def build(*, godot: Path, destination: Path) -> Path:
    workspace = find_workspace(__file__)
    runner = GodotWaypointMazeRunner(
        executable=godot,
        project_path=workspace.path("worldarena_godot"),
    )
    target = destination / DEMO_ID / VERSION
    if os.path.lexists(target):
        raise FileExistsError(f"immutable promoted demo already exists: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="worldeval-waypoint-maze-",
        dir=str(target.parent),
    ) as temporary:
        service = WaypointMazeService(
            runner=runner,
            replay_root=Path(temporary),
        )
        result = service.run(SCENARIO_ID, run_id=RUN_ID)
        staging = target.parent / f".{VERSION}.staging-{RUN_ID}"
        shutil.copytree(result.bundle_path, staging, symlinks=False)
        os.rename(staging, target)
    return target


def check(*, godot: Path, destination: Path) -> Path:
    workspace = find_workspace(__file__)
    runner = GodotWaypointMazeRunner(
        executable=godot,
        project_path=workspace.path("worldarena_godot"),
    )
    target = destination / DEMO_ID / VERSION
    verify_replay_bundle(
        target,
        native_verifiers=runner.native_verifiers(),
        require_native_verification=True,
        require_provider_calls_zero=True,
        require_claim_binding=True,
    )
    return target


def main(argv: Sequence[str] | None = None) -> int:
    workspace = find_workspace(__file__)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--godot",
        type=Path,
        default=default_godot_executable(),
    )
    parser.add_argument(
        "--destination",
        type=Path,
        default=workspace.path("worldarena") / "demos",
    )
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args(argv)
    try:
        path = (
            check(
                godot=arguments.godot.resolve(),
                destination=arguments.destination.resolve(),
            )
            if arguments.check
            else build(
                godot=arguments.godot.resolve(),
                destination=arguments.destination.resolve(),
            )
        )
    except (OSError, RuntimeError, ValueError) as error:
        parser.error(str(error))
    print(f"WAYPOINT_MAZE_DEMO_OK path={path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
