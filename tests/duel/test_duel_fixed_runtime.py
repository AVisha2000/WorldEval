from __future__ import annotations

# ruff: noqa: UP045 -- Keep tests importable on the project's Python 3.9 floor.
import asyncio
from dataclasses import dataclass, field, replace
from typing import Dict, Optional, Set, Tuple

import pytest
from genesis_arena.duel.canonical import canonical_json_bytes, strict_json_loads
from genesis_arena.duel.commitment import action_batch_commit_hash
from genesis_arena.duel.gateway_validation import BatchValidationContext
from genesis_arena.duel.models import ActionBatch
from genesis_arena.duel.provider_adapters import (
    EndpointOwnership,
    ParticipantProviderAdapter,
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
    ScriptedProviderAdapter,
    ScriptedProviderStep,
)
from genesis_arena.duel.runtime import (
    MAX_CANONICAL_INPUT_BYTES,
    DuplicateOpportunityError,
    FixedAuthoritativeBridge,
    FixedCommitRequest,
    FixedDecisionOpportunity,
    FixedOpportunityDisposition,
    FixedPlayerInput,
    FixedRevealRequest,
    FixedRuntimeConfigurationError,
    FixedSimultaneousRuntime,
    canonical_provider_input_envelope_bytes,
)
from genesis_arena.duel.timing import FailureOwner, ModelFailureCounter

MATCH_ID = "m_fixed_runtime"
OBSERVATION_SEQ = 7
BOUNDARY_TICK = 700


def _wire_batch(slot: int, *, client_batch_id: Optional[str] = None) -> bytes:
    return canonical_json_bytes(
        {
            "based_on_observation_hash": ("a" if slot == 0 else "b") * 64,
            "client_batch_id": client_batch_id or f"batch_{OBSERVATION_SEQ}_{slot}",
            "commands": [],
            "match_id": MATCH_ID,
            "message_type": "action_batch",
            "observation_seq": OBSERVATION_SEQ,
            "protocol_version": "worldeval-rts/1.0.0",
            "valid_until_tick": BOUNDARY_TICK + 1,
        }
    )


def _player_input(slot: int, *, marker: Optional[str] = None) -> FixedPlayerInput:
    observation_hash = ("a" if slot == 0 else "b") * 64
    match_init = {
        "match_id": MATCH_ID,
        "message_type": "match_init",
        "perspective": "self",
        "protocol_version": "worldeval-rts/1.0.0",
        "self_marker": marker or f"only-slot-{slot}",
    }
    observation = {
        "match_id": MATCH_ID,
        "message_type": "observation",
        "observation_hash": observation_hash,
        "observation_seq": OBSERVATION_SEQ,
        "private_marker": marker or f"only-slot-{slot}",
        "protocol_version": "worldeval-rts/1.0.0",
        "tick": BOUNDARY_TICK,
    }
    return FixedPlayerInput(
        player_slot=slot,
        system_prompt=f"control self for slot {slot}",
        match_init_json=canonical_json_bytes(match_init),
        observation_json=canonical_json_bytes(observation),
        action_schema_json=canonical_json_bytes({}),
        validation_context=BatchValidationContext(
            match_id=MATCH_ID,
            observation_seq=OBSERVATION_SEQ,
            observation_hash=observation_hash,
            application_tick=BOUNDARY_TICK + 1,
            controller_valid_until_tick=BOUNDARY_TICK + 1,
            squad_sizes={},
            transport_passenger_counts={},
        ),
    )


def _opportunity(
    *,
    deadline_ms: int = 250,
    opportunity_id: str = "fixed-window-7",
    reverse_inputs: bool = False,
) -> FixedDecisionOpportunity:
    inputs = (_player_input(0), _player_input(1))
    if reverse_inputs:
        inputs = tuple(reversed(inputs))  # type: ignore[assignment]
    return FixedDecisionOpportunity(
        opportunity_id=opportunity_id,
        match_id=MATCH_ID,
        observation_seq=OBSERVATION_SEQ,
        boundary_tick=BOUNDARY_TICK,
        response_deadline_ms=deadline_ms,
        player_inputs=inputs,
    )


