"""Durable public evidence and participant-only native playback for trio series."""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

from ..protocol import canonical_json_bytes, strict_json_loads
from ..replay_archive import SavedReplayError, _render_participant_mp4
from .common import TRIO_PARTICIPANT_IDS
from .evidence import TrioSeriesEvidenceBundle

ARCHIVE_FORMAT = "llm-controller/trio-series-archive/1.0.0"
_SERIES = re.compile(r"^trio_[A-Za-z0-9._-]{1,120}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


class TrioSeriesArchiveError(RuntimeError):
    pass


@dataclass(frozen=True)
class ArchivedTrioVideo:
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
class ArchivedTrioSeries:
    series_id: str
    plan_sha256: str
    evidence_sha256: str
    evaluation_sha256: str
    timeline_sha256: str
    result_sha256: str
    videos: tuple[ArchivedTrioVideo, ...] = ()
    native_reason: str = "participant_video_not_configured"

    def public_dict(self) -> Mapping[str, object]:
        native: Mapping[str, object] = (
            {"state": "ready", "artifacts": [value.public_dict() for value in self.videos]}
            if len(self.videos) == 9
            else {"state": "unavailable", "reason": self.native_reason}
        )
        return {
            "archive_format": ARCHIVE_FORMAT,
            "evidence": {"state": "ready", "sha256": self.evidence_sha256},
            "evaluation": {"state": "ready", "sha256": self.evaluation_sha256},
            "native_replay": native,
            "plan_sha256": self.plan_sha256,
            "result": {"state": "ready", "sha256": self.result_sha256},
            "series_id": self.series_id,
            "timeline": {"state": "ready", "sha256": self.timeline_sha256},
        }


class TrioSeriesArchive:
    def __init__(
        self,
        runs_dir: Path,
        *,
        godot_executable: Path | None = None,
        godot_project_path: Path | None = None,
        ffmpeg_executable: Path | None = None,
    ) -> None:
        self._root = Path(runs_dir).resolve() / "embodiment-trio-series"
        self._godot = None if godot_executable is None else Path(godot_executable).resolve()
        self._project = (
            None if godot_project_path is None else Path(godot_project_path).resolve()
        )
        self._ffmpeg = None if ffmpeg_executable is None else Path(ffmpeg_executable).resolve()
        configured = (self._godot is not None, self._project is not None, self._ffmpeg is not None)
        if any(configured) and not all(configured):
            raise ValueError("trio native renderer configuration is incomplete")

    def save(
        self,
        public: TrioSeriesEvidenceBundle,
        *,
        evaluation: Mapping[str, object],
        timeline: Mapping[str, object],
        result: Mapping[str, object],
        protected: TrioSeriesEvidenceBundle | None,
    ) -> ArchivedTrioSeries:
        public = TrioSeriesEvidenceBundle.verify(public.bundle_bytes)
        if public.layer != "public" or _SERIES.fullmatch(public.series_id) is None:
            raise TrioSeriesArchiveError("trio public evidence identity is invalid")
        if protected is not None:
            protected = TrioSeriesEvidenceBundle.verify(protected.bundle_bytes)
            if (
                protected.layer != "protected"
                or protected.series_id != public.series_id
                or protected.plan_sha256 != public.plan_sha256
            ):
                raise TrioSeriesArchiveError("trio protected evidence identity differs")
        projections = {
            "evaluation": canonical_json_bytes(dict(evaluation)),
            "timeline": canonical_json_bytes(dict(timeline)),
            "result": canonical_json_bytes(dict(result)),
        }
        self._root.mkdir(mode=0o700, parents=True, exist_ok=True)
        target = self._directory(public.series_id)
        existing = self.get(public.series_id) if target.exists() else None
        if existing is not None:
            return existing
        if target.exists():
            raise TrioSeriesArchiveError("trio archive target already exists")
        staging = Path(tempfile.mkdtemp(prefix=f".{public.series_id}-", dir=self._root))
        try:
            (staging / "public.bundle.json").write_bytes(public.bundle_bytes)
            for name, payload in projections.items():
                (staging / f"{name}.json").write_bytes(payload)
            videos, native_reason = self._render(staging, protected)
            archived = ArchivedTrioSeries(
                public.series_id,
                public.plan_sha256,
                hashlib.sha256(public.bundle_bytes).hexdigest(),
                hashlib.sha256(projections["evaluation"]).hexdigest(),
                hashlib.sha256(projections["timeline"]).hexdigest(),
                hashlib.sha256(projections["result"]).hexdigest(),
                videos,
                native_reason,
            )
            (staging / "manifest.json").write_bytes(
                canonical_json_bytes(archived.public_dict())
            )
            os.replace(staging, target)
        except Exception as error:
            shutil.rmtree(staging, ignore_errors=True)
            raise TrioSeriesArchiveError("trio archive could not be finalized") from error
        return self._load(public.series_id)

    def get(self, series_id: str) -> ArchivedTrioSeries | None:
        if not isinstance(series_id, str) or _SERIES.fullmatch(series_id) is None:
            return None
        try:
            return self._load(series_id)
        except (OSError, TrioSeriesArchiveError):
            return None

    def replay(self, series_id: str) -> TrioSeriesEvidenceBundle | None:
        archived = self.get(series_id)
        if archived is None:
            return None
        payload = (self._directory(series_id) / "public.bundle.json").read_bytes()
        if hashlib.sha256(payload).hexdigest() != archived.evidence_sha256:
            raise TrioSeriesArchiveError("trio archive evidence hash differs")
        return TrioSeriesEvidenceBundle.verify(payload)

    def projection(self, series_id: str, name: str) -> Mapping[str, object] | None:
        if name not in ("evaluation", "timeline", "result"):
            raise ValueError("unknown trio archive projection")
        archived = self.get(series_id)
        if archived is None:
            return None
        payload = (self._directory(series_id) / f"{name}.json").read_bytes()
        if hashlib.sha256(payload).hexdigest() != getattr(archived, f"{name}_sha256"):
            raise TrioSeriesArchiveError(f"trio archive {name} hash differs")
        value = strict_json_loads(payload)
        if not isinstance(value, dict):
            raise TrioSeriesArchiveError(f"trio archive {name} is invalid")
        return value

    def video_path(
        self, series_id: str, leg_index: int, participant_id: str
    ) -> Path | None:
        archived = self.get(series_id)
        if archived is None:
            return None
        video = next(
            (
                value
                for value in archived.videos
                if value.leg_index == leg_index and value.participant_id == participant_id
            ),
            None,
        )
        if video is None:
            return None
        path = self._directory(series_id) / video.filename
        try:
            if (
                path.stat().st_size != video.size_bytes
                or hashlib.sha256(path.read_bytes()).hexdigest() != video.sha256
            ):
                return None
        except OSError:
            return None
        return path

    def _render(
        self, staging: Path, protected: TrioSeriesEvidenceBundle | None
    ) -> tuple[tuple[ArchivedTrioVideo, ...], str]:
        if self._godot is None or protected is None:
            return (), "participant_video_not_configured"
        videos = []
        try:
            for leg_index, leg in enumerate(protected.legs):
                replay_path = staging / f".leg-{leg_index}.replay.json"
                replay_path.write_bytes(leg.read("authority_replay"))
                try:
                    for participant_id in TRIO_PARTICIPANT_IDS:
                        output = staging / f"leg-{leg_index}-{participant_id}.mp4"
                        _render_participant_mp4(
                            replay_path=replay_path,
                            output_path=output,
                            godot_executable=self._godot,
                            godot_project_path=self._project,  # type: ignore[arg-type]
                            ffmpeg_executable=self._ffmpeg,  # type: ignore[arg-type]
                            protocol_version="llm-controller/0.3.0",
                            participant_id=participant_id,
                        )
                        payload = output.read_bytes()
                        videos.append(
                            ArchivedTrioVideo(
                                leg_index,
                                participant_id,
                                hashlib.sha256(payload).hexdigest(),
                                len(payload),
                            )
                        )
                finally:
                    replay_path.unlink(missing_ok=True)
        except (OSError, SavedReplayError):
            for path in staging.glob("leg-*-participant_*.mp4"):
                path.unlink(missing_ok=True)
            return (), "participant_video_render_failed"
        return tuple(videos), ""

    def _load(self, series_id: str) -> ArchivedTrioSeries:
        directory = self._directory(series_id)
        payload = (directory / "manifest.json").read_bytes()
        value = strict_json_loads(payload)
        if not isinstance(value, dict) or canonical_json_bytes(value) != payload:
            raise TrioSeriesArchiveError("trio archive manifest is invalid")
        if set(value) != {
            "archive_format",
            "evidence",
            "evaluation",
            "native_replay",
            "plan_sha256",
            "result",
            "series_id",
            "timeline",
        } or value.get("archive_format") != ARCHIVE_FORMAT or value.get(
            "series_id"
        ) != series_id:
            raise TrioSeriesArchiveError("trio archive manifest fields differ")
        digests = {}
        for name in ("evidence", "evaluation", "result", "timeline"):
            descriptor = value[name]
            if (
                not isinstance(descriptor, dict)
                or set(descriptor) != {"state", "sha256"}
                or descriptor.get("state") != "ready"
                or not isinstance(descriptor.get("sha256"), str)
                or _SHA256.fullmatch(descriptor["sha256"]) is None
            ):
                raise TrioSeriesArchiveError("trio archive descriptor is invalid")
            digests[name] = descriptor["sha256"]
        plan_sha = value.get("plan_sha256")
        if not isinstance(plan_sha, str) or _SHA256.fullmatch(plan_sha) is None:
            raise TrioSeriesArchiveError("trio archive plan hash is invalid")
        native = value["native_replay"]
        videos: tuple[ArchivedTrioVideo, ...] = ()
        native_reason = ""
        if isinstance(native, dict) and set(native) == {"state", "artifacts"} and native.get(
            "state"
        ) == "ready":
            artifacts = native["artifacts"]
            if not isinstance(artifacts, list) or len(artifacts) != 9:
                raise TrioSeriesArchiveError("trio native artifacts differ")
            videos = tuple(_video(value) for value in artifacts)
        elif isinstance(native, dict) and set(native) == {"state", "reason"} and native.get(
            "state"
        ) == "unavailable" and native.get("reason") in (
            "participant_video_not_configured",
            "participant_video_render_failed",
        ):
            native_reason = native["reason"]
        else:
            raise TrioSeriesArchiveError("trio native replay status differs")
        archived = ArchivedTrioSeries(
            series_id,
            plan_sha,
            digests["evidence"],
            digests["evaluation"],
            digests["timeline"],
            digests["result"],
            videos,
            native_reason,
        )
        if videos:
            identities = {
                (video.leg_index, video.participant_id) for video in videos
            }
            expected = {
                (leg_index, participant_id)
                for leg_index in (0, 1, 2)
                for participant_id in TRIO_PARTICIPANT_IDS
            }
            if identities != expected:
                raise TrioSeriesArchiveError("trio native artifact identities differ")
        files = {
            "public.bundle.json": archived.evidence_sha256,
            "evaluation.json": archived.evaluation_sha256,
            "timeline.json": archived.timeline_sha256,
            "result.json": archived.result_sha256,
        }
        for filename, digest in files.items():
            if hashlib.sha256((directory / filename).read_bytes()).hexdigest() != digest:
                raise TrioSeriesArchiveError("trio archive file hash differs")
        for video in videos:
            path = directory / video.filename
            if (
                path.stat().st_size != video.size_bytes
                or hashlib.sha256(path.read_bytes()).hexdigest() != video.sha256
            ):
                raise TrioSeriesArchiveError("trio native replay file differs")
        bundle = TrioSeriesEvidenceBundle.verify((directory / "public.bundle.json").read_bytes())
        if bundle.series_id != series_id or bundle.plan_sha256 != plan_sha:
            raise TrioSeriesArchiveError("trio archive evidence identity differs")
        return archived

    def _directory(self, series_id: str) -> Path:
        return self._root / series_id


def _video(value: object) -> ArchivedTrioVideo:
    if not isinstance(value, dict) or set(value) != {
        "fps",
        "height",
        "leg_index",
        "mime_type",
        "participant_id",
        "sha256",
        "size_bytes",
        "width",
    }:
        raise TrioSeriesArchiveError("trio video descriptor is invalid")
    if (
        value.get("fps") != 30
        or value.get("height") != 720
        or value.get("width") != 1280
        or value.get("mime_type") != "video/mp4"
        or value.get("leg_index") not in (0, 1, 2)
        or value.get("participant_id") not in TRIO_PARTICIPANT_IDS
        or not isinstance(value.get("sha256"), str)
        or _SHA256.fullmatch(value["sha256"]) is None
        or isinstance(value.get("size_bytes"), bool)
        or not isinstance(value.get("size_bytes"), int)
        or value["size_bytes"] < 1024
    ):
        raise TrioSeriesArchiveError("trio video descriptor values differ")
    return ArchivedTrioVideo(
        value["leg_index"], value["participant_id"], value["sha256"], value["size_bytes"]
    )


__all__ = [
    "ARCHIVE_FORMAT",
    "ArchivedTrioSeries",
    "ArchivedTrioVideo",
    "TrioSeriesArchive",
    "TrioSeriesArchiveError",
]
