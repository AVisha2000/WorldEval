"""Fixed-simultaneous, provider-neutral Duel gateway orchestration.

This module coordinates model I/O and the commit/lock/reveal wire boundary only.  It never
interprets a command or mutates game state; the injected authoritative bridge remains the sole
path by which canonical batches can reach Godot.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep runtime-compatible public annotations for Python 3.9.
import asyncio
import hashlib
import re
import secrets
import time
import unicodedata
from dataclasses import dataclass
from enum import Enum
from typing import Callable, Dict, Mapping, Optional, Protocol, Set, Tuple

from .canonical import canonical_json_bytes, strict_json_loads
from .commitment import BatchReveal, FixedCommitRevealWindow
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
from .timing import FailureClassification, FailureOwner, ModelFailureCounter

_OPPORTUNITY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
_FORBIDDEN_PROVIDER_KEYS = frozenset(
    {"checkpoint_hash", "omniscient_state_hash", "state_hash"}
)
MAX_CANONICAL_INPUT_BYTES = 262_144
_INPUT_FRAME_DOMAIN = b"worldeval-rts/provider-input-envelope/v1\x00"
_INPUT_COMPONENT_NAMES = (
    "system_prompt",
    "match_init_json",
    "observation_json",
    "action_schema_json",
)


class FixedRuntimeError(RuntimeError):
    """Base error for a fail-closed fixed-simultaneous opportunity."""


class FixedRuntimeConfigurationError(FixedRuntimeError, ValueError):
    """The caller did not supply one coherent frozen two-player boundary."""


class DuplicateOpportunityError(FixedRuntimeError):
    """An opportunity ID or boundary was already started and may not execute again."""


class FixedRuntimeInfrastructureError(FixedRuntimeError):
    """The authoritative commit/reveal bridge failed as organizer infrastructure."""

    def __init__(self, stage: str) -> None:
        super().__init__(f"authoritative bridge failed during {stage}")
        self.stage = stage


class FixedOpportunityDisposition(str, Enum):
    """Failure decision evaluated jointly before the activation tick."""

    CONTINUE = "continue"
    TECHNICAL_FORFEIT_SLOT_0 = "technical_forfeit_slot_0"
    TECHNICAL_FORFEIT_SLOT_1 = "technical_forfeit_slot_1"
    DRAW_DOUBLE_TECHNICAL_FORFEIT = "draw_double_technical_forfeit"
    VOID_INFRASTRUCTURE = "void_infrastructure"


@dataclass(frozen=True)
class FixedPlayerInput:
    """Frozen provider-visible bytes and the matching private validation context."""

    player_slot: int
    system_prompt: str
    match_init_json: bytes
    observation_json: bytes
    action_schema_json: bytes
    validation_context: BatchValidationContext

    def __post_init__(self) -> None:
        if self.player_slot not in {0, 1}:
            raise FixedRuntimeConfigurationError("player_slot must be 0 or 1")
        if not self.system_prompt:
            raise FixedRuntimeConfigurationError("system_prompt is required")
        for name in ("match_init_json", "observation_json", "action_schema_json"):
            if not isinstance(getattr(self, name), bytes):
                raise FixedRuntimeConfigurationError(f"{name} must be immutable bytes")


def canonical_provider_input_envelope_bytes(player_input: FixedPlayerInput) -> bytes:
    """Frame the exact logical provider-visible input for byte-limit accounting.

    Provider APIs serialize system/tool/messages differently, so their transport wrappers are not
    comparable benchmark inputs.  The frozen logical envelope instead uses this provider-neutral
    byte framing, in fixed component order::

        domain || name || NUL || uint64_be(payload_bytes) || payload

    ``payload`` is the exact UTF-8 system prompt or exact canonical JSON bytes supplied to the
    adapter.  ``MATCH_INIT`` contains the complete static catalogs and remains counted on every
    opportunity even when a provider caches that prefix.  Framing bytes count toward the cap.
    """

    if unicodedata.normalize("NFC", player_input.system_prompt) != player_input.system_prompt:
        raise FixedRuntimeConfigurationError("system_prompt must be NFC-normalized")
    try:
        prompt_bytes = player_input.system_prompt.encode(errors="strict")
    except UnicodeEncodeError as exc:
        raise FixedRuntimeConfigurationError("system_prompt is not valid UTF-8") from exc
    payloads = (
        prompt_bytes,
        player_input.match_init_json,
        player_input.observation_json,
        player_input.action_schema_json,
    )
    framed = bytearray(_INPUT_FRAME_DOMAIN)
    for name, payload in zip(_INPUT_COMPONENT_NAMES, payloads):
        framed.extend(name.encode("ascii"))
        framed.append(0)
        framed.extend(len(payload).to_bytes(8, byteorder="big", signed=False))
        framed.extend(payload)
    return bytes(framed)


@dataclass(frozen=True)
class FixedDecisionOpportunity:
    """One decision boundary shared by exactly two private player projections."""

    opportunity_id: str
    match_id: str
    observation_seq: int
    boundary_tick: int
    response_deadline_ms: int
    player_inputs: Tuple[FixedPlayerInput, FixedPlayerInput]

    def __post_init__(self) -> None:
        if _OPPORTUNITY_RE.fullmatch(self.opportunity_id) is None:
            raise FixedRuntimeConfigurationError("opportunity_id has invalid syntax")
        if not self.match_id:
            raise FixedRuntimeConfigurationError("match_id is required")
        for name in ("observation_seq", "boundary_tick"):
            value = getattr(self, name)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise FixedRuntimeConfigurationError(f"{name} must be non-negative")
        if (
            not isinstance(self.response_deadline_ms, int)
            or isinstance(self.response_deadline_ms, bool)
            or not 1 <= self.response_deadline_ms <= 45_000
        ):
            raise FixedRuntimeConfigurationError("response_deadline_ms must be in [1, 45000]")
        if len(self.player_inputs) != 2 or {
            value.player_slot for value in self.player_inputs
        } != {0, 1}:
            raise FixedRuntimeConfigurationError("player_inputs must contain slots 0 and 1")


@dataclass(frozen=True)
class SlotCommit:
    player_slot: int
    commit_hash: str


@dataclass(frozen=True)
class FixedCommitRequest:
    match_id: str
    opportunity_id: str
    observation_seq: int
    boundary_tick: int
    commits: Tuple[SlotCommit, SlotCommit]


@dataclass(frozen=True)
class SlotReveal:
    player_slot: int
    batch: ActionBatch
    salt_hex: str


@dataclass(frozen=True)
class FixedRevealRequest:
    match_id: str
    opportunity_id: str
    observation_seq: int
    boundary_tick: int
    activation_tick: int
    disposition: FixedOpportunityDisposition
    reveals: Tuple[SlotReveal, SlotReveal]

    def __post_init__(self) -> None:
        if self.activation_tick != self.boundary_tick + 1:
            raise FixedRuntimeConfigurationError("fixed reveals must activate at boundary_tick + 1")
        if tuple(value.player_slot for value in self.reveals) != (0, 1):
            raise FixedRuntimeConfigurationError("reveals must be in canonical slot order")


class FixedAuthoritativeBridge(Protocol):
    """The only interface through which fixed batches may reach authoritative Godot."""

    async def lock_batch_commits(self, request: FixedCommitRequest) -> None:
        """Atomically lock the complete pair of hashes without receiving either batch."""

    async def reveal_batch_pair(self, request: FixedRevealRequest) -> None:
        """Atomically verify/reveal both batches and schedule the authoritative decision."""


@dataclass(frozen=True)
class FailureRecord:
    opportunity_id: str
    code: str
    owner: FailureOwner
    hard_model_failure: bool
    dispatch_monotonic_ns: int
    deadline_monotonic_ns: int
    arrival_monotonic_ns: Optional[int]
    consecutive_count_after: int
    cumulative_count_after: int


@dataclass(frozen=True)
class PlayerDecisionResult:
    """Sanitized result; raw bytes, private text, salts, and rival data are excluded."""

    player_slot: int
    client_batch_id: str
    batch_commit_hash: str
    used_fallback: bool
    classification_code: str
    failure: Optional[FailureRecord]
    provider_telemetry: ProviderTelemetry
    dispatch_monotonic_ns: int
    deadline_monotonic_ns: int
    arrival_monotonic_ns: Optional[int]
    consecutive_failures: int
    cumulative_failures: int
    forfeit_threshold_reached: bool


@dataclass(frozen=True)
class FixedOpportunityResult:
    match_id: str
    opportunity_id: str
    observation_seq: int
    boundary_tick: int
    activation_tick: int
    disposition: FixedOpportunityDisposition
    commits: Tuple[SlotCommit, SlotCommit]
    player_results: Tuple[PlayerDecisionResult, PlayerDecisionResult]

    def __post_init__(self) -> None:
        if self.activation_tick != self.boundary_tick + 1:
            raise FixedRuntimeConfigurationError("fixed result activation tick is not T + 1")
        if tuple(value.player_slot for value in self.player_results) != (0, 1):
            raise FixedRuntimeConfigurationError("player results must be in canonical slot order")


@dataclass(frozen=True)
class _ProviderInvocation:
    result: Optional[ProviderCallResult]
    arrival_monotonic_ns: int
    adapter_contract_failed: bool


@dataclass(frozen=True)
class _ClassifiedBatch:
    batch: ActionBatch
    used_fallback: bool
    classification_code: str
    failure_classification: Optional[FailureClassification]
    telemetry: ProviderTelemetry
    arrival_monotonic_ns: Optional[int]


SaltSource = Callable[[str, str, int], str]


class FixedSimultaneousRuntime:
    """Run fair two-player LLM opportunities against one frozen simulation boundary."""

    def __init__(
        self,
        *,
        adapters: Mapping[int, ParticipantProviderAdapter],
        bridge: FixedAuthoritativeBridge,
        validator: Optional[ActionEnvelopeValidator] = None,
        failure_counters: Optional[Mapping[int, ModelFailureCounter]] = None,
        batch_idempotency: Optional[BatchIdempotencyRegistry] = None,
        salt_source: Optional[SaltSource] = None,
        monotonic_ns: Callable[[], int] = time.monotonic_ns,
    ) -> None:
        if set(adapters) != {0, 1}:
            raise FixedRuntimeConfigurationError("adapters must contain exactly slots 0 and 1")
        for slot, adapter in adapters.items():
            if not callable(getattr(adapter, "request", None)):
                raise FixedRuntimeConfigurationError(f"slot {slot} adapter has no request method")
            if not isinstance(getattr(adapter, "endpoint_ownership", None), EndpointOwnership):
                raise FixedRuntimeConfigurationError(
                    f"slot {slot} adapter endpoint ownership is invalid"
                )
        counters = failure_counters or {0: ModelFailureCounter(), 1: ModelFailureCounter()}
        if set(counters) != {0, 1}:
            raise FixedRuntimeConfigurationError(
                "failure_counters must contain exactly slots 0 and 1"
            )
        self._adapters = dict(adapters)
        self._bridge = bridge
        self._validator = validator or ActionEnvelopeValidator()
        self._failure_counters = dict(counters)
        self._batch_idempotency = batch_idempotency or BatchIdempotencyRegistry()
        self._salt_source = salt_source or _random_salt
        self._monotonic_ns = monotonic_ns
        self._used_opportunity_ids: Set[Tuple[str, str]] = set()
        self._used_boundaries: Set[Tuple[str, int, int]] = set()
        self._opportunity_guard = asyncio.Lock()

    @property
    def failure_counters(self) -> Mapping[int, ModelFailureCounter]:
        return dict(self._failure_counters)

    async def run_opportunity(
        self, opportunity: FixedDecisionOpportunity
    ) -> FixedOpportunityResult:
        """Dispatch, classify, commit, lock, and reveal one idempotent fixed window."""

        inputs = _validate_and_index_opportunity(opportunity)
        await self._claim_opportunity(opportunity)

        loop = asyncio.get_running_loop()
        dispatch_ns = self._monotonic_ns()
        deadline_ns = dispatch_ns + opportunity.response_deadline_ms * 1_000_000
        loop_deadline = loop.time() + opportunity.response_deadline_ms / 1_000
        tasks: Dict[int, asyncio.Task[_ProviderInvocation]] = {}
        for slot in (0, 1):
            player_input = inputs[slot]
            request = ProviderRequest(
                match_id=opportunity.match_id,
                opportunity_id=opportunity.opportunity_id,
                player_slot=slot,
                observation_seq=opportunity.observation_seq,
                boundary_tick=opportunity.boundary_tick,
                deadline_monotonic_ns=deadline_ns,
                system_prompt=player_input.system_prompt,
                match_init_json=player_input.match_init_json,
                observation_json=player_input.observation_json,
                action_schema_json=player_input.action_schema_json,
            )
            tasks[slot] = asyncio.create_task(
                self._invoke_provider(self._adapters[slot], request),
                name=f"duel-fixed-{opportunity.opportunity_id}-slot-{slot}",
            )

        try:
            remaining = max(0.0, loop_deadline - loop.time())
            await asyncio.wait(set(tasks.values()), timeout=remaining)
            invocations = _collect_on_time_invocations(tasks, deadline_ns)
            late_tasks = {task for task in tasks.values() if not task.done()}
            await _cancel_and_drain(late_tasks)
        except asyncio.CancelledError:
            await _cancel_and_drain(set(tasks.values()))
            raise

        classified: Dict[int, _ClassifiedBatch] = {}
        for slot in (0, 1):
            classified[slot] = self._classify_slot(
                opportunity=opportunity,
                player_input=inputs[slot],
                adapter=self._adapters[slot],
                invocation=invocations.get(slot),
            )

        threshold_by_slot: Dict[int, bool] = {}
        failure_records: Dict[int, Optional[FailureRecord]] = {}
        for slot in (0, 1):
            item = classified[slot]
            counter = self._failure_counters[slot]
            if item.failure_classification is None:
                counter.record_valid_envelope()
                threshold = False
                failure_record = None
            else:
                threshold = counter.record(item.failure_classification)
                failure_record = FailureRecord(
                    opportunity_id=opportunity.opportunity_id,
                    code=item.failure_classification.code,
                    owner=item.failure_classification.owner,
                    hard_model_failure=item.failure_classification.hard_model_failure,
                    dispatch_monotonic_ns=dispatch_ns,
                    deadline_monotonic_ns=deadline_ns,
                    arrival_monotonic_ns=item.arrival_monotonic_ns,
                    consecutive_count_after=counter.consecutive,
                    cumulative_count_after=counter.cumulative,
                )
            threshold_by_slot[slot] = threshold
            failure_records[slot] = failure_record

        disposition = _joint_disposition(classified, threshold_by_slot)
        window = FixedCommitRevealWindow(
            opportunity.match_id, opportunity.observation_seq, player_slots=(0, 1)
        )
        for slot in (0, 1):
            salt = self._salt_source(opportunity.match_id, opportunity.opportunity_id, slot)
            window.add_private_batch(slot, classified[slot].batch, salt)
        commits_by_slot = window.lock_commits()
        commits = tuple(
            SlotCommit(player_slot=slot, commit_hash=commits_by_slot[slot]) for slot in (0, 1)
        )
        commit_request = FixedCommitRequest(
            match_id=opportunity.match_id,
            opportunity_id=opportunity.opportunity_id,
            observation_seq=opportunity.observation_seq,
            boundary_tick=opportunity.boundary_tick,
            commits=commits,  # type: ignore[arg-type]
        )
        try:
            await self._bridge.lock_batch_commits(commit_request)
        except Exception:
            raise FixedRuntimeInfrastructureError("commit lock") from None

        reveals_by_slot = window.reveal_all()
        reveals = tuple(_slot_reveal(reveals_by_slot[slot]) for slot in (0, 1))
        reveal_request = FixedRevealRequest(
            match_id=opportunity.match_id,
            opportunity_id=opportunity.opportunity_id,
            observation_seq=opportunity.observation_seq,
            boundary_tick=opportunity.boundary_tick,
            activation_tick=opportunity.boundary_tick + 1,
            disposition=disposition,
            reveals=reveals,  # type: ignore[arg-type]
        )
        try:
            await self._bridge.reveal_batch_pair(reveal_request)
        except Exception:
            raise FixedRuntimeInfrastructureError("batch reveal") from None

        player_results = tuple(
            PlayerDecisionResult(
                player_slot=slot,
                client_batch_id=classified[slot].batch.client_batch_id,
                batch_commit_hash=commits_by_slot[slot],
                used_fallback=classified[slot].used_fallback,
                classification_code=classified[slot].classification_code,
                failure=failure_records[slot],
                provider_telemetry=classified[slot].telemetry,
                dispatch_monotonic_ns=dispatch_ns,
                deadline_monotonic_ns=deadline_ns,
                arrival_monotonic_ns=classified[slot].arrival_monotonic_ns,
                consecutive_failures=self._failure_counters[slot].consecutive,
                cumulative_failures=self._failure_counters[slot].cumulative,
                forfeit_threshold_reached=threshold_by_slot[slot],
            )
            for slot in (0, 1)
        )
        return FixedOpportunityResult(
            match_id=opportunity.match_id,
            opportunity_id=opportunity.opportunity_id,
            observation_seq=opportunity.observation_seq,
            boundary_tick=opportunity.boundary_tick,
            activation_tick=opportunity.boundary_tick + 1,
            disposition=disposition,
            commits=commits,  # type: ignore[arg-type]
            player_results=player_results,  # type: ignore[arg-type]
        )

    async def _claim_opportunity(self, opportunity: FixedDecisionOpportunity) -> None:
        identity = (opportunity.match_id, opportunity.opportunity_id)
        boundary = (
            opportunity.match_id,
            opportunity.observation_seq,
            opportunity.boundary_tick,
        )
        async with self._opportunity_guard:
            if identity in self._used_opportunity_ids or boundary in self._used_boundaries:
                raise DuplicateOpportunityError(
                    "fixed opportunity ID or frozen boundary was already started"
                )
            self._used_opportunity_ids.add(identity)
            self._used_boundaries.add(boundary)

    async def _invoke_provider(
        self, adapter: ParticipantProviderAdapter, request: ProviderRequest
    ) -> _ProviderInvocation:
        try:
            result = await adapter.request(request)
            arrived = self._monotonic_ns()
            if not isinstance(result, ProviderCallResult):
                return _ProviderInvocation(None, arrived, True)
            return _ProviderInvocation(result, arrived, False)
        except asyncio.CancelledError:
            raise
        except Exception:
            # Provider SDK exception strings can contain headers, endpoint URLs, or credentials.
            return _ProviderInvocation(None, self._monotonic_ns(), True)

    def _classify_slot(
        self,
        *,
        opportunity: FixedDecisionOpportunity,
        player_input: FixedPlayerInput,
        adapter: ParticipantProviderAdapter,
        invocation: Optional[_ProviderInvocation],
    ) -> _ClassifiedBatch:
        if invocation is None:
            return self._fallback(
                opportunity,
                player_input,
                FailureClassification("provider_timeout", FailureOwner.MODEL, True),
                ProviderTelemetry(),
                None,
            )
        if invocation.adapter_contract_failed or invocation.result is None:
            return self._fallback(
                opportunity,
                player_input,
                FailureClassification(
                    "provider_adapter_exception",
                    FailureOwner.ORGANIZER_INFRASTRUCTURE,
                    False,
                ),
                ProviderTelemetry(),
                invocation.arrival_monotonic_ns,
            )

        provider_result = invocation.result
        if provider_result.failure is not None:
            classification = _classify_provider_failure(
                provider_result.failure, adapter.endpoint_ownership
            )
            return self._fallback(
                opportunity,
                player_input,
                classification,
                provider_result.telemetry,
                invocation.arrival_monotonic_ns,
            )

        validation = self._validator.validate(
            provider_result.raw_output or b"", player_input.validation_context
        )
        if not validation.valid or validation.batch is None:
            code = validation.code or BatchErrorCode.SCHEMA_MISMATCH
            return self._fallback(
                opportunity,
                player_input,
                FailureClassification(code.value, FailureOwner.MODEL, True),
                provider_result.telemetry,
                invocation.arrival_monotonic_ns,
            )
        if not self._batch_idempotency.register(
            match_id=opportunity.match_id,
            player_slot=player_input.player_slot,
            client_batch_id=validation.batch.client_batch_id,
        ):
            return self._fallback(
                opportunity,
                player_input,
                FailureClassification(
                    BatchErrorCode.DUPLICATE_BATCH.value, FailureOwner.MODEL, True
                ),
                provider_result.telemetry,
                invocation.arrival_monotonic_ns,
            )
        return _ClassifiedBatch(
            batch=validation.batch,
            used_fallback=False,
            classification_code="valid_envelope",
            failure_classification=None,
            telemetry=provider_result.telemetry,
            arrival_monotonic_ns=invocation.arrival_monotonic_ns,
        )

    def _fallback(
        self,
        opportunity: FixedDecisionOpportunity,
        player_input: FixedPlayerInput,
        classification: FailureClassification,
        telemetry: ProviderTelemetry,
        arrival_monotonic_ns: Optional[int],
    ) -> _ClassifiedBatch:
        batch = self._canonical_no_op(opportunity, player_input)
        return _ClassifiedBatch(
            batch=batch,
            used_fallback=True,
            classification_code=classification.code,
            failure_classification=classification,
            telemetry=telemetry,
            arrival_monotonic_ns=arrival_monotonic_ns,
        )

    def _canonical_no_op(
        self, opportunity: FixedDecisionOpportunity, player_input: FixedPlayerInput
    ) -> ActionBatch:
        identity = (
            f"{opportunity.match_id}\x00{opportunity.opportunity_id}\x00"
            f"{player_input.player_slot}"
        ).encode()
        digest = hashlib.sha256(identity).hexdigest()[:16]
        for nonce in range(32):
            suffix = "" if nonce == 0 else f"_{nonce}"
            client_batch_id = (
                f"gateway_noop_{opportunity.observation_seq}_"
                f"{player_input.player_slot}_{digest}{suffix}"
            )
            if self._batch_idempotency.register(
                match_id=opportunity.match_id,
                player_slot=player_input.player_slot,
                client_batch_id=client_batch_id,
            ):
                return ActionBatch(
                    match_id=opportunity.match_id,
                    observation_seq=opportunity.observation_seq,
                    based_on_observation_hash=player_input.validation_context.observation_hash,
                    client_batch_id=client_batch_id,
                    valid_until_tick=opportunity.boundary_tick + 1,
                    commands=[],
                )
        raise FixedRuntimeInfrastructureError("fallback batch allocation")


def _validate_and_index_opportunity(
    opportunity: FixedDecisionOpportunity,
) -> Dict[int, FixedPlayerInput]:
    inputs = {value.player_slot: value for value in opportunity.player_inputs}
    activation_tick = opportunity.boundary_tick + 1
    for slot in (0, 1):
        player_input = inputs[slot]
        context = player_input.validation_context
        if context.match_id != opportunity.match_id:
            raise FixedRuntimeConfigurationError(
                f"slot {slot} validation match is not frozen match"
            )
        if context.observation_seq != opportunity.observation_seq:
            raise FixedRuntimeConfigurationError(
                f"slot {slot} validation sequence is not frozen sequence"
            )
        if context.application_tick != activation_tick:
            raise FixedRuntimeConfigurationError(
                f"slot {slot} application tick must be boundary_tick + 1"
            )
        if context.controller_valid_until_tick != activation_tick:
            raise FixedRuntimeConfigurationError(
                f"slot {slot} fixed validity ceiling must be boundary_tick + 1"
            )

        match_init = _strict_wire_object(player_input.match_init_json, f"slot {slot} MATCH_INIT")
        observation = _strict_wire_object(
            player_input.observation_json, f"slot {slot} OBSERVATION"
        )
        action_schema = _strict_wire_object(
            player_input.action_schema_json, f"slot {slot} action schema"
        )
        if canonical_json_bytes(match_init) != player_input.match_init_json:
            raise FixedRuntimeConfigurationError(f"slot {slot} MATCH_INIT is not canonical JSON")
        if canonical_json_bytes(observation) != player_input.observation_json:
            raise FixedRuntimeConfigurationError(f"slot {slot} OBSERVATION is not canonical JSON")
        if canonical_json_bytes(action_schema) != player_input.action_schema_json:
            raise FixedRuntimeConfigurationError(
                f"slot {slot} action schema is not canonical JSON"
            )
        input_bytes = canonical_provider_input_envelope_bytes(player_input)
        if len(input_bytes) > MAX_CANONICAL_INPUT_BYTES:
            raise FixedRuntimeConfigurationError(
                f"slot {slot} canonical provider input exceeds "
                f"{MAX_CANONICAL_INPUT_BYTES} bytes"
            )
        if match_init.get("message_type") != "match_init":
            raise FixedRuntimeConfigurationError(f"slot {slot} MATCH_INIT type is invalid")
        if observation.get("message_type") != "observation":
            raise FixedRuntimeConfigurationError(f"slot {slot} OBSERVATION type is invalid")
        for value, label in ((match_init, "MATCH_INIT"), (observation, "OBSERVATION")):
            if value.get("protocol_version") != DUEL_PROTOCOL_VERSION:
                raise FixedRuntimeConfigurationError(
                    f"slot {slot} {label} protocol version is invalid"
                )
            if value.get("match_id") != opportunity.match_id:
                raise FixedRuntimeConfigurationError(f"slot {slot} {label} match is invalid")
            if _contains_forbidden_provider_key(value):
                raise FixedRuntimeConfigurationError(
                    f"slot {slot} {label} contains an omniscient state hash"
                )
        if match_init.get("perspective") != "self":
            raise FixedRuntimeConfigurationError(f"slot {slot} MATCH_INIT is not self-relative")
        if observation.get("observation_seq") != opportunity.observation_seq:
            raise FixedRuntimeConfigurationError(f"slot {slot} OBSERVATION sequence is invalid")
        if observation.get("tick") != opportunity.boundary_tick:
            raise FixedRuntimeConfigurationError(
                f"slot {slot} OBSERVATION is not from the shared boundary"
            )
        if observation.get("observation_hash") != context.observation_hash:
            raise FixedRuntimeConfigurationError(
                f"slot {slot} observation hash does not match validation context"
            )
    return inputs


def _strict_wire_object(payload: bytes, label: str) -> dict[str, object]:
    try:
        value = strict_json_loads(payload)
    except (TypeError, ValueError, UnicodeError) as exc:
        raise FixedRuntimeConfigurationError(f"{label} is invalid strict JSON") from exc
    if not isinstance(value, dict):
        raise FixedRuntimeConfigurationError(f"{label} must be a JSON object")
    return value


def _contains_forbidden_provider_key(value: object) -> bool:
    if isinstance(value, dict):
        if any(key in _FORBIDDEN_PROVIDER_KEYS for key in value):
            return True
        return any(_contains_forbidden_provider_key(child) for child in value.values())
    if isinstance(value, list):
        return any(_contains_forbidden_provider_key(child) for child in value)
    return False


def _collect_on_time_invocations(
    tasks: Mapping[int, asyncio.Task[_ProviderInvocation]], deadline_ns: int
) -> Dict[int, _ProviderInvocation]:
    result: Dict[int, _ProviderInvocation] = {}
    for slot in (0, 1):
        task = tasks[slot]
        if not task.done() or task.cancelled():
            continue
        invocation = task.result()
        if invocation.arrival_monotonic_ns <= deadline_ns:
            result[slot] = invocation
    return result


async def _cancel_and_drain(tasks: Set[asyncio.Task[_ProviderInvocation]]) -> None:
    if not tasks:
        return
    for task in tasks:
        if not task.done():
            task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)


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


def _joint_disposition(
    classified: Mapping[int, _ClassifiedBatch], threshold_by_slot: Mapping[int, bool]
) -> FixedOpportunityDisposition:
    if any(
        item.failure_classification is not None
        and item.failure_classification.owner is FailureOwner.ORGANIZER_INFRASTRUCTURE
        for item in classified.values()
    ):
        return FixedOpportunityDisposition.VOID_INFRASTRUCTURE
    if threshold_by_slot[0] and threshold_by_slot[1]:
        return FixedOpportunityDisposition.DRAW_DOUBLE_TECHNICAL_FORFEIT
    if threshold_by_slot[0]:
        return FixedOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_0
    if threshold_by_slot[1]:
        return FixedOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_1
    return FixedOpportunityDisposition.CONTINUE


def _slot_reveal(reveal: BatchReveal) -> SlotReveal:
    return SlotReveal(
        player_slot=reveal.player_slot,
        batch=reveal.batch,
        salt_hex=reveal.salt_hex,
    )


def _random_salt(match_id: str, opportunity_id: str, player_slot: int) -> str:
    del match_id, opportunity_id, player_slot
    return secrets.token_hex(32)
