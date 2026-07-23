#!/usr/bin/env python3
"""Render verified embodiment replays with Godot Movie Maker and local FFmpeg."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Sequence

from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage
from genesis_arena.embodiment.replay import verify_replay_bytes
from worldeval.workspace import find_workspace

WORKSPACE = find_workspace(__file__)
WORKSPACE_ROOT = WORKSPACE.root
ROOT = WORKSPACE.path("worldarena")
GODOT_PROJECT = ROOT / "godot"
DEFAULT_GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
LOCAL_FFMPEG = (
    WORKSPACE_ROOT
    / ".video-tools/lib/python3.9/site-packages/imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1"
)
Y_BOT_MANIFEST = GODOT_PROJECT / "assets/external/mixamo/approved-y-bot.manifest.json"
MOVIE_SCRIPT = "res://scripts/embodiment/replay/embodiment_movie_maker_cli.gd"


class DemoRenderError(RuntimeError):
    pass


def render_demo(
    *,
    output: Path,
    godot: Path,
    ffmpeg: Path,
    replays: Sequence[Path] = (),
    allow_placeholder: bool = False,
) -> Path:
    """Render one standards-friendly MP4 from replays verified inside the playback process."""

    godot = Path(godot).resolve()
    ffmpeg = Path(ffmpeg).resolve()
    output = Path(output).resolve()
    if not godot.is_file() or not os.access(godot, os.X_OK):
        raise DemoRenderError("the pinned Godot executable is unavailable")
    if not ffmpeg.is_file() or not os.access(ffmpeg, os.X_OK):
        raise DemoRenderError("a local FFmpeg executable is unavailable")
    if "remotion" in str(ffmpeg).lower():
        raise DemoRenderError("the embodiment demo must not use a Remotion-provided encoder")
    y_bot_manifest_sha256: str | None = None
    if not allow_placeholder:
        try:
            from scripts.run_embodiment_mvp_certification import validate_y_bot_intake
        except ModuleNotFoundError:
            from run_embodiment_mvp_certification import validate_y_bot_intake

        y_bot_gate = validate_y_bot_intake(Y_BOT_MANIFEST)
        if y_bot_gate.get("passed") is not True:
            raise DemoRenderError(
                "approved and integrated Mixamo Y Bot intake is required for a final demo; "
                "use --allow-placeholder only for an explicitly labelled preview"
            )
        y_bot_manifest_sha256 = str(y_bot_gate["manifest_sha256"])
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="worldarena-embodiment-demo-") as temporary:
        work = Path(temporary)
        selected = tuple(Path(value).resolve() for value in replays)
        if not selected:
            replay_dir = work / "replays"
            _run(
                [
                    str(WORKSPACE_ROOT / ".venv/bin/python"),
                    "scripts/build_embodiment_demo_replays.py",
                    "--output-dir",
                    str(replay_dir),
                    "--godot",
                    str(godot),
                ],
                "demo replay generation failed",
            )
            selected = (
                replay_dir / "stage-c.replay.json",
                replay_dir / "duel-leg-a.replay.json",
                replay_dir / "duel-leg-b.replay.json",
            )
        if not selected or any(not replay.is_file() for replay in selected):
            raise DemoRenderError("every demo replay path must be a readable file")
        verified_replays = _verify_demo_replay_set(selected)
        if not allow_placeholder:
            verified_replays = _persist_verified_replays(output, verified_replays)
        movie = work / "embodiment-demo.avi"
        command = [
            str(godot),
            "--no-header",
            "--audio-driver",
            "Dummy",
            "--path",
            str(GODOT_PROJECT),
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
            MOVIE_SCRIPT,
            "--",
        ]
        command.extend(f"--embodiment-replay={replay}" for replay in selected)
        _run(command, "Godot Movie Maker render failed")
        if not movie.is_file() or movie.stat().st_size == 0:
            raise DemoRenderError("Godot Movie Maker produced no AVI")
        _run(
            [
                str(ffmpeg),
                "-y",
                "-hide_banner",
                "-loglevel",
                "warning",
                "-i",
                str(movie),
                "-f",
                "lavfi",
                "-i",
                "anullsrc=channel_layout=stereo:sample_rate=48000",
                "-shortest",
                "-vf",
                "scale=1920:1080:force_original_aspect_ratio=decrease:"
                "in_range=full:out_range=tv,"
                "pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,format=yuv420p",
                "-r",
                "30",
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
                str(output),
            ],
            "FFmpeg encoding failed",
        )
    _verify_mp4(output, ffmpeg)
    if not allow_placeholder:
        assert y_bot_manifest_sha256 is not None
        _write_final_evidence(
            output,
            verified_replays,
            y_bot_manifest_sha256=y_bot_manifest_sha256,
        )
    return output


def _verify_mp4(output: Path, ffmpeg: Path) -> None:
    payload = output.read_bytes()
    if len(payload) < 32 or b"ftyp" not in payload[:32]:
        raise DemoRenderError("encoded output is not an MP4")
    moov = payload.find(b"moov")
    mdat = payload.find(b"mdat")
    if moov < 0 or mdat < 0 or moov > mdat:
        raise DemoRenderError("MP4 does not have +faststart atom ordering")
    checked = subprocess.run(
        [str(ffmpeg), "-hide_banner", "-i", str(output), "-f", "null", "-"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if (
        checked.returncode != 0
        or "Video: h264" not in checked.stdout
        or "yuv420p(" not in checked.stdout
        or "yuvj420p" in checked.stdout
        or "30 fps" not in checked.stdout
    ):
        raise DemoRenderError("MP4 H.264 stream verification failed")
    if "Audio: aac" not in checked.stdout or "1920x1080" not in checked.stdout:
        raise DemoRenderError("MP4 AAC/1920x1080 verification failed")


def _verify_demo_replay_set(replays: Sequence[Path]) -> tuple[tuple[str, Path, str], ...]:
    if len(replays) != 3:
        raise DemoRenderError("demo rendering requires Stage C followed by exactly two duel legs")
    package = EmbodimentProtocolPackage.from_repository(ROOT)
    roles = ("stage-c", "duel-leg-a", "duel-leg-b")
    output = []
    values = []
    for role, path in zip(roles, replays):
        payload = path.read_bytes()
        try:
            replay = verify_replay_bytes(payload, package=package)
        except Exception as error:
            raise DemoRenderError(f"{role} replay failed independent verification") from error
        output.append((role, path, hashlib.sha256(payload).hexdigest()))
        values.append(replay)
    stage_config = values[0]["config"]
    duel_configs = [value["config"] for value in values[1:]]
    if (
        stage_config.get("mode") != "solo-curriculum-v0"
        or stage_config.get("task_id") != "construction-v0"
        or stage_config.get("observation_profile") != "hybrid-visible-v1"
    ):
        raise DemoRenderError("first demo replay is not verified hybrid Stage C")
    if (
        any(
            config.get("mode") not in ("scripted-duel-v0", "model-duel-v0")
            for config in duel_configs
        )
        or duel_configs[0].get("mode") != duel_configs[1].get("mode")
        or any(config.get("task_id") != "central-relay-v0" for config in duel_configs)
        or any(config.get("observation_profile") != "hybrid-visible-v1" for config in duel_configs)
        or duel_configs[0].get("episode_id") == duel_configs[1].get("episode_id")
    ):
        raise DemoRenderError("final two demo replays are not a distinct verified duel pair")
    return tuple(output)


def _write_final_evidence(
    output: Path,
    replays: Sequence[tuple[str, Path, str]],
    *,
    y_bot_manifest_sha256: str,
) -> None:
    evidence_path = output.with_suffix(output.suffix + ".evidence.json")
    replay_evidence = []
    for role, target, digest in replays:
        if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise DemoRenderError("persisted replay evidence digest differs")
        replay_evidence.append(
            {
                "path": os.path.relpath(target, evidence_path.parent),
                "role": role,
                "sha256": digest,
                "verified": True,
            }
        )
    value = {
        "format": "llm-controller/final-video-evidence/1.0.0",
        "renderer": "godot-movie-maker+ffmpeg",
        "placeholder": False,
        "y_bot_manifest_sha256": y_bot_manifest_sha256,
        "video": {
            "path": os.path.relpath(output, evidence_path.parent),
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
            "width": 1920,
            "height": 1080,
            "fps": 30,
            "video_codec": "h264",
            "pixel_format": "yuv420p",
            "audio_codec": "aac",
            "faststart": True,
        },
        "replays": replay_evidence,
    }
    evidence_path.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def _persist_verified_replays(
    output: Path, replays: Sequence[tuple[str, Path, str]]
) -> tuple[tuple[str, Path, str], ...]:
    replay_dir = output.parent / f"{output.stem}.verified-replays"
    replay_dir.mkdir(parents=True, exist_ok=True)
    persisted = []
    for role, source, digest in replays:
        target = replay_dir / f"{role}.replay.json"
        shutil.copyfile(source, target)
        if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise DemoRenderError("copied replay evidence digest differs")
        persisted.append((role, target, digest))
    return tuple(persisted)


def _run(command: Sequence[str], message: str) -> None:
    completed = subprocess.run(
        list(command),
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        tail = "\n".join(completed.stdout.splitlines()[-30:])
        raise DemoRenderError(f"{message}\n{tail}")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--godot", type=Path, default=DEFAULT_GODOT)
    parser.add_argument("--ffmpeg", type=Path, default=LOCAL_FFMPEG)
    parser.add_argument("--replay", type=Path, action="append", default=[])
    parser.add_argument("--allow-placeholder", action="store_true")
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        output = render_demo(
            output=arguments.output,
            godot=arguments.godot,
            ffmpeg=arguments.ffmpeg,
            replays=arguments.replay,
            allow_placeholder=arguments.allow_placeholder,
        )
    except DemoRenderError as error:
        print(f"EMBODIMENT_DEMO_FAILED: {error}")
        return 2
    print(f"EMBODIMENT_DEMO_OK output={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
