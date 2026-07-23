"""Production orchestration for one authenticated WorldArena Duel match.

The lower-level fixed and continuous runtimes deliberately know nothing about a complete match.
This module joins those runtimes to the authenticated Godot bridge without moving any gameplay
authority into Python.  It verifies the exact provider-visible inputs, drives both decision modes,
records an immutable orchestration trace, and refuses to acknowledge match completion until an
artifact finalizer has sealed the result.
"""

from __future__ import annotations

# ruff: noqa: UP045 -- Keep runtime-compatible public annotations for Python 3.9.
import asyncio
import re
import time
from dataclasses import dataclass
from dataclasses import field as dataclass_field
from typing import (
    Awaitable,
    Callable,
    Dict,
    List,
    Mapping,
    Optional,
    Protocol,
    Sequence,
    Tuple,
)

from pydantic import JsonValue

from .canonical import strict_json_loads
from .continuous_runtime import (
    CONTINUOUS_DECISION_PERIOD_TICKS,
    ContinuousDecisionOpportunity,
    ContinuousDispatchResult,
    ContinuousDispatchStatus,
    ContinuousGateResult,
    ContinuousOpportunityDisposition,
    ContinuousPlayerInput,
    ContinuousRealtimeRuntime,
)
from .gateway_validation import ActionEnvelopeValidator, BatchValidationContext
from .godot_bridge import (
    AcknowledgedActionBatch,
    ProviderObservation,
    ProviderObservationPair,
    TerminalReport,
)
from .match_init import MatchInitAssembly
from .models import MatchConfig
from .provider_adapters import ParticipantProviderAdapter
from .runtime import (
    FixedDecisionOpportunity,
    FixedOpportunityResult,
    FixedPlayerInput,
    FixedSimultaneousRuntime,
)
from .timing import COMMAND_GATE_NS, controller_valid_until_tick

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_ARTIFACT_CODE_RE = re.compile(r"^[a-z0-9][a-z0-9._:-]{0,95}$")
_DEFAULT_GATE_LEAD_NS = 50_000_000


class LiveMatchError(RuntimeError):
    """Base error for complete-match orchestration."""


class LiveMatchConfigurationError(LiveMatchError, ValueError):
    """Static inputs cannot describe one coherent official match."""


class LiveMatchInfrastructureError(LiveMatchError):
    """Trusted orchestration could not safely complete the match."""


@dataclass(frozen=True)
class LiveArtifactSeal:
    """Content-addressed artifact completion returned by a trusted finalizer."""

    artifact_hash: str
    manifest: Mapping[str, JsonValue]

    def __post_init__(self) -> None:
        if _SHA256_RE.fullmatch(self.artifact_hash) is None:
            raise LiveMatchConfigurationError("artifact_hash must be lowercase SHA-256")
        if not isinstance(self.manifest, Mapping):
            raise LiveMatchConfigurationError("artifact manifest must be a mapping")


@dataclass(frozen=True)
class LiveMatchTrace:
    """Exact trusted inputs and sanitized scheduler results needed to seal match artifacts.

    Observation bytes are protected-audit material.  Callers must never publish this object as a
    replay directly; the supplied artifact finalizer is responsible for public/protected layering.
    """

    match_id: str
    config: MatchConfig
    match_init_json: bytes
    match_start_monotonic_ns: Optional[int]
    observations: Tuple[ProviderObservationPair, ...]
    action_receipts: Tuple[Mapping[str, JsonValue], ...]
    acknowledged_action_batches: Tuple[AcknowledgedActionBatch, ...] = dataclass_field(repr=False)
    fixed_opportunities: Tuple[FixedOpportunityResult, ...]
    continuous_dispatches: Tuple[ContinuousDispatchResult, ...]
    continuous_gates: Tuple[ContinuousGateResult, ...]
    tick_events: Tuple[Mapping[str, JsonValue], ...]
    checkpoints: Tuple[Mapping[str, JsonValue], ...]
    terminal: TerminalReport


