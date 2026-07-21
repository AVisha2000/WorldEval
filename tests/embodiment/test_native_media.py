from __future__ import annotations

import hashlib
import subprocess
from pathlib import Path

import pytest
from genesis_arena.embodiment import native_media
from genesis_arena.embodiment.native_media import NativeMediaError
from genesis_arena.embodiment.protocol import canonical_json_bytes, strict_json_loads

ROOT = Path(__file__).resolve().parents[2]
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


def _verified_replay(*, profile: str = "hybrid-visible-v1") -> dict[str, object]:
    return {
        "config": {
            "episode_id": "ep_native_release",
            "mode": "model-duel-v0",
            "observation_profile": profile,
            "participant_ids": ["participant_0", "participant_1"],
            "task_id": "duo-relay-control-v0",
        },
        "final_state_hash": "a" * 64,
        "protocol_package_sha256": "b" * 64,
        "protocol_version": "llm-controller/0.2.0",
        "steps": [
            {"decision_window": {"duration_ticks": 10}},
            {"decision_window": {"duration_ticks": 10}},
        ],
    }


def _patch_verified_input(
    monkeypatch: pytest.MonkeyPatch, replay: dict[str, object]
) -> None:
    monkeypatch.setattr(
        native_media.EmbodimentProtocolRegistry,
        "from_repository",
        classmethod(lambda _cls, _root: object()),
    )
    monkeypatch.setattr(native_media, "verify_replay_bytes", lambda _payload, registry: replay)


