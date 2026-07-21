from __future__ import annotations

# ruff: noqa: UP045 -- Keep tests importable on the project's Python 3.9 floor.
import asyncio
from dataclasses import dataclass, field
from typing import Dict, Optional, Tuple

import pytest
from genesis_arena.duel.canonical import canonical_json_bytes
from genesis_arena.duel.continuous_runtime import (
    ContinuousApplyGateRequest,
    ContinuousAuthoritativeBridge,
    ContinuousDecisionOpportunity,
    ContinuousDispatchStatus,
    ContinuousOpportunityDisposition,
    ContinuousPlayerInput,
    ContinuousProviderCallResult,
    ContinuousRealtimeRuntime,
    ContinuousRuntimeConfigurationError,
)
from genesis_arena.duel.gateway_validation import BatchValidationContext
from genesis_arena.duel.provider_adapters import (
    EndpointOwnership,
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
)
from genesis_arena.duel.timing import ModelFailureCounter

MATCH_ID = "m_continuous_runtime"
START_NS = 10_000_000_000
GATE_NS = 100_000_000


@dataclass
class FakeClock:
    value: int = START_NS

    def __call__(self) -> int:
        return self.value

    def set_tick(self, tick: int) -> None:
        self.value = START_NS + tick * GATE_NS


class ScriptedClock:
    def __init__(self, values: list[int]) -> None:
        self.values = list(values)
        self.last = values[-1]

    def __call__(self) -> int:
        if self.values:
            self.last = self.values.pop(0)
        return self.last


def _wire_batch(
    slot: int,
    sequence: int,
    boundary_tick: int,
    *,
    client_batch_id: Optional[str] = None,
    valid_until_tick: Optional[int] = None,
) -> bytes:
    return canonical_json_bytes(
        {
            "based_on_observation_hash": ("a" if slot == 0 else "b") * 64,
            "client_batch_id": client_batch_id or f"continuous_{sequence}_{slot}",
            "commands": [],
            "match_id": MATCH_ID,
            "message_type": "action_batch",
            "observation_seq": sequence,
            "protocol_version": "worldeval-rts/1.0.0",
            "valid_until_tick": (
                boundary_tick + 100 if valid_until_tick is None else valid_until_tick
            ),
        }
    )


def _player_input(slot: int, sequence: int, boundary_tick: int) -> ContinuousPlayerInput:
    observation_hash = ("a" if slot == 0 else "b") * 64
    return ContinuousPlayerInput(
        player_slot=slot,
        system_prompt=f"control self for slot {slot}",
        match_init_json=canonical_json_bytes(
            {
                "decision": {"mode": "continuous_realtime"},
                "match_id": MATCH_ID,
                "message_type": "match_init",
                "perspective": "self",
                "protocol_version": "worldeval-rts/1.0.0",
                "self_marker": f"slot-{slot}",
            }
        ),
        observation_json=canonical_json_bytes(
            {
                "match_id": MATCH_ID,
                "message_type": "observation",
                "observation_hash": observation_hash,
                "observation_seq": sequence,
                "private_marker": f"slot-{slot}",
                "protocol_version": "worldeval-rts/1.0.0",
                "tick": boundary_tick,
            }
        ),
        action_schema_json=canonical_json_bytes({}),
        validation_context=BatchValidationContext(
            match_id=MATCH_ID,
            observation_seq=sequence,
            observation_hash=observation_hash,
            application_tick=boundary_tick + 1,
            controller_valid_until_tick=boundary_tick + 100,
            squad_sizes={},
            transport_passenger_counts={},
        ),
    )


def _opportunity(
    sequence: int = 0,
    boundary_tick: int = 0,
    *,
    deadline_ms: int = 200,
    dispatch_order: Tuple[int, int] = (0, 1),
) -> ContinuousDecisionOpportunity:
    return ContinuousDecisionOpportunity(
        opportunity_id=f"continuous-window-{sequence}",
        match_id=MATCH_ID,
        observation_seq=sequence,
        boundary_tick=boundary_tick,
        response_deadline_ms=deadline_ms,
        player_inputs=(
            _player_input(0, sequence, boundary_tick),
            _player_input(1, sequence, boundary_tick),
        ),
        dispatch_order=dispatch_order,
    )