@dataclass(frozen=True)
class LiveMatchResult:
    """A terminal match whose replay/audit layers were sealed and acknowledged by Godot."""

    trace: LiveMatchTrace
    artifact: LiveArtifactSeal

    @property
    def terminal(self) -> TerminalReport:
        return self.trace.terminal


class LiveArtifactFinalizer(Protocol):
    """Turn a complete trusted trace into separately governed artifact layers."""

    async def seal(self, trace: LiveMatchTrace) -> LiveArtifactSeal:
        """Persist/verify artifacts and return their content-addressed completion manifest."""


class LiveGodotBridge(Protocol):
    """Complete-match subset of :class:`GatewayGodotBridge` used by the runner."""

    match_id: str
    terminal_report: Optional[TerminalReport]

    async def configure(self, config: MatchConfig) -> object: ...

    async def next_match_init(self) -> bytes: ...

    async def next_observation_pair(self) -> ProviderObservationPair: ...

    async def next_action_receipts(self) -> Mapping[str, JsonValue]: ...

    async def next_acknowledged_action_batches(
        self,
    ) -> Tuple[AcknowledgedActionBatch, ...]: ...

    async def next_tick_events(self) -> Mapping[str, JsonValue]: ...

    async def next_checkpoint(self) -> Mapping[str, JsonValue]: ...

    async def wait_terminal(self) -> TerminalReport: ...

    async def start_continuous_clock(self) -> None: ...

    async def send_thinking_status(
        self,
        *,
        observation_hash: str,
        player_slot: int,
        status: str,
        observation_seq: int,
    ) -> None: ...

    async def declare_continuous_disposition(
        self, disposition: ContinuousOpportunityDisposition, *, code: str
    ) -> None: ...

    async def mark_artifact_ready(
        self, *, artifact_hash: str, manifest: Mapping[str, JsonValue]
    ) -> None: ...


MonotonicClock = Callable[[], int]
AsyncSleep = Callable[[float], Awaitable[None]]


