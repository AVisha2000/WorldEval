"""Release-grade participant-video export from a verified embodiment replay.

This module is deliberately local-only.  Its input is protected authority replay evidence and its
output is a participant-filtered Godot presentation plus a small hash-only sidecar.  Neither the
replay nor any semantic observation is copied into the video evidence document.
"""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, Mapping

from .evaluation import validate_multi_action_showcase_replay
from .protocol import canonical_json_bytes
from .protocol_registry import EmbodimentProtocolRegistry
from .replay import verify_replay_bytes
from .trio_games.scheduling import TRIO_DEMO_ENTRANTS

NATIVE_MEDIA_FORMAT = "worldarena/native-participant-video-evidence/1.0.0"
RELEASE_WIDTH = 1920
RELEASE_HEIGHT = 1080
RELEASE_FPS = 30
_DURATION = re.compile(r"Duration: (\d{2}):(\d{2}):(\d{2})\.(\d{2})")
_PROTOCOL_PADDING_FRAMES = {
    "llm-controller/0.1.0": 75,
    "llm-controller/0.2.0": 45,
    "llm-controller/0.3.0": 45,
}


class NativeMediaError(RuntimeError):
    """A replay or rendered participant video is unsuitable for release."""


@dataclass(frozen=True)
class NativeMediaResult:
    video_path: Path
    evidence_path: Path
    evidence: Mapping[str, Any]


def render_verified_participant_video(
    *,
    repository_root: Path,
    replay_path: Path,
    output_path: Path,
    participant_id: str,
    godot_executable: Path,
    ffmpeg_executable: Path,
    y_bot_manifest_sha256: str,
    showcase: Literal["solo", "duo", "trio"],
    scenario_id: str | None = None,
) -> NativeMediaResult:
    """Verify one replay, render one participant camera, and seal release metadata."""

    root = Path(repository_root).resolve()
    replay_path = Path(replay_path).resolve()
    output_path = Path(output_path).resolve()
    godot_executable = Path(godot_executable).resolve()
    ffmpeg_executable = Path(ffmpeg_executable).resolve()
    if replay_path == output_path or output_path.suffix.lower() != ".mp4":
        raise NativeMediaError("native media output must be a distinct MP4 path")
    try:
        replay_payload = replay_path.read_bytes()
        registry = EmbodimentProtocolRegistry.from_repository(root)
        replay = verify_replay_bytes(replay_payload, registry=registry)
    except Exception as error:
        raise NativeMediaError("authority replay failed independent verification") from error

    config = replay.get("config")
    if not isinstance(config, Mapping):
        raise NativeMediaError("verified replay configuration is unavailable")
    participants = config.get("participant_ids")
    if not isinstance(participants, list) or participant_id not in participants:
        raise NativeMediaError("participant is not present in the verified replay")
    if config.get("observation_profile") != "hybrid-visible-v1":
        raise NativeMediaError("release video requires a participant-visible hybrid replay")
    protocol_version = replay.get("protocol_version")
    if protocol_version not in _PROTOCOL_PADDING_FRAMES:
        raise NativeMediaError("replay protocol has no native renderer")
    if not re.fullmatch(r"[0-9a-f]{64}", y_bot_manifest_sha256):
        raise NativeMediaError("approved Y Bot manifest digest is invalid")
    showcase_identity = _showcase_identity(
        replay, participant_id=participant_id, showcase=showcase, scenario_id=scenario_id
    )

    authority_ticks = _authority_ticks(replay)
    expected_frames = authority_ticks * 3 + _PROTOCOL_PADDING_FRAMES[protocol_version]
    output_path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    try:
        _render_release_participant_mp4(
            replay_path=replay_path,
            output_path=output_path,
            godot_executable=godot_executable,
            godot_project_path=root / "godot",
            ffmpeg_executable=ffmpeg_executable,
            protocol_version=protocol_version,
            participant_id=participant_id,
        )
    except (OSError, NativeMediaError) as error:
        raise NativeMediaError("participant-native render failed") from error

    probe = _probe_release_video(output_path, ffmpeg_executable)
    expected_duration_ms = expected_frames * 1000 // 30
    if abs(probe["duration_milliseconds"] - expected_duration_ms) > 40:
        raise NativeMediaError("participant video duration differs from authority replay")
    video_payload = output_path.read_bytes()
    evidence: Mapping[str, Any] = {
        "authority": {
            "episode_id": config["episode_id"],
            "final_state_sha256": replay["final_state_hash"],
            "protocol_package_sha256": replay["protocol_package_sha256"],
            "protocol_version": protocol_version,
            "replay_sha256": hashlib.sha256(replay_payload).hexdigest(),
            "task_id": config["task_id"],
            "ticks": authority_ticks,
        },
        "format": NATIVE_MEDIA_FORMAT,
        "participant_id": participant_id,
        "release_profile": "worldarena-participant-1080p30-v1",
        "renderer": "godot-movie-maker+ffmpeg",
        "showcase": showcase_identity,
        "video": {
            **probe,
            "expected_frames": expected_frames,
            "path": os.path.relpath(output_path, output_path.parent),
            "sha256": hashlib.sha256(video_payload).hexdigest(),
            "size_bytes": len(video_payload),
        },
        "y_bot_manifest_sha256": y_bot_manifest_sha256,
    }
    evidence_path = output_path.with_suffix(output_path.suffix + ".evidence.json")
    _write_atomic(evidence_path, canonical_json_bytes(evidence))
    return NativeMediaResult(output_path, evidence_path, evidence)


