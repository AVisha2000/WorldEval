"""Browser-safe presentation projections for managed embodiment episodes."""

from .participant_frames import (
    ParticipantFrameSnapshot,
    ParticipantFrameStore,
    ParticipantPreviewHub,
    sanitize_participant_png,
)
from .preview_ingress import InternalParticipantPreviewIngress

__all__ = [
    "ParticipantFrameSnapshot",
    "ParticipantFrameStore",
    "ParticipantPreviewHub",
    "InternalParticipantPreviewIngress",
    "sanitize_participant_png",
]