def _salt_source(match_id: str, opportunity_id: str, slot: int) -> str:
    assert match_id == MATCH_ID
    assert opportunity_id.startswith("fixed-window")
    return ("10" if slot == 0 else "20") * 32


@dataclass
class RecordingBridge(FixedAuthoritativeBridge):
    required_finished_slots: Optional[Set[int]] = None
    events: list[str] = field(default_factory=list)
    commit_request: Optional[FixedCommitRequest] = None
    reveal_request: Optional[FixedRevealRequest] = None

    async def lock_batch_commits(self, request: FixedCommitRequest) -> None:
        if self.required_finished_slots is not None:
            assert self.required_finished_slots == {0, 1}
        assert tuple(value.player_slot for value in request.commits) == (0, 1)
        self.events.append("lock")
        self.commit_request = request

    async def reveal_batch_pair(self, request: FixedRevealRequest) -> None:
        assert self.events == ["lock"]
        assert self.commit_request is not None
        assert tuple(value.player_slot for value in request.reveals) == (0, 1)
        for commit, reveal in zip(self.commit_request.commits, request.reveals):
            assert commit.player_slot == reveal.player_slot
            assert (
                action_batch_commit_hash(reveal.batch, reveal.salt_hex) == commit.commit_hash
            )
        self.events.append("reveal")
        self.reveal_request = request


def _scripted_pair(
    *, delays: Tuple[float, float] = (0.0, 0.0)
) -> Dict[int, ScriptedProviderAdapter]:
    return {
        slot: ScriptedProviderAdapter(
            [
                ScriptedProviderStep(
                    ProviderCallResult.success(_wire_batch(slot)),
                    delay_seconds=delays[slot],
                )
            ]
        )
        for slot in (0, 1)
    }


@pytest.mark.asyncio
async def test_dispatch_is_concurrent_and_slot_output_ignores_completion_order() -> None:
    async def run(delays: Tuple[float, float]) -> tuple[object, RecordingBridge]:
        bridge = RecordingBridge()
        runtime = FixedSimultaneousRuntime(
            adapters=_scripted_pair(delays=delays),
            bridge=bridge,
            salt_source=_salt_source,
        )
        return await runtime.run_opportunity(_opportunity(reverse_inputs=True)), bridge

    slow_zero, bridge_a = await run((0.03, 0.001))
    slow_one, bridge_b = await run((0.001, 0.03))

    assert tuple(value.player_slot for value in slow_zero.player_results) == (0, 1)
    assert tuple(value.player_slot for value in slow_one.player_results) == (0, 1)
    assert slow_zero.commits == slow_one.commits
    assert [value.classification_code for value in slow_zero.player_results] == [
        "valid_envelope",
        "valid_envelope",
    ]
    assert bridge_a.events == bridge_b.events == ["lock", "reveal"]


@dataclass
class _DispatchBarrier:
    started: Set[int] = field(default_factory=set)
    both_started: asyncio.Event = field(default_factory=asyncio.Event)


class _BarrierAdapter(ParticipantProviderAdapter):
    endpoint_ownership = EndpointOwnership.PARTICIPANT_HOSTED

    def __init__(self, slot: int, barrier: _DispatchBarrier) -> None:
        self.slot = slot
        self.barrier = barrier

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        assert request.player_slot == self.slot
        self.barrier.started.add(self.slot)
        if self.barrier.started == {0, 1}:
            self.barrier.both_started.set()
        await self.barrier.both_started.wait()
        return ProviderCallResult.success(_wire_batch(self.slot))


@pytest.mark.asyncio
async def test_both_provider_coroutines_start_before_either_may_finish() -> None:
    barrier = _DispatchBarrier()
    bridge = RecordingBridge()
    runtime = FixedSimultaneousRuntime(
        adapters={0: _BarrierAdapter(0, barrier), 1: _BarrierAdapter(1, barrier)},
        bridge=bridge,
        salt_source=_salt_source,
    )
    result = await runtime.run_opportunity(_opportunity(deadline_ms=100))
    assert barrier.started == {0, 1}
    assert not any(value.used_fallback for value in result.player_results)


