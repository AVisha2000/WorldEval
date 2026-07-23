"""Durable public evidence and verified participant-view playback for paired duels.

Protected authority replays are accepted only as private render inputs and are deleted before the
archive is finalized.  The durable directory contains the public aggregate evidence, safe
evaluation/timeline projections, and (when rendering succeeds) four participant-isolated MP4s:
one for each seat in each leg.  It never contains observations, prompts, provider output,
credentials, protected bundles, or spectator pixels.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Tuple

from ..protocol import canonical_json_bytes, strict_json_loads
from ..replay_archive import SavedReplayError, _render_participant_mp4
from .evidence import DuelSeriesEvidenceBundle

ARCHIVE_FORMAT = "llm-controller/paired-duel-archive/1.1.0"
_ARCHIVE_DIR = "embodiment-duel-series"
_SERIES_ID = re.compile(r"^series_[A-Za-z0-9._-]{1,120}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_PARTICIPANTS = ("participant_0", "participant_1")


class DuelSeriesArchiveError(RuntimeError):
    """A sealed public pair cannot be safely persisted or loaded."""


@dataclass(frozen=True)
class ArchivedDuelVideo:
    leg_index: int
    participant_id: str
    sha256: str
    size_bytes: int

    @property
    def filename(self) -> str:
        return f"leg-{self.leg_index}-{self.participant_id}.mp4"

    def public_dict(self) -> Mapping[str, object]:
        return {
            "fps": 30,
            "height": 720,
            "leg_index": self.leg_index,
            "mime_type": "video/mp4",
            "participant_id": self.participant_id,
            "sha256": self.sha256,
            "size_bytes": self.size_bytes,
            "width": 1280,
        }


@dataclass(frozen=True)
class ArchivedDuelSeries:
    series_id: str
    plan_sha256: str
    evidence_sha256: str
    evaluation_sha256: str
    timeline_sha256: str
    videos: Tuple[ArchivedDuelVideo, ...] = ()
    native_reason: str = "participant_video_not_configured"

    def public_dict(self) -> Mapping[str, object]:
        native: Mapping[str, object] = (
            {"state": "ready", "artifacts": [video.public_dict() for video in self.videos]}
            if len(self.videos) == 4
            else {"state": "unavailable", "reason": self.native_reason}
        )
        return {
            "archive_format": ARCHIVE_FORMAT,
            "evidence": {"state": "ready", "sha256": self.evidence_sha256},
            "evaluation": {"state": "ready", "sha256": self.evaluation_sha256},
            "native_replay": native,
            "plan_sha256": self.plan_sha256,
            "series_id": self.series_id,
            "timeline": {"state": "ready", "sha256": self.timeline_sha256},
        }


class DuelSeriesArchive:
    """Atomically retain a verified pair and its participant-only native playback."""

    def __init__(
        self,
        runs_dir: Path,
        *,
        godot_executable: Path | None = None,
        godot_project_path: Path | None = None,
        ffmpeg_executable: Path | None = None,
    ) -> None:
        self._root = Path(runs_dir).resolve() / _ARCHIVE_DIR
        self._godot_executable = (
            None if godot_executable is None else Path(godot_executable).resolve()
        )
        self._godot_project_path = (
            None if godot_project_path is None else Path(godot_project_path).resolve()
        )
        self._ffmpeg_executable = (
            None if ffmpeg_executable is None else Path(ffmpeg_executable).resolve()
        )
        configured = (
            self._godot_executable is not None,
            self._godot_project_path is not None,
            self._ffmpeg_executable is not None,
        )
        if any(configured) and not all(configured):
            raise ValueError("paired native renderer configuration is incomplete")

    def save(
        self,
        bundle: DuelSeriesEvidenceBundle,
        *,
        evaluation: Mapping[str, object],
        timeline: Mapping[str, object],
        protected_bundle: DuelSeriesEvidenceBundle | None = None,
    ) -> ArchivedDuelSeries:
        public = DuelSeriesEvidenceBundle.verify(bundle.bundle_bytes)
        if public.layer != "public" or public.series_id != bundle.series_id:
            raise DuelSeriesArchiveError("paired archive requires matching public evidence")
        if _SERIES_ID.fullmatch(public.series_id) is None:
            raise DuelSeriesArchiveError("paired archive series id is invalid")
        protected = self._validated_protected(public, protected_bundle)
        evaluation_bytes = canonical_json_bytes(dict(evaluation))
        timeline_bytes = canonical_json_bytes(dict(timeline))
        self._validate_projection(evaluation_bytes, public.series_id, "evaluation")
        self._validate_projection(timeline_bytes, public.series_id, "timeline")

        self._root.mkdir(mode=0o700, parents=True, exist_ok=True)
        target = self._directory(public.series_id)
        existing = self.get(public.series_id) if target.exists() else None
        if existing is not None:
            return existing
        if target.exists():
            raise DuelSeriesArchiveError("paired archive target already exists")
        staging = Path(tempfile.mkdtemp(prefix=f".{public.series_id}-", dir=self._root))
        try:
            (staging / "public.bundle.json").write_bytes(public.bundle_bytes)
            (staging / "evaluation.json").write_bytes(evaluation_bytes)
            (staging / "timeline.json").write_bytes(timeline_bytes)
            videos, native_reason = self._render_native_videos(staging, protected)
            archived = ArchivedDuelSeries(
                series_id=public.series_id,
                plan_sha256=public.plan_sha256,
                evidence_sha256=hashlib.sha256(public.bundle_bytes).hexdigest(),
                evaluation_sha256=hashlib.sha256(evaluation_bytes).hexdigest(),
                timeline_sha256=hashlib.sha256(timeline_bytes).hexdigest(),
                videos=videos,
                native_reason=native_reason,
            )
            (staging / "manifest.json").write_bytes(canonical_json_bytes(archived.public_dict()))
            os.replace(staging, target)
        except Exception as error:
            shutil.rmtree(staging, ignore_errors=True)
            raise DuelSeriesArchiveError("paired archive could not be finalized") from error
        return self._load(public.series_id)

    def get(self, series_id: str) -> ArchivedDuelSeries | None:
        if _SERIES_ID.fullmatch(series_id) is None:
            return None
        try:
            return self._load(series_id)
        except (OSError, DuelSeriesArchiveError):
            return None

    def replay(self, series_id: str) -> DuelSeriesEvidenceBundle | None:
        archived = self.get(series_id)
        if archived is None:
            return None
        payload = (self._directory(series_id) / "public.bundle.json").read_bytes()
        bundle = DuelSeriesEvidenceBundle.verify(payload)
        if hashlib.sha256(payload).hexdigest() != archived.evidence_sha256:
            raise DuelSeriesArchiveError("paired archive evidence hash differs")
        return bundle

    def evaluation(self, series_id: str) -> Mapping[str, object] | None:
        return self._projection(series_id, "evaluation")

    def timeline(self, series_id: str) -> Mapping[str, object] | None:
        return self._projection(series_id, "timeline")

    def video_path(
        self, series_id: str, leg_index: int, participant_id: str
    ) -> Path | None:
        archived = self.get(series_id)
        if archived is None:
            return None
        video = next(
            (
                value for value in archived.videos
                if value.leg_index == leg_index and value.participant_id == participant_id
            ),
            None,
        )
        if video is None:
            return None
        path = self._directory(series_id) / video.filename
        try:
            if (
                not path.is_file()
                or path.stat().st_size != video.size_bytes
                or hashlib.sha256(path.read_bytes()).hexdigest() != video.sha256
            ):
                return None
        except OSError:
            return None
        return path

    def _render_native_videos(
        self,
        staging: Path,
        protected: DuelSeriesEvidenceBundle | None,
    ) -> tuple[Tuple[ArchivedDuelVideo, ...], str]:
        if self._godot_executable is None or protected is None:
            return (), "participant_video_not_configured"
        videos = []
        try:
            for leg_index, leg in enumerate(protected.legs):
                replay_path = staging / f".leg-{leg_index}-authority.replay.json"
                replay_payload = leg.read("authority_replay")
                replay_value = strict_json_loads(replay_payload)
                if not isinstance(replay_value, dict):
                    raise DuelSeriesArchiveError("paired replay protocol identity is invalid")
                # Frozen v1 protected fixtures predate an explicit top-level field; current
                # verified v1/v2 ledgers always bind their protocol before reaching the archive.
                protocol_version = replay_value.get("protocol_version", "llm-controller/0.1.0")
                if not isinstance(protocol_version, str):
                    raise DuelSeriesArchiveError("paired replay protocol identity is invalid")
                replay_path.write_bytes(replay_payload)
                try:
                    for participant_id in _PARTICIPANTS:
                        output = staging / f"leg-{leg_index}-{participant_id}.mp4"
                        _render_participant_mp4(
                            replay_path=replay_path,
                            output_path=output,
                            godot_executable=self._godot_executable,
                            godot_project_path=self._godot_project_path,
                            ffmpeg_executable=self._ffmpeg_executable,
                            protocol_version=protocol_version,
                            participant_id=participant_id,
                        )
                        payload = output.read_bytes()
                        if len(payload) < 1024:
                            raise DuelSeriesArchiveError("paired participant video is empty")
                        videos.append(
                            ArchivedDuelVideo(
                                leg_index, participant_id,
                                hashlib.sha256(payload).hexdigest(), len(payload)
                            )
                        )
                finally:
                    replay_path.unlink(missing_ok=True)
        except (OSError, SavedReplayError, DuelSeriesArchiveError):
            for child in staging.glob("leg-*-participant_*.mp4"):
                child.unlink(missing_ok=True)
            return (), "participant_video_render_failed"
        return tuple(videos), ""

    def _projection(self, series_id: str, name: str) -> Mapping[str, object] | None:
        archived = self.get(series_id)
        if archived is None:
            return None
        payload = (self._directory(series_id) / f"{name}.json").read_bytes()
        if hashlib.sha256(payload).hexdigest() != getattr(archived, f"{name}_sha256"):
            raise DuelSeriesArchiveError(f"paired archive {name} hash differs")
        value = strict_json_loads(payload)
        if not isinstance(value, dict):
            raise DuelSeriesArchiveError(f"paired archive {name} is invalid")
        return value

    def _load(self, series_id: str) -> ArchivedDuelSeries:
        directory = self._directory(series_id)
        manifest_bytes = (directory / "manifest.json").read_bytes()
        value = strict_json_loads(manifest_bytes)
        if not isinstance(value, dict) or canonical_json_bytes(value) != manifest_bytes:
            raise DuelSeriesArchiveError("paired archive manifest is invalid")
        if set(value) != {
            "archive_format", "evidence", "evaluation", "native_replay",
            "plan_sha256", "series_id", "timeline",
        } or value.get("archive_format") != ARCHIVE_FORMAT or value.get("series_id") != series_id:
            raise DuelSeriesArchiveError("paired archive manifest fields differ")
        evidence = value.get("evidence")
        evaluation = value.get("evaluation")
        timeline = value.get("timeline")
        for descriptor in (evidence, evaluation, timeline):
            if (
                not isinstance(descriptor, dict)
                or set(descriptor) != {"state", "sha256"}
                or descriptor.get("state") != "ready"
                or not isinstance(descriptor.get("sha256"), str)
                or _SHA256.fullmatch(descriptor["sha256"]) is None
            ):
                raise DuelSeriesArchiveError("paired archive descriptor is invalid")
        native = value.get("native_replay")
        videos: Tuple[ArchivedDuelVideo, ...] = ()
        native_reason = ""
        if (
            isinstance(native, dict)
            and native.get("state") == "ready"
            and set(native) == {"state", "artifacts"}
        ):
            artifacts = native.get("artifacts")
            if not isinstance(artifacts, list) or len(artifacts) != 4:
                raise DuelSeriesArchiveError("paired archive native artifacts differ")
            videos = tuple(self._video_from_public(child) for child in artifacts)
            expected = {(leg, participant) for leg in (0, 1) for participant in _PARTICIPANTS}
            if {(video.leg_index, video.participant_id) for video in videos} != expected:
                raise DuelSeriesArchiveError("paired archive native identities differ")
        elif (
            isinstance(native, dict)
            and set(native) == {"state", "reason"}
            and native.get("state") == "unavailable"
            and native.get("reason")
            in ("participant_video_not_configured", "participant_video_render_failed")
        ):
            native_reason = str(native["reason"])
        else:
            raise DuelSeriesArchiveError("paired archive native replay status differs")
        plan_sha256 = value.get("plan_sha256")
        if not isinstance(plan_sha256, str) or _SHA256.fullmatch(plan_sha256) is None:
            raise DuelSeriesArchiveError("paired archive plan hash is invalid")
        archived = ArchivedDuelSeries(
            series_id, plan_sha256, evidence["sha256"], evaluation["sha256"],
            timeline["sha256"], videos, native_reason
        )
        files = {
            "public.bundle.json": archived.evidence_sha256,
            "evaluation.json": archived.evaluation_sha256,
            "timeline.json": archived.timeline_sha256,
        }
        for filename, digest in files.items():
            if hashlib.sha256((directory / filename).read_bytes()).hexdigest() != digest:
                raise DuelSeriesArchiveError("paired archive file hash differs")
        for video in videos:
            path = directory / video.filename
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if path.stat().st_size != video.size_bytes or digest != video.sha256:
                raise DuelSeriesArchiveError("paired archive video differs")
        bundle = DuelSeriesEvidenceBundle.verify((directory / "public.bundle.json").read_bytes())
        if bundle.series_id != series_id or bundle.plan_sha256 != plan_sha256:
            raise DuelSeriesArchiveError("paired archive evidence identity differs")
        return archived

    @staticmethod
    def _video_from_public(value: object) -> ArchivedDuelVideo:
        if not isinstance(value, dict) or set(value) != {
            "fps", "height", "leg_index", "mime_type", "participant_id",
            "sha256", "size_bytes", "width",
        }:
            raise DuelSeriesArchiveError("paired archive video descriptor is invalid")
        if (
            value.get("leg_index") not in (0, 1)
            or value.get("participant_id") not in _PARTICIPANTS
            or value.get("mime_type") != "video/mp4"
            or (value.get("width"), value.get("height"), value.get("fps")) != (1280, 720, 30)
            or isinstance(value.get("size_bytes"), bool)
            or not isinstance(value.get("size_bytes"), int)
            or value["size_bytes"] < 1024
            or not isinstance(value.get("sha256"), str)
            or _SHA256.fullmatch(value["sha256"]) is None
        ):
            raise DuelSeriesArchiveError("paired archive video descriptor value is invalid")
        return ArchivedDuelVideo(
            value["leg_index"], value["participant_id"], value["sha256"], value["size_bytes"]
        )

    @staticmethod
    def _validated_protected(
        public: DuelSeriesEvidenceBundle,
        value: DuelSeriesEvidenceBundle | None,
    ) -> DuelSeriesEvidenceBundle | None:
        if value is None:
            return None
        protected = DuelSeriesEvidenceBundle.verify(value.bundle_bytes)
        if (
            protected.layer != "protected"
            or protected.series_id != public.series_id
            or protected.plan_sha256 != public.plan_sha256
            or protected.fairness_lock_sha256 != public.fairness_lock_sha256
        ):
            raise DuelSeriesArchiveError("paired protected render input identity differs")
        return protected

    @staticmethod
    def _validate_projection(payload: bytes, series_id: str, name: str) -> None:
        value = strict_json_loads(payload)
        if not isinstance(value, dict) or value.get("series_id") != series_id:
            raise DuelSeriesArchiveError(f"paired archive {name} identity differs")

    def _directory(self, series_id: str) -> Path:
        if _SERIES_ID.fullmatch(series_id) is None:
            raise DuelSeriesArchiveError("paired archive series id is invalid")
        return self._root / series_id


__all__ = [
    "ArchivedDuelSeries",
    "ArchivedDuelVideo",
    "DuelSeriesArchive",
    "DuelSeriesArchiveError",
]