def _showcase_identity(
    replay: Mapping[str, Any],
    *,
    participant_id: str,
    showcase: str,
    scenario_id: str | None,
) -> Mapping[str, Any]:
    config = replay["config"]
    participants = config["participant_ids"]
    protocol_version = replay["protocol_version"]
    task_id = config["task_id"]
    if showcase == "solo":
        if (
            protocol_version != "llm-controller/0.1.0"
            or participants != ["participant_0"]
            or task_id != "construction-v0"
            or scenario_id != "multi-action-demo-v0"
        ):
            raise NativeMediaError("solo release is not the multi-action showcase")
        try:
            validate_multi_action_showcase_replay(replay)
        except (KeyError, TypeError, ValueError) as error:
            raise NativeMediaError("solo multi-action replay evidence is incomplete") from error
        return {
            "kind": "solo",
            "participant_count": 1,
            "scenario_id": scenario_id,
        }
    if showcase == "duo":
        if (
            protocol_version not in ("llm-controller/0.1.0", "llm-controller/0.2.0")
            or participants != ["participant_0", "participant_1"]
            or config.get("mode") not in ("scripted-duel-v0", "model-duel-v0")
            or scenario_id is not None
        ):
            raise NativeMediaError("duo release is not a scripted two-participant game")
        return {
            "kind": "duo",
            "participant_count": 2,
            "scenario_id": task_id,
        }
    if showcase == "trio":
        rotation = config.get("seat_rotation")
        if (
            protocol_version != "llm-controller/0.3.0"
            or participants != ["participant_0", "participant_1", "participant_2"]
            or task_id != "trio-free-for-all-v0"
            or config.get("mode") != "trio-game-v0"
            or isinstance(rotation, bool)
            or not isinstance(rotation, int)
            or rotation not in (0, 1, 2)
            or scenario_id is not None
        ):
            raise NativeMediaError("trio release is not a Sol/Luna/Terra free-for-all")
        entrant_ids = tuple(value.entrant_id for value in TRIO_DEMO_ENTRANTS)
        seat_index = participants.index(participant_id)
        selected_entrant = entrant_ids[(seat_index - rotation) % 3]
        return {
            "entrants": [value.as_dict() for value in TRIO_DEMO_ENTRANTS],
            "kind": "trio",
            "participant_count": 3,
            "scenario_id": task_id,
            "seat_rotation": rotation,
            "selected_entrant_id": selected_entrant,
        }
    raise NativeMediaError("release showcase kind is unsupported")