def test_native_media_seals_hash_only_participant_release_evidence(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    replay_path = tmp_path / "authority.replay.json"
    replay_path.write_bytes(b"protected replay input")
    output = tmp_path / "participant.mp4"
    _patch_verified_input(monkeypatch, _verified_replay())

    def render(**values: object) -> None:
        assert values["participant_id"] == "participant_1"
        assert values["protocol_version"] == "llm-controller/0.2.0"
        Path(values["output_path"]).write_bytes(b"participant pixels" * 100)

    monkeypatch.setattr(native_media, "_render_release_participant_mp4", render)
    monkeypatch.setattr(
        native_media,
        "_probe_release_video",
        lambda _output, _ffmpeg: {
            "audio_codec": "aac",
            "duration_milliseconds": 3500,
            "faststart": True,
            "fps": 30,
            "height": 1080,
            "mime_type": "video/mp4",
            "pixel_format": "yuv420p",
            "video_codec": "h264",
            "width": 1920,
        },
    )
    result = native_media.render_verified_participant_video(
        repository_root=tmp_path,
        replay_path=replay_path,
        output_path=output,
        participant_id="participant_1",
        godot_executable=tmp_path / "godot",
        ffmpeg_executable=tmp_path / "ffmpeg",
        y_bot_manifest_sha256="c" * 64,
        showcase="duo",
    )

    payload = result.evidence_path.read_bytes()
    evidence = strict_json_loads(payload)
    assert canonical_json_bytes(evidence) == payload
    assert evidence["format"] == native_media.NATIVE_MEDIA_FORMAT
    assert evidence["renderer"] == "godot-movie-maker+ffmpeg"
    assert evidence["release_profile"] == "worldarena-participant-1080p30-v1"
    assert evidence["participant_id"] == "participant_1"
    assert evidence["authority"] == {
        "episode_id": "ep_native_release",
        "final_state_sha256": "a" * 64,
        "protocol_package_sha256": "b" * 64,
        "protocol_version": "llm-controller/0.2.0",
        "replay_sha256": hashlib.sha256(b"protected replay input").hexdigest(),
        "task_id": "duo-relay-control-v0",
        "ticks": 20,
    }
    assert evidence["video"]["expected_frames"] == 105
    for protected in ("prompt", "raw_output", "api_key", "position_mt", "spectator"):
        assert protected not in payload.decode("utf-8")


@pytest.mark.parametrize(
    ("participant_id", "profile", "message"),
    (
        ("participant_2", "hybrid-visible-v1", "participant is not present"),
        ("participant_0", "text-visible-v1", "participant-visible hybrid replay"),
    ),
)
def test_native_media_rejects_non_participant_or_non_hybrid_release(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    participant_id: str,
    profile: str,
    message: str,
) -> None:
    replay_path = tmp_path / "authority.replay.json"
    replay_path.write_bytes(b"replay")
    _patch_verified_input(monkeypatch, _verified_replay(profile=profile))
    monkeypatch.setattr(
        native_media,
        "_render_release_participant_mp4",
        lambda **_values: pytest.fail("invalid release reached renderer"),
    )
    with pytest.raises(NativeMediaError, match=message):
        native_media.render_verified_participant_video(
            repository_root=tmp_path,
            replay_path=replay_path,
            output_path=tmp_path / "participant.mp4",
            participant_id=participant_id,
            godot_executable=tmp_path / "godot",
            ffmpeg_executable=tmp_path / "ffmpeg",
            y_bot_manifest_sha256="c" * 64,
            showcase="duo",
        )


def test_native_media_probe_requires_faststart_release_codec_contract(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    output = tmp_path / "participant.mp4"
    output.write_bytes(b"\x00\x00\x00\x18ftypmp42moovmdat" + b"P" * 2048)
    report = """
Duration: 00:00:03.50, start: 0.000000, bitrate: 1 kb/s
Video: h264 (High), yuv420p(tv, progressive), 1920x1080, 30 fps
Audio: aac (LC), 48000 Hz, stereo, fltp
"""
    monkeypatch.setattr(
        native_media.subprocess,
        "run",
        lambda *_args, **_kwargs: subprocess.CompletedProcess([], 0, report),
    )
    assert native_media._probe_release_video(output, tmp_path / "ffmpeg") == {
        "audio_codec": "aac",
        "duration_milliseconds": 3500,
        "faststart": True,
        "fps": 30,
        "height": 1080,
        "mime_type": "video/mp4",
        "pixel_format": "yuv420p",
        "video_codec": "h264",
        "width": 1920,
    }

    output.write_bytes(b"\x00\x00\x00\x18ftypmp42mdatmoov" + b"P" * 2048)
    with pytest.raises(NativeMediaError, match="fast-start"):
        native_media._probe_release_video(output, tmp_path / "ffmpeg")


def test_release_showcase_profiles_bind_multi_action_and_trio_identity(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    solo = _verified_replay()
    solo["protocol_version"] = "llm-controller/0.1.0"
    solo["config"] = {
        **solo["config"],  # type: ignore[dict-item]
        "mode": "solo-curriculum-v0",
        "participant_ids": ["participant_0"],
        "task_id": "construction-v0",
    }
    validated: list[object] = []
    monkeypatch.setattr(
        native_media,
        "validate_multi_action_showcase_replay",
        lambda replay: validated.append(replay),
    )
    assert native_media._showcase_identity(
        solo,
        participant_id="participant_0",
        showcase="solo",
        scenario_id="multi-action-demo-v0",
    ) == {
        "kind": "solo",
        "participant_count": 1,
        "scenario_id": "multi-action-demo-v0",
    }
    assert validated == [solo]

    trio = _verified_replay()
    trio["protocol_version"] = "llm-controller/0.3.0"
    trio["config"] = {
        **trio["config"],  # type: ignore[dict-item]
        "mode": "trio-game-v0",
        "participant_ids": ["participant_0", "participant_1", "participant_2"],
        "seat_rotation": 1,
        "task_id": "trio-free-for-all-v0",
    }
    identity = native_media._showcase_identity(
        trio,
        participant_id="participant_2",
        showcase="trio",
        scenario_id=None,
    )
    assert identity["selected_entrant_id"] == "luna"
    assert [value["display_name"] for value in identity["entrants"]] == [
        "Sol",
        "Luna",
        "Terra",
    ]


def test_release_renderer_uses_separate_1080p_movie_profile(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    godot = tmp_path / "godot"
    ffmpeg = tmp_path / "ffmpeg"
    godot.write_bytes(b"tool")
    ffmpeg.write_bytes(b"tool")
    godot.chmod(0o700)
    ffmpeg.chmod(0o700)
    project = tmp_path / "project"
    project.mkdir()
    output = tmp_path / "release.mp4"
    commands: list[tuple[str, ...]] = []

    def run(
        command: tuple[str, ...], *, cwd: Path, timeout_s: float, message: str
    ) -> None:
        del cwd, timeout_s, message
        commands.append(command)
        if "--write-movie" in command:
            Path(command[command.index("--write-movie") + 1]).write_bytes(b"A" * 2048)
        else:
            output.write_bytes(b"B" * 2048)

    monkeypatch.setattr(native_media, "_run_command", run)
    native_media._render_release_participant_mp4(
        replay_path=tmp_path / "replay.json",
        output_path=output,
        godot_executable=godot,
        godot_project_path=project,
        ffmpeg_executable=ffmpeg,
        protocol_version="llm-controller/0.3.0",
        participant_id="participant_2",
    )
    assert commands[0][commands[0].index("--resolution") + 1] == "1920x1080"
    assert "res://scripts/embodiment/v3/replay/embodiment_movie_maker_cli_v3.gd" in commands[0]
    assert "scale=1920:1080" in next(value for value in commands[1] if "scale=" in value)


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
def test_versioned_native_projection_tween_is_participant_scoped() -> None:
    completed = subprocess.run(
        (
            str(GODOT),
            "--headless",
            "--audio-driver",
            "Dummy",
            "--path",
            str(ROOT / "godot"),
            "--script",
            "res://tests/embodiment/versioned_projection_tween_headless_runner.gd",
        ),
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    assert completed.returncode == 0, completed.stdout + completed.stderr
    assert "VERSIONED_PROJECTION_TWEEN_OK" in completed.stdout
