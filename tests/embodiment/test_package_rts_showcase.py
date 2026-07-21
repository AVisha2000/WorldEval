from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest

from scripts import package_rts_showcase as package

ROOT = Path(__file__).resolve().parents[2]


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _metadata() -> dict[str, object]:
    return {
        "label": "WorldArena: Mini RTS — Blue vs Red",
        "winner": {"team": "Blue Command"},
        "completion": {"outcome": "win", "reason": "town_hall_destroyed", "tick": 1190},
        "casualties": [
            {"at_tick": 850, "team": "Blue", "unit_id": "blue_0"},
            {"at_tick": 880, "team": "Red", "unit_id": "red_0"},
        ],
        "highlights": [
            {"at_seconds": 0, "label": "Workers deploy"},
            {"at_seconds": 80, "label": "Bridge battle"},
            {"at_seconds": 145, "label": "Blue victory"},
        ],
        "evaluation_metrics": [
            {"id": "economy", "label": "Economy", "value": "Three workers gather resources"},
            {"id": "determinism", "label": "Determinism", "value": "Replay verified"},
        ],
    }


def _source_files(tmp_path: Path) -> tuple[Path, Path, Path, Path]:
    replay = tmp_path / "source.replay.json"
    replay.write_bytes(b"sealed replay")
    video = tmp_path / "source.mp4"
    video.write_bytes(b"\x00\x00\x00\x18ftypisom" + b"0" * 32)
    evaluation = tmp_path / "source-evaluation.json"
    evaluation.write_text(
        json.dumps(
            {
                "task_id": "rts-skirmish-v0",
                "completion": _metadata()["completion"],
                "media": {
                    "path": package.VIDEO_NAME,
                    "sha256": _sha256(video.read_bytes()),
                    "duration_seconds": 150,
                    "width": 1920,
                    "height": 1080,
                },
                "replay": {
                    "path": package.REPLAY_NAME,
                    "sha256": _sha256(replay.read_bytes()),
                    "final_state_sha256": "f" * 64,
                    "python_verified": True,
                },
            }
        ),
        encoding="utf-8",
    )
    metadata = tmp_path / "public-story.json"
    metadata.write_text(json.dumps(_metadata()), encoding="utf-8")
    return replay, evaluation, video, metadata


def _verified_replay(_replay: bytes, *, registry: object) -> dict[str, object]:
    del registry
    return {
        "config": {"task_id": "rts-skirmish-v0"},
        "final_state_hash": "f" * 64,
    }


def test_package_rts_showcase_validates_then_promotes_all_four_artifacts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    replay, evaluation, video, metadata = _source_files(tmp_path)
    monkeypatch.setattr(package, "verify_replay_bytes", _verified_replay)
    monkeypatch.setattr(
        package,
        "probe_video",
        lambda *_args: {"duration_seconds": 150.0, "width": 1920, "height": 1080, "fps": 30.0},
    )
    destination = tmp_path / "rts_skirmish"

    promoted = package.package_rts_showcase(
        repository_root=ROOT,
        replay_path=replay,
        evaluation_path=evaluation,
        video_path=video,
        metadata_path=metadata,
        ffmpeg_executable=tmp_path / "unused-ffmpeg",
        destination=destination,
    )

    assert promoted == destination
    assert {path.name for path in destination.iterdir()} == {
        package.REPLAY_NAME,
        package.EVALUATION_NAME,
        package.VIDEO_NAME,
        package.MANIFEST_NAME,
    }
    manifest = json.loads((destination / package.MANIFEST_NAME).read_text(encoding="utf-8"))
    assert manifest["video"]["duration_seconds"] == 150
    assert manifest["video"]["fps"] == 30
    assert manifest["replay"]["sha256"] == _sha256(replay.read_bytes())
    assert "raw_output" not in repr(manifest)
    assert all(path.stat().st_mode & 0o777 == 0o644 for path in destination.iterdir())


def test_package_rts_showcase_does_not_replace_existing_cache_on_bad_video(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    replay, evaluation, video, metadata = _source_files(tmp_path)
    destination = tmp_path / "rts_skirmish"
    destination.mkdir()
    sentinel = destination / "keep.txt"
    sentinel.write_text("previous cache", encoding="utf-8")
    monkeypatch.setattr(package, "verify_replay_bytes", _verified_replay)
    monkeypatch.setattr(
        package,
        "probe_video",
        lambda *_args: {"duration_seconds": 149.7, "width": 1920, "height": 1080, "fps": 30.0},
    )

    with pytest.raises(package.RtsShowcasePackagingError, match="150.0"):
        package.package_rts_showcase(
            repository_root=ROOT,
            replay_path=replay,
            evaluation_path=evaluation,
            video_path=video,
            metadata_path=metadata,
            ffmpeg_executable=tmp_path / "unused-ffmpeg",
            destination=destination,
        )

    assert sentinel.read_text(encoding="utf-8") == "previous cache"


def test_video_probe_parser_rejects_fractional_fps() -> None:
    report = """
Input #0, mov, from 'rts.mp4':
  Duration: 00:02:30.00, start: 0.000000, bitrate: 1 kb/s
  Stream #0:0: Video: h264, yuv420p, 1920x1080, 29.97 fps, 29.97 tbr
"""
    assert package._parse_duration(report) == 150.0
    assert package._parse_video_stream(report) == (1920, 1080, 29.97)
    with pytest.raises(package.RtsShowcasePackagingError, match="30 FPS"):
        package._validate_video_probe(
            {"duration_seconds": 150.0, "width": 1920, "height": 1080, "fps": 29.97}
        )
