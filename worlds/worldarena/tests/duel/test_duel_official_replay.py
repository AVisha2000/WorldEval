from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
RUNNER = "res://tests/duel/duel_official_replay_headless_runner.gd"


def test_official_replay_is_exact_offline_and_fail_closed() -> None:
    if not GODOT.is_file():
        pytest.skip("pinned Godot 4.5 binary is not installed")
    completed = subprocess.run(
        [
            str(GODOT),
            "--headless",
            "--path",
            str(ROOT / "godot"),
            "--script",
            RUNNER,
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
        timeout=240,
    )
    output = completed.stdout + completed.stderr
    assert completed.returncode == 0, output
    assert "DUEL_OFFICIAL_REPLAY_OK" in output
    assert "modes=2 exact_checkpoints=2 external_calls=0" in output
    assert "SCRIPT ERROR" not in output
