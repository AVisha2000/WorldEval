"""Symmetric paired-series orchestration for embodiment model duels."""

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
from .evidence import (
    DuelSeriesEvidenceBundle,
    DuelSeriesExecution,
    PairedDuelEvidence,
    VerifiedLegMaterial,
    verify_offline_paired_duel,
)
from .managed import VerifiedManagedDuelSession
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
    "AsyncDuelSession",
    "DuelCallSettings",
    "DuelEntrant",
    "DuelLegPlan",
    "DuelLegResult",
    "DuelLegVerification",
    "DuelSeriesEvidenceBundle",
    "DuelSeriesExecution",
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
    "derive_paired_duel_rerun_plan",
    "run_paired_duel_with_reruns",
    "verify_offline_paired_duel",
]
