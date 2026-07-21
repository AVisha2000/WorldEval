"""Checked-in, evidence-bound solo gameplay highlight for hosted Controller Labs."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .protocol import strict_json_loads

SHOWCASE_ID = "solo-multi-action-v0"
TASK_ID = "construction-v0"
SCENARIO_ID = "multi-action-demo-v0"
ASSET_DIRECTORY = Path("godot/showcases/solo_multi_action")
EVIDENCE_FILENAME = "evidence.json"
EXPECTED_EVIDENCE_SHA256 = "ee168abab86ad6d720171f1ae4cb2a80810e094ce229dbae098dcefcfbb5bd09"
MAX_VIDEO_BYTES = 90 * 1024 * 1024
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


class SoloShowcaseError(RuntimeError):
    """The packaged solo video or its native-video evidence is invalid."""


@dataclass(frozen=True)
class CachedSoloShowcase:
    video_path: Path
    evidence_sha256: str
    evidence: Mapping[str, Any]

    @classmethod
    def load(cls, repository_root: Path) -> CachedSoloShowcase:
        directory = Path(repository_root).resolve() / ASSET_DIRECTORY
        try:
            evidence_bytes = (directory / EVIDENCE_FILENAME).read_bytes()
            evidence = strict_json_loads(evidence_bytes)
        except OSError as error:
            raise SoloShowcaseError("solo_showcase_missing") from error
        evidence_sha256 = hashlib.sha256(evidence_bytes).hexdigest()
        if evidence_sha256 != EXPECTED_EVIDENCE_SHA256 or not isinstance(evidence, dict):
            raise SoloShowcaseError("solo_showcase_evidence_invalid")
        _validate_evidence(evidence)

        video = evidence["video"]
        video_path = directory / video["path"]
        try:
            video_bytes = video_path.read_bytes()
        except OSError as error:
            raise SoloShowcaseError("solo_showcase_missing") from error
        if (
            len(video_bytes) != video["size_bytes"]
            or len(video_bytes) > MAX_VIDEO_BYTES
            or hashlib.sha256(video_bytes).hexdigest() != video["sha256"]
            or len(video_bytes) < 32
            or b"ftyp" not in video_bytes[:32]
        ):
            raise SoloShowcaseError("solo_showcase_video_invalid")
        return cls(video_path=video_path, evidence_sha256=evidence_sha256, evidence=evidence)

    def public_view(self) -> Mapping[str, Any]:
        authority = self.evidence["authority"]
        video = self.evidence["video"]
        return {
            "showcase_id": SHOWCASE_ID,
            "task_id": TASK_ID,
            "scenario_id": SCENARIO_ID,
            "label": "Solo Multi-Action Construction",
            "tagline": (
                "Turn, walk, gather, carry, deposit, build, and celebrate in one "
                "sealed run."
            ),
            "status": "ready",
            "cached": True,
            "participant": {
                "participant_id": self.evidence["participant_id"],
                "display_name": "Demo Builder",
                "model": "construction-demo-v1",
            },
            "video": {
                "duration_seconds": video["duration_milliseconds"] / 1000,
                "fps": video["fps"],
                "height": video["height"],
                "mime_type": video["mime_type"],
                "sha256": video["sha256"],
                "width": video["width"],
            },
            "highlights": [
                {"at_seconds": 0, "label": "Orient toward the visible worksite"},
                {"at_seconds": 24, "label": "Gather and carry the required materials"},
                {"at_seconds": 67, "label": "Deposit materials at the relay"},
                {"at_seconds": 94, "label": "Build the visible barricade"},
                {"at_seconds": 116, "label": "Authority confirms completion"},
            ],
            "verification": {
                "state": "verified",
                "renderer": self.evidence["renderer"],
                "release_profile": self.evidence["release_profile"],
                "evidence_sha256": self.evidence_sha256,
                "replay_sha256": authority["replay_sha256"],
                "final_state_sha256": authority["final_state_sha256"],
                "protocol_package_sha256": authority["protocol_package_sha256"],
                "protocol_version": authority["protocol_version"],
                "authority_ticks": authority["ticks"],
            },
        }


def _validate_evidence(value: Mapping[str, Any]) -> None:
    if set(value) != {
        "authority",
        "format",
        "participant_id",
        "release_profile",
        "renderer",
        "showcase",
        "video",
        "y_bot_manifest_sha256",
    }:
        raise SoloShowcaseError("solo_showcase_evidence_invalid")
    authority = value.get("authority")
    showcase = value.get("showcase")
    video = value.get("video")
    if not all(isinstance(item, dict) for item in (authority, showcase, video)):
        raise SoloShowcaseError("solo_showcase_evidence_invalid")
    if (
        value.get("format") != "worldarena/native-participant-video-evidence/1.0.0"
        or value.get("participant_id") != "participant_0"
        or value.get("release_profile") != "worldarena-participant-1080p30-v1"
        or value.get("renderer") != "godot-movie-maker+ffmpeg"
        or value.get("y_bot_manifest_sha256") is None
        or showcase != {
            "kind": "solo",
            "participant_count": 1,
            "scenario_id": SCENARIO_ID,
        }
    ):
        raise SoloShowcaseError("solo_showcase_evidence_invalid")
    if set(authority) != {
        "episode_id",
        "final_state_sha256",
        "protocol_package_sha256",
        "protocol_version",
        "replay_sha256",
        "task_id",
        "ticks",
    } or (
        authority.get("task_id") != TASK_ID
        or authority.get("protocol_version") != "llm-controller/0.1.0"
        or not isinstance(authority.get("episode_id"), str)
        or not authority["episode_id"].startswith("ep_")
        or not isinstance(authority.get("ticks"), int)
        or authority["ticks"] <= 0
    ):
        raise SoloShowcaseError("solo_showcase_evidence_invalid")
    for field in (
        authority.get("final_state_sha256"),
        authority.get("protocol_package_sha256"),
        authority.get("replay_sha256"),
        value.get("y_bot_manifest_sha256"),
    ):
        if not isinstance(field, str) or _SHA256.fullmatch(field) is None:
            raise SoloShowcaseError("solo_showcase_evidence_invalid")
    expected_video = {
        "audio_codec": "aac",
        "duration_milliseconds": 121900,
        "expected_frames": 3657,
        "faststart": True,
        "fps": 30,
        "height": 1080,
        "mime_type": "video/mp4",
        "path": "solo-multi-action-1080p-release.mp4",
        "pixel_format": "yuv420p",
        "sha256": "3e54bc538ebad897c32905274934381bac3ef4468ba37e63c188ce533785856d",
        "size_bytes": 26567801,
        "video_codec": "h264",
        "width": 1920,
    }
    if video != expected_video:
        raise SoloShowcaseError("solo_showcase_evidence_invalid")


__all__ = [
    "ASSET_DIRECTORY",
    "CachedSoloShowcase",
    "SCENARIO_ID",
    "SHOWCASE_ID",
    "SoloShowcaseError",
    "TASK_ID",
]
