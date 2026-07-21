from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
PREFIX = "EMBODIMENT_SCRIPTED_SOLO_DEMO_EVIDENCE="


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
def test_scripted_solo_demos_complete_all_non_construction_stages() -> None:
    completed = subprocess.run(
        [
            str(GODOT),
            "--headless",
            "--audio-driver",
            "Dummy",
            "--path",
            str(ROOT / "godot"),
            "--script",
            "res://tests/embodiment/embodiment_scripted_solo_demo_headless_runner.gd",
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
    summaries = json.loads(line)

    assert {
        task_id: (summary["outcome"], summary["reason"])
        for task_id, summary in summaries.items()
    } == {
        "orientation-v0": ("success", "beacon_held"),
        "interaction-v0": ("success", "resource_deposited"),
        "neutral-encounter-v0": ("success", "relay_activated"),
    }
    assert all(summary["tick_count"] > 1 for summary in summaries.values())