@dataclass
class RecordingBridge(ContinuousAuthoritativeBridge):
    requests: list[ContinuousApplyGateRequest] = field(default_factory=list)

    async def apply_continuous_gate(self, request: ContinuousApplyGateRequest) -> None:
        self.requests.append(request)


class ImmediateAdapter:
    endpoint_ownership = EndpointOwnership.PARTICIPANT_HOSTED

    def __init__(self, slot: int, *, result: Optional[ProviderCallResult] = None) -> None:
        self.slot = slot
        self.result = result
        self.requests: list[ProviderRequest] = []

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        self.requests.append(request)
        return self.result or ProviderCallResult.success(
            _wire_batch(self.slot, request.observation_seq, request.boundary_tick)
        )


class GateAdapter:
    endpoint_ownership = EndpointOwnership.PARTICIPANT_HOSTED

    def __init__(self, slot: int) -> None:
        self.slot = slot
        self.release = asyncio.Event()
        self.started = asyncio.Event()
        self.requests: list[ProviderRequest] = []
        self.cancelled = 0
        self.output: Optional[bytes] = None

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        self.requests.append(request)
        self.started.set()
        try:
            await self.release.wait()
        except asyncio.CancelledError:
            self.cancelled += 1
            raise
        return ProviderCallResult.success(
            self.output
            or _wire_batch(self.slot, request.observation_seq, request.boundary_tick)
        )


def _runtime(
    clock: object,
    adapters: Dict[int, object],
    bridge: Optional[RecordingBridge] = None,
    *,
    counters: Optional[Dict[int, ModelFailureCounter]] = None,
    sustained_gate_drift_count: int = 2,
) -> tuple[ContinuousRealtimeRuntime, RecordingBridge]:
    actual_bridge = bridge or RecordingBridge()
    runtime = ContinuousRealtimeRuntime(
        match_id=MATCH_ID,
        match_start_monotonic_ns=START_NS,
        adapters=adapters,  # type: ignore[arg-type]
        bridge=actual_bridge,
        monotonic_ns=clock,  # type: ignore[arg-type]
        failure_counters=counters,
        sustained_gate_drift_count=sustained_gate_drift_count,
    )
    return runtime, actual_bridge


async def _yield_until_done(runtime: ContinuousRealtimeRuntime) -> None:
    for _ in range(20):
        if runtime.in_flight_by_slot == {0: 0, 1: 0}:
            return
        await asyncio.sleep(0)
    raise AssertionError("provider tasks did not finish")


@pytest.mark.asyncio
async def test_pair_dispatch_is_concurrent_swappable_and_gate_application_is_canonical() -> None:
    clock = FakeClock()
    call_order: list[int] = []
    both_started = asyncio.Event()

    class BarrierAdapter(ImmediateAdapter):
        async def request(self, request: ProviderRequest) -> ContinuousProviderCallResult:
            self.requests.append(request)
            call_order.append(self.slot)
            if len(call_order) == 2:
                both_started.set()
            await both_started.wait()
            return ContinuousProviderCallResult(
                ProviderCallResult.success(
                    _wire_batch(self.slot, request.observation_seq, request.boundary_tick)
                ),
                first_token_monotonic_ns=clock.value,
            )

    adapters = {0: BarrierAdapter(0), 1: BarrierAdapter(1)}
    runtime, bridge = _runtime(clock, adapters)
    dispatch = await runtime.dispatch_opportunity(_opportunity(dispatch_order=(1, 0)))
    await _yield_until_done(runtime)

    assert call_order == [1, 0]
    assert tuple(value.player_slot for value in dispatch.slots) == (0, 1)
    assert {value.status for value in dispatch.slots} == {
        ContinuousDispatchStatus.DISPATCHED
    }
    assert dispatch.slots[0].actual_dispatch_monotonic_ns == START_NS
    assert dispatch.slots[1].actual_dispatch_monotonic_ns == START_NS
    assert adapters[0].requests[0].deadline_monotonic_ns == dispatch.deadline_monotonic_ns
    assert adapters[1].requests[0].deadline_monotonic_ns == dispatch.deadline_monotonic_ns

    clock.set_tick(1)
    gate = await runtime.process_gate(1)
    assert [value.player_slot for value in gate.applications] == [0, 1]
    assert len(bridge.requests) == 1
    assert [value.player_slot for value in bridge.requests[0].applications] == [0, 1]
    assert all(
        value.timing.first_token_monotonic_ns == START_NS
        for value in bridge.requests[0].applications
    )


