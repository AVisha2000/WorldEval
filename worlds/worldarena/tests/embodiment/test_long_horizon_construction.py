from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
PREFIX = "EMBODIMENT_LONG_HORIZON_CONSTRUCTION="


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
def test_long_horizon_construction_stays_active_until_the_final_build() -> None:
    completed = subprocess.run(
        [
            str(GODOT),
            "--headless",
            "--audio-driver",
            "Dummy",
            "--path",
            str(ROOT / "godot"),
            "--script",
            "res://tests/embodiment/embodiment_long_horizon_construction_headless_runner.gd",
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

    assert 1176 <= summary["final_tick"] < 1200
    assert summary["wait_ticks"] <= 80
    assert summary["task_counts"]["gather_materials"] > 500
    assert summary["task_counts"]["deliver_materials"] > 500
