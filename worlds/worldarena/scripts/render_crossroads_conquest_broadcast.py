#!/usr/bin/env python3
"""Render the sealed Crossroads Conquest replay as an exact native broadcast MP4.

The authority replay is read-only. Godot consumes its public frames and produces one
native Movie Maker frame per delivery frame; FFmpeg performs only the release encode.
The validated MP4 is moved into place atomically. Package promotion remains the job of
the showcase packager, after its independent two-run authority verification succeeds.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import struct
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from genesis_arena.embodiment.protocol import canonical_json_bytes, strict_json_loads

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
WIDTH = 1920
HEIGHT = 1080
FPS = 30
DURATION_SECONDS = 180.0
TOTAL_FRAMES = 5400
MAX_VIDEO_BYTES = 90 * 1024 * 1024
REPLAY_SCHEMA = "worldarena/crossroads-conquest-replay/1"
SHOWCASE_ID = "crossroads-conquest-v0"
MOVIE_MAKER_SCRIPT = (
    "res://scripts/arena/presentation/crossroads_conquest/"
    "crossroads_conquest_movie_maker_cli.gd"
)


class CrossroadsBroadcastRenderError(RuntimeError):
    """The replay, renderer, encoder, or final media profile is invalid."""


@dataclass(frozen=True)
class VideoProbe:
    duration_seconds: float
    width: int
    height: int
    fps: float
    codec: str
    pixel_format: str
    audio_codec: str
    audio_channels: int
    frame_count: int
    fast_start: bool
    size_bytes: int


def _default_ffmpeg() -> Path:
    discovered = shutil.which("ffmpeg")
    if discovered:
        return Path(discovered)
    try:
        import imageio_ffmpeg

        return Path(imageio_ffmpeg.get_ffmpeg_exe())
    except (ImportError, RuntimeError):
        return ROOT / ".video-tools" / "ffmpeg"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--godot", type=Path, default=DEFAULT_GODOT)
    parser.add_argument("--ffmpeg", type=Path, default=_default_ffmpeg())
    parser.add_argument(
        "--smoke-frames",
        type=int,
        choices=(1, 2, 3),
        help="render a short 1-3 frame MP4 for visual pipeline smoke testing",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="replace an existing output only after a new render passes validation",
    )
    return parser


def render_crossroads_conquest_broadcast(
    *,
    replay_path: Path,
    output_path: Path,
    godot_executable: Path,
    ffmpeg_executable: Path,
    smoke_frames: int | None = None,
    overwrite: bool = False,
) -> VideoProbe:
    replay = _canonical_replay(replay_path)
    _validate_replay_identity(replay)
    output = Path(output_path).resolve()
    if output.suffix.lower() != ".mp4" or output == ROOT or output.parent == output:
        raise CrossroadsBroadcastRenderError("output must be a safe absolute MP4 path")
    if not output.parent.is_dir():
        raise CrossroadsBroadcastRenderError("output parent directory is unavailable")
    if output.exists() and not overwrite:
        raise CrossroadsBroadcastRenderError("refusing to overwrite an existing broadcast")
    godot = _executable(godot_executable, "Godot")
    ffmpeg = _executable(ffmpeg_executable, "FFmpeg")
    if smoke_frames is not None and smoke_frames not in (1, 2, 3):
        raise CrossroadsBroadcastRenderError("smoke render must contain one to three frames")

    with tempfile.TemporaryDirectory(
        prefix="worldarena-crossroads-render-", dir=output.parent
    ) as temporary_value:
        temporary = Path(temporary_value)
        source_movie = temporary / "crossroads-conquest.avi"
        staged_mp4 = temporary / "crossroads-conquest-broadcast.mp4"
        _render_godot_movie(
            replay_path=Path(replay_path).resolve(),
            movie_path=source_movie,
            godot=godot,
            smoke_frames=smoke_frames,
        )
        _encode_mp4(
            movie_path=source_movie,
            output_path=staged_mp4,
            ffmpeg=ffmpeg,
            smoke_frames=smoke_frames,
        )
        probe = probe_crossroads_video(staged_mp4, ffmpeg, smoke_frames=smoke_frames)
        _validate_probe(probe, smoke_frames=smoke_frames)
        # os.replace keeps users from observing a partial final MP4. Existing output is
        # retained until all release checks have passed.
        os.replace(staged_mp4, output)
    return probe


def _canonical_replay(path: Path) -> dict[str, object]:
    replay_path = Path(path).resolve()
    if not replay_path.is_file() or replay_path.is_symlink():
        raise CrossroadsBroadcastRenderError("authority replay is unavailable")
    payload = replay_path.read_bytes()
    try:
        replay = strict_json_loads(payload)
    except (TypeError, ValueError) as error:
        raise CrossroadsBroadcastRenderError("authority replay JSON is invalid") from error
    if not isinstance(replay, dict) or canonical_json_bytes(replay) != payload:
        raise CrossroadsBroadcastRenderError("authority replay is not canonical JSON")
    return replay


def _validate_replay_identity(replay: dict[str, object]) -> None:
    schema = replay.get("schema", replay.get("schema_version"))
    policy = replay.get("policy")
    authority = replay.get("authority")
    if (
        schema != REPLAY_SCHEMA
        or replay.get("showcase_id") != SHOWCASE_ID
        or replay.get("protocol") != "world-arena/0.4"
        or replay.get("rules_id") != "arena-v0.4"
        or replay.get("map_id") != "tri_13_v1"
        or replay.get("seed") != 424242
        or replay.get("duration_seconds") != 180
        or not isinstance(policy, dict)
        or policy.get("id") != "crossroads-conquest-demo-v1"
        or not _sha256(policy.get("sha256"))
        or not isinstance(authority, dict)
        or not _sha256(authority.get("normalized_trace_sha256"))
        or not _sha256(authority.get("final_state_sha256"))
    ):
        raise CrossroadsBroadcastRenderError("authority replay identity is invalid")


def _render_godot_movie(
    *,
    replay_path: Path,
    movie_path: Path,
    godot: Path,
    smoke_frames: int | None,
) -> None:
    command = [
        str(godot),
        "--no-header",
        "--audio-driver",
        "Dummy",
        "--path",
        str(ROOT / "godot"),
        "--rendering-method",
        "gl_compatibility",
        "--resolution",
        f"{WIDTH}x{HEIGHT}",
        "--fixed-fps",
        str(FPS),
        "--disable-vsync",
        "--write-movie",
        str(movie_path),
        "--script",
        MOVIE_MAKER_SCRIPT,
        "--",
        f"--crossroads-replay={replay_path}",
    ]
    if smoke_frames is not None:
        command.append(f"--crossroads-smoke-frames={smoke_frames}")
    _run(command, timeout=120 if smoke_frames else 1800, label="Godot broadcast render")
    if not movie_path.is_file() or movie_path.stat().st_size < 512:
        raise CrossroadsBroadcastRenderError("Godot produced no broadcast movie")


def _encode_mp4(
    *, movie_path: Path, output_path: Path, ffmpeg: Path, smoke_frames: int | None
) -> None:
    frames = smoke_frames if smoke_frames is not None else TOTAL_FRAMES
    duration = frames / FPS
    command = [
        str(ffmpeg),
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
        "-map",
        "0:v:0",
        "-map",
        "1:a:0",
        "-map_metadata",
        "-1",
        "-vf",
        (
            "scale=1920:1080:force_original_aspect_ratio=decrease,"
            "pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,fps=30,format=yuv420p"
        ),
        "-frames:v",
        str(frames),
        "-t",
        f"{duration:.6f}",
        "-c:v",
        "libx264",
        "-preset",
        "medium",
        "-b:v",
        "2800k",
        "-maxrate",
        "3500k",
        "-bufsize",
        "7000k",
        "-g",
        "60",
        "-keyint_min",
        "30",
        "-sc_threshold",
        "0",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        "96k",
        "-ac",
        "2",
        "-ar",
        "48000",
        "-movflags",
        "+faststart",
        str(output_path),
    ]
    _run(command, timeout=120 if smoke_frames else 1800, label="FFmpeg release encode")


def probe_crossroads_video(
    video_path: Path, ffmpeg_executable: Path, *, smoke_frames: int | None = None
) -> VideoProbe:
    ffmpeg = _executable(ffmpeg_executable, "FFmpeg")
    video = Path(video_path).resolve()
    if not video.is_file() or video.is_symlink():
        raise CrossroadsBroadcastRenderError("broadcast MP4 is unavailable")
    report = _run(
        [str(ffmpeg), "-hide_banner", "-i", str(video), "-f", "null", "-"],
        timeout=180,
        label="FFmpeg broadcast probe",
        return_output=True,
    )
    duration_match = re.search(
        r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)", report
    )
    video_line = next((line for line in report.splitlines() if " Video: " in line), "")
    audio_line = next((line for line in report.splitlines() if " Audio: " in line), "")
    dimensions = re.search(r"(?:^|\s)(\d{2,5})x(\d{2,5})(?:[,\s])", video_line)
    fps_match = re.search(r"([0-9]+(?:\.[0-9]+)?)\s+fps", video_line)
    codec_match = re.search(r"Video:\s*([^,\s]+)", video_line)
    pixel_match = re.search(r"Video:[^\n]*?\b(yuv[0-9a-z]+)\b", video_line)
    audio_match = re.search(r"Audio:\s*([^,\s]+)", audio_line)
    if not all(
        (duration_match, dimensions, fps_match, codec_match, pixel_match, audio_match)
    ):
        raise CrossroadsBroadcastRenderError("broadcast stream metadata is incomplete")
    hours, minutes, seconds = duration_match.groups()
    duration = int(hours) * 3600 + int(minutes) * 60 + float(seconds)
    frame_matches = re.findall(r"frame=\s*(\d+)", report)
    frame_count = int(frame_matches[-1]) if frame_matches else round(duration * FPS)
    channels = 2 if re.search(r"\bstereo\b", audio_line) else 1
    return VideoProbe(
        duration_seconds=duration,
        width=int(dimensions.group(1)),
        height=int(dimensions.group(2)),
        fps=float(fps_match.group(1)),
        codec=codec_match.group(1).lower(),
        pixel_format=pixel_match.group(1).lower(),
        audio_codec=audio_match.group(1).lower(),
        audio_channels=channels,
        frame_count=frame_count,
        fast_start=_has_fast_start(video),
        size_bytes=video.stat().st_size,
    )


def _validate_probe(probe: VideoProbe, *, smoke_frames: int | None) -> None:
    expected_frames = smoke_frames if smoke_frames is not None else TOTAL_FRAMES
    expected_duration = expected_frames / FPS
    if (
        probe.width != WIDTH
        or probe.height != HEIGHT
        or abs(probe.fps - FPS) > 0.001
        or probe.codec not in {"h264", "avc1"}
        or probe.pixel_format != "yuv420p"
        or probe.audio_codec != "aac"
        or probe.audio_channels != 2
        # Container probing can report the AAC tail as an adjacent video frame on
        # some macOS FFmpeg builds; duration/fps remain the release authority.
        or abs(probe.frame_count - expected_frames) > 1
        or abs(probe.duration_seconds - expected_duration) > 0.02
        or not probe.fast_start
        or probe.size_bytes <= 1024
        or probe.size_bytes > MAX_VIDEO_BYTES
    ):
        raise CrossroadsBroadcastRenderError(
            "broadcast must be exact 1920x1080p30 H.264/yuv420p with silent stereo "
            "AAC, fast-start, the required frame count, and at most 90 MiB"
        )


def _has_fast_start(path: Path) -> bool:
    moov_offset: int | None = None
    mdat_offset: int | None = None
    with path.open("rb") as stream:
        offset = 0
        size = path.stat().st_size
        while offset + 8 <= size:
            stream.seek(offset)
            header = stream.read(16)
            if len(header) < 8:
                break
            atom_size = struct.unpack(">I", header[:4])[0]
            atom_type = header[4:8]
            header_size = 8
            if atom_size == 1:
                if len(header) < 16:
                    break
                atom_size = struct.unpack(">Q", header[8:16])[0]
                header_size = 16
            elif atom_size == 0:
                atom_size = size - offset
            if atom_size < header_size or offset + atom_size > size:
                break
            if atom_type == b"moov":
                moov_offset = offset
            elif atom_type == b"mdat":
                mdat_offset = offset
            if moov_offset is not None and mdat_offset is not None:
                break
            offset += atom_size
    return moov_offset is not None and mdat_offset is not None and moov_offset < mdat_offset


def _sha256(value: object) -> bool:
    return isinstance(value, str) and bool(re.fullmatch(r"[0-9a-f]{64}", value))


def _executable(path: Path, label: str) -> Path:
    value = Path(path).resolve()
    if not value.is_file() or not os.access(value, os.X_OK):
        raise CrossroadsBroadcastRenderError(f"{label} executable is unavailable")
    return value


def _run(
    command: Sequence[str],
    *,
    timeout: int,
    label: str,
    return_output: bool = False,
) -> str:
    try:
        completed = subprocess.run(
            tuple(command),
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CrossroadsBroadcastRenderError(f"{label} failed") from error
    if completed.returncode != 0:
        raise CrossroadsBroadcastRenderError(
            f"{label} failed:\n{completed.stdout[-5000:]}"
        )
    if not return_output and completed.stdout.strip():
        print(completed.stdout.strip())
    return completed.stdout


def main() -> int:
    arguments = _parser().parse_args()
    try:
        probe = render_crossroads_conquest_broadcast(
            replay_path=arguments.replay,
            output_path=arguments.output,
            godot_executable=arguments.godot,
            ffmpeg_executable=arguments.ffmpeg,
            smoke_frames=arguments.smoke_frames,
            overwrite=arguments.overwrite,
        )
    except (CrossroadsBroadcastRenderError, OSError) as error:
        print(f"CROSSROADS_CONQUEST_RENDER_FAILED: {error}")
        return 2
    marker = "SMOKE" if arguments.smoke_frames else "RENDER"
    print(
        f"CROSSROADS_CONQUEST_{marker}_OK output={arguments.output.resolve()} "
        f"frames={probe.frame_count} duration={probe.duration_seconds:.3f}s "
        f"size={probe.size_bytes}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