class DuelLiveMatchRunner:
    """Drive one configured two-model Duel through terminal artifact acknowledgement.

    The bridge must already have completed its authenticated ``hello``/``auth`` handshake.  Godot
    remains paused while fixed-mode providers answer.  Continuous mode uses a 100-ms host gate
    scheduler with a small pre-phase-1 delivery lead; it never asks Godot to run faster than 1x.
    """

    def __init__(
        self,
        *,
        config: MatchConfig,
        match_init: MatchInitAssembly,
        adapters: Mapping[int, ParticipantProviderAdapter],
        bridge: LiveGodotBridge,
        artifact_finalizer: LiveArtifactFinalizer,
        validator: Optional[ActionEnvelopeValidator] = None,
        monotonic_ns: MonotonicClock = time.monotonic_ns,
        sleep: AsyncSleep = asyncio.sleep,
        gate_lead_ns: int = _DEFAULT_GATE_LEAD_NS,
    ) -> None:
        self.config = config
        self.match_init = match_init
        self.adapters = dict(adapters)
        self.bridge = bridge
        self.artifact_finalizer = artifact_finalizer
        self.validator = validator or ActionEnvelopeValidator()
        self.monotonic_ns = monotonic_ns
        self.sleep = sleep
        self.gate_lead_ns = gate_lead_ns
        self._validate_configuration()

        self._observations: List[ProviderObservationPair] = []
        self._action_receipts: List[Mapping[str, JsonValue]] = []
        self._acknowledged_action_batches: List[AcknowledgedActionBatch] = []
        self._fixed_results: List[FixedOpportunityResult] = []
        self._continuous_dispatches: List[ContinuousDispatchResult] = []
        self._continuous_gates: List[ContinuousGateResult] = []
        self._tick_events: List[Mapping[str, JsonValue]] = []
        self._checkpoints: List[Mapping[str, JsonValue]] = []
        self._observation_by_opportunity: Dict[
            str, Tuple[ProviderObservation, ProviderObservation]
        ] = {}
        self._match_start_ns: Optional[int] = None

    async def run(self) -> LiveMatchResult:
        """Configure Godot, run the selected track, seal artifacts, and close cleanly."""

        await self.bridge.configure(self.config)
        authoritative_match_init = await self.bridge.next_match_init()
        if authoritative_match_init != self.match_init.canonical_bytes:
            raise LiveMatchInfrastructureError(
                "Godot MATCH_INIT bytes differ from the locked provider package"
            )

        terminal_task = asyncio.create_task(
            self.bridge.wait_terminal(), name=f"duel-terminal-{self.bridge.match_id}"
        )
        receipt_task = asyncio.create_task(
            self._record_stream(self.bridge.next_action_receipts, self._action_receipts),
            name=f"duel-action-receipts-{self.bridge.match_id}",
        )
        acknowledged_batch_task = asyncio.create_task(
            self._record_acknowledged_batch_stream(),
            name=f"duel-acknowledged-batches-{self.bridge.match_id}",
        )
        event_task = asyncio.create_task(
            self._record_stream(self.bridge.next_tick_events, self._tick_events),
            name=f"duel-events-{self.bridge.match_id}",
        )
        checkpoint_task = asyncio.create_task(
            self._record_stream(self.bridge.next_checkpoint, self._checkpoints),
            name=f"duel-checkpoints-{self.bridge.match_id}",
        )
        try:
            if self.config.decision_mode == "fixed_simultaneous":
                terminal = await self._run_fixed(terminal_task)
            else:
                terminal = await self._run_continuous(terminal_task)
        except BaseException:
            await _cancel_and_drain((terminal_task,))
            raise
        finally:
            # Give already-decoded terminal-adjacent events one turn to enter the trace before the
            # blocking stream readers are cancelled.
            await asyncio.sleep(0)
            await _cancel_and_drain(
                (receipt_task, acknowledged_batch_task, event_task, checkpoint_task)
            )

        trace = LiveMatchTrace(
            match_id=self.bridge.match_id,
            config=self.config,
            match_init_json=self.match_init.canonical_bytes,
            match_start_monotonic_ns=self._match_start_ns,
            observations=tuple(self._observations),
            action_receipts=tuple(self._action_receipts),
            acknowledged_action_batches=tuple(self._acknowledged_action_batches),
            fixed_opportunities=tuple(self._fixed_results),
            continuous_dispatches=tuple(self._continuous_dispatches),
            continuous_gates=tuple(self._continuous_gates),
            tick_events=tuple(self._tick_events),
            checkpoints=tuple(self._checkpoints),
            terminal=terminal,
        )
        try:
            artifact = await self.artifact_finalizer.seal(trace)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            raise LiveMatchInfrastructureError("match artifact sealing failed") from exc
        if not isinstance(artifact, LiveArtifactSeal):
            raise LiveMatchInfrastructureError(
                "artifact finalizer returned an invalid completion object"
            )
        await self.bridge.mark_artifact_ready(
            artifact_hash=artifact.artifact_hash, manifest=artifact.manifest
        )
        return LiveMatchResult(trace=trace, artifact=artifact)

    async def _run_fixed(self, terminal_task: asyncio.Task[TerminalReport]) -> TerminalReport:
        runtime = FixedSimultaneousRuntime(
            adapters=self.adapters,
            bridge=self.bridge,
            validator=self.validator,
            monotonic_ns=self.monotonic_ns,
        )
        while True:
            pair = await self._next_pair_or_terminal(terminal_task)
            if pair is None:
                return terminal_task.result()
            self._observations.append(pair)
            opportunity = build_fixed_live_opportunity(
                pair=pair,
                config=self.config,
                match_init=self.match_init,
            )
            await self._send_pair_status(pair, "thinking")
            result = await runtime.run_opportunity(opportunity)
            self._fixed_results.append(result)
            await self._send_pair_status(pair, "locked")
            if terminal_task.done():
                return terminal_task.result()

    async def _run_continuous(self, terminal_task: asyncio.Task[TerminalReport]) -> TerminalReport:
        first_pair = await self._next_pair_or_terminal(terminal_task)
        if first_pair is None:
            return terminal_task.result()
        if first_pair.tick != 0:
            raise LiveMatchInfrastructureError("continuous match did not begin at tick 0")
        # Godot stays paused after emitting the initial projection.  The authenticated ACK is the
        # shared epoch: Godot arms its first 100-ms phase-1 deadline as that ACK is queued, and the
        # gateway anchors its monotonic scheduler immediately when the ACK arrives.
        await self.bridge.start_continuous_clock()
        self._match_start_ns = self.monotonic_ns()
        runtime = ContinuousRealtimeRuntime(
            match_id=self.bridge.match_id,
            match_start_monotonic_ns=self._match_start_ns,
            adapters=self.adapters,
            bridge=self.bridge,
            validator=self.validator,
            monotonic_ns=self.monotonic_ns,
        )
        self._observations.append(first_pair)
        await self._dispatch_continuous_pair(runtime, first_pair)
        observation_task = asyncio.create_task(
            self._continuous_observation_loop(runtime),
            name=f"duel-observations-{self.bridge.match_id}",
        )
        try:
            gate_tick = 1
            while True:
                target_ns = self._match_start_ns + gate_tick * COMMAND_GATE_NS - self.gate_lead_ns
                wait_result = await self._wait_until_gate_or_stop(
                    target_ns, terminal_task, observation_task
                )
                if wait_result == "terminal":
                    return terminal_task.result()
                if wait_result == "observation_error":
                    observation_task.result()
                    raise AssertionError("unreachable observation task result")

                gate = await runtime.process_gate(gate_tick)
                self._continuous_gates.append(gate)
                await self._publish_gate_statuses(gate)
                if gate.disposition is not ContinuousOpportunityDisposition.CONTINUE:
                    code = gate.infrastructure_code or "model_failure_threshold"
                    if _ARTIFACT_CODE_RE.fullmatch(code) is None:
                        code = "continuous_runtime_failure"
                    await self.bridge.declare_continuous_disposition(gate.disposition, code=code)
                    return await terminal_task
                if terminal_task.done():
                    return terminal_task.result()
                gate_tick += 1
        finally:
            await runtime.aclose()
            await _cancel_and_drain((observation_task,))

    async def _continuous_observation_loop(self, runtime: ContinuousRealtimeRuntime) -> None:
        while True:
            pair = await self.bridge.next_observation_pair()
            if pair.tick == 0:
                raise LiveMatchInfrastructureError("duplicate continuous tick-0 observation")
            if pair.tick % CONTINUOUS_DECISION_PERIOD_TICKS != 0:
                raise LiveMatchInfrastructureError(
                    "continuous observation is outside the frozen 50-tick grid"
                )
            self._observations.append(pair)
            await self._dispatch_continuous_pair(runtime, pair)

    async def _dispatch_continuous_pair(
        self, runtime: ContinuousRealtimeRuntime, pair: ProviderObservationPair
    ) -> None:
        dispatch_order = (0, 1) if pair.observation_seq % 2 == 0 else (1, 0)
        opportunity = build_continuous_live_opportunity(
            pair=pair,
            config=self.config,
            match_init=self.match_init,
            dispatch_order=dispatch_order,
        )
        self._observation_by_opportunity[opportunity.opportunity_id] = pair.observations
        result = await runtime.dispatch_opportunity(opportunity)
        self._continuous_dispatches.append(result)
        for slot_result in result.slots:
            if slot_result.status is ContinuousDispatchStatus.DISPATCHED:
                observation = pair.observations[slot_result.player_slot]
                await self._send_status(
                    observation_hash=observation.observation_hash,
                    player_slot=slot_result.player_slot,
                    status="thinking",
                    observation_seq=pair.observation_seq,
                )

    async def _publish_gate_statuses(self, gate: ContinuousGateResult) -> None:
        ready = {
            (application.opportunity_id, application.player_slot)
            for application in gate.applications
        }
        for opportunity_id, slot in sorted(ready):
            observation = self._observation_for(opportunity_id, slot)
            await self._send_status(
                observation_hash=observation.observation_hash,
                player_slot=slot,
                status="ready",
                observation_seq=observation.observation_seq,
            )
        for evaluation in gate.evaluations:
            for outcome in evaluation.player_outcomes:
                identity = (evaluation.opportunity_id, outcome.player_slot)
                if identity in ready or outcome.classification_code == "in_flight_skipped":
                    continue
                observation = self._observation_for(*identity)
                await self._send_status(
                    observation_hash=observation.observation_hash,
                    player_slot=outcome.player_slot,
                    status="timeout" if outcome.used_no_op else "ready",
                    observation_seq=observation.observation_seq,
                )

    def _observation_for(self, opportunity_id: str, slot: int) -> ProviderObservation:
        pair = self._observation_by_opportunity.get(opportunity_id)
        if pair is None or slot not in {0, 1}:
            raise LiveMatchInfrastructureError("scheduler result references an unknown observation")
        return pair[slot]

    async def _next_pair_or_terminal(
        self, terminal_task: asyncio.Task[TerminalReport]
    ) -> Optional[ProviderObservationPair]:
        pair_task = asyncio.create_task(self.bridge.next_observation_pair())
        done, _ = await asyncio.wait(
            {pair_task, terminal_task}, return_when=asyncio.FIRST_COMPLETED
        )
        if terminal_task in done:
            await _cancel_and_drain((pair_task,))
            return None
        return pair_task.result()

    async def _wait_until_gate_or_stop(
        self,
        target_ns: int,
        terminal_task: asyncio.Task[TerminalReport],
        observation_task: asyncio.Task[None],
    ) -> str:
        delay_seconds = max(0, target_ns - self.monotonic_ns()) / 1_000_000_000
        sleep_task = asyncio.create_task(self.sleep(delay_seconds))
        done, _ = await asyncio.wait(
            {sleep_task, terminal_task, observation_task},
            return_when=asyncio.FIRST_COMPLETED,
        )
        if terminal_task in done:
            await _cancel_and_drain((sleep_task,))
            return "terminal"
        if observation_task in done:
            await _cancel_and_drain((sleep_task,))
            return "observation_error"
        return "gate"

    async def _send_pair_status(self, pair: ProviderObservationPair, status: str) -> None:
        for observation in pair.observations:
            await self._send_status(
                observation_hash=observation.observation_hash,
                player_slot=observation.player_slot,
                status=status,
                observation_seq=pair.observation_seq,
            )

    async def _send_status(
        self,
        *,
        observation_hash: str,
        player_slot: int,
        status: str,
        observation_seq: int,
    ) -> None:
        # Status is protected telemetry, never authority.  A terminal frame can legitimately race
        # an action acknowledgement; in that one case there is nothing left to annotate and the
        # already-authoritative result must not be turned into an infrastructure failure.
        if getattr(self.bridge, "terminal_report", None) is not None:
            return
        try:
            await self.bridge.send_thinking_status(
                observation_hash=observation_hash,
                player_slot=player_slot,
                status=status,
                observation_seq=observation_seq,
            )
        except Exception:
            if getattr(self.bridge, "terminal_report", None) is not None:
                return
            raise

    async def _record_stream(
        self,
        receive: Callable[[], Awaitable[Mapping[str, JsonValue]]],
        destination: List[Mapping[str, JsonValue]],
    ) -> None:
        while True:
            destination.append(dict(await receive()))

    async def _record_acknowledged_batch_stream(self) -> None:
        while True:
            group = await self.bridge.next_acknowledged_action_batches()
            if not isinstance(group, tuple) or not group:
                raise LiveMatchInfrastructureError(
                    "acknowledged action batch stream returned an invalid group"
                )
            if any(not isinstance(value, AcknowledgedActionBatch) for value in group):
                raise LiveMatchInfrastructureError(
                    "acknowledged action batch stream returned an invalid record"
                )
            self._acknowledged_action_batches.extend(group)

    def _validate_configuration(self) -> None:
        if set(self.adapters) != {0, 1}:
            raise LiveMatchConfigurationError("adapters must contain exactly slots 0 and 1")
        if self.bridge.match_id != self.match_init.message.match_id:
            raise LiveMatchConfigurationError("bridge and MATCH_INIT match IDs differ")
        decision = self.match_init.message.decision
        if decision.get("mode") != self.config.decision_mode:
            raise LiveMatchConfigurationError("config and MATCH_INIT decision modes differ")
        if decision.get("decision_period_ticks") != self.config.decision_period_ticks:
            raise LiveMatchConfigurationError("config and MATCH_INIT decision cadences differ")
        if decision.get("response_deadline_ms") != self.config.response_deadline_ms:
            raise LiveMatchConfigurationError("config and MATCH_INIT deadlines differ")
        if not callable(getattr(self.artifact_finalizer, "seal", None)):
            raise LiveMatchConfigurationError("artifact_finalizer must expose async seal(trace)")
        if (
            not isinstance(self.gate_lead_ns, int)
            or isinstance(self.gate_lead_ns, bool)
            or not 0 <= self.gate_lead_ns < COMMAND_GATE_NS
        ):
            raise LiveMatchConfigurationError("gate_lead_ns must be in [0, 100000000)")


