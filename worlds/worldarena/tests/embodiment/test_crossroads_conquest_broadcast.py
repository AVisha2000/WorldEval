from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
from scripts import render_crossroads_conquest_broadcast as renderer
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
def test_crossroads_broadcast_director_scene_and_hud_are_authority_bound() -> None:
    completed = subprocess.run(
        [
            str(GODOT),
            "--headless",
            "--audio-driver",
            "Dummy",
            "--path",
            str(ROOT / "godot"),
            "--script",
            (
                "res://tests/arena/crossroads_conquest/"
                "crossroads_conquest_broadcast_headless_runner.gd"
            ),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert "CROSSROADS_CONQUEST_BROADCAST_OK" in completed.stdout


def test_crossroads_release_profile_is_exact_and_size_bounded() -> None:
    probe = renderer.VideoProbe(
        duration_seconds=180.0,
        width=1920,
        height=1080,
        fps=30.0,
        codec="h264",
        pixel_format="yuv420p",
        audio_codec="aac",
        audio_channels=2,
        frame_count=5400,
        fast_start=True,
        size_bytes=renderer.MAX_VIDEO_BYTES,
    )
    renderer._validate_probe(probe, smoke_frames=None)
    renderer._validate_probe(
        renderer.VideoProbe(**{**probe.__dict__, "frame_count": 5399}),
        smoke_frames=None,
    )

    with pytest.raises(renderer.CrossroadsBroadcastRenderError, match="exact 1920"):
        renderer._validate_probe(
            renderer.VideoProbe(**{**probe.__dict__, "frame_count": 5398}),
            smoke_frames=None,
        )
    with pytest.raises(renderer.CrossroadsBroadcastRenderError, match="exact 1920"):
        renderer._validate_probe(
            renderer.VideoProbe(
                **{**probe.__dict__, "size_bytes": renderer.MAX_VIDEO_BYTES + 1}
            ),
            smoke_frames=None,
        )


def test_crossroads_encoder_requests_silent_stereo_aac_and_fast_start(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    commands: list[tuple[str, ...]] = []

    def fake_run(command: list[str], **_kwargs: object) -> str:
        commands.append(tuple(command))
        return ""

    monkeypatch.setattr(renderer, "_run", fake_run)
    renderer._encode_mp4(
        movie_path=tmp_path / "source.avi",
        output_path=tmp_path / "broadcast.mp4",
        ffmpeg=tmp_path / "ffmpeg",
        smoke_frames=None,
    )

    command = commands[0]
    assert "anullsrc=channel_layout=stereo:sample_rate=48000" in command
    assert command[command.index("-frames:v") + 1] == "5400"
    assert command[command.index("-t") + 1] == "180.000000"
    assert command[command.index("-c:v") + 1] == "libx264"
    assert command[command.index("-pix_fmt") + 1] == "yuv420p"
    assert command[command.index("-c:a") + 1] == "aac"
    assert command[command.index("-ac") + 1] == "2"
    assert command[command.index("-movflags") + 1] == "+faststart"


def test_crossroads_fast_start_requires_moov_before_mdat(tmp_path: Path) -> None:
    def atom(kind: bytes, payload: bytes = b"x" * 8) -> bytes:
        size = 8 + len(payload)
        return size.to_bytes(4, "big") + kind + payload

    fast = tmp_path / "fast.mp4"
    fast.write_bytes(atom(b"ftyp") + atom(b"moov") + atom(b"mdat"))
    slow = tmp_path / "slow.mp4"
    slow.write_bytes(atom(b"ftyp") + atom(b"mdat") + atom(b"moov"))
    assert renderer._has_fast_start(fast)
    assert not renderer._has_fast_start(slow)
