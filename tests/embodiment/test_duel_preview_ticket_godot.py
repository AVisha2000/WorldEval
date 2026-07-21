import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
def test_python_and_godot_derive_identical_duel_preview_tickets() -> None:
    completed = subprocess.run(
        (
            str(GODOT), "--headless", "--no-header", "--audio-driver", "Dummy",
            "--path", str(ROOT / "godot"), "--script",
            "res://tests/embodiment/duel_preview_ticket_headless_runner.gd",
        ),
        capture_output=True,
        check=False,
        timeout=20,
    )
    assert completed.returncode == 0, (completed.stdout + completed.stderr).decode(
        "utf-8", errors="replace"
    )
    assert b"DUEL_PREVIEW_TICKET_OK" in completed.stdout
