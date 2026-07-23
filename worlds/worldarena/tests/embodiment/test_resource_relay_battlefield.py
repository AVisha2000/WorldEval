from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
def test_resource_relay_uses_the_participant_safe_rts_battlefield() -> None:
    completed = subprocess.run(
        [
            str(GODOT),
            "--headless",
            "--audio-driver",
            "Dummy",
            "--path",
            str(ROOT / "godot"),
            "--script",
            "res://tests/embodiment/resource_relay_battlefield_headless_runner.gd",
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert "RESOURCE_RELAY_BATTLEFIELD_OK" in completed.stdout
