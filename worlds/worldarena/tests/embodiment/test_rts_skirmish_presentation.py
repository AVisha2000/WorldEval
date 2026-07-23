from __future__ import annotations

import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
def test_rts_skirmish_participant_presentation_is_complete_and_player_scoped() -> None:
    completed = subprocess.run(
        [str(GODOT), "--headless", "--audio-driver", "Dummy", "--path", str(ROOT / "godot"),
         "--script", "res://tests/embodiment/rts_skirmish_presentation_headless_runner.gd"],
        check=True,
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert "RTS_SKIRMISH_PRESENTATION_OK" in completed.stdout


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
def test_rts_skirmish_dispatcher_bridges_only_public_participant_projections() -> None:
    completed = subprocess.run(
        [str(GODOT), "--headless", "--audio-driver", "Dummy", "--path", str(ROOT / "godot"),
         "--script", "res://tests/embodiment/rts_skirmish_dispatcher_presentation_headless_runner.gd"],
        check=True,
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert "RTS_SKIRMISH_DISPATCHER_PRESENTATION_OK" in completed.stdout
