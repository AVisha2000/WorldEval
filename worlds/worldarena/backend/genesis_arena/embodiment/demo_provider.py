"""Deterministic, credential-free provider core for offline WorldArena demonstrations.

The demo provider intentionally consumes the exact same :class:`ProviderRequest` and returns the
same raw :class:`ProviderCallResult` as a network adapter.  Its immutable policy lock lives outside
the participant observation, so scenario identifiers and seeds never need to be added to the
provider request contract.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from typing import Any, Callable, Union

from .contracts import ControllerAction, ControllerState
from .protocol import canonical_json_bytes
from .providers.contracts import (
    InMemoryProviderAuditLog,
    ProviderAuditRecord,
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
    ProviderTelemetry,
)

_SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_MAX_EXACT_INTEGER = 9_007_199_254_740_991


@dataclass(frozen=True)
class DemoPolicyLock:
    """Evidence-bound identity and budget for one deterministic demo participant."""

    scenario_id: str
    policy_id: str
    fixture_sha256: str
    seed: int
    participant_id: str
    model: str
    total_decision_budget: int

    def __post_init__(self) -> None:
        for name in ("scenario_id", "policy_id", "participant_id", "model"):
            value = getattr(self, name)
            if not isinstance(value, str) or not _SAFE_ID.fullmatch(value):
                raise ValueError(f"{name} must be a safe identifier")
        if not isinstance(self.fixture_sha256, str) or not _SHA256.fullmatch(
            self.fixture_sha256
        ):
            raise ValueError("fixture_sha256 must be lowercase SHA-256")
        if (
            isinstance(self.seed, bool)
            or not isinstance(self.seed, int)
            or not 0 <= self.seed <= _MAX_EXACT_INTEGER
        ):
            raise ValueError("seed must be a non-negative exact integer")
        if (
            isinstance(self.total_decision_budget, bool)
            or not isinstance(self.total_decision_budget, int)
            or not 1 <= self.total_decision_budget <= _MAX_EXACT_INTEGER
        ):
            raise ValueError("total_decision_budget must be a positive exact integer")

    def as_dict(self) -> dict[str, object]:
        return {
            "scenario_id": self.scenario_id,
            "policy_id": self.policy_id,
            "fixture_sha256": self.fixture_sha256,
            "seed": self.seed,
            "participant_id": self.participant_id,
            "model": self.model,
            "total_decision_budget": self.total_decision_budget,
        }

    @property
    def sha256(self) -> str:
        """Canonical digest suitable for protected run evidence."""

        return hashlib.sha256(canonical_json_bytes(self.as_dict())).hexdigest()


DemoBehaviorResult = Union[bytes, ProviderFailureKind, ProviderCallResult]
DemoBehavior = Callable[[ProviderRequest, DemoPolicyLock, int], DemoBehaviorResult]


class DemoProvider:
    """Bounded local ProviderAdapter with injectable deterministic fixture behavior.

    ``behavior`` is synchronous by design: an offline fixture must not perform I/O or sleep.  It
    receives the zero-based call index, making valid, malformed, stale, refusal, and fake-timeout
    sequences deterministic without consulting wall-clock time.
    """

    provider_name = "demo"

    def __init__(
        self,
        policy_lock: DemoPolicyLock,
        *,
        behavior: DemoBehavior | None = None,
        delegate: Any | None = None,
        fixture_bytes: bytes | None = None,
        audit_log: InMemoryProviderAuditLog | None = None,
        monotonic_ns: Callable[[], int] | None = None,
    ) -> None:
        if not isinstance(policy_lock, DemoPolicyLock):
            raise TypeError("policy_lock must be DemoPolicyLock")
        if behavior is not None and delegate is not None:
            raise ValueError("pass either behavior or delegate, not both")
        if behavior is not None and not callable(behavior):
            raise TypeError("behavior must be callable")
        if delegate is not None and not _is_trusted_delegate(delegate):
            raise ValueError("delegate must be an exact trusted scripted provider")
        if fixture_bytes is not None:
            if not isinstance(fixture_bytes, bytes):
                raise TypeError("fixture_bytes must be immutable bytes")
            if hashlib.sha256(fixture_bytes).hexdigest() != policy_lock.fixture_sha256:
                raise ValueError("fixture_bytes do not match the demo policy lock")
        if monotonic_ns is not None and not callable(monotonic_ns):
            raise TypeError("monotonic_ns must be callable")
        self._policy_lock = policy_lock
        self._behavior = behavior or _neutral_behavior
        self._delegate = delegate
        self._audit_log = audit_log or InMemoryProviderAuditLog()
        # Demo evidence must be byte-for-byte repeatable by default.  Tests may inject a clock to
        # exercise the adapter's timeout edge, while the outer managed runner owns real deadlines.
        self._monotonic_ns = monotonic_ns or _zero_clock
        self._enforce_deadline = monotonic_ns is not None
        self._decision_count = 0

    @property
    def policy_lock(self) -> DemoPolicyLock:
        return self._policy_lock

    @property
    def audit_log(self) -> InMemoryProviderAuditLog:
        return self._audit_log

    @property
    def decision_count(self) -> int:
        return self._decision_count

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        if not isinstance(request, ProviderRequest):
            raise TypeError("request must be ProviderRequest")
        if request.participant_id != self._policy_lock.participant_id:
            raise ValueError("request participant does not match the demo policy lock")
        if request.model != self._policy_lock.model:
            raise ValueError("request model does not match the demo policy lock")

        started_ns = self._monotonic_ns()
        if self._decision_count >= self._policy_lock.total_decision_budget:
            return self._finish(
                request, started_ns, ProviderFailureKind.INVALID_RESPONSE, count_decision=False
            )

        call_index = self._decision_count
        self._decision_count += 1
        if self._enforce_deadline and request.deadline_monotonic_ns <= started_ns:
            return self._finish(
                request, started_ns, ProviderFailureKind.TIMEOUT, count_decision=False
            )

        try:
            value = (
                await self._delegate.request(request)
                if self._delegate is not None
                else self._behavior(request, self._policy_lock, call_index)
            )
            if isinstance(value, ProviderCallResult):
                if (
                    value.raw_output is not None
                    and len(value.raw_output) > request.max_output_bytes
                ):
                    result = ProviderCallResult.failed(
                        ProviderFailureKind.OUTPUT_TOO_LARGE, self._telemetry(started_ns)
                    )
                else:
                    result = value
            elif isinstance(value, ProviderFailureKind):
                result = ProviderCallResult.failed(value, self._telemetry(started_ns))
            elif isinstance(value, bytes):
                if len(value) > request.max_output_bytes:
                    result = ProviderCallResult.failed(
                        ProviderFailureKind.OUTPUT_TOO_LARGE, self._telemetry(started_ns)
                    )
                else:
                    result = ProviderCallResult.success(value, self._telemetry(started_ns))
            else:
                result = ProviderCallResult.failed(
                    ProviderFailureKind.INVALID_RESPONSE, self._telemetry(started_ns)
                )
        except Exception:
            # Fixture bugs are collapsed to the same safe boundary used by live adapters.
            result = ProviderCallResult.failed(
                ProviderFailureKind.INTERNAL, self._telemetry(started_ns)
            )
        completed_ns = self._monotonic_ns()
        self._record(request, result, started_ns, completed_ns)
        return result

    def _telemetry(self, started_ns: int) -> ProviderTelemetry:
        completed_ns = self._monotonic_ns()
        return ProviderTelemetry(latency_ms=max(0, completed_ns - started_ns) // 1_000_000)

    def _finish(
        self,
        request: ProviderRequest,
        started_ns: int,
        failure: ProviderFailureKind,
        *,
        count_decision: bool,
    ) -> ProviderCallResult:
        if count_decision:
            self._decision_count += 1
        completed_ns = self._monotonic_ns()
        result = ProviderCallResult.failed(
            failure,
            ProviderTelemetry(latency_ms=max(0, completed_ns - started_ns) // 1_000_000),
        )
        self._record(request, result, started_ns, completed_ns)
        return result

    def _record(
        self,
        request: ProviderRequest,
        result: ProviderCallResult,
        started_ns: int,
        completed_ns: int,
    ) -> None:
        self._audit_log.record(
            ProviderAuditRecord(
                provider=self.provider_name,
                request=request,
                result=result,
                started_monotonic_ns=started_ns,
                completed_monotonic_ns=completed_ns,
            )
        )

    async def aclose(self) -> None:
        return None


def _neutral_behavior(
    request: ProviderRequest, _lock: DemoPolicyLock, call_index: int
) -> bytes:
    action = ControllerAction(
        episode_id=request.episode_id,
        observation_seq=request.observation_seq,
        action_id=f"demo_{call_index:06d}",
        control=ControllerState.neutral(1),
        intent_label="Demo: wait",
        memory_update="",
    )
    return canonical_json_bytes(action.as_dict())


def _zero_clock() -> int:
    return 0


def _is_trusted_delegate(delegate: object) -> bool:
    """Accept only repository-owned deterministic solo policies, never duck-typed adapters."""

    # Lazy imports avoid making provider contracts depend on the higher-level solo policy modules.
    from .scripted_construction_demo import ScriptedConstructionDemoProvider
    from .scripted_solo_demo import ScriptedSoloDemoProvider

    return type(delegate) in (ScriptedSoloDemoProvider, ScriptedConstructionDemoProvider)


__all__ = ["DemoBehavior", "DemoBehaviorResult", "DemoPolicyLock", "DemoProvider"]