@pytest.mark.asyncio
async def test_exact_gate_completion_uses_the_following_gate() -> None:
    clock = FakeClock()
    adapters = {0: GateAdapter(0), 1: GateAdapter(1)}
    runtime, bridge = _runtime(clock, adapters)
    await runtime.dispatch_opportunity(_opportunity())
    await asyncio.gather(adapters[0].started.wait(), adapters[1].started.wait())

    clock.set_tick(1)
    adapters[0].release.set()
    adapters[1].release.set()
    await _yield_until_done(runtime)
    first_gate = await runtime.process_gate(1)
    assert first_gate.applications == ()

    clock.set_tick(2)
    second_gate = await runtime.process_gate(2)
    assert len(second_gate.applications) == 2
    assert bridge.requests[0].application_tick == 2


@pytest.mark.asyncio
async def test_busy_player_skips_next_grid_opportunity_without_overlapping_calls() -> None:
    clock = FakeClock()
    slow_zero = GateAdapter(0)
    fast_one = ImmediateAdapter(1)
    runtime, bridge = _runtime(clock, {0: slow_zero, 1: fast_one})
    await runtime.dispatch_opportunity(_opportunity(deadline_ms=8_000))
    await slow_zero.started.wait()

    clock.set_tick(1)
    await runtime.process_gate(1)
    assert len(bridge.requests) == 1
    clock.set_tick(50)
    second = await runtime.dispatch_opportunity(
        _opportunity(1, 50, deadline_ms=8_000, dispatch_order=(1, 0))
    )

    assert second.slots[0].status is ContinuousDispatchStatus.SKIPPED_IN_FLIGHT
    assert second.slots[1].status is ContinuousDispatchStatus.DISPATCHED
    assert len(slow_zero.requests) == 1
    assert len(fast_one.requests) == 2
    assert runtime.in_flight_by_slot[0] == 1

    slow_zero.release.set()
    await runtime.aclose()


@pytest.mark.asyncio
async def test_timeout_is_cancelled_and_counted_at_first_strictly_later_deadline_gate() -> None:
    clock = FakeClock()
    adapters = {0: GateAdapter(0), 1: GateAdapter(1)}
    runtime, bridge = _runtime(clock, adapters)
    dispatch = await runtime.dispatch_opportunity(_opportunity(deadline_ms=200))
    assert dispatch.evaluation_tick == 3

    clock.set_tick(2)
    deadline_gate = await runtime.process_gate(2)
    assert deadline_gate.evaluations == ()
    assert runtime.in_flight_by_slot == {0: 1, 1: 1}

    clock.set_tick(3)
    evaluation_gate = await runtime.process_gate(3)
    assert bridge.requests == []
    assert adapters[0].cancelled == adapters[1].cancelled == 1
    assert evaluation_gate.disposition is ContinuousOpportunityDisposition.CONTINUE
    outcomes = evaluation_gate.evaluations[0].player_outcomes
    assert [value.classification_code for value in outcomes] == [
        "provider_timeout",
        "provider_timeout",
    ]
    assert [value.consecutive_failures for value in outcomes] == [1, 1]
    assert all(value.used_no_op for value in outcomes)


