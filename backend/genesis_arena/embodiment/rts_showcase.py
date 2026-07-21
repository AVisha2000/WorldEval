"""Immutable, public Mini RTS showcase package.

The featured RTS is a checked-in, verified artifact.  Its manifest is deliberately the one
authority for the public story and integrity bindings: replacing a replay/video requires
replacing the manifest at the same time.  The browser is never given the replay or evaluation
artifact; it receives small allow-listed projections only.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .protocol import strict_json_loads
from .protocol_registry import EmbodimentProtocolRegistry
from .replay import verify_replay_bytes

SHOWCASE_ID = "rts-skirmish-v0"
_ASSET_DIRECTORY = Path("godot/showcases/rts_skirmish")
_MANIFEST_FILENAME = "manifest.json"
_SHA256_LENGTH = 64
_MANIFEST_SCHEMA = "worldarena/rts-skirmish-showcase-manifest/2"
_PUBLIC_TEXT_LIMIT = 180
_PUBLIC_METRIC_LIMIT = 12
_PRIVATE_TERMS = frozenset(
    {
        "api key",
        "api_key",
        "authorization",
        "bearer",
        "chain of thought",
        "credential",
        "memory",
        "observation",
        "prompt",
        "raw output",
        "raw_output",
        "secret",
        "spectator",
        "token",
    }
)


class RtsShowcaseError(RuntimeError):
    """A packaged showcase is absent, tampered with, or not safe to publish."""


@dataclass(frozen=True)
class CachedRtsShowcase:
    """A verified local presentation that is safe to reuse for every dashboard visitor."""

    root: Path
    video_path: Path
    video_sha256: str
    replay_sha256: str
    final_state_sha256: str
    manifest_sha256: str
    manifest: Mapping[str, Any]

    @classmethod
    def load(cls, repository_root: Path) -> CachedRtsShowcase:
        root = Path(repository_root).resolve()
        asset_directory = root / _ASSET_DIRECTORY
        manifest_path = asset_directory / _MANIFEST_FILENAME
        try:
            manifest_bytes = manifest_path.read_bytes()
            manifest = strict_json_loads(manifest_bytes)
        except OSError as error:
            raise RtsShowcaseError("rts_showcase_missing") from error
        if not isinstance(manifest, dict):
            raise RtsShowcaseError("rts_showcase_manifest_invalid")
        cls._validate_manifest(manifest)

        video_spec = manifest["video"]
        replay_spec = manifest["replay"]
        evaluation_spec = manifest["evaluation"]
        video_path = asset_directory / video_spec["path"]
        replay_path = asset_directory / replay_spec["path"]
        evaluation_path = asset_directory / evaluation_spec["path"]
        try:
            video = video_path.read_bytes()
            replay = replay_path.read_bytes()
            evaluation_bytes = evaluation_path.read_bytes()
            evaluation = strict_json_loads(evaluation_bytes)
        except OSError as error:
            raise RtsShowcaseError("rts_showcase_missing") from error
        if not _is_mp4(video):
            raise RtsShowcaseError("rts_showcase_video_invalid")
        if not isinstance(evaluation, dict):
            raise RtsShowcaseError("rts_showcase_evaluation_invalid")

        replay_sha256 = hashlib.sha256(replay).hexdigest()
        video_sha256 = hashlib.sha256(video).hexdigest()
        evaluation_sha256 = hashlib.sha256(evaluation_bytes).hexdigest()
        if replay_sha256 != replay_spec["sha256"]:
            raise RtsShowcaseError("rts_showcase_replay_hash_invalid")
        if video_sha256 != video_spec["sha256"]:
            raise RtsShowcaseError("rts_showcase_video_hash_invalid")
        if evaluation_sha256 != evaluation_spec["sha256"]:
            raise RtsShowcaseError("rts_showcase_evaluation_hash_invalid")

        registry = EmbodimentProtocolRegistry.from_repository(root)
        try:
            verified = verify_replay_bytes(replay, registry=registry)
        except Exception as error:
            raise RtsShowcaseError("rts_showcase_replay_invalid") from error
        if verified["config"].get("task_id") != SHOWCASE_ID:
            raise RtsShowcaseError("rts_showcase_task_invalid")
        if verified["final_state_hash"] != replay_spec["final_state_sha256"]:
            raise RtsShowcaseError("rts_showcase_state_hash_invalid")
        cls._validate_evaluation(evaluation, manifest)

        return cls(
            root=root,
            video_path=video_path,
            video_sha256=video_sha256,
            replay_sha256=replay_sha256,
            final_state_sha256=replay_spec["final_state_sha256"],
            manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
            manifest=manifest,
        )

    @staticmethod
    def _validate_manifest(value: Mapping[str, Any]) -> None:
        required = {
            "casualties",
            "completion",
            "evaluation",
            "highlights",
            "label",
            "replay",
            "schema_version",
            "showcase_id",
            "task_id",
            "video",
            "winner",
        }
        if set(value) != required:
            raise RtsShowcaseError("rts_showcase_manifest_invalid")
        if (
            value.get("schema_version") != _MANIFEST_SCHEMA
            or value.get("showcase_id") != SHOWCASE_ID
            or value.get("task_id") != SHOWCASE_ID
        ):
            raise RtsShowcaseError("rts_showcase_manifest_invalid")
        _public_text(value.get("label"))
        _completion(value.get("completion"))
        winner = _mapping(value.get("winner"))
        if set(winner) != {"team"}:
            raise RtsShowcaseError("rts_showcase_manifest_invalid")
        _public_text(winner.get("team"))
        _asset_spec(
            value.get("video"),
            {"duration_seconds", "fps", "height", "mime_type", "path", "sha256", "width"},
        )
        video = _mapping(value["video"])
        if (
            video.get("mime_type") != "video/mp4"
            or not _positive_int(video.get("duration_seconds"))
            or not _positive_int(video.get("fps"))
            or not _positive_int(video.get("height"))
            or not _positive_int(video.get("width"))
        ):
            raise RtsShowcaseError("rts_showcase_manifest_invalid")
        _asset_spec(value.get("replay"), {"final_state_sha256", "path", "sha256"})
        replay = _mapping(value["replay"])
        _sha256(replay.get("final_state_sha256"))

        evaluation = _mapping(value.get("evaluation"))
        if set(evaluation) != {"metrics", "path", "sha256"}:
            raise RtsShowcaseError("rts_showcase_manifest_invalid")
        _file_name(evaluation.get("path"))
        _sha256(evaluation.get("sha256"))
        metrics = evaluation.get("metrics")
        if not isinstance(metrics, list) or not 1 <= len(metrics) <= _PUBLIC_METRIC_LIMIT:
            raise RtsShowcaseError("rts_showcase_manifest_invalid")
        for metric in metrics:
            item = _mapping(metric)
            if set(item) != {"id", "label", "value"}:
                raise RtsShowcaseError("rts_showcase_manifest_invalid")
            _public_text(item.get("id"), limit=48)
            _public_text(item.get("label"), limit=72)
            _public_text(item.get("value"), limit=_PUBLIC_TEXT_LIMIT)

        highlights = value.get("highlights")
        if not isinstance(highlights, list) or not highlights:
            raise RtsShowcaseError("rts_showcase_manifest_invalid")
        previous = -1
        duration = video["duration_seconds"]
        for highlight in highlights:
            item = _mapping(highlight)
            if set(item) != {"at_seconds", "label"}:
                raise RtsShowcaseError("rts_showcase_manifest_invalid")
            at_seconds = item.get("at_seconds")
            if (
                not isinstance(at_seconds, int)
                or isinstance(at_seconds, bool)
                or not 0 <= at_seconds <= duration
                or at_seconds <= previous
            ):
                raise RtsShowcaseError("rts_showcase_manifest_invalid")
            previous = at_seconds
            _public_text(item.get("label"))

        casualties = value.get("casualties")
        if not isinstance(casualties, list):
            raise RtsShowcaseError("rts_showcase_manifest_invalid")
        last_tick = -1
        for casualty in casualties:
            item = _mapping(casualty)
            if set(item) != {"at_tick", "team", "unit_id"}:
                raise RtsShowcaseError("rts_showcase_manifest_invalid")
            if (
                not isinstance(item.get("at_tick"), int)
                or isinstance(item["at_tick"], bool)
                or item["at_tick"] <= last_tick
            ):
                raise RtsShowcaseError("rts_showcase_manifest_invalid")
            last_tick = item["at_tick"]
            _public_text(item.get("team"), limit=40)
            _public_text(item.get("unit_id"), limit=48)

    @staticmethod
    def _validate_evaluation(value: Mapping[str, Any], manifest: Mapping[str, Any]) -> None:
        """Bind the human-readable evaluation to the sealed manifest without publishing it."""

        media = _mapping(value.get("media"))
        replay = _mapping(value.get("replay"))
        if value.get("task_id") != SHOWCASE_ID or value.get("completion") != manifest["completion"]:
            raise RtsShowcaseError("rts_showcase_evaluation_invalid")
        if (
            media.get("path") != manifest["video"]["path"]
            or media.get("sha256") != manifest["video"]["sha256"]
            or media.get("duration_seconds") != manifest["video"]["duration_seconds"]
            or media.get("width") != manifest["video"]["width"]
            or media.get("height") != manifest["video"]["height"]
            or replay.get("path") != manifest["replay"]["path"]
            or replay.get("sha256") != manifest["replay"]["sha256"]
            or replay.get("final_state_sha256") != manifest["replay"]["final_state_sha256"]
            or replay.get("python_verified") is not True
        ):
            raise RtsShowcaseError("rts_showcase_evaluation_invalid")

    def public_view(self) -> Mapping[str, Any]:
        """Only browser-safe playback and story metadata; never authority replay state."""

        video = self.manifest["video"]
        return {
            "showcase_id": SHOWCASE_ID,
            "task_id": SHOWCASE_ID,
            "label": self.manifest["label"],
            "status": "ready",
            "cached": True,
            "video": {
                "duration_seconds": video["duration_seconds"],
                "fps": video["fps"],
                "height": video["height"],
                "mime_type": video["mime_type"],
                "sha256": self.video_sha256,
                "width": video["width"],
            },
            "winner": dict(self.manifest["winner"]),
            "completion": dict(self.manifest["completion"]),
            "casualties": [dict(item) for item in self.manifest["casualties"]],
            "highlights": [dict(item) for item in self.manifest["highlights"]],
        }

    def public_evaluation(self) -> Mapping[str, Any]:
        """Return the pre-approved metric cards, never the full evaluator artifact."""

        return {
            "showcase_id": SHOWCASE_ID,
            "task_id": SHOWCASE_ID,
            "completion": dict(self.manifest["completion"]),
            "metrics": [dict(item) for item in self.manifest["evaluation"]["metrics"]],
            "verification": {
                "manifest_sha256": self.manifest_sha256,
                "replay_sha256": self.replay_sha256,
                "video_sha256": self.video_sha256,
                "final_state_sha256": self.final_state_sha256,
                "state": "verified",
            },
        }


def _mapping(value: Any) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise RtsShowcaseError("rts_showcase_manifest_invalid")
    return value


def _is_mp4(value: bytes) -> bool:
    return len(value) > 16 and b"ftyp" in value[:32]


def _positive_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _sha256(value: Any) -> None:
    if (
        not isinstance(value, str)
        or len(value) != _SHA256_LENGTH
        or any(char not in "0123456789abcdef" for char in value)
    ):
        raise RtsShowcaseError("rts_showcase_manifest_invalid")


def _file_name(value: Any) -> None:
    if not isinstance(value, str) or not value or Path(value).name != value or value in {".", ".."}:
        raise RtsShowcaseError("rts_showcase_manifest_invalid")


def _asset_spec(value: Any, required: set[str]) -> None:
    item = _mapping(value)
    if set(item) != required:
        raise RtsShowcaseError("rts_showcase_manifest_invalid")
    _file_name(item.get("path"))
    _sha256(item.get("sha256"))


def _completion(value: Any) -> None:
    item = _mapping(value)
    if (
        set(item) != {"outcome", "reason", "tick"}
        or not isinstance(item.get("tick"), int)
        or isinstance(item["tick"], bool)
        or item["tick"] < 0
    ):
        raise RtsShowcaseError("rts_showcase_manifest_invalid")
    _public_text(item.get("outcome"), limit=40)
    _public_text(item.get("reason"), limit=72)


def _public_text(value: Any, *, limit: int = _PUBLIC_TEXT_LIMIT) -> None:
    if not isinstance(value, str) or not value or len(value) > limit or "\x00" in value:
        raise RtsShowcaseError("rts_showcase_manifest_invalid")
    lowered = value.casefold()
    if any(term in lowered for term in _PRIVATE_TERMS):
        raise RtsShowcaseError("rts_showcase_manifest_invalid")


__all__ = ["CachedRtsShowcase", "RtsShowcaseError", "SHOWCASE_ID"]