def build_fixed_live_opportunity(
    *,
    pair: ProviderObservationPair,
    config: MatchConfig,
    match_init: MatchInitAssembly,
) -> FixedDecisionOpportunity:
    """Build one fixed opportunity only from its two legal provider projections."""

    if config.decision_mode != "fixed_simultaneous":
        raise LiveMatchConfigurationError("fixed opportunity requires fixed_simultaneous config")
    player_inputs = tuple(
        _fixed_player_input(observation, pair, config, match_init)
        for observation in pair.observations
    )
    return FixedDecisionOpportunity(
        opportunity_id=_opportunity_id("fixed", pair.observation_seq),
        match_id=match_init.message.match_id,
        observation_seq=pair.observation_seq,
        boundary_tick=pair.tick,
        response_deadline_ms=config.response_deadline_ms,
        player_inputs=player_inputs,  # type: ignore[arg-type]
    )


def build_continuous_live_opportunity(
    *,
    pair: ProviderObservationPair,
    config: MatchConfig,
    match_init: MatchInitAssembly,
    dispatch_order: Tuple[int, int] = (0, 1),
) -> ContinuousDecisionOpportunity:
    """Build one continuous grid opportunity from the paired Godot observation."""

    if config.decision_mode != "continuous_realtime":
        raise LiveMatchConfigurationError("continuous opportunity requires continuous config")
    player_inputs = tuple(
        _continuous_player_input(observation, pair, config, match_init)
        for observation in pair.observations
    )
    return ContinuousDecisionOpportunity(
        opportunity_id=_opportunity_id("continuous", pair.observation_seq),
        match_id=match_init.message.match_id,
        observation_seq=pair.observation_seq,
        boundary_tick=pair.tick,
        response_deadline_ms=config.response_deadline_ms,
        player_inputs=player_inputs,  # type: ignore[arg-type]
        dispatch_order=dispatch_order,
    )