@pytest.mark.asyncio
async def test_shared_deadline_cancels_late_call_and_commits_canonical_no_op() -> None:
    adapters = _scripted_pair(delays=(0.0, 1.0))
    bridge = RecordingBridge()
    runtime = FixedSimultaneousRuntime(
        adapters=adapters,
        bridge=bridge,
        salt_source=_salt_source,
    )
    result = await runtime.run_opportunity(_opportunity(deadline_ms=20))

    zero, one = result.player_results
    assert not zero.used_fallback
    assert one.used_fallback
    assert one.classification_code == "provider_timeout"
    assert one.failure is not None
    assert one.failure.owner is FailureOwner.MODEL
    assert one.failure.consecutive_count_after == one.failure.cumulative_count_after == 1
    assert adapters[1].cancelled_requests == 1
    assert (
        adapters[0].requests[0].deadline_monotonic_ns
        == adapters[1].requests[0].deadline_monotonic_ns
    )
    assert bridge.reveal_request is not None
    fallback = bridge.reveal_request.reveals[1].batch
    assert isinstance(fallback, ActionBatch)
    assert fallback.commands == []
    assert fallback.valid_until_tick == BOUNDARY_TICK + 1
    assert fallback.based_on_observation_hash == "b" * 64


@pytest.mark.asyncio
async def test_bridge_sees_no_batch_before_pair_lock_and_activation_is_exact() -> None:
    finished: Set[int] = set()

    def finish(slot: int):
        def factory(request: ProviderRequest) -> ProviderCallResult:
            assert request.player_slot == slot
            finished.add(slot)
            return ProviderCallResult.success(_wire_batch(slot))

        return factory

    adapters = {
        0: ScriptedProviderAdapter([ScriptedProviderStep(finish(0), delay_seconds=0.001)]),
        1: ScriptedProviderAdapter([ScriptedProviderStep(finish(1), delay_seconds=0.025)]),
    }
    bridge = RecordingBridge(required_finished_slots=finished)
    runtime = FixedSimultaneousRuntime(
        adapters=adapters,
        bridge=bridge,
        salt_source=_salt_source,
    )
    result = await runtime.run_opportunity(_opportunity())

    assert bridge.events == ["lock", "reveal"]
    assert bridge.reveal_request is not None
    assert bridge.reveal_request.activation_tick == BOUNDARY_TICK + 1
    assert result.activation_tick == BOUNDARY_TICK + 1
    assert bridge.reveal_request.disposition is FixedOpportunityDisposition.CONTINUE


@pytest.mark.asyncio
async def test_opportunity_and_boundary_are_idempotent_even_under_new_id() -> None:
    adapters = _scripted_pair()
    bridge = RecordingBridge()
    runtime = FixedSimultaneousRuntime(
        adapters=adapters,
        bridge=bridge,
        salt_source=_salt_source,
    )
    opportunity = _opportunity()
    await runtime.run_opportunity(opportunity)

    with pytest.raises(DuplicateOpportunityError):
        await runtime.run_opportunity(opportunity)
    with pytest.raises(DuplicateOpportunityError):
        await runtime.run_opportunity(_opportunity(opportunity_id="fixed-window-renamed"))
    assert len(adapters[0].requests) == len(adapters[1].requests) == 1
    assert bridge.events == ["lock", "reveal"]