def _render_release_participant_mp4(
    *,
    replay_path: Path,
    output_path: Path,
    godot_executable: Path,
    godot_project_path: Path,
    ffmpeg_executable: Path,
    protocol_version: str,
    participant_id: str,
) -> None:
    for path, label in (
        (godot_executable, "pinned Godot executable"),
        (ffmpeg_executable, "local FFmpeg executable"),
    ):
        if not path.is_file() or not os.access(path, os.X_OK):
            raise NativeMediaError(f"{label} is unavailable")
    if "remotion" in str(ffmpeg_executable).lower():
        raise NativeMediaError("release encoder is invalid")
    scripts = {
        "llm-controller/0.1.0": "res://scripts/embodiment/replay/embodiment_movie_maker_cli.gd",
        "llm-controller/0.2.0": (
            "res://scripts/embodiment/v2/replay/embodiment_movie_maker_cli_v2.gd"
        ),
        "llm-controller/0.3.0": (
            "res://scripts/embodiment/v3/replay/embodiment_movie_maker_cli_v3.gd"
        ),
    }
    movie_script = scripts.get(protocol_version)
    if movie_script is None:
        raise NativeMediaError("release replay protocol is unsupported")
    with tempfile.TemporaryDirectory(prefix="worldarena-native-release-") as temporary:
        movie_path = Path(temporary) / "participant.avi"
        _run_command(
            (
                str(godot_executable),
                "--no-header",
                "--audio-driver",
                "Dummy",
                "--path",
                str(godot_project_path),
                "--rendering-method",
                "gl_compatibility",
                "--resolution",
                f"{RELEASE_WIDTH}x{RELEASE_HEIGHT}",
                "--fixed-fps",
                str(RELEASE_FPS),
                "--disable-vsync",
                "--write-movie",
                str(movie_path),
                "--script",
                movie_script,
                "--",
                f"--embodiment-replay={replay_path}",
                f"--embodiment-participant={participant_id}",
            ),
            cwd=godot_project_path,
            timeout_s=600,
            message="Godot release Movie Maker render failed",
        )
        if not movie_path.is_file() or movie_path.stat().st_size < 1024:
            raise NativeMediaError("Godot release Movie Maker produced no video")
        _run_command(
            (
                str(ffmpeg_executable),
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                str(movie_path),
                "-f",
                "lavfi",
                "-i",
                "anullsrc=channel_layout=stereo:sample_rate=48000",
                "-shortest",
                "-map_metadata",
                "-1",
                "-vf",
                "scale=1920:1080:force_original_aspect_ratio=decrease:"
                "in_range=full:out_range=tv,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:"
                "black,format=yuv420p",
                "-r",
                str(RELEASE_FPS),
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-color_range",
                "tv",
                "-c:a",
                "aac",
                "-b:a",
                "128k",
                "-movflags",
                "+faststart",
                str(output_path),
            ),
            cwd=godot_project_path,
            timeout_s=300,
            message="FFmpeg release encoding failed",
        )


def _run_command(
    command: tuple[str, ...], *, cwd: Path, timeout_s: float, message: str
) -> None:
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
            timeout=timeout_s,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise NativeMediaError(message) from error
    if completed.returncode != 0:
        tail = "\n".join(completed.stdout.splitlines()[-30:])
        raise NativeMediaError(f"{message}\n{tail}")


def _authority_ticks(replay: Mapping[str, Any]) -> int:
    steps = replay.get("steps")
    if not isinstance(steps, list) or not steps:
        raise NativeMediaError("verified replay has no authority steps")
    total = 0
    for step in steps:
        window = step.get("decision_window") if isinstance(step, Mapping) else None
        duration = window.get("duration_ticks") if isinstance(window, Mapping) else None
        if isinstance(duration, bool) or not isinstance(duration, int) or duration < 1:
            raise NativeMediaError("verified replay has an invalid authority horizon")
        total += duration
    return total


def _probe_release_video(output: Path, ffmpeg: Path) -> dict[str, Any]:
    try:
        payload = output.read_bytes()
    except OSError as error:
        raise NativeMediaError("participant video is missing") from error
    moov = payload.find(b"moov")
    mdat = payload.find(b"mdat")
    if len(payload) < 1024 or b"ftyp" not in payload[:32] or moov < 0 or mdat < 0 or moov > mdat:
        raise NativeMediaError("participant video is not a fast-start MP4")
    try:
        completed = subprocess.run(
            (str(ffmpeg), "-hide_banner", "-i", str(output), "-f", "null", "-"),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
            timeout=180,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise NativeMediaError("participant video probe failed") from error
    report = completed.stdout
    duration = _DURATION.search(report)
    if (
        completed.returncode != 0
        or duration is None
        or "Video: h264" not in report
        or "yuv420p(" not in report
        or "yuvj420p" in report
        or f"{RELEASE_WIDTH}x{RELEASE_HEIGHT}" not in report
        or "30 fps" not in report
        or "Audio: aac" not in report
        or "48000 Hz, stereo" not in report
    ):
        raise NativeMediaError("participant video codec contract differs")
    hours, minutes, seconds, centiseconds = (int(value) for value in duration.groups())
    return {
        "audio_codec": "aac",
        "duration_milliseconds": ((hours * 60 + minutes) * 60 + seconds) * 1000
        + centiseconds * 10,
        "faststart": True,
        "fps": RELEASE_FPS,
        "height": RELEASE_HEIGHT,
        "mime_type": "video/mp4",
        "pixel_format": "yuv420p",
        "video_codec": "h264",
        "width": RELEASE_WIDTH,
    }


def _write_atomic(path: Path, payload: bytes) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(payload)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


__all__ = [
    "NATIVE_MEDIA_FORMAT",
    "NativeMediaError",
    "NativeMediaResult",
    "render_verified_participant_video",
]
