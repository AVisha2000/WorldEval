#!/usr/bin/env python3
"""Build, render, and seal the cached WorldArena Labyrinth Run highlight."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from genesis_arena.embodiment.labyrinth_run import (
    ASSET_DIRECTORY,
    SHOWCASE_SCHEMA,
    TASK_ID,
    CachedLabyrinthRun,
    build_demo_replay,
    public_evaluation,
)
from genesis_arena.embodiment.protocol import canonical_json_bytes
from worldeval.workspace import find_workspace

try:
    from scripts.package_rts_showcase import probe_video
except ModuleNotFoundError:
    from package_rts_showcase import probe_video

WORKSPACE = find_workspace(__file__)
ROOT = WORKSPACE.path("worldarena")
DEFAULT_GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
VIDEO_NAME = "labyrinth-run-broadcast.mp4"
REPLAY_NAME = "labyrinth-run-demo.replay.json"
EVALUATION_NAME = "evaluation.json"


def _default_ffmpeg() -> Path:
    discovered = shutil.which("ffmpeg")
    if discovered:
        return Path(discovered)
    try:
        import imageio_ffmpeg

        return Path(imageio_ffmpeg.get_ffmpeg_exe())
    except (ImportError, RuntimeError):
        pass
    candidate = (
        WORKSPACE.path("media")
        / "remotion/node_modules/.pnpm/@remotion+compositor-darwin-arm64@4.0.491/"
        "node_modules/@remotion/compositor-darwin-arm64/ffmpeg"
    )
    return candidate


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, default=DEFAULT_GODOT)
    parser.add_argument("--ffmpeg", type=Path, default=_default_ffmpeg())
    parser.add_argument("--skip-render", action="store_true")
    parser.add_argument("--destination", type=Path, default=ROOT / ASSET_DIRECTORY)
    return parser


def build_showcase(*, destination: Path, godot: Path, ffmpeg: Path, render: bool) -> Path:
    destination = destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    replay = build_demo_replay()
    evaluation = public_evaluation(replay)
    replay_path = destination / REPLAY_NAME
    evaluation_path = destination / EVALUATION_NAME
    video_path = destination / VIDEO_NAME
    _write(replay_path, replay)
    _write(evaluation_path, evaluation)
    if render:
        _render(replay_path, video_path, godot.resolve(), ffmpeg.resolve())
    if not video_path.is_file():
        raise RuntimeError("labyrinth broadcast video is missing")
    probe = probe_video(video_path, ffmpeg.resolve())
    if (
        int(probe["width"]) != 1920
        or int(probe["height"]) != 1080
        or int(probe["fps"]) != 30
        or abs(float(probe["duration_seconds"]) - 72.0) > 0.1
    ):
        raise RuntimeError("labyrinth broadcast does not match the 1080p30 72-second profile")
    manifest = {
        "schema_version": SHOWCASE_SCHEMA,
        "showcase_id": TASK_ID,
        "task_id": TASK_ID,
        "label": "WorldArena: Labyrinth Run",
        "tagline": "Three agents. The same maze. No shared vision. One memory-limited race.",
        "video": {
            "path": VIDEO_NAME,
            "sha256": _sha256(video_path),
            "mime_type": "video/mp4",
            "duration_seconds": 72,
            "fps": 30,
            "width": 1920,
            "height": 1080,
        },
        "replay": {"path": REPLAY_NAME, "sha256": _sha256(replay_path)},
        "evaluation": {"path": EVALUATION_NAME, "sha256": _sha256(evaluation_path)},
        "highlights": [
            {
                "at_seconds": 0,
                "participant_id": "broadcast",
                "kind": "title",
                "label": "Three identical private maze lanes",
            },
            {
                "at_seconds": 5,
                "participant_id": "broadcast",
                "kind": "start",
                "label": "The 60-second race begins",
            },
            {
                "at_seconds": 20,
                "participant_id": "broadcast",
                "kind": "comparison",
                "label": "Visible-only search policies diverge",
            },
            {
                "at_seconds": 35,
                "participant_id": "participant_1",
                "kind": "dead_end",
                "label": "Luna and Terra recover from wrong passages",
            },
            {
                "at_seconds": 49,
                "participant_id": "participant_0",
                "kind": "finish",
                "label": "Sol reaches the exit first at 44.8 seconds",
            },
            {
                "at_seconds": 59,
                "participant_id": "participant_2",
                "kind": "finish",
                "label": "Terra secures second place",
            },
            {
                "at_seconds": 64,
                "participant_id": "participant_1",
                "kind": "finish",
                "label": "Luna completes the podium before timeout",
            },
            {
                "at_seconds": 66,
                "participant_id": "broadcast",
                "kind": "result",
                "label": "Winner calling card and spatial-reasoning metrics",
            },
        ],
    }
    _write(destination / "manifest.json", manifest)
    CachedLabyrinthRun.load(
        ROOT if destination == (ROOT / ASSET_DIRECTORY).resolve() else destination.parents[2]
    )
    return destination


def _render(replay_path: Path, output: Path, godot: Path, ffmpeg: Path) -> None:
    for executable, label in ((godot, "Godot"), (ffmpeg, "FFmpeg")):
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise RuntimeError(f"{label} executable is unavailable")
    with tempfile.TemporaryDirectory(prefix="worldarena-labyrinth-") as temporary:
        movie = Path(temporary) / "labyrinth.avi"
        _run(
            (
                str(godot),
                "--no-header",
                "--audio-driver",
                "Dummy",
                "--path",
                str(ROOT / "godot"),
                "--rendering-method",
                "gl_compatibility",
                "--resolution",
                "1920x1080",
                "--fixed-fps",
                "30",
                "--disable-vsync",
                "--write-movie",
                str(movie),
                "--script",
                "res://scripts/embodiment/trio_games/trio_maze_movie_maker_cli.gd",
                "--",
                f"--labyrinth-replay={replay_path}",
            ),
            timeout=900,
            label="Godot Labyrinth Run render",
        )
        if not movie.is_file() or movie.stat().st_size < 1024:
            raise RuntimeError("Godot produced no Labyrinth Run movie")
        _run(
            (
                str(ffmpeg),
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                str(movie),
                "-f",
                "lavfi",
                "-i",
                "anullsrc=channel_layout=stereo:sample_rate=48000",
                "-shortest",
                "-map_metadata",
                "-1",
                "-vf",
                "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p",
                "-r",
                "30",
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-b:a",
                "128k",
                "-movflags",
                "+faststart",
                str(output),
            ),
            timeout=600,
            label="FFmpeg Labyrinth Run encode",
        )


def _run(command: tuple[str, ...], *, timeout: int, label: str) -> None:
    completed = subprocess.run(
        command,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"{label} failed:\n{completed.stdout[-4000:]}")
    print(completed.stdout.strip())


def _write(path: Path, value: object) -> None:
    path.write_bytes(canonical_json_bytes(value))


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    arguments = _parser().parse_args()
    build_showcase(
        destination=arguments.destination,
        godot=arguments.godot,
        ffmpeg=arguments.ffmpeg,
        render=not arguments.skip_render,
    )
    print(f"LABYRINTH_RUN_SHOWCASE_OK {arguments.destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
