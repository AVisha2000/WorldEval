"""Tick-driven continuous real-time LLM scheduling for WorldArena Duel.

The runtime deliberately does not own a wall-clock loop.  Authoritative Godot calls
``dispatch_opportunity`` on the frozen 50-tick observation grid and ``process_gate`` immediately
before phase 1 of every 100-ms simulation tick.  Provider work remains in independent asyncio
tasks, so inference never blocks the simulation thread and tests need no sleeps or network.

Only structurally valid, fresh batches cross ``ContinuousAuthoritativeBridge``.  Empty, invalid,
late, stale, refused, and timed-out responses are recorded as no-ops; existing authoritative
orders are therefore left untouched.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep the public runtime surface explicit on the Python 3.9 floor.
import asyncio
import re
import time
from dataclasses import dataclass, field, replace
from enum import Enum
from typing import Callable, Dict, Mapping, Optional, Protocol, Set, Tuple, Union

from .canonical import canonical_json_bytes, strict_json_loads
from .gateway_validation import (
    ActionEnvelopeValidator,
    BatchErrorCode,
    BatchIdempotencyRegistry,
    BatchValidationContext,
)
from .models import ActionBatch
from .protocol import DUEL_PROTOCOL_VERSION
from .provider_adapters import (
    EndpointOwnership,
    ParticipantProviderAdapter,
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
    ProviderTelemetry,
)
from .runtime import (
    MAX_CANONICAL_INPUT_BYTES,
    FixedPlayerInput,
    canonical_provider_input_envelope_bytes,
)
from .timing import (
    COMMAND_GATE_NS,
    FailureClassification,
    FailureOwner,
    ModelFailureCounter,
    continuous_application_tick,
    controller_valid_until_tick,
)

CONTINUOUS_DECISION_PERIOD_TICKS = 50
CONTINUOUS_MAX_DEADLINE_MS = 8_000
_OPPORTUNITY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
_FORBIDDEN_PROVIDER_KEYS = frozenset(
    {"checkpoint_hash", "omniscient_state_hash", "state_hash"}
)


class ContinuousRuntimeError(RuntimeError):
    """Base error for continuous scheduling."""


class ContinuousRuntimeConfigurationError(ContinuousRuntimeError, ValueError):
    """The caller supplied a boundary that cannot be an official continuous opportunity."""


class ContinuousDuplicateOpportunityError(ContinuousRuntimeError):
    """An opportunity ID or observation boundary was already claimed."""


class ContinuousRuntimeTerminatedError(ContinuousRuntimeError):
    """The match already reached an infrastructure void or technical-forfeit disposition."""


class ContinuousOpportunityDisposition(str, Enum):
    CONTINUE = "continue"
    TECHNICAL_FORFEIT_SLOT_0 = "technical_forfeit_slot_0"
    TECHNICAL_FORFEIT_SLOT_1 = "technical_forfeit_slot_1"
    DRAW_DOUBLE_TECHNICAL_FORFEIT = "draw_double_technical_forfeit"
    VOID_INFRASTRUCTURE = "void_infrastructure"


class ContinuousDispatchStatus(str, Enum):
    DISPATCHED = "dispatched"
    SKIPPED_IN_FLIGHT = "skipped_in_flight"
    NOT_DISPATCHED_INFRASTRUCTURE = "not_dispatched_infrastructure"


@dataclass(frozen=True)
class ContinuousPlayerInput:
    """One private, immutable provider projection for a continuous observation."""

    player_slot: int
    system_prompt: str
    match_init_json: bytes
    observation_json: bytes
    action_schema_json: bytes
    validation_context: BatchValidationContext

    def __post_init__(self) -> None:
        if self.player_slot not in {0, 1}:
            raise ContinuousRuntimeConfigurationError("player_slot must be 0 or 1")
        if not self.system_prompt:
            raise ContinuousRuntimeConfigurationError("system_prompt is required")
        for name in ("match_init_json", "observation_json", "action_schema_json"):
            if not isinstance(getattr(self, name), bytes):
                raise ContinuousRuntimeConfigurationError(f"{name} must be immutable bytes")

    def provider_envelope(self) -> FixedPlayerInput:
        """Reuse the frozen provider-neutral input framing shared with fixed mode."""

        return FixedPlayerInput(
            player_slot=self.player_slot,
            system_prompt=self.system_prompt,
            match_init_json=self.match_init_json,
            observation_json=self.observation_json,
            action_schema_json=self.action_schema_json,
            validation_context=self.validation_context,
        )


@dataclass(frozen=True)
class ContinuousDecisionOpportunity:
    """A paired observation captured on the predetermined real-time tick grid."""

    opportunity_id: str
    match_id: str
    observation_seq: int
    boundary_tick: int
    response_deadline_ms: int
    player_inputs: Tuple[ContinuousPlayerInput, ContinuousPlayerInput]
    dispatch_order: Tuple[int, int] = (0, 1)

    def __post_init__(self) -> None:
        if _OPPORTUNITY_RE.fullmatch(self.opportunity_id) is None:
            raise ContinuousRuntimeConfigurationError("opportunity_id has invalid syntax")
        if not self.match_id:
            raise ContinuousRuntimeConfigurationError("match_id is required")
        for name in ("observation_seq", "boundary_tick"):
            value = getattr(self, name)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ContinuousRuntimeConfigurationError(f"{name} must be non-negative")
        if self.boundary_tick % CONTINUOUS_DECISION_PERIOD_TICKS != 0:
            raise ContinuousRuntimeConfigurationError(
                "continuous observations must use the 50-tick dispatch grid"
            )
        if (
            not isinstance(self.response_deadline_ms, int)
            or isinstance(self.response_deadline_ms, bool)
            or not 1 <= self.response_deadline_ms <= CONTINUOUS_MAX_DEADLINE_MS
        ):
            raise ContinuousRuntimeConfigurationError("response_deadline_ms must be in [1, 8000]")
        if len(self.player_inputs) != 2 or {
            value.player_slot for value in self.player_inputs
        } != {0, 1}:
            raise ContinuousRuntimeConfigurationError("player_inputs must contain slots 0 and 1")
        if tuple(sorted(self.dispatch_order)) != (0, 1):
            raise ContinuousRuntimeConfigurationError(
                "dispatch_order must be a permutation of (0, 1)"
            )


@dataclass(frozen=True)
class ContinuousProviderCallResult:
    """Optional streaming timing paired with the provider-neutral result.

    Existing adapters may return ``ProviderCallResult`` directly, in which case first-token time is
    unavailable.  Official streaming adapters return this wrapper so all required latency fields
    are recorded without trusting provider-reported wall-clock durations.
    """

    result: ProviderCallResult
    first_token_monotonic_ns: Optional[int]

    def __post_init__(self) -> None:
        if not isinstance(self.result, ProviderCallResult):
            raise TypeError("result must be ProviderCallResult")
        value = self.first_token_monotonic_ns
        if value is not None and (
            not isinstance(value, int) or isinstance(value, bool) or value < 0
        ):
            raise ValueError("first_token_monotonic_ns must be non-negative")


@dataclass(frozen=True)
class ContinuousSlotDispatch:
    player_slot: int
    status: ContinuousDispatchStatus
    actual_dispatch_monotonic_ns: Optional[int]


@dataclass(frozen=True)
class ContinuousDispatchResult:
    match_id: str
    opportunity_id: str
    observation_seq: int
    boundary_tick: int
    scheduled_dispatch_monotonic_ns: int
    dispatch_anchor_monotonic_ns: int
    deadline_monotonic_ns: int
    evaluation_tick: int
    slots: Tuple[ContinuousSlotDispatch, ContinuousSlotDispatch]
    disposition: ContinuousOpportunityDisposition
    infrastructure_code: Optional[str] = None


@dataclass(frozen=True)
class ContinuousTimingRecord:
    dispatch_monotonic_ns: int
    deadline_monotonic_ns: int
    first_token_monotonic_ns: Optional[int]
    completion_monotonic_ns: Optional[int]
    parse_started_monotonic_ns: Optional[int]
    parse_completed_monotonic_ns: Optional[int]
    ready_monotonic_ns: Optional[int]
    application_tick: Optional[int]
    application_gate_monotonic_ns: Optional[int] = None
    receipt_monotonic_ns: Optional[int] = None


@dataclass(frozen=True)
class ContinuousFailureRecord:
    opportunity_id: str
    code: str
    owner: FailureOwner
    hard_model_failure: bool
    evaluation_tick: int
    dispatch_monotonic_ns: int
    deadline_monotonic_ns: int
    arrival_monotonic_ns: Optional[int]
    consecutive_count_after: int
    cumulative_count_after: int


@dataclass(frozen=True)
class ContinuousSlotOutcome:
    player_slot: int
    classification_code: str
    used_no_op: bool
    client_batch_id: Optional[str]
    provider_telemetry: ProviderTelemetry
    timing: Optional[ContinuousTimingRecord]
    failure: Optional[ContinuousFailureRecord]
    consecutive_failures: int
    cumulative_failures: int
    forfeit_threshold_reached: bool


@dataclass(frozen=True)
class ContinuousOpportunityEvaluation:
    match_id: str
    opportunity_id: str
    observation_seq: int
    boundary_tick: int
    evaluation_tick: int
    player_outcomes: Tuple[ContinuousSlotOutcome, ContinuousSlotOutcome]


@dataclass(frozen=True)
class ContinuousBatchApplication:
    player_slot: int
    opportunity_id: str
    observation_seq: int
    observation_tick: int
    batch: ActionBatch
    timing: ContinuousTimingRecord


@dataclass(frozen=True)
class ContinuousApplyGateRequest:
    """All fresh batches entering one authoritative command gate, in canonical order."""

    match_id: str
    application_tick: int
    applications: Tuple[ContinuousBatchApplication, ...]

    def __post_init__(self) -> None:
        if not self.applications:
            raise ContinuousRuntimeConfigurationError("an apply gate requires at least one batch")
        keys = [
            (value.player_slot, value.observation_seq, value.opportunity_id)
            for value in self.applications
        ]
        if keys != sorted(keys):
            raise ContinuousRuntimeConfigurationError("gate applications are not canonical")
        if any(
            value.timing.application_tick != self.application_tick
            for value in self.applications
        ):
            raise ContinuousRuntimeConfigurationError("application tick mismatch")


class ContinuousAuthoritativeBridge(Protocol):
    """Sole path for fresh continuous batches to reach authoritative Godot."""

    async def apply_continuous_gate(self, request: ContinuousApplyGateRequest) -> None:
        """Revalidate and atomically enter every batch scheduled for this command gate."""


@dataclass(frozen=True)
class ContinuousApplicationRecord:
    player_slot: int
    opportunity_id: str
    client_batch_id: str
    application_tick: int
    application_gate_monotonic_ns: int
    receipt_monotonic_ns: int


@dataclass(frozen=True)
class ContinuousGateResult:
    match_id: str
    gate_tick: int
    gate_monotonic_ns: int
    applications: Tuple[ContinuousApplicationRecord, ...]
    evaluations: Tuple[ContinuousOpportunityEvaluation, ...]
    disposition: ContinuousOpportunityDisposition
    infrastructure_code: Optional[str] = None


@dataclass(frozen=True)
class _Attempt:
    batch: Optional[ActionBatch]
    classification: Optional[FailureClassification]
    classification_code: str
    telemetry: ProviderTelemetry
    timing: ContinuousTimingRecord


@dataclass
class _TrackedCall:
    opportunity_id: str
    player_slot: int
    task: Optional[asyncio.Task[_Attempt]] = None
    actual_dispatch_monotonic_ns: Optional[int] = None


@dataclass
class _OpportunityState:
    opportunity: ContinuousDecisionOpportunity
    inputs: Dict[int, ContinuousPlayerInput]
    dispatch_anchor_ns: int
    deadline_ns: int
    evaluation_tick: int
    slot_statuses: Dict[int, ContinuousDispatchStatus]
    calls: Dict[int, _TrackedCall] = field(default_factory=dict)
    attempts: Dict[int, _Attempt] = field(default_factory=dict)
    evaluated: bool = False


ProviderResult = Union[ProviderCallResult, ContinuousProviderCallResult]


class ContinuousRealtimeRuntime:
    """Run one fair, real-time, one-in-flight LLM scheduler without sleeping the simulation."""

    def __init__(
        self,
        *,
        match_id: str,
        match_start_monotonic_ns: int,
        adapters: Mapping[int, ParticipantProviderAdapter],
        bridge: ContinuousAuthoritativeBridge,
        validator: Optional[ActionEnvelopeValidator] = None,
        failure_counters: Optional[Mapping[int, ModelFailureCounter]] = None,
        batch_idempotency: Optional[BatchIdempotencyRegistry] = None,
        monotonic_ns: Callable[[], int] = time.monotonic_ns,
        gate_period_ns: int = COMMAND_GATE_NS,
        maximum_dispatch_skew_ns: int = COMMAND_GATE_NS,
        maximum_gate_drift_ns: int = COMMAND_GATE_NS,
        sustained_gate_drift_count: int = 2,
    ) -> None:
        if not match_id:
            raise ContinuousRuntimeConfigurationError("match_id is required")
        if (
            not isinstance(match_start_monotonic_ns, int)
            or isinstance(match_start_monotonic_ns, bool)
            or match_start_monotonic_ns < 0
        ):
            raise ContinuousRuntimeConfigurationError(
                "match_start_monotonic_ns must be non-negative"
            )
        if set(adapters) != {0, 1}:
            raise ContinuousRuntimeConfigurationError("adapters must contain exactly slots 0 and 1")
        for slot, adapter in adapters.items():
            if not callable(getattr(adapter, "request", None)):
                raise ContinuousRuntimeConfigurationError(
                    f"slot {slot} adapter has no request method"
                )
            if not isinstance(getattr(adapter, "endpoint_ownership", None), EndpointOwnership):
                raise ContinuousRuntimeConfigurationError(
                    f"slot {slot} adapter endpoint ownership is invalid"
                )
        counters = failure_counters or {0: ModelFailureCounter(), 1: ModelFailureCounter()}
        if set(counters) != {0, 1}:
            raise ContinuousRuntimeConfigurationError(
                "failure_counters must contain exactly slots 0 and 1"
            )
        for name, value in (
            ("gate_period_ns", gate_period_ns),
            ("maximum_dispatch_skew_ns", maximum_dispatch_skew_ns),
            ("maximum_gate_drift_ns", maximum_gate_drift_ns),
            ("sustained_gate_drift_count", sustained_gate_drift_count),
        ):
            if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
                raise ContinuousRuntimeConfigurationError(f"{name} must be positive")

        self.match_id = match_id
        self.match_start_monotonic_ns = match_start_monotonic_ns
        self._adapters = dict(adapters)
        self._bridge = bridge
        self._validator = validator or ActionEnvelopeValidator()
        self._failure_counters = dict(counters)
        self._batch_idempotency = batch_idempotency or BatchIdempotencyRegistry()
        self._monotonic_ns = monotonic_ns
        self._gate_period_ns = gate_period_ns
        self._maximum_dispatch_skew_ns = maximum_dispatch_skew_ns
        self._maximum_gate_drift_ns = maximum_gate_drift_ns
        self._sustained_gate_drift_count = sustained_gate_drift_count
        self._clock_last_ns = match_start_monotonic_ns
        self._consecutive_gate_drift = 0
        self._current_completed_tick = -1
        self._last_gate_tick = -1
        self._last_boundary_tick = -CONTINUOUS_DECISION_PERIOD_TICKS
        self._last_observation_seq = -1
        self._used_opportunity_ids: Set[str] = set()
        self._used_boundaries: Set[Tuple[int, int]] = set()
        self._opportunities: Dict[str, _OpportunityState] = {}
        self._active_by_slot: Dict[int, Set[asyncio.Task[_Attempt]]] = {0: set(), 1: set()}
        self._pending_applications: list[ContinuousBatchApplication] = []
        self._disposition = ContinuousOpportunityDisposition.CONTINUE
        self._infrastructure_code: Optional[str] = None
        self._closed = False
        self._guard = asyncio.Lock()

    @property
    def failure_counters(self) -> Mapping[int, ModelFailureCounter]:
        return dict(self._failure_counters)

    @property
    def disposition(self) -> ContinuousOpportunityDisposition:
        return self._disposition

    @property
    def in_flight_by_slot(self) -> Mapping[int, int]:
        self._discard_finished_active_tasks()
        return {
            slot: sum(not task.done() for task in self._active_by_slot[slot])
            for slot in (0, 1)
        }

    async def dispatch_opportunity(
        self, opportunity: ContinuousDecisionOpportunity
    ) -> ContinuousDispatchResult:
        """Launch available player requests on one shared observation boundary.

        Calls are launched in the declared order (which paired games swap), while every externally
        visible tuple remains in canonical player order.  A busy player is skipped, never
        overlapped.
        """

        async with self._guard:
            self._require_running()
            inputs = _validate_and_index_opportunity(opportunity)
            self._claim_opportunity(opportunity)
            scheduled_ns = (
                self.match_start_monotonic_ns + opportunity.boundary_tick * self._gate_period_ns
            )
            dispatch_anchor_ns = self._checked_now()
            deadline_ns = dispatch_anchor_ns + opportunity.response_deadline_ms * 1_000_000
            evaluation_tick = continuous_application_tick(
                match_start_monotonic_ns=self.match_start_monotonic_ns,
                ready_time_ns=deadline_ns,
                current_completed_tick=-1,
                gate_period_ns=self._gate_period_ns,
            )
            statuses: Dict[int, ContinuousDispatchStatus] = {}
            state = _OpportunityState(
                opportunity=opportunity,
                inputs=inputs,
                dispatch_anchor_ns=dispatch_anchor_ns,
                deadline_ns=deadline_ns,
                evaluation_tick=evaluation_tick,
                slot_statuses=statuses,
            )
            self._opportunities[opportunity.opportunity_id] = state

            if abs(dispatch_anchor_ns - scheduled_ns) > self._gate_period_ns:
                for slot in (0, 1):
                    statuses[slot] = ContinuousDispatchStatus.NOT_DISPATCHED_INFRASTRUCTURE
                self._void("dispatch_grid_drift")
                return self._dispatch_result(state, scheduled_ns)

            self._discard_finished_active_tasks()
            newly_created: list[asyncio.Task[_Attempt]] = []
            for slot in opportunity.dispatch_order:
                if any(not task.done() for task in self._active_by_slot[slot]):
                    statuses[slot] = ContinuousDispatchStatus.SKIPPED_IN_FLIGHT
                    continue
                statuses[slot] = ContinuousDispatchStatus.DISPATCHED
                tracked = _TrackedCall(opportunity.opportunity_id, slot)
                task = asyncio.create_task(
                    self._run_provider(state, tracked),
                    name=f"duel-continuous-{opportunity.opportunity_id}-slot-{slot}",
                )
                tracked.task = task
                state.calls[slot] = tracked
                self._active_by_slot[slot].add(task)
                task.add_done_callback(self._consume_background_exception)
                newly_created.append(task)

        try:
            # Yield only to start the two coroutines; this is not a wall-clock sleep.
            await asyncio.sleep(0)
        except asyncio.CancelledError:
            await self._cancel_and_drain(newly_created)
            raise

        async with self._guard:
            dispatch_times = [
                tracked.actual_dispatch_monotonic_ns
                for tracked in state.calls.values()
                if tracked.actual_dispatch_monotonic_ns is not None
            ]
            if (
                len(dispatch_times) == 2
                and max(dispatch_times) - min(dispatch_times) > self._maximum_dispatch_skew_ns
            ):
                self._void("dispatch_skew_breach")
                for task in newly_created:
                    task.cancel()
            return self._dispatch_result(state, scheduled_ns)

    async def process_gate(self, gate_tick: int) -> ContinuousGateResult:
        """Process completions, deadline evaluation, and applications before tick phase 1."""

        if not isinstance(gate_tick, int) or isinstance(gate_tick, bool) or gate_tick < 0:
            raise ContinuousRuntimeConfigurationError("gate_tick must be non-negative")
        async with self._guard:
            self._require_running()
            if gate_tick <= self._last_gate_tick:
                raise ContinuousRuntimeConfigurationError("gate ticks must be strictly increasing")
            now_ns = self._checked_now()
            expected_ns = self.match_start_monotonic_ns + gate_tick * self._gate_period_ns
            drift_ns = abs(now_ns - expected_ns)
            if drift_ns > self._maximum_gate_drift_ns:
                self._consecutive_gate_drift += 1
            else:
                self._consecutive_gate_drift = 0
            if self._consecutive_gate_drift >= self._sustained_gate_drift_count:
                self._void("sustained_gate_drift")
                return self._gate_result(gate_tick, now_ns, (), ())
            self._last_gate_tick = gate_tick
            self._current_completed_tick = gate_tick - 1

        # Let providers that became runnable before this gate publish their immutable result.
        await asyncio.sleep(0)

        async with self._guard:
            await self._collect_completed_and_deadline_attempts(gate_tick)
            evaluations, threshold_slots = self._evaluate_due_opportunities(gate_tick)
            if self._disposition is ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE:
                return self._gate_result(gate_tick, now_ns, (), evaluations)
            if threshold_slots:
                self._disposition = _threshold_disposition(threshold_slots)
                await self._cancel_all_active()
                return self._gate_result(gate_tick, now_ns, (), evaluations)

            due = sorted(
                (
                    value
                    for value in self._pending_applications
                    if value.timing.application_tick is not None
                    and value.timing.application_tick <= gate_tick
                ),
                key=lambda value: (
                    value.timing.application_tick,
                    value.player_slot,
                    value.observation_seq,
                    value.opportunity_id,
                ),
            )
            if any(value.timing.application_tick < gate_tick for value in due):
                self._void("missed_application_gate")
                return self._gate_result(gate_tick, now_ns, (), evaluations)
            applications = tuple(
                value for value in due if value.timing.application_tick == gate_tick
            )
            self._pending_applications = [
                value for value in self._pending_applications if value not in applications
            ]
            if not applications:
                return self._gate_result(gate_tick, now_ns, (), evaluations)

            request = ContinuousApplyGateRequest(
                match_id=self.match_id,
                application_tick=gate_tick,
                applications=applications,
            )
            try:
                await self._bridge.apply_continuous_gate(request)
            except asyncio.CancelledError:
                await self._cancel_all_active()
                raise
            except Exception:
                self._void("authoritative_bridge_failure")
                return self._gate_result(gate_tick, now_ns, (), evaluations)
            receipt_ns = self._checked_now()
            records = tuple(
                ContinuousApplicationRecord(
                    player_slot=value.player_slot,
                    opportunity_id=value.opportunity_id,
                    client_batch_id=value.batch.client_batch_id,
                    application_tick=gate_tick,
                    application_gate_monotonic_ns=now_ns,
                    receipt_monotonic_ns=receipt_ns,
                )
                for value in applications
            )
            return self._gate_result(gate_tick, now_ns, records, evaluations)

    async def aclose(self) -> None:
        """Cancel and drain every cooperative provider task; no result may apply afterward."""

        async with self._guard:
            if self._closed:
                return
            await self._cancel_all_active()
            self._pending_applications.clear()
            self._closed = True

    async def _run_provider(
        self, state: _OpportunityState, tracked: _TrackedCall
    ) -> _Attempt:
        slot = tracked.player_slot
        player_input = state.inputs[slot]
        try:
            dispatch_ns = self._checked_now()
            tracked.actual_dispatch_monotonic_ns = dispatch_ns
            request = ProviderRequest(
                match_id=self.match_id,
                opportunity_id=state.opportunity.opportunity_id,
                player_slot=slot,
                observation_seq=state.opportunity.observation_seq,
                boundary_tick=state.opportunity.boundary_tick,
                deadline_monotonic_ns=state.deadline_ns,
                system_prompt=player_input.system_prompt,
                match_init_json=player_input.match_init_json,
                observation_json=player_input.observation_json,
                action_schema_json=player_input.action_schema_json,
            )
            raw_result = await self._adapters[slot].request(request)
            completion_ns = self._checked_now()
        except asyncio.CancelledError:
            raise
        except Exception:
            now_ns = self._safe_now()
            return self._failed_attempt(
                state,
                tracked,
                FailureClassification(
                    "provider_adapter_exception", FailureOwner.ORGANIZER_INFRASTRUCTURE, False
                ),
                ProviderTelemetry(),
                completion_ns=now_ns,
            )

        provider_result, first_token_ns = _unwrap_provider_result(raw_result)
        if provider_result is None:
            return self._failed_attempt(
                state,
                tracked,
                FailureClassification(
                    "provider_adapter_exception", FailureOwner.ORGANIZER_INFRASTRUCTURE, False
                ),
                ProviderTelemetry(),
                completion_ns=completion_ns,
            )
        if first_token_ns is not None and not dispatch_ns <= first_token_ns <= completion_ns:
            return self._failed_attempt(
                state,
                tracked,
                FailureClassification(
                    "provider_timing_invalid", FailureOwner.ORGANIZER_INFRASTRUCTURE, False
                ),
                provider_result.telemetry,
                completion_ns=completion_ns,
            )
        if completion_ns > state.deadline_ns:
            return self._failed_attempt(
                state,
                tracked,
                FailureClassification("provider_timeout", FailureOwner.MODEL, True),
                provider_result.telemetry,
                first_token_ns=first_token_ns,
                completion_ns=completion_ns,
            )
        if provider_result.failure is not None:
            return self._failed_attempt(
                state,
                tracked,
                _classify_provider_failure(
                    provider_result.failure, self._adapters[slot].endpoint_ownership
                ),
                provider_result.telemetry,
                first_token_ns=first_token_ns,
                completion_ns=completion_ns,
            )

        parse_started_ns = self._checked_now()
        provisional_tick = max(
            state.opportunity.boundary_tick + 1, self._current_completed_tick + 1
        )
        provisional_context = replace(
            player_input.validation_context,
            application_tick=provisional_tick,
        )
        validation = self._validator.validate(
            provider_result.raw_output or b"", provisional_context
        )
        parse_completed_ns = self._checked_now()
        if not validation.valid or validation.batch is None:
            code = validation.code or BatchErrorCode.SCHEMA_MISMATCH
            classification = _validation_failure(code)
            return _Attempt(
                batch=None,
                classification=classification,
                classification_code=classification.code,
                telemetry=provider_result.telemetry,
                timing=ContinuousTimingRecord(
                    dispatch_monotonic_ns=dispatch_ns,
                    deadline_monotonic_ns=state.deadline_ns,
                    first_token_monotonic_ns=first_token_ns,
                    completion_monotonic_ns=completion_ns,
                    parse_started_monotonic_ns=parse_started_ns,
                    parse_completed_monotonic_ns=parse_completed_ns,
                    ready_monotonic_ns=parse_completed_ns,
                    application_tick=None,
                ),
            )

        ready_ns = parse_completed_ns
        application_tick = continuous_application_tick(
            match_start_monotonic_ns=self.match_start_monotonic_ns,
            ready_time_ns=ready_ns,
            current_completed_tick=self._current_completed_tick,
            gate_period_ns=self._gate_period_ns,
        )
        final_context = replace(
            player_input.validation_context,
            application_tick=application_tick,
        )
        final_validation = self._validator.validate(
            provider_result.raw_output or b"", final_context
        )
        if not final_validation.valid or final_validation.batch is None:
            code = final_validation.code or BatchErrorCode.SCHEMA_MISMATCH
            classification = _validation_failure(code)
            return _Attempt(
                batch=None,
                classification=classification,
                classification_code=classification.code,
                telemetry=provider_result.telemetry,
                timing=ContinuousTimingRecord(
                    dispatch_monotonic_ns=dispatch_ns,
                    deadline_monotonic_ns=state.deadline_ns,
                    first_token_monotonic_ns=first_token_ns,
                    completion_monotonic_ns=completion_ns,
                    parse_started_monotonic_ns=parse_started_ns,
                    parse_completed_monotonic_ns=parse_completed_ns,
                    ready_monotonic_ns=ready_ns,
                    application_tick=application_tick,
                ),
            )
        batch = final_validation.batch
        if not self._batch_idempotency.register(
            match_id=self.match_id,
            player_slot=slot,
            client_batch_id=batch.client_batch_id,
        ):
            classification = FailureClassification(
                BatchErrorCode.DUPLICATE_BATCH.value, FailureOwner.MODEL, True
            )
            return _Attempt(
                batch=None,
                classification=classification,
                classification_code=classification.code,
                telemetry=provider_result.telemetry,
                timing=ContinuousTimingRecord(
                    dispatch_monotonic_ns=dispatch_ns,
                    deadline_monotonic_ns=state.deadline_ns,
                    first_token_monotonic_ns=first_token_ns,
                    completion_monotonic_ns=completion_ns,
                    parse_started_monotonic_ns=parse_started_ns,
                    parse_completed_monotonic_ns=parse_completed_ns,
                    ready_monotonic_ns=ready_ns,
                    application_tick=application_tick,
                ),
            )
        return _Attempt(
            batch=batch,
            classification=None,
            classification_code="valid_envelope",
            telemetry=provider_result.telemetry,
            timing=ContinuousTimingRecord(
                dispatch_monotonic_ns=dispatch_ns,
                deadline_monotonic_ns=state.deadline_ns,
                first_token_monotonic_ns=first_token_ns,
                completion_monotonic_ns=completion_ns,
                parse_started_monotonic_ns=parse_started_ns,
                parse_completed_monotonic_ns=parse_completed_ns,
                ready_monotonic_ns=ready_ns,
                application_tick=application_tick,
            ),
        )

    async def _collect_completed_and_deadline_attempts(self, gate_tick: int) -> None:
        for state in sorted(
            self._opportunities.values(),
            key=lambda value: (
                value.opportunity.boundary_tick,
                value.opportunity.observation_seq,
                value.opportunity.opportunity_id,
            ),
        ):
            for slot in (0, 1):
                tracked = state.calls.get(slot)
                if tracked is None or slot in state.attempts or tracked.task is None:
                    continue
                task = tracked.task
                if task.done() and not task.cancelled():
                    try:
                        attempt = task.result()
                    except Exception:
                        attempt = self._failed_attempt(
                            state,
                            tracked,
                            FailureClassification(
                                "provider_adapter_exception",
                                FailureOwner.ORGANIZER_INFRASTRUCTURE,
                                False,
                            ),
                            ProviderTelemetry(),
                            completion_ns=self._safe_now(),
                        )
                    state.attempts[slot] = attempt
                    if attempt.batch is not None:
                        self._pending_applications.append(
                            ContinuousBatchApplication(
                                player_slot=slot,
                                opportunity_id=state.opportunity.opportunity_id,
                                observation_seq=state.opportunity.observation_seq,
                                observation_tick=state.opportunity.boundary_tick,
                                batch=attempt.batch,
                                timing=attempt.timing,
                            )
                        )
                    continue
                if gate_tick >= state.evaluation_tick:
                    task.cancel()
                    state.attempts[slot] = self._failed_attempt(
                        state,
                        tracked,
                        FailureClassification("provider_timeout", FailureOwner.MODEL, True),
                        ProviderTelemetry(),
                        completion_ns=None,
                    )
        await asyncio.sleep(0)
        self._discard_finished_active_tasks()

    def _evaluate_due_opportunities(
        self, gate_tick: int
    ) -> Tuple[Tuple[ContinuousOpportunityEvaluation, ...], Set[int]]:
        evaluations: list[ContinuousOpportunityEvaluation] = []
        threshold_slots: Set[int] = set()
        for state in sorted(
            self._opportunities.values(),
            key=lambda value: (
                value.evaluation_tick,
                value.opportunity.boundary_tick,
                value.opportunity.opportunity_id,
            ),
        ):
            if state.evaluated or gate_tick < state.evaluation_tick:
                continue
            outcomes: list[ContinuousSlotOutcome] = []
            for slot in (0, 1):
                if state.slot_statuses[slot] is ContinuousDispatchStatus.SKIPPED_IN_FLIGHT:
                    counter = self._failure_counters[slot]
                    outcomes.append(
                        ContinuousSlotOutcome(
                            player_slot=slot,
                            classification_code="in_flight_skipped",
                            used_no_op=True,
                            client_batch_id=None,
                            provider_telemetry=ProviderTelemetry(),
                            timing=None,
                            failure=None,
                            consecutive_failures=counter.consecutive,
                            cumulative_failures=counter.cumulative,
                            forfeit_threshold_reached=False,
                        )
                    )
                    continue
                attempt = state.attempts.get(slot)
                if attempt is None:
                    attempt = self._failed_attempt(
                        state,
                        state.calls.get(slot, _TrackedCall(state.opportunity.opportunity_id, slot)),
                        FailureClassification(
                            "shared_gateway_state_corruption",
                            FailureOwner.ORGANIZER_INFRASTRUCTURE,
                            False,
                        ),
                        ProviderTelemetry(),
                        completion_ns=None,
                    )
                counter = self._failure_counters[slot]
                if attempt.classification is None:
                    counter.record_valid_envelope()
                    reached = False
                    failure = None
                else:
                    reached = counter.record(attempt.classification)
                    failure = ContinuousFailureRecord(
                        opportunity_id=state.opportunity.opportunity_id,
                        code=attempt.classification.code,
                        owner=attempt.classification.owner,
                        hard_model_failure=attempt.classification.hard_model_failure,
                        evaluation_tick=state.evaluation_tick,
                        dispatch_monotonic_ns=attempt.timing.dispatch_monotonic_ns,
                        deadline_monotonic_ns=attempt.timing.deadline_monotonic_ns,
                        arrival_monotonic_ns=attempt.timing.completion_monotonic_ns,
                        consecutive_count_after=counter.consecutive,
                        cumulative_count_after=counter.cumulative,
                    )
                    if attempt.classification.owner is FailureOwner.ORGANIZER_INFRASTRUCTURE:
                        self._void(attempt.classification.code)
                if reached:
                    threshold_slots.add(slot)
                outcomes.append(
                    ContinuousSlotOutcome(
                        player_slot=slot,
                        classification_code=attempt.classification_code,
                        used_no_op=attempt.batch is None,
                        client_batch_id=(
                            attempt.batch.client_batch_id if attempt.batch is not None else None
                        ),
                        provider_telemetry=attempt.telemetry,
                        timing=attempt.timing,
                        failure=failure,
                        consecutive_failures=counter.consecutive,
                        cumulative_failures=counter.cumulative,
                        forfeit_threshold_reached=reached,
                    )
                )
            state.evaluated = True
            evaluations.append(
                ContinuousOpportunityEvaluation(
                    match_id=self.match_id,
                    opportunity_id=state.opportunity.opportunity_id,
                    observation_seq=state.opportunity.observation_seq,
                    boundary_tick=state.opportunity.boundary_tick,
                    evaluation_tick=state.evaluation_tick,
                    player_outcomes=(outcomes[0], outcomes[1]),
                )
            )
        return tuple(evaluations), threshold_slots

    def _failed_attempt(
        self,
        state: _OpportunityState,
        tracked: _TrackedCall,
        classification: FailureClassification,
        telemetry: ProviderTelemetry,
        *,
        first_token_ns: Optional[int] = None,
        completion_ns: Optional[int],
    ) -> _Attempt:
        dispatch_ns = tracked.actual_dispatch_monotonic_ns or state.dispatch_anchor_ns
        return _Attempt(
            batch=None,
            classification=classification,
            classification_code=classification.code,
            telemetry=telemetry,
            timing=ContinuousTimingRecord(
                dispatch_monotonic_ns=dispatch_ns,
                deadline_monotonic_ns=state.deadline_ns,
                first_token_monotonic_ns=first_token_ns,
                completion_monotonic_ns=completion_ns,
                parse_started_monotonic_ns=None,
                parse_completed_monotonic_ns=None,
                ready_monotonic_ns=None,
                application_tick=None,
            ),
        )

    def _claim_opportunity(self, opportunity: ContinuousDecisionOpportunity) -> None:
        boundary = (opportunity.observation_seq, opportunity.boundary_tick)
        if (
            opportunity.opportunity_id in self._used_opportunity_ids
            or boundary in self._used_boundaries
        ):
            raise ContinuousDuplicateOpportunityError(
                "continuous opportunity ID or observation boundary was already started"
            )
        if opportunity.match_id != self.match_id:
            raise ContinuousRuntimeConfigurationError("opportunity match does not match runtime")
        if opportunity.boundary_tick <= self._last_boundary_tick:
            raise ContinuousRuntimeConfigurationError("observation boundary ticks must increase")
        if opportunity.observation_seq <= self._last_observation_seq:
            raise ContinuousRuntimeConfigurationError("observation sequences must increase")
        self._used_opportunity_ids.add(opportunity.opportunity_id)
        self._used_boundaries.add(boundary)
        self._last_boundary_tick = opportunity.boundary_tick
        self._last_observation_seq = opportunity.observation_seq

    def _dispatch_result(
        self, state: _OpportunityState, scheduled_ns: int
    ) -> ContinuousDispatchResult:
        slots = tuple(
            ContinuousSlotDispatch(
                player_slot=slot,
                status=state.slot_statuses[slot],
                actual_dispatch_monotonic_ns=(
                    state.calls[slot].actual_dispatch_monotonic_ns
                    if slot in state.calls
                    else None
                ),
            )
            for slot in (0, 1)
        )
        return ContinuousDispatchResult(
            match_id=self.match_id,
            opportunity_id=state.opportunity.opportunity_id,
            observation_seq=state.opportunity.observation_seq,
            boundary_tick=state.opportunity.boundary_tick,
            scheduled_dispatch_monotonic_ns=scheduled_ns,
            dispatch_anchor_monotonic_ns=state.dispatch_anchor_ns,
            deadline_monotonic_ns=state.deadline_ns,
            evaluation_tick=state.evaluation_tick,
            slots=slots,  # type: ignore[arg-type]
            disposition=self._disposition,
            infrastructure_code=self._infrastructure_code,
        )

    def _gate_result(
        self,
        gate_tick: int,
        gate_ns: int,
        applications: Tuple[ContinuousApplicationRecord, ...],
        evaluations: Tuple[ContinuousOpportunityEvaluation, ...],
    ) -> ContinuousGateResult:
        return ContinuousGateResult(
            match_id=self.match_id,
            gate_tick=gate_tick,
            gate_monotonic_ns=gate_ns,
            applications=applications,
            evaluations=evaluations,
            disposition=self._disposition,
            infrastructure_code=self._infrastructure_code,
        )

    def _checked_now(self) -> int:
        value = self._monotonic_ns()
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            self._void("host_clock_failure")
            raise ContinuousRuntimeConfigurationError("monotonic clock returned an invalid value")
        if value < self._clock_last_ns:
            self._void("host_clock_failure")
            raise ContinuousRuntimeConfigurationError("monotonic clock moved backwards")
        self._clock_last_ns = value
        return value

    def _safe_now(self) -> int:
        try:
            return self._checked_now()
        except ContinuousRuntimeConfigurationError:
            return self._clock_last_ns

    def _void(self, code: str) -> None:
        self._disposition = ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE
        self._infrastructure_code = code

    def _require_running(self) -> None:
        if self._closed:
            raise ContinuousRuntimeTerminatedError("continuous runtime is closed")
        if self._disposition is not ContinuousOpportunityDisposition.CONTINUE:
            raise ContinuousRuntimeTerminatedError(
                f"continuous runtime terminated: {self._disposition.value}"
            )

    def _discard_finished_active_tasks(self) -> None:
        for slot in (0, 1):
            self._active_by_slot[slot] = {
                task for task in self._active_by_slot[slot] if not task.done()
            }

    @staticmethod
    def _consume_background_exception(task: asyncio.Task[_Attempt]) -> None:
        if task.cancelled():
            return
        try:
            task.exception()
        except (asyncio.CancelledError, Exception):
            return

    async def _cancel_and_drain(self, tasks: list[asyncio.Task[_Attempt]]) -> None:
        for task in tasks:
            if not task.done():
                task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self._discard_finished_active_tasks()

    async def _cancel_all_active(self) -> None:
        tasks = [task for values in self._active_by_slot.values() for task in values]
        await self._cancel_and_drain(tasks)


def _validate_and_index_opportunity(
    opportunity: ContinuousDecisionOpportunity,
) -> Dict[int, ContinuousPlayerInput]:
    inputs = {value.player_slot: value for value in opportunity.player_inputs}
    valid_until = controller_valid_until_tick(
        opportunity.boundary_tick, "continuous_realtime"
    )
    for slot in (0, 1):
        player_input = inputs[slot]
        context = player_input.validation_context
        if context.match_id != opportunity.match_id:
            raise ContinuousRuntimeConfigurationError(
                f"slot {slot} validation match is not frozen match"
            )
        if context.observation_seq != opportunity.observation_seq:
            raise ContinuousRuntimeConfigurationError(
                f"slot {slot} validation sequence is not frozen sequence"
            )
        if context.controller_valid_until_tick != valid_until:
            raise ContinuousRuntimeConfigurationError(
                f"slot {slot} validity ceiling must be observation tick + 100"
            )

        match_init = _strict_wire_object(player_input.match_init_json, f"slot {slot} MATCH_INIT")
        observation = _strict_wire_object(
            player_input.observation_json, f"slot {slot} OBSERVATION"
        )
        action_schema = _strict_wire_object(
            player_input.action_schema_json, f"slot {slot} action schema"
        )
        if canonical_json_bytes(match_init) != player_input.match_init_json:
            raise ContinuousRuntimeConfigurationError(
                f"slot {slot} MATCH_INIT is not canonical JSON"
            )
        if canonical_json_bytes(observation) != player_input.observation_json:
            raise ContinuousRuntimeConfigurationError(
                f"slot {slot} OBSERVATION is not canonical JSON"
            )
        if canonical_json_bytes(action_schema) != player_input.action_schema_json:
            raise ContinuousRuntimeConfigurationError(
                f"slot {slot} action schema is not canonical JSON"
            )
        if len(canonical_provider_input_envelope_bytes(player_input.provider_envelope())) > (
            MAX_CANONICAL_INPUT_BYTES
        ):
            raise ContinuousRuntimeConfigurationError(
                f"slot {slot} canonical provider input exceeds {MAX_CANONICAL_INPUT_BYTES} bytes"
            )
        if match_init.get("message_type") != "match_init":
            raise ContinuousRuntimeConfigurationError(f"slot {slot} MATCH_INIT type is invalid")
        if observation.get("message_type") != "observation":
            raise ContinuousRuntimeConfigurationError(f"slot {slot} OBSERVATION type is invalid")
        for value, label in ((match_init, "MATCH_INIT"), (observation, "OBSERVATION")):
            if value.get("protocol_version") != DUEL_PROTOCOL_VERSION:
                raise ContinuousRuntimeConfigurationError(
                    f"slot {slot} {label} protocol version is invalid"
                )
            if value.get("match_id") != opportunity.match_id:
                raise ContinuousRuntimeConfigurationError(f"slot {slot} {label} match is invalid")
            if _contains_forbidden_provider_key(value):
                raise ContinuousRuntimeConfigurationError(
                    f"slot {slot} {label} contains an omniscient state hash"
                )
        if match_init.get("perspective") != "self":
            raise ContinuousRuntimeConfigurationError(
                f"slot {slot} MATCH_INIT is not self-relative"
            )
        decision = match_init.get("decision")
        if not isinstance(decision, dict) or decision.get("mode") != "continuous_realtime":
            raise ContinuousRuntimeConfigurationError(
                f"slot {slot} MATCH_INIT decision mode is not continuous_realtime"
            )
        if observation.get("observation_seq") != opportunity.observation_seq:
            raise ContinuousRuntimeConfigurationError(
                f"slot {slot} OBSERVATION sequence is invalid"
            )
        if observation.get("tick") != opportunity.boundary_tick:
            raise ContinuousRuntimeConfigurationError(
                f"slot {slot} OBSERVATION is not from the shared boundary"
            )
        if observation.get("observation_hash") != context.observation_hash:
            raise ContinuousRuntimeConfigurationError(
                f"slot {slot} observation hash does not match validation context"
            )
    return inputs


def _strict_wire_object(payload: bytes, label: str) -> dict[str, object]:
    try:
        value = strict_json_loads(payload)
    except (TypeError, ValueError, UnicodeError) as exc:
        raise ContinuousRuntimeConfigurationError(f"{label} is invalid strict JSON") from exc
    if not isinstance(value, dict):
        raise ContinuousRuntimeConfigurationError(f"{label} must be a JSON object")
    return value


def _contains_forbidden_provider_key(value: object) -> bool:
    if isinstance(value, dict):
        if any(key in _FORBIDDEN_PROVIDER_KEYS for key in value):
            return True
        return any(_contains_forbidden_provider_key(child) for child in value.values())
    if isinstance(value, list):
        return any(_contains_forbidden_provider_key(child) for child in value)
    return False


def _unwrap_provider_result(
    value: object,
) -> Tuple[Optional[ProviderCallResult], Optional[int]]:
    if isinstance(value, ContinuousProviderCallResult):
        return value.result, value.first_token_monotonic_ns
    if isinstance(value, ProviderCallResult):
        return value, value.first_token_monotonic_ns
    return None, None


def _validation_failure(code: BatchErrorCode) -> FailureClassification:
    if code is BatchErrorCode.EXPIRED_BATCH:
        # It was an on-time structurally valid envelope, so staleness is a no-op but not a strike.
        return FailureClassification(code.value, FailureOwner.MODEL, False)
    return FailureClassification(code.value, FailureOwner.MODEL, True)


def _classify_provider_failure(
    failure: ProviderFailureKind, ownership: EndpointOwnership
) -> FailureClassification:
    if failure is ProviderFailureKind.REFUSAL:
        return FailureClassification(failure.value, FailureOwner.MODEL, True)
    if failure is ProviderFailureKind.SHARED_PROVIDER_OUTAGE:
        return FailureClassification(
            failure.value, FailureOwner.ORGANIZER_INFRASTRUCTURE, False
        )
    if ownership is EndpointOwnership.PARTICIPANT_HOSTED:
        return FailureClassification(failure.value, FailureOwner.PARTICIPANT_ENDPOINT, True)
    return FailureClassification(failure.value, FailureOwner.ORGANIZER_INFRASTRUCTURE, False)


def _threshold_disposition(slots: Set[int]) -> ContinuousOpportunityDisposition:
    if slots == {0, 1}:
        return ContinuousOpportunityDisposition.DRAW_DOUBLE_TECHNICAL_FORFEIT
    if slots == {0}:
        return ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_0
    if slots == {1}:
        return ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_1
    return ContinuousOpportunityDisposition.CONTINUE
