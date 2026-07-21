"""Symmetric paired-series orchestration for embodiment model duels."""

from .archive import (
    ArchivedDuelSeries,
    ArchivedDuelVideo,
    DuelSeriesArchive,
    DuelSeriesArchiveError,
)
from .contracts import (
    DuelCallSettings,
    DuelEntrant,
    DuelLegPlan,
    DuelLegResult,
    DuelLegVerification,
    PairedDuelPlan,
    PairedDuelResult,
    SeatAssignment,
    aggregate_verified_pair,
)
from .demo_provider import DEMO_DUEL_POLICIES, build_demo_duel_provider
from .evidence import (
    DuelSeriesEvidenceBundle,
    DuelSeriesExecution,
    PairedDuelEvidence,
    VerifiedLegMaterial,
    verify_offline_paired_duel,
)
from .managed import VerifiedManagedDuelSession
from .participant_frames import DuelParticipantFrameSnapshot, DuelParticipantFrameStore
from .scheduler import (
    MAX_PAIR_ATTEMPTS,
    AsyncDuelSession,
    LiveProviderCallBudget,
    LiveProviderCallBudgetExceeded,
    PairedDuelScheduler,
    ProviderFactory,
    RepeatedInvalidPairError,
    SessionFactory,
    derive_paired_duel_rerun_plan,
    run_paired_duel_with_reruns,
)

__all__ = [
    "ArchivedDuelSeries",
    "ArchivedDuelVideo",
    "DuelSeriesArchive",
    "DuelSeriesArchiveError",
    "AsyncDuelSession",
    "DuelCallSettings",
    "DEMO_DUEL_POLICIES",
    "DuelEntrant",
    "DuelLegPlan",
    "DuelLegResult",
    "DuelLegVerification",
    "DuelSeriesEvidenceBundle",
    "DuelSeriesExecution",
    "DuelParticipantFrameSnapshot",
    "DuelParticipantFrameStore",
    "LiveProviderCallBudget",
    "LiveProviderCallBudgetExceeded",
    "MAX_PAIR_ATTEMPTS",
    "PairedDuelPlan",
    "PairedDuelEvidence",
    "PairedDuelResult",
    "PairedDuelScheduler",
    "ProviderFactory",
    "RepeatedInvalidPairError",
    "SeatAssignment",
    "SessionFactory",
    "VerifiedManagedDuelSession",
    "VerifiedLegMaterial",
    "aggregate_verified_pair",
    "build_demo_duel_provider",
    "derive_paired_duel_rerun_plan",
    "run_paired_duel_with_reruns",
    "verify_offline_paired_duel",
]
