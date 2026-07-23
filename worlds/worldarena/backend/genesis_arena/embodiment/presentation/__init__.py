"""Browser-safe presentation projections for managed embodiment episodes."""

from .participant_frames import (
    ParticipantFrameSnapshot,
    ParticipantFrameStore,
    ParticipantLivePreviewHub,
    ParticipantLivePreviewSnapshot,
    ParticipantLivePreviewStore,
    ParticipantPreviewHub,
    sanitize_participant_jpeg,
    sanitize_participant_png,
)
from .preview_ingress import InternalParticipantPreviewIngress, derive_trio_preview_ticket

__all__ = [
    "ParticipantFrameSnapshot",
    "ParticipantFrameStore",
    "ParticipantLivePreviewHub",
    "ParticipantLivePreviewSnapshot",
    "ParticipantLivePreviewStore",
    "ParticipantPreviewHub",
    "InternalParticipantPreviewIngress",
    "derive_trio_preview_ticket",
    "sanitize_participant_jpeg",
    "sanitize_participant_png",
]