@pytest.mark.asyncio
async def test_each_adapter_receives_only_its_own_private_projection() -> None:
    inputs = (
        _player_input(0, marker="PRIVATE-ALPHA"),
        _player_input(1, marker="PRIVATE-BRAVO"),
    )
    adapters = _scripted_pair()
    bridge = RecordingBridge()
    runtime = FixedSimultaneousRuntime(
        adapters=adapters,
        bridge=bridge,
        salt_source=_salt_source,
    )
    opportunity = FixedDecisionOpportunity(
        opportunity_id="fixed-window-private",
        match_id=MATCH_ID,
        observation_seq=OBSERVATION_SEQ,
        boundary_tick=BOUNDARY_TICK,
        response_deadline_ms=100,
        player_inputs=inputs,
    )
    await runtime.run_opportunity(opportunity)

    request_zero = adapters[0].requests[0]
    request_one = adapters[1].requests[0]
    assert b"PRIVATE-ALPHA" in request_zero.observation_json
    assert b"PRIVATE-BRAVO" not in request_zero.observation_json
    assert b"PRIVATE-BRAVO" in request_one.observation_json
    assert b"PRIVATE-ALPHA" not in request_one.observation_json
    assert request_zero.player_slot == 0 and request_one.player_slot == 1
    assert strict_json_loads(request_zero.observation_json)["tick"] == BOUNDARY_TICK
    assert strict_json_loads(request_one.observation_json)["tick"] == BOUNDARY_TICK


@pytest.mark.asyncio
async def test_mismatched_or_omniscient_projection_fails_before_dispatch() -> None:
    adapters = _scripted_pair()
    bridge = RecordingBridge()
    runtime = FixedSimultaneousRuntime(
        adapters=adapters,
        bridge=bridge,
        salt_source=_salt_source,
    )
    slot_zero = _player_input(0)
    bad_observation = strict_json_loads(slot_zero.observation_json)
    bad_observation["tick"] = BOUNDARY_TICK - 1
    bad_observation["state_hash"] = "c" * 64
    slot_zero = replace(slot_zero, observation_json=canonical_json_bytes(bad_observation))
    opportunity = replace(_opportunity(), player_inputs=(slot_zero, _player_input(1)))

    with pytest.raises(FixedRuntimeConfigurationError):
        await runtime.run_opportunity(opportunity)
    assert not adapters[0].requests and not adapters[1].requests
    assert bridge.events == []


@pytest.mark.asyncio
async def test_canonical_provider_input_accepts_exact_cap_and_rejects_one_byte_over() -> None:
    slot_zero = _player_input(0)
    match_init = strict_json_loads(slot_zero.match_init_json)
    match_init["catalog_padding"] = ""
    slot_zero = replace(slot_zero, match_init_json=canonical_json_bytes(match_init))
    padding_bytes = MAX_CANONICAL_INPUT_BYTES - len(
        canonical_provider_input_envelope_bytes(slot_zero)
    )
    assert padding_bytes > 0
    match_init["catalog_padding"] = "x" * padding_bytes
    exact_input = replace(slot_zero, match_init_json=canonical_json_bytes(match_init))
    assert (
        len(canonical_provider_input_envelope_bytes(exact_input))
        == MAX_CANONICAL_INPUT_BYTES
    )

    exact_adapters = _scripted_pair()
    exact_bridge = RecordingBridge()
    exact_runtime = FixedSimultaneousRuntime(
        adapters=exact_adapters,
        bridge=exact_bridge,
        salt_source=_salt_source,
    )
    exact_opportunity = replace(
        _opportunity(), player_inputs=(exact_input, _player_input(1))
    )
    exact_result = await exact_runtime.run_opportunity(exact_opportunity)
    assert not exact_result.player_results[0].used_fallback
    assert exact_bridge.events == ["lock", "reveal"]

    match_init["catalog_padding"] += "x"
    oversized_input = replace(slot_zero, match_init_json=canonical_json_bytes(match_init))
    assert (
        len(canonical_provider_input_envelope_bytes(oversized_input))
        == MAX_CANONICAL_INPUT_BYTES + 1
    )
    oversized_adapters = _scripted_pair()
    oversized_bridge = RecordingBridge()
    oversized_runtime = FixedSimultaneousRuntime(
        adapters=oversized_adapters,
        bridge=oversized_bridge,
        salt_source=_salt_source,
    )
    oversized_opportunity = replace(
        _opportunity(), player_inputs=(oversized_input, _player_input(1))
    )
    with pytest.raises(FixedRuntimeConfigurationError, match="exceeds 262144 bytes"):
        await oversized_runtime.run_opportunity(oversized_opportunity)
    assert not oversized_adapters[0].requests and not oversized_adapters[1].requests
    assert oversized_bridge.events == []