@pytest.mark.asyncio
async def test_on_deadline_response_is_accepted_and_applies_at_following_gate() -> None:
    clock = FakeClock()
    adapters = {0: GateAdapter(0), 1: GateAdapter(1)}
    runtime, bridge = _runtime(clock, adapters)
    dispatch = await runtime.dispatch_opportunity(_opportunity(deadline_ms=200))

    clock.value = dispatch.deadline_monotonic_ns
    adapters[0].release.set()
    adapters[1].release.set()
    await _yield_until_done(runtime)
    deadline_gate = await runtime.process_gate(2)
    assert deadline_gate.applications == ()

    clock.set_tick(3)
    apply_gate = await runtime.process_gate(3)
    assert len(apply_gate.applications) == 2
    assert [
        value.classification_code
        for value in apply_gate.evaluations[0].player_outcomes
    ] == ["valid_envelope", "valid_envelope"]
    assert bridge.requests[0].application_tick == 3


@pytest.mark.asyncio
async def test_stale_structurally_valid_batch_is_noop_without_hard_failure_strike() -> None:
    clock = FakeClock()
    counters = {
        0: ModelFailureCounter(consecutive=2, cumulative=2),
        1: ModelFailureCounter(consecutive=2, cumulative=2),
    }
    adapters = {0: GateAdapter(0), 1: GateAdapter(1)}
    for slot in (0, 1):
        adapters[slot].output = _wire_batch(slot, 0, 0, valid_until_tick=1)
    runtime, bridge = _runtime(clock, adapters, counters=counters)
    dispatch = await runtime.dispatch_opportunity(_opportunity(deadline_ms=200))
    clock.set_tick(1)
    adapters[0].release.set()
    adapters[1].release.set()
    await _yield_until_done(runtime)

    clock.set_tick(dispatch.evaluation_tick)
    result = await runtime.process_gate(dispatch.evaluation_tick)
    outcomes = result.evaluations[0].player_outcomes
    assert [value.classification_code for value in outcomes] == [
        "expired_batch",
        "expired_batch",
    ]
    assert all(value.failure is not None for value in outcomes)
    assert all(not value.failure.hard_model_failure for value in outcomes if value.failure)
    assert [(value.consecutive_failures, value.cumulative_failures) for value in outcomes] == [
        (0, 2),
        (0, 2),
    ]
    assert bridge.requests == []


@pytest.mark.asyncio
async def test_simultaneous_third_hard_failures_draw_double_technical_forfeit() -> None:
    clock = FakeClock()
    counters = {
        0: ModelFailureCounter(consecutive=2, cumulative=2),
        1: ModelFailureCounter(consecutive=2, cumulative=2),
    }
    adapters = {
        slot: ImmediateAdapter(
            slot,
            result=ProviderCallResult.failed(ProviderFailureKind.REFUSAL),
        )
        for slot in (0, 1)
    }
    runtime, bridge = _runtime(clock, adapters, counters=counters)
    dispatch = await runtime.dispatch_opportunity(_opportunity(deadline_ms=200))
    await _yield_until_done(runtime)

    clock.set_tick(dispatch.evaluation_tick)
    result = await runtime.process_gate(dispatch.evaluation_tick)
    assert result.disposition is ContinuousOpportunityDisposition.DRAW_DOUBLE_TECHNICAL_FORFEIT
    assert all(
        value.forfeit_threshold_reached
        for value in result.evaluations[0].player_outcomes
    )
    assert bridge.requests == []


@pytest.mark.asyncio
async def test_organizer_endpoint_failure_voids_without_model_counter() -> None:
    clock = FakeClock()
    organizer_failure = ImmediateAdapter(
        0,
        result=ProviderCallResult.failed(ProviderFailureKind.CREDENTIAL_ERROR),
    )
    organizer_failure.endpoint_ownership = EndpointOwnership.ORGANIZER_HOSTED
    runtime, _ = _runtime(clock, {0: organizer_failure, 1: ImmediateAdapter(1)})
    dispatch = await runtime.dispatch_opportunity(_opportunity(deadline_ms=200))
    await _yield_until_done(runtime)

    clock.set_tick(1)
    await runtime.process_gate(1)
    clock.set_tick(dispatch.evaluation_tick)
    result = await runtime.process_gate(dispatch.evaluation_tick)
    failed = result.evaluations[0].player_outcomes[0]
    assert result.disposition is ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE
    assert result.infrastructure_code == "credential_error"
    assert failed.consecutive_failures == failed.cumulative_failures == 0


