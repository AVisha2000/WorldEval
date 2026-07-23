"""Provider-neutral participant adapter contracts for WorldArena Duel.

Adapters translate a frozen, player-scoped request into raw response bytes.  Provider SDK
objects and exceptions must stop at this boundary: the runtime receives only the small typed
result below, whose telemetry cannot contain credentials, prompts, raw headers, or provider
response bodies.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep the public adapter surface explicit on the Python 3.9 floor.
import asyncio
import re
from collections import deque
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Deque, Optional, Protocol, Sequence, Tuple, Union, runtime_checkable

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_SAFE_LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$")


class EndpointOwnership(str, Enum):
    """Who supplied and operates a participant's inference endpoint."""

    ORGANIZER_HOSTED = "organizer_hosted"
    PARTICIPANT_HOSTED = "participant_hosted"


class ProviderFailureKind(str, Enum):
    """Provider failures that an adapter may safely expose to orchestration."""

    REFUSAL = "provider_refusal"
    TRANSPORT_DISCONNECT = "transport_disconnect"
    INFERENCE_WORKER_CRASH = "inference_worker_crash"
    CREDENTIAL_ERROR = "credential_error"
    QUOTA_ERROR = "quota_error"
    RATE_LIMIT_ERROR = "rate_limit_error"
    ENDPOINT_ERROR = "endpoint_error"
    SHARED_PROVIDER_OUTAGE = "shared_provider_outage"


@dataclass(frozen=True)
class ProviderTelemetry:
    """Allow-listed, non-secret provider accounting metadata.

    Raw provider request IDs are intentionally excluded.  An adapter may supply a SHA-256 digest
    when audit correlation is required without disclosing the underlying identifier.
    """

    input_tokens: Optional[int] = None
    output_tokens: Optional[int] = None
    cached_input_tokens: Optional[int] = None
    service_tier: Optional[str] = None
    provider_request_id_sha256: Optional[str] = None

    def __post_init__(self) -> None:
        for name in ("input_tokens", "output_tokens", "cached_input_tokens"):
            value = getattr(self, name)
            if value is not None and (
                not isinstance(value, int) or isinstance(value, bool) or value < 0
            ):
                raise ValueError(f"{name} must be a non-negative integer")
        if self.service_tier is not None and _SAFE_LABEL_RE.fullmatch(self.service_tier) is None:
            raise ValueError("service_tier must be a short non-secret label")
        digest = self.provider_request_id_sha256
        if digest is not None and _SHA256_RE.fullmatch(digest) is None:
            raise ValueError("provider_request_id_sha256 must be lowercase SHA-256")


@dataclass(frozen=True)
class ProviderCallResult:
    """Exactly one provider response body or one sanitized provider failure."""

    raw_output: Optional[bytes] = None
    failure: Optional[ProviderFailureKind] = None
    telemetry: ProviderTelemetry = field(default_factory=ProviderTelemetry)
    first_token_monotonic_ns: Optional[int] = None

    def __post_init__(self) -> None:
        has_output = self.raw_output is not None
        has_failure = self.failure is not None
        if has_output == has_failure:
            raise ValueError("provider result requires exactly one of raw_output or failure")
        if self.raw_output is not None and not isinstance(self.raw_output, bytes):
            raise TypeError("raw_output must be immutable bytes")
        if self.failure is not None and not isinstance(self.failure, ProviderFailureKind):
            raise TypeError("failure must be a ProviderFailureKind")
        first_token = self.first_token_monotonic_ns
        if first_token is not None and (
            not isinstance(first_token, int) or isinstance(first_token, bool) or first_token < 0
        ):
            raise ValueError("first_token_monotonic_ns must be a non-negative integer")

    @classmethod
    def success(
        cls,
        raw_output: bytes,
        *,
        telemetry: Optional[ProviderTelemetry] = None,
        first_token_monotonic_ns: Optional[int] = None,
    ) -> ProviderCallResult:
        return cls(
            raw_output=raw_output,
            telemetry=telemetry or ProviderTelemetry(),
            first_token_monotonic_ns=first_token_monotonic_ns,
        )

    @classmethod
    def failed(
        cls,
        failure: ProviderFailureKind,
        *,
        telemetry: Optional[ProviderTelemetry] = None,
        first_token_monotonic_ns: Optional[int] = None,
    ) -> ProviderCallResult:
        return cls(
            failure=failure,
            telemetry=telemetry or ProviderTelemetry(),
            first_token_monotonic_ns=first_token_monotonic_ns,
        )


@dataclass(frozen=True)
class ProviderRequest:
    """One immutable player-scoped model request.

    No opponent observation or omniscient checkpoint hash is representable here.  Prompt/catalog
    assembly occurs before this boundary and supplies canonical static and observation bytes.
    """

    match_id: str
    opportunity_id: str
    player_slot: int
    observation_seq: int
    boundary_tick: int
    deadline_monotonic_ns: int
    system_prompt: str
    match_init_json: bytes
    observation_json: bytes
    action_schema_json: bytes

    def __post_init__(self) -> None:
        if self.player_slot not in {0, 1}:
            raise ValueError("player_slot must be 0 or 1")
        for name in ("observation_seq", "boundary_tick", "deadline_monotonic_ns"):
            value = getattr(self, name)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError(f"{name} must be a non-negative integer")
        if not self.match_id or not self.opportunity_id:
            raise ValueError("match_id and opportunity_id are required")
        if not self.system_prompt:
            raise ValueError("system_prompt is required")
        for name in ("match_init_json", "observation_json", "action_schema_json"):
            if not isinstance(getattr(self, name), bytes):
                raise TypeError(f"{name} must be immutable bytes")


@runtime_checkable
class ParticipantProviderAdapter(Protocol):
    """Minimal async contract implemented by every provider integration."""

    endpoint_ownership: EndpointOwnership

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        """Return one raw response or a sanitized failure without retrying the window."""


ScriptedResultFactory = Callable[[ProviderRequest], ProviderCallResult]


@dataclass(frozen=True)
class ScriptedProviderStep:
    """One deterministic response used by integration tests and local harnesses."""

    result: Union[ProviderCallResult, ScriptedResultFactory]
    delay_seconds: float = 0.0

    def __post_init__(self) -> None:
        if self.delay_seconds < 0:
            raise ValueError("delay_seconds must be non-negative")


class ScriptedProviderAdapter:
    """Small provider-free adapter with controllable latency and recorded requests."""

    def __init__(
        self,
        steps: Sequence[ScriptedProviderStep],
        *,
        endpoint_ownership: EndpointOwnership = EndpointOwnership.PARTICIPANT_HOSTED,
    ) -> None:
        self.endpoint_ownership = endpoint_ownership
        self._steps: Deque[ScriptedProviderStep] = deque(steps)
        self._requests: list[ProviderRequest] = []
        self.cancelled_requests = 0

    @property
    def requests(self) -> Tuple[ProviderRequest, ...]:
        return tuple(self._requests)

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        self._requests.append(request)
        if not self._steps:
            raise RuntimeError("scripted provider has no response step")
        step = self._steps.popleft()
        try:
            if step.delay_seconds:
                await asyncio.sleep(step.delay_seconds)
        except asyncio.CancelledError:
            self.cancelled_requests += 1
            raise
        result = step.result(request) if callable(step.result) else step.result
        if not isinstance(result, ProviderCallResult):
            raise TypeError("scripted result factory must return ProviderCallResult")
        return result