@pytest.mark.asyncio
async def test_invalid_envelope_counts_once_and_never_exposes_raw_output() -> None:
    adapters = {
        0: ScriptedProviderAdapter(
            [ScriptedProviderStep(ProviderCallResult.success(b"not-json and secret text"))]
        ),
        1: ScriptedProviderAdapter(
            [ScriptedProviderStep(ProviderCallResult.success(_wire_batch(1)))]
        ),
    }
    bridge = RecordingBridge()
    runtime = FixedSimultaneousRuntime(
        adapters=adapters,
        bridge=bridge,
        salt_source=_salt_source,
    )
    result = await runtime.run_opportunity(_opportunity())
    failed = result.player_results[0]
    assert failed.used_fallback
    assert failed.classification_code == "invalid_json"
    assert failed.consecutive_failures == failed.cumulative_failures == 1
    assert "secret" not in repr(failed)


@pytest.mark.asyncio
async def test_both_thresholds_are_evaluated_together_as_double_forfeit_draw() -> None:
    counters = {
        0: ModelFailureCounter(consecutive=2, cumulative=2),
        1: ModelFailureCounter(consecutive=2, cumulative=2),
    }
    adapters = {
        slot: ScriptedProviderAdapter(
            [
                ScriptedProviderStep(
                    ProviderCallResult.failed(ProviderFailureKind.REFUSAL)
                )
            ]
        )
        for slot in (0, 1)
    }
    bridge = RecordingBridge()
    runtime = FixedSimultaneousRuntime(
        adapters=adapters,
        bridge=bridge,
        failure_counters=counters,
        salt_source=_salt_source,
    )
    result = await runtime.run_opportunity(_opportunity())

    assert result.disposition is FixedOpportunityDisposition.DRAW_DOUBLE_TECHNICAL_FORFEIT
    assert all(value.forfeit_threshold_reached for value in result.player_results)
    counter_values = [
        (value.consecutive_failures, value.cumulative_failures)
        for value in result.player_results
    ]
    assert counter_values == [
        (3, 3),
        (3, 3),
    ]
    assert bridge.reveal_request is not None
    assert bridge.reveal_request.disposition is result.disposition


@pytest.mark.asyncio
async def test_endpoint_owner_controls_provider_failure_without_false_model_strike() -> None:
    adapters = {
        0: ScriptedProviderAdapter(
            [
                ScriptedProviderStep(
                    ProviderCallResult.failed(ProviderFailureKind.CREDENTIAL_ERROR)
                )
            ],
            endpoint_ownership=EndpointOwnership.ORGANIZER_HOSTED,
        ),
        1: ScriptedProviderAdapter(
            [ScriptedProviderStep(ProviderCallResult.success(_wire_batch(1)))]
        ),
    }
    bridge = RecordingBridge()
    runtime = FixedSimultaneousRuntime(
        adapters=adapters,
        bridge=bridge,
        salt_source=_salt_source,
    )
    result = await runtime.run_opportunity(_opportunity())

    failed = result.player_results[0]
    assert failed.failure is not None
    assert failed.failure.owner is FailureOwner.ORGANIZER_INFRASTRUCTURE
    assert failed.consecutive_failures == failed.cumulative_failures == 0
    assert result.disposition is FixedOpportunityDisposition.VOID_INFRASTRUCTURE


@pytest.mark.asyncio
async def test_parent_cancellation_cancels_and_drains_both_provider_calls() -> None:
    adapters = _scripted_pair(delays=(5.0, 5.0))
    bridge = RecordingBridge()
    runtime = FixedSimultaneousRuntime(
        adapters=adapters,
        bridge=bridge,
        salt_source=_salt_source,
    )
    task = asyncio.create_task(runtime.run_opportunity(_opportunity(deadline_ms=1_000)))
    for _ in range(100):
        if adapters[0].requests and adapters[1].requests:
            break
        await asyncio.sleep(0)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task

    assert adapters[0].cancelled_requests == adapters[1].cancelled_requests == 1
    assert bridge.events == []