def _fixed_player_input(
    observation: ProviderObservation,
    pair: ProviderObservationPair,
    config: MatchConfig,
    match_init: MatchInitAssembly,
) -> FixedPlayerInput:
    context = _validation_context(
        observation, pair, config, expected_match_id=match_init.message.match_id
    )
    return FixedPlayerInput(
        player_slot=observation.player_slot,
        system_prompt=match_init.system_prompt,
        match_init_json=match_init.player_payloads[observation.player_slot],
        observation_json=observation.canonical_bytes,
        action_schema_json=match_init.action_schema_bytes,
        validation_context=context,
    )


def _continuous_player_input(
    observation: ProviderObservation,
    pair: ProviderObservationPair,
    config: MatchConfig,
    match_init: MatchInitAssembly,
) -> ContinuousPlayerInput:
    context = _validation_context(
        observation, pair, config, expected_match_id=match_init.message.match_id
    )
    return ContinuousPlayerInput(
        player_slot=observation.player_slot,
        system_prompt=match_init.system_prompt,
        match_init_json=match_init.player_payloads[observation.player_slot],
        observation_json=observation.canonical_bytes,
        action_schema_json=match_init.action_schema_bytes,
        validation_context=context,
    )


def _validation_context(
    observation: ProviderObservation,
    pair: ProviderObservationPair,
    config: MatchConfig,
    *,
    expected_match_id: str,
) -> BatchValidationContext:
    if observation.observation_seq != pair.observation_seq or observation.tick != pair.tick:
        raise LiveMatchInfrastructureError("observation identity differs from its pair boundary")
    try:
        payload = strict_json_loads(observation.canonical_bytes)
    except (TypeError, ValueError, UnicodeError) as exc:
        raise LiveMatchInfrastructureError("provider observation is not strict JSON") from exc
    if not isinstance(payload, dict):
        raise LiveMatchInfrastructureError("provider observation root is not an object")
    if payload.get("match_id") != expected_match_id:
        raise LiveMatchInfrastructureError("provider observation has the wrong match ID")
    if payload.get("observation_seq") != pair.observation_seq or payload.get("tick") != pair.tick:
        raise LiveMatchInfrastructureError("provider observation boundary fields are inconsistent")
    if payload.get("observation_hash") != observation.observation_hash:
        raise LiveMatchInfrastructureError("provider observation hash field is inconsistent")
    decision = _mapping_field(payload, "decision")
    expected_valid_until = controller_valid_until_tick(pair.tick, config.decision_mode)
    if decision.get("mode") != config.decision_mode:
        raise LiveMatchInfrastructureError("provider observation decision mode is inconsistent")
    if decision.get("observation_tick") != pair.tick:
        raise LiveMatchInfrastructureError("provider observation decision tick is inconsistent")
    if decision.get("valid_until_tick") != expected_valid_until:
        raise LiveMatchInfrastructureError("provider observation validity ceiling is inconsistent")
    expected_apply_tick: Optional[int] = pair.tick + 1
    if config.decision_mode == "continuous_realtime":
        expected_apply_tick = None
    if decision.get("commands_apply_tick") != expected_apply_tick:
        raise LiveMatchInfrastructureError("provider observation application tick is inconsistent")

    squad_sizes: Dict[str, int] = {}
    for row in _object_array(payload, "squads"):
        squad_id = row.get("squad_id")
        members = row.get("member_ids")
        if not isinstance(squad_id, str) or not isinstance(members, list):
            raise LiveMatchInfrastructureError("provider squad projection is malformed")
        if squad_id in squad_sizes or any(not isinstance(value, str) for value in members):
            raise LiveMatchInfrastructureError("provider squad projection is ambiguous")
        squad_sizes[squad_id] = len(members)

    transport_counts: Dict[str, int] = {}
    for field in ("owned_entities", "heroes", "owned_structures"):
        for row in _object_array(payload, field):
            passengers = row.get("passenger_ids")
            if passengers is None:
                continue
            entity_id = row.get("entity_id")
            if (
                not isinstance(entity_id, str)
                or not isinstance(passengers, list)
                or any(not isinstance(value, str) for value in passengers)
                or entity_id in transport_counts
            ):
                raise LiveMatchInfrastructureError("provider transport projection is malformed")
            transport_counts[entity_id] = len(passengers)

    return BatchValidationContext(
        match_id=expected_match_id,
        observation_seq=pair.observation_seq,
        observation_hash=observation.observation_hash,
        application_tick=pair.tick + 1,
        controller_valid_until_tick=expected_valid_until,
        squad_sizes=squad_sizes,
        transport_passenger_counts=transport_counts,
    )


def _mapping_field(payload: Mapping[str, object], field: str) -> Mapping[str, object]:
    value = payload.get(field)
    if not isinstance(value, dict):
        raise LiveMatchInfrastructureError(f"provider observation {field} is malformed")
    return value


def _object_array(payload: Mapping[str, object], field: str) -> Sequence[Mapping[str, object]]:
    value = payload.get(field)
    if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
        raise LiveMatchInfrastructureError(f"provider observation {field} is malformed")
    return value  # type: ignore[return-value]


def _opportunity_id(mode: str, sequence: int) -> str:
    # This identity is authority-owned and intentionally mode-neutral.  It must match the protected
    # opportunity frozen by DuelMatchSession for the same observation sequence.
    del mode
    return f"opp_{sequence:08d}"


async def _cancel_and_drain(tasks: Sequence[asyncio.Task[object]]) -> None:
    for task in tasks:
        if not task.done():
            task.cancel()
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)
