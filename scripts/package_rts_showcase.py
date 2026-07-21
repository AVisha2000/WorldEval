#!/usr/bin/env python3
"""Verify and atomically promote one sealed Mini RTS showcase package.

The input replay remains a server-side integrity artifact.  This utility copies it into the
showcase package for server verification only; it does not add or alter any browser API route.

Example:
    .venv/bin/python scripts/package_rts_showcase.py \
      --replay /tmp/rts.replay.json --evaluation /tmp/evaluation.json --video /tmp/rts.mp4 \
      --metadata /tmp/public-rts-story.json --ffmpeg /path/to/ffmpeg
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path
from typing import Any, Mapping, Sequence

from genesis_arena.embodiment.protocol import strict_json_loads
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.replay import verify_replay_bytes
from genesis_arena.embodiment.rts_showcase import SHOWCASE_ID, CachedRtsShowcase

ROOT = Path(__file__).resolve().parents[1]
SHOWCASE_DIRECTORY = Path("godot/showcases/rts_skirmish")
VIDEO_NAME = "rts-skirmish-broadcast.mp4"
REPLAY_NAME = "rts-skirmish-demo.replay.json"
EVALUATION_NAME = "evaluation.json"
MANIFEST_NAME = "manifest.json"
EXPECTED_WIDTH = 1920
EXPECTED_HEIGHT = 1080
EXPECTED_FPS = 30
EXPECTED_DURATION_SECONDS = 150.0
DURATION_TOLERANCE_SECONDS = 0.1


class RtsShowcasePackagingError(RuntimeError):
    """Promotion inputs are absent, inconsistent, or not release-grade."""


def _default_ffmpeg() -> Path:
    discovered = shutil.which("ffmpeg")
    if discovered:
        return Path(discovered)
    try:
        import imageio_ffmpeg

        return Path(imageio_ffmpeg.get_ffmpeg_exe())
    except (ImportError, RuntimeError):
        return ROOT / ".video-tools/ffmpeg"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--replay", type=Path, required=True)
    parser.add_argument("--evaluation", type=Path, required=True)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument(
        "--metadata",
        type=Path,
        required=True,
        help=(
            "safe public story JSON: label, winner, completion, casualties, highlights, "
            "evaluation_metrics"
        ),
    )
    parser.add_argument("--ffmpeg", type=Path, default=_default_ffmpeg())
    parser.add_argument("--repository-root", type=Path, default=ROOT)
    parser.add_argument(
        "--destination",
        type=Path,
        help="defaults to <repository-root>/godot/showcases/rts_skirmish",
    )
    return parser


def package_rts_showcase(
    *,
    repository_root: Path,
    replay_path: Path,
    evaluation_path: Path,
    video_path: Path,
    metadata_path: Path,
    ffmpeg_executable: Path,
    destination: Path | None = None,
) -> Path:
    """Validate explicit source artifacts, then publish one complete cache directory."""

    root = Path(repository_root).resolve()
    replay_path = _readable_file(replay_path, "replay")
    evaluation_path = _readable_file(evaluation_path, "evaluation")
    video_path = _readable_file(video_path, "video")
    metadata_path = _readable_file(metadata_path, "metadata")
    target = (Path(destination) if destination is not None else root / SHOWCASE_DIRECTORY).resolve()
    if target == root or target.parent == target:
        raise RtsShowcasePackagingError("showcase destination is unsafe")
    if not target.parent.is_dir():
        raise RtsShowcasePackagingError("showcase destination parent is unavailable")

    replay_bytes = replay_path.read_bytes()
    evaluation_bytes = evaluation_path.read_bytes()
    video_bytes = video_path.read_bytes()
    _validate_mp4_header(video_bytes)
    metadata = _load_metadata(metadata_path)
    try:
        evaluation = strict_json_loads(evaluation_bytes)
    except (TypeError, ValueError) as error:
        raise RtsShowcasePackagingError("evaluation JSON is invalid") from error
    if not isinstance(evaluation, dict):
        raise RtsShowcasePackagingError("evaluation JSON is invalid")

    registry = EmbodimentProtocolRegistry.from_repository(root)
    try:
        verified_replay = verify_replay_bytes(replay_bytes, registry=registry)
    except Exception as error:
        raise RtsShowcasePackagingError("authority replay failed verification") from error
    config = verified_replay.get("config")
    if not isinstance(config, Mapping) or config.get("task_id") != SHOWCASE_ID:
        raise RtsShowcasePackagingError("replay is not the Mini RTS showcase")

    probe = probe_video(video_path, ffmpeg_executable)
    _validate_video_probe(probe)
    manifest = _build_manifest(
        metadata=metadata,
        replay_sha256=_sha256(replay_bytes),
        final_state_sha256=_required_sha256(
            verified_replay.get("final_state_hash"), "replay final state"
        ),
        evaluation_sha256=_sha256(evaluation_bytes),
        video_sha256=_sha256(video_bytes),
        probe=probe,
    )
    try:
        CachedRtsShowcase._validate_manifest(manifest)
        CachedRtsShowcase._validate_evaluation(evaluation, manifest)
    except Exception as error:
        raise RtsShowcasePackagingError("evaluation does not bind the sealed showcase") from error

    staged = Path(tempfile.mkdtemp(prefix=f".{target.name}.stage-", dir=target.parent))
    try:
        shutil.copy2(replay_path, staged / REPLAY_NAME)
        shutil.copy2(evaluation_path, staged / EVALUATION_NAME)
        shutil.copy2(video_path, staged / VIDEO_NAME)
        _write_manifest(staged / MANIFEST_NAME, manifest)
        for artifact in staged.iterdir():
            artifact.chmod(0o644)
        _validate_staged_package(root, staged, manifest)
        _replace_directory(staged, target)
    except Exception:
        shutil.rmtree(staged, ignore_errors=True)
        raise
    return target


def probe_video(video_path: Path, ffmpeg_executable: Path) -> Mapping[str, float | int]:
    """Use local/supplied FFmpeg to inspect the playable MP4 stream."""

    ffmpeg = _readable_executable(ffmpeg_executable, "FFmpeg")
    try:
        completed = subprocess.run(
            (str(ffmpeg), "-hide_banner", "-i", str(video_path), "-f", "null", "-"),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
            timeout=180,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RtsShowcasePackagingError("RTS video probe failed") from error
    report = completed.stdout
    if completed.returncode != 0:
        raise RtsShowcasePackagingError("RTS video probe rejected the MP4")
    duration = _parse_duration(report)
    width, height, fps = _parse_video_stream(report)
    return {"duration_seconds": duration, "width": width, "height": height, "fps": fps}


def _build_manifest(
    *,
    metadata: Mapping[str, Any],
    replay_sha256: str,
    final_state_sha256: str,
    evaluation_sha256: str,
    video_sha256: str,
    probe: Mapping[str, float | int],
) -> dict[str, Any]:
    return {
        "schema_version": "worldarena/rts-skirmish-showcase-manifest/2",
        "showcase_id": SHOWCASE_ID,
        "task_id": SHOWCASE_ID,
        "label": metadata["label"],
        "video": {
            "path": VIDEO_NAME,
            "sha256": video_sha256,
            "mime_type": "video/mp4",
            "duration_seconds": int(round(float(probe["duration_seconds"]))),
            "fps": int(probe["fps"]),
            "width": int(probe["width"]),
            "height": int(probe["height"]),
        },
        "replay": {
            "path": REPLAY_NAME,
            "sha256": replay_sha256,
            "final_state_sha256": final_state_sha256,
        },
        "evaluation": {
            "path": EVALUATION_NAME,
            "sha256": evaluation_sha256,
            "metrics": metadata["evaluation_metrics"],
        },
        "completion": metadata["completion"],
        "winner": metadata["winner"],
        "casualties": metadata["casualties"],
        "highlights": metadata["highlights"],
    }


def _load_metadata(path: Path) -> Mapping[str, Any]:
    try:
        value = strict_json_loads(path.read_bytes())
    except (OSError, TypeError, ValueError) as error:
        raise RtsShowcasePackagingError("public RTS metadata JSON is invalid") from error
    if not isinstance(value, dict) or set(value) != {
        "casualties", "completion", "evaluation_metrics", "highlights", "label", "winner"
    }:
        raise RtsShowcasePackagingError("public RTS metadata schema is invalid")
    return value


def _validate_video_probe(probe: Mapping[str, float | int]) -> None:
    duration = probe.get("duration_seconds")
    if (
        probe.get("width") != EXPECTED_WIDTH
        or probe.get("height") != EXPECTED_HEIGHT
        or not isinstance(probe.get("fps"), (int, float))
        or abs(float(probe["fps"]) - EXPECTED_FPS) > 0.001
        or not isinstance(duration, (int, float))
        or isinstance(duration, bool)
        or abs(float(duration) - EXPECTED_DURATION_SECONDS) > DURATION_TOLERANCE_SECONDS
    ):
        raise RtsShowcasePackagingError(
            "RTS video must be 1920x1080 at 30 FPS for 150.0±0.1 seconds"
        )


def _parse_duration(report: str) -> float:
    marker = "Duration: "
    start = report.find(marker)
    if start < 0:
        raise RtsShowcasePackagingError("RTS video duration is unavailable")
    token = report[start + len(marker):].split(",", 1)[0].strip()
    parts = token.split(":")
    if len(parts) != 3:
        raise RtsShowcasePackagingError("RTS video duration is invalid")
    try:
        hours, minutes, seconds = (float(value) for value in parts)
    except ValueError as error:
        raise RtsShowcasePackagingError("RTS video duration is invalid") from error
    return hours * 3600 + minutes * 60 + seconds


def _parse_video_stream(report: str) -> tuple[int, int, float]:
    for line in report.splitlines():
        if " Video: " not in line or " fps" not in line:
            continue
        tokens = line.split()
        dimensions = next(
            (token for token in tokens if "x" in token and token.count("x") == 1), None
        )
        fps_index = next(
            (
                index
                for index, token in enumerate(tokens)
                if token.rstrip(",") == "fps" and index > 0
            ),
            None,
        )
        if dimensions is None or fps_index is None:
            continue
        try:
            width, height = (int(value) for value in dimensions.rstrip(",").split("x", 1))
            fps = float(tokens[fps_index - 1].rstrip(","))
        except (ValueError, IndexError):
            continue
        return width, height, fps
    raise RtsShowcasePackagingError("RTS video stream metadata is unavailable")


def _validate_mp4_header(video: bytes) -> None:
    if len(video) <= 16 or b"ftyp" not in video[:32]:
        raise RtsShowcasePackagingError("RTS video is not an MP4")


def _validate_staged_package(
    root: Path, staged: Path, manifest: Mapping[str, Any]
) -> None:
    """Check the exact bytes about to be made public, not only their source files."""

    try:
        staged_manifest = strict_json_loads((staged / MANIFEST_NAME).read_bytes())
        replay = (staged / REPLAY_NAME).read_bytes()
        evaluation_bytes = (staged / EVALUATION_NAME).read_bytes()
        evaluation = strict_json_loads(evaluation_bytes)
        video = (staged / VIDEO_NAME).read_bytes()
    except (OSError, TypeError, ValueError) as error:
        raise RtsShowcasePackagingError("staged RTS showcase is unreadable") from error
    if staged_manifest != manifest or not isinstance(evaluation, dict):
        raise RtsShowcasePackagingError("staged RTS showcase manifest is invalid")
    if (
        _sha256(replay) != manifest["replay"]["sha256"]
        or _sha256(evaluation_bytes) != manifest["evaluation"]["sha256"]
        or _sha256(video) != manifest["video"]["sha256"]
    ):
        raise RtsShowcasePackagingError("staged RTS showcase hashes are invalid")
    try:
        verified = verify_replay_bytes(
            replay, registry=EmbodimentProtocolRegistry.from_repository(root)
        )
    except Exception as error:
        raise RtsShowcasePackagingError("staged RTS replay failed verification") from error
    if verified.get("final_state_hash") != manifest["replay"]["final_state_sha256"]:
        raise RtsShowcasePackagingError("staged RTS final state is invalid")
    try:
        CachedRtsShowcase._validate_manifest(manifest)
        CachedRtsShowcase._validate_evaluation(evaluation, manifest)
    except Exception as error:
        raise RtsShowcasePackagingError("staged RTS evaluation is invalid") from error


def _replace_directory(staged: Path, destination: Path) -> None:
    """Publish a complete sibling directory, restoring the previous cache on failure."""

    backup: Path | None = None
    if destination.exists():
        if not destination.is_dir() or destination.is_symlink():
            raise RtsShowcasePackagingError("showcase destination is not a directory")
        backup = destination.with_name(f".{destination.name}.previous-{uuid.uuid4().hex}")
        os.replace(destination, backup)
    try:
        os.replace(staged, destination)
    except OSError as error:
        if backup is not None:
            os.replace(backup, destination)
        raise RtsShowcasePackagingError("atomic RTS showcase promotion failed") from error
    if backup is not None:
        shutil.rmtree(backup, ignore_errors=True)


def _write_manifest(path: Path, manifest: Mapping[str, Any]) -> None:
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _readable_file(value: Path, label: str) -> Path:
    path = Path(value).resolve()
    if not path.is_file() or path.is_symlink():
        raise RtsShowcasePackagingError(f"{label} file is unavailable")
    return path


def _readable_executable(value: Path, label: str) -> Path:
    path = Path(value).resolve()
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RtsShowcasePackagingError(f"{label} executable is unavailable")
    return path


def _required_sha256(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(char not in "0123456789abcdef" for char in value)
    ):
        raise RtsShowcasePackagingError(f"{label} digest is invalid")
    return value


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        destination = package_rts_showcase(
            repository_root=arguments.repository_root,
            replay_path=arguments.replay,
            evaluation_path=arguments.evaluation,
            video_path=arguments.video,
            metadata_path=arguments.metadata,
            ffmpeg_executable=arguments.ffmpeg,
            destination=arguments.destination,
        )
    except (OSError, RtsShowcasePackagingError) as error:
        print(f"RTS_SHOWCASE_PACKAGE_FAILED: {error}")
        return 2
    print(f"RTS_SHOWCASE_PACKAGE_OK destination={destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