@pytest.mark.asyncio
async def test_dispatch_skew_over_one_tick_voids_match_and_cancels_calls() -> None:
    clock = ScriptedClock(
        [
            START_NS,
            START_NS,
            START_NS + GATE_NS + 1,
            START_NS + GATE_NS + 1,
            START_NS + GATE_NS + 1,
        ]
    )
    adapters = {0: GateAdapter(0), 1: GateAdapter(1)}
    runtime, _ = _runtime(clock, adapters)
    dispatch = await runtime.dispatch_opportunity(_opportunity())
    await asyncio.sleep(0)

    assert dispatch.disposition is ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE
    assert dispatch.infrastructure_code == "dispatch_skew_breach"
    assert adapters[0].cancelled == adapters[1].cancelled == 1
    await runtime.aclose()


@pytest.mark.asyncio
async def test_sustained_gate_drift_and_backwards_clock_are_infrastructure_failures() -> None:
    clock = FakeClock()
    adapters = {
        slot: ImmediateAdapter(
            slot,
            result=ProviderCallResult.failed(ProviderFailureKind.REFUSAL),
        )
        for slot in (0, 1)
    }
    runtime, _ = _runtime(clock, adapters)
    await runtime.dispatch_opportunity(_opportunity(deadline_ms=8_000))
    await _yield_until_done(runtime)

    clock.value = START_NS + 3 * GATE_NS
    first = await runtime.process_gate(1)
    assert first.disposition is ContinuousOpportunityDisposition.CONTINUE
    clock.value = START_NS + 4 * GATE_NS
    second = await runtime.process_gate(2)
    assert second.disposition is ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE
    assert second.infrastructure_code == "sustained_gate_drift"

    backwards = FakeClock(START_NS - 1)
    other, _ = _runtime(backwards, {0: ImmediateAdapter(0), 1: ImmediateAdapter(1)})
    with pytest.raises(ContinuousRuntimeConfigurationError, match="backwards"):
        await other.dispatch_opportunity(_opportunity())
    assert other.disposition is ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE


@pytest.mark.asyncio
async def test_invalid_private_boundary_fails_before_any_provider_dispatch() -> None:
    clock = FakeClock()
    adapters = {0: ImmediateAdapter(0), 1: ImmediateAdapter(1)}
    runtime, _ = _runtime(clock, adapters)
    bad_zero = _player_input(0, 0, 0)
    bad_zero = ContinuousPlayerInput(
        player_slot=bad_zero.player_slot,
        system_prompt=bad_zero.system_prompt,
        match_init_json=bad_zero.match_init_json,
        observation_json=canonical_json_bytes(
            {
                "match_id": MATCH_ID,
                "message_type": "observation",
                "observation_hash": "a" * 64,
                "observation_seq": 0,
                "omniscient_state_hash": "secret",
                "protocol_version": "worldeval-rts/1.0.0",
                "tick": 0,
            }
        ),
        action_schema_json=bad_zero.action_schema_json,
        validation_context=bad_zero.validation_context,
    )
    opportunity = ContinuousDecisionOpportunity(
        opportunity_id="bad-private-boundary",
        match_id=MATCH_ID,
        observation_seq=0,
        boundary_tick=0,
        response_deadline_ms=200,
        player_inputs=(bad_zero, _player_input(1, 0, 0)),
    )

    with pytest.raises(ContinuousRuntimeConfigurationError, match="omniscient"):
        await runtime.dispatch_opportunity(opportunity)
    assert adapters[0].requests == adapters[1].requests == []


@pytest.mark.asyncio
async def test_aclose_cancels_both_provider_calls_and_never_applies() -> None:
    clock = FakeClock()
    adapters = {0: GateAdapter(0), 1: GateAdapter(1)}
    runtime, bridge = _runtime(clock, adapters)
    await runtime.dispatch_opportunity(_opportunity(deadline_ms=8_000))
    await asyncio.gather(adapters[0].started.wait(), adapters[1].started.wait())

    await runtime.aclose()
    assert adapters[0].cancelled == adapters[1].cancelled == 1
    assert runtime.in_flight_by_slot == {0: 0, 1: 0}
    assert bridge.requests == []
