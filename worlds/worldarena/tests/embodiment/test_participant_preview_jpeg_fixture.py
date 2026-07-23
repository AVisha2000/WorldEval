from __future__ import annotations

import shutil
import subprocess
from io import BytesIO
from pathlib import Path

import pytest
from genesis_arena.embodiment.presentation.participant_frames import sanitize_participant_jpeg
from PIL import Image
from worldarena.paths import WORLDARENA_ROOT

_REPOSITORY = WORLDARENA_ROOT
_MAC_GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


def _godot_binary() -> str | None:
    discovered = shutil.which("godot") or shutil.which("godot4")
    if discovered:
        return discovered
    return str(_MAC_GODOT) if _MAC_GODOT.is_file() else None


def _assert_no_metadata_segments(jpeg: bytes) -> None:
    offset = 2
    while offset < len(jpeg):
        assert jpeg[offset] == 0xFF
        marker = jpeg[offset + 1]
        if marker in (0xD9, 0xDA):
            return
        length = int.from_bytes(jpeg[offset + 2 : offset + 4], "big")
        assert marker != 0xFE and not 0xE0 <= marker <= 0xEF
        offset += 2 + length
    raise AssertionError("JPEG scan marker was not found")


def test_python_sanitizer_accepts_real_godot_preview_jpeg(tmp_path: Path) -> None:
    godot = _godot_binary()
    if godot is None:
        pytest.skip("Godot is unavailable for preview JPEG conformance")
    source = tmp_path / "godot-preview.jpg"
    completed = subprocess.run(
        [
            godot,
            "--headless",
            "--audio-driver",
            "Dummy",
            "--path",
            str(_REPOSITORY / "godot"),
            "--script",
            "res://tests/embodiment/participant_preview_jpeg_fixture_runner.gd",
            "--",
            f"--output={source}",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert completed.returncode == 0, completed.stdout + completed.stderr

    sanitized = sanitize_participant_jpeg(source.read_bytes())
    _assert_no_metadata_segments(sanitized)
    with Image.open(BytesIO(sanitized)) as decoded:
        decoded.load()
        assert decoded.format == "JPEG"
        assert decoded.mode == "RGB"
        assert decoded.size == (1280, 720)
