#!/usr/bin/env python3
"""Build or verify the promoted provider-free Primitive Sandbox replay bundles."""

from __future__ import annotations

import argparse
import os
import shutil
import tempfile
from pathlib import Path
from typing import Sequence

from worldarena.primitive_sandbox.godot import GodotPrimitiveSandboxRunner
from worldarena.primitive_sandbox.service import PrimitiveSandboxService
from worldarena.replay_verifiers import default_native_verifiers
from worldeval.replay import verify_replay_bundle
from worldeval.workspace import find_workspace

DEMOS = (
    (
        "tree-chop-nominal-v0",
        "primitive-sandbox-tree-chop-nominal",
        "primitive-sandbox-nominal-accepted-v1",
    ),
    (
        "tree-chop-interrupted-v0",
        "primitive-sandbox-tree-chop-interrupted",
        "primitive-sandbox-interrupted-accepted-v1",
    ),
)
VERSION = "1.0.0"


def build(*, godot: Path, destination: Path) -> list[Path]:
    workspace = find_workspace(__file__)
    runner = GodotPrimitiveSandboxRunner(
        executable=godot,
        project_path=workspace.path("worldarena_godot"),
    )
    built: list[Path] = []
    for scenario_id, demo_id, run_id in DEMOS:
        target = destination / demo_id / VERSION
        if os.path.lexists(target):
            raise FileExistsError(f"immutable promoted demo already exists: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(
            prefix=f"worldeval-{demo_id}-", dir=str(target.parent)
        ) as temporary:
            temporary_root = Path(temporary)
            service = PrimitiveSandboxService(runner=runner, replay_root=temporary_root)
            result = service.run(scenario_id, run_id=run_id)
            staging = target.parent / f".{VERSION}.staging-{run_id}"
            shutil.copytree(result.bundle_path, staging, symlinks=False)
            os.rename(staging, target)
        built.append(target)
    return built


def check(*, godot: Path, destination: Path) -> list[Path]:
    workspace = find_workspace(__file__)
    native_verifiers = default_native_verifiers(
        godot_executable=godot,
        godot_project_path=workspace.path("worldarena_godot"),
    )
    verified: list[Path] = []
    for _scenario_id, demo_id, _run_id in DEMOS:
        target = destination / demo_id / VERSION
        verify_replay_bundle(
            target,
            native_verifiers=native_verifiers,
            require_native_verification=True,
            require_provider_calls_zero=True,
            require_claim_binding=True,
        )
        verified.append(target)
    return verified


def main(argv: Sequence[str] | None = None) -> int:
    workspace = find_workspace(__file__)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--godot",
        type=Path,
        default=Path("/Applications/Godot.app/Contents/MacOS/Godot"),
    )
    parser.add_argument(
        "--destination",
        type=Path,
        default=workspace.path("worldarena") / "demos",
    )
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args(argv)
    try:
        paths = (
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
    for path in paths:
        print(f"PRIMITIVE_SANDBOX_DEMO_OK path={path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
