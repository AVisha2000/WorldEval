from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
PREFIX = "EMBODIMENT_SCRIPTED_CONSTRUCTION_EVIDENCE="


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
def test_scripted_construction_demo_completes_with_a_frame_at_every_boundary() -> None:
    completed = subprocess.run(
        [
            str(GODOT),
            "--headless",
            "--audio-driver",
            "Dummy",
            "--path",
            str(ROOT / "godot"),
            "--script",
            "res://tests/embodiment/embodiment_scripted_construction_demo_headless_runner.gd",
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=20,
    )
    line = next(
        value.removeprefix(PREFIX)
        for value in completed.stdout.splitlines()
        if value.startswith(PREFIX)
    )
    summary = json.loads(line)

    assert summary["outcome"] == "success"
    assert summary["reason"] == "barricade_built"
    assert summary["frame_count"] == summary["tick_count"] + 1
    assert summary["frame_count"] > 100
