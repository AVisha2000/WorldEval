from __future__ import annotations

# ruff: noqa: UP045 -- Keep tests importable on the project's advertised Python floor.
import asyncio
import hashlib
from dataclasses import replace
from typing import Tuple

import pytest
from genesis_arena.duel.canonical import canonical_json_bytes, strict_json_loads
from genesis_arena.duel.continuous_runtime import (
    ContinuousApplyGateRequest,
    ContinuousBatchApplication,
    ContinuousOpportunityDisposition,
    ContinuousTimingRecord,
)
from genesis_arena.duel.godot_bridge import (
    FROZEN_GODOT_ENGINE_VERSION,
    SESSION_BOUNDARY_HASH,
    AuthenticatedGodotCodec,
    GatewayGodotBridge,
    GodotBridgeInfrastructureError,
    GodotBridgeModelError,
    GodotBridgePhase,
    InMemoryGodotTransport,
)
from genesis_arena.duel.models import ActionBatch, MatchConfig
from genesis_arena.duel.runtime import (
    FixedCommitRequest,
    FixedOpportunityDisposition,
    FixedRevealRequest,
    SlotCommit,
    SlotReveal,
)
from genesis_arena.duel.timing import FailureOwner

MATCH_ID = "m_godot_bridge"
TOKEN = bytes(range(32))
CHECKPOINT_HASH = "c" * 64


def _config(mode: str = "fixed_simultaneous") -> MatchConfig:
    return MatchConfig(
        decision_mode=mode,
        faction_preset_id="vanguard-v1",
        seed=42,
        decision_period_ticks=50,
        response_deadline_ms=500,
        players=[
            {"slot": 0, "model": "model-a", "reasoning": "medium"},
            {"slot": 1, "model": "model-b", "reasoning": "medium"},
        ],
    )


def _observation(slot: int, sequence: int = 7, tick: int = 350) -> dict[str, object]:
    payload: dict[str, object] = {
        "match_id": MATCH_ID,
        "message_type": "observation",
        "observation_seq": sequence,
        "player_slot": slot,
        "protocol_version": "worldeval-rts/1.0.0",
        "self": {"gold": 500 + slot},
        "tick": tick,
    }
    observation_hash = hashlib.sha256(canonical_json_bytes(payload)).hexdigest()
    payload["observation_hash"] = observation_hash
    return {
        "observation": payload,
        "observation_hash": observation_hash,
        "observation_seq": sequence,
        "player_slot": slot,
        "tick": tick,
    }


def _batch(
    slot: int,
    *,
    sequence: int = 7,
    valid_until_tick: int = 351,
    working_memory: str | None = None,
) -> ActionBatch:
    return ActionBatch(
        match_id=MATCH_ID,
        observation_seq=sequence,
        based_on_observation_hash=("a" if slot == 0 else "b") * 64,
        client_batch_id=f"batch_{sequence}_{slot}",
        valid_until_tick=valid_until_tick,
        working_memory=working_memory,
        commands=[],
    )


def _action_receipts_body(
    *,
    checkpoint_hash: str = "d" * 64,
    application_seq: int = 0,
    include_private_key: bool = False,
) -> dict[str, object]:
    records: list[dict[str, object]] = []
    for slot in (0, 1):
        intent: dict[str, object] = {
            "intent_kind": "no_op",
            "source": {"command_id": f"command_{slot}"},
        }
        if include_private_key and slot == 0:
            intent["working_memory"] = "must-not-cross"
        records.append(
            {
                "batch_digest": ("a" if slot == 0 else "b") * 64,
                "batch_id": f"batch_{slot}",
                "compiled_intents": [intent],
                "player_slot": slot,
                "receipt": {
                    "apply_tick": 351,
                    "batch_id": f"batch_{slot}",
                    "batch_status": "applied",
                    "commands": [],
                    "observation_seq": 7,
                    "received_tick": 350,
                },
            }
        )
    return {
        "application_seq": application_seq,
        "application_tick": 351,
        "checkpoint_hash": checkpoint_hash,
        "checkpoint_tick": 350,
        "decision_mode": "fixed_simultaneous",
        "kind": "fixed_pair",
        "match_id": MATCH_ID,
        "records": records,
    }


def _tick_events_body(
    *, checkpoint_hash: str = "e" * 64, first_event_seq: int = 1, tick: int = 351
) -> dict[str, object]:
    event = {
        "audience": "omniscient",
        "event_seq": first_event_seq,
        "kind": "order_started",
        "payload": {"compiled_order_id": "order_1"},
        "tick": tick,
    }
    return {
        "checkpoint_hash": checkpoint_hash,
        "events": [event],
        "first_event_seq": first_event_seq,
        "last_event_seq": first_event_seq,
        "match_id": MATCH_ID,
        "tick_from": tick,
        "tick_through": tick,
    }


async def _authenticated_link(
    mode: str = "fixed_simultaneous",
) -> tuple[GatewayGodotBridge, InMemoryGodotTransport]:
    bridge = GatewayGodotBridge(match_id=MATCH_ID, token=TOKEN, response_timeout_s=1)
    link = InMemoryGodotTransport(bridge, token=TOKEN)
    auth = await link.hello()
    assert auth.message_type == "auth"
    assert auth.body == {"accepted": True, "connection_id": "godot-headless-1"}

    configure_task = asyncio.create_task(bridge.configure(_config(mode)))
    frame = await link.receive_at_godot()
    assert frame.message_type == "match_config"
    await link.send_from_godot(
        "config_accepted",
        boundary_hash=frame.boundary_hash,
        body={"accepted": True, "config_hash": frame.body["config_hash"]},
    )
    await configure_task
    assert bridge.phase is GodotBridgePhase.RUNNING
    return bridge, link


async def _freeze_boundary(bridge: GatewayGodotBridge, link: InMemoryGodotTransport) -> None:
    await link.send_from_godot(
        "observation_pair",
        boundary_hash=CHECKPOINT_HASH,
        body={
            "checkpoint_hash": CHECKPOINT_HASH,
            "observation_seq": 7,
            # Deliberately reversed to verify canonical slot projection.
            "observations": [_observation(1), _observation(0)],
            "tick": 350,
        },
    )
    assert bridge.checkpoint_hash == CHECKPOINT_HASH


async def _freeze_initial_boundary(
    bridge: GatewayGodotBridge, link: InMemoryGodotTransport
) -> None:
    await link.send_from_godot(
        "observation_pair",
        boundary_hash=CHECKPOINT_HASH,
        body={
            "checkpoint_hash": CHECKPOINT_HASH,
            "observation_seq": 0,
            "observations": [
                _observation(0, sequence=0, tick=0),
                _observation(1, sequence=0, tick=0),
            ],
            "tick": 0,
        },
    )


async def _send_terminal_checkpoint(
    link: InMemoryGodotTransport, *, tick: int, checkpoint_hash: str = "9" * 64
) -> None:
    await link.send_from_godot(
        "checkpoint",
        boundary_hash=checkpoint_hash,
        body={
            "checkpoint_hash": checkpoint_hash,
            "reason": "terminal",
            "tick": tick,
        },
    )


async def _start_continuous_clock(bridge: GatewayGodotBridge, link: InMemoryGodotTransport) -> None:
    task = asyncio.create_task(bridge.start_continuous_clock())
    frame = await link.receive_at_godot()
    assert frame.message_type == "continuous_start"
    await link.send_from_godot(
        "continuous_start_accepted",
        boundary_hash=frame.boundary_hash,
        body={"accepted": True, **frame.body},
    )
    await task


async def _lock_fixed_window(bridge: GatewayGodotBridge, link: InMemoryGodotTransport) -> None:
    request = FixedCommitRequest(
        match_id=MATCH_ID,
        opportunity_id="fixed-7",
        observation_seq=7,
        boundary_tick=350,
        commits=(SlotCommit(0, "a" * 64), SlotCommit(1, "b" * 64)),
    )
    task = asyncio.create_task(bridge.lock_batch_commits(request))
    frame = await link.receive_at_godot()
    assert frame.message_type == "batch_commit_hashes"
    await link.send_from_godot(
        "batch_commits_locked",
        boundary_hash=CHECKPOINT_HASH,
        body={
            "boundary_tick": 350,
            "locked": True,
            "observation_seq": 7,
            "opportunity_id": "fixed-7",
        },
    )
    await task


def test_authenticated_codec_is_canonical_directional_and_replay_protected() -> None:
    gateway = AuthenticatedGodotCodec(match_id=MATCH_ID, token=TOKEN, local_role="gateway")
    godot = AuthenticatedGodotCodec(match_id=MATCH_ID, token=TOKEN, local_role="godot")
    payload = godot.encode(
        "hello",
        boundary_hash=SESSION_BOUNDARY_HASH,
        body={
            "connection_id": "godot-headless-1",
            "engine_version": FROZEN_GODOT_ENGINE_VERSION,
        },
    )
    assert canonical_json_bytes(strict_json_loads(payload)) == payload
    assert gateway.decode(payload).sequence == 0
    assert TOKEN.hex() not in repr(gateway)

    with pytest.raises(GodotBridgeInfrastructureError) as replay:
        gateway.decode(payload)
    assert replay.value.code == "sequence_violation"
    assert replay.value.classification.owner is FailureOwner.ORGANIZER_INFRASTRUCTURE
    with pytest.raises(GodotBridgeInfrastructureError) as closed:
        gateway.decode(payload)
    assert closed.value.code == "codec_failed_closed"


def test_tampered_or_noncanonical_authenticated_frame_fails_closed() -> None:
    godot = AuthenticatedGodotCodec(match_id=MATCH_ID, token=TOKEN, local_role="godot")
    payload = godot.encode(
        "hello",
        boundary_hash=SESSION_BOUNDARY_HASH,
        body={
            "connection_id": "godot-headless-1",
            "engine_version": FROZEN_GODOT_ENGINE_VERSION,
        },
    )
    value = strict_json_loads(payload)
    value["body"]["connection_id"] = "tampered"

    receiver = AuthenticatedGodotCodec(match_id=MATCH_ID, token=TOKEN, local_role="gateway")
    with pytest.raises(GodotBridgeInfrastructureError) as tampered:
        receiver.decode(canonical_json_bytes(value))
    assert tampered.value.code == "authentication_failed"

    receiver = AuthenticatedGodotCodec(match_id=MATCH_ID, token=TOKEN, local_role="gateway")
    with pytest.raises(GodotBridgeInfrastructureError) as noncanonical:
        receiver.decode(payload + b"\n")
    assert noncanonical.value.code == "inbound_frame_invalid"


def test_continuous_disposition_cross_runtime_vectors_are_frozen() -> None:
    match_id = "m_gateway-codec"
    boundary_hash = "ab" * 32
    core = {
        "code": "dispatch_grid_drift",
        "disposition": "void_infrastructure",
        "match_id": match_id,
        "reason": "gateway_infrastructure_failure",
    }
    body = {
        **core,
        "request_id": hashlib.sha256(canonical_json_bytes(core)).hexdigest(),
    }
    gateway = AuthenticatedGodotCodec(match_id=match_id, token=TOKEN, local_role="gateway")
    gateway.encode(
        "auth",
        boundary_hash=SESSION_BOUNDARY_HASH,
        body={"accepted": True, "connection_id": "conn-vector"},
    )
    disposition = gateway.encode("gateway_disposition", boundary_hash=boundary_hash, body=body)
    assert hashlib.sha256(disposition).hexdigest() == (
        "8e0eb3a464689696746b97dfdabca14666a3e80a2493a0946d8633566bd4c67d"
    )

    godot = AuthenticatedGodotCodec(match_id=match_id, token=TOKEN, local_role="godot")
    godot.encode(
        "hello",
        boundary_hash=SESSION_BOUNDARY_HASH,
        body={
            "connection_id": "conn-vector",
            "engine_version": FROZEN_GODOT_ENGINE_VERSION,
            "headless": True,
        },
    )
    godot.encode(
        "config_accepted",
        boundary_hash=boundary_hash,
        body={"accepted": True, "config_hash": boundary_hash},
    )
    acknowledgement = godot.encode(
        "gateway_disposition_accepted",
        boundary_hash=boundary_hash,
        body={"accepted": True, **body},
    )
    assert hashlib.sha256(acknowledgement).hexdigest() == (
        "805490fbbc303bdf4052f337134fc9348fa92783d53fbfb21d2e424f53b21cab"
    )

    start_core = {"match_id": match_id, "observation_seq": 0, "tick": 0}
    start_body = {
        **start_core,
        "start_id": hashlib.sha256(canonical_json_bytes(start_core)).hexdigest(),
    }
    start = gateway.encode("continuous_start", boundary_hash=boundary_hash, body=start_body)
    assert hashlib.sha256(start).hexdigest() == (
        "ac2560e73a83727073c41be3950f1502661ba1043a08ac6af827b325979e72ad"
    )
    start_acknowledgement = godot.encode(
        "continuous_start_accepted",
        boundary_hash=boundary_hash,
        body={"accepted": True, **start_body},
    )
    assert hashlib.sha256(start_acknowledgement).hexdigest() == (
        "8a5f3f39047e299c3073eabec9bf363624aa5955e595919de08fbf65d656ce6a"
    )


@pytest.mark.asyncio
async def test_hello_auth_and_config_are_strict_and_non_reconnectable() -> None:
    bridge, link = await _authenticated_link()
    assert bridge.connection_id == "godot-headless-1"
    assert bridge.decision_mode == "fixed_simultaneous"

    with pytest.raises(GodotBridgeInfrastructureError) as duplicate:
        await link.send_from_godot(
            "hello",
            boundary_hash=SESSION_BOUNDARY_HASH,
            body={
                "connection_id": "second-connection",
                "engine_version": FROZEN_GODOT_ENGINE_VERSION,
            },
        )
    assert duplicate.value.code == "unexpected_direction"
    assert bridge.phase is GodotBridgePhase.FAILED


@pytest.mark.asyncio
async def test_provider_observation_projection_never_exposes_world_checkpoint() -> None:
    bridge, link = await _authenticated_link()
    await _freeze_boundary(bridge, link)
    pair = await bridge.next_observation_pair()
    assert tuple(value.player_slot for value in pair.observations) == (0, 1)
    assert all(b"checkpoint_hash" not in value.canonical_bytes for value in pair.observations)
    assert all(b"state_hash" not in value.canonical_bytes for value in pair.observations)
    assert bridge.checkpoint_hash not in {value.observation_hash for value in pair.observations}


@pytest.mark.asyncio
async def test_nested_world_hash_in_provider_observation_poison_session() -> None:
    bridge, link = await _authenticated_link()
    leaked = _observation(0)
    leaked_payload = leaked["observation"]
    assert isinstance(leaked_payload, dict)
    leaked_payload["nested"] = {"state_hash": "d" * 64}
    hash_payload = dict(leaked_payload)
    hash_payload.pop("observation_hash")
    leaked_hash = hashlib.sha256(canonical_json_bytes(hash_payload)).hexdigest()
    leaked_payload["observation_hash"] = leaked_hash
    leaked["observation_hash"] = leaked_hash

    with pytest.raises(GodotBridgeInfrastructureError) as error:
        await link.send_from_godot(
            "observation_pair",
            boundary_hash=CHECKPOINT_HASH,
            body={
                "checkpoint_hash": CHECKPOINT_HASH,
                "observation_seq": 7,
                "observations": [leaked, _observation(1)],
                "tick": 350,
            },
        )
    assert error.value.code == "omniscient_hash_leak"
    assert bridge.phase is GodotBridgePhase.FAILED


@pytest.mark.asyncio
async def test_blocking_runtime_waiters_fail_closed_on_disconnect() -> None:
    bridge, _ = await _authenticated_link()
    waiters = [
        asyncio.create_task(bridge.next_match_init()),
        asyncio.create_task(bridge.next_observation_pair()),
        asyncio.create_task(bridge.next_observation()),
        asyncio.create_task(bridge.next_action_receipts()),
        asyncio.create_task(bridge.next_acknowledged_action_batches()),
        asyncio.create_task(bridge.next_tick_events()),
        asyncio.create_task(bridge.next_checkpoint()),
    ]
    await asyncio.sleep(0)
    bridge.disconnect()
    results = await asyncio.gather(*waiters, return_exceptions=True)
    assert all(isinstance(value, GodotBridgeInfrastructureError) for value in results)
    assert {
        value.code for value in results if isinstance(value, GodotBridgeInfrastructureError)
    } == {"connection_lost"}


@pytest.mark.asyncio
async def test_terminal_waiter_fails_closed_on_disconnect() -> None:
    bridge, _ = await _authenticated_link()
    waiter = asyncio.create_task(bridge.wait_terminal())
    await asyncio.sleep(0)
    bridge.disconnect()
    with pytest.raises(GodotBridgeInfrastructureError) as error:
        await waiter
    assert error.value.code == "connection_lost"


@pytest.mark.asyncio
async def test_authenticated_replay_evidence_streams_are_separate_and_checkpoint_bound() -> None:
    bridge, link = await _authenticated_link()
    await _freeze_boundary(bridge, link)
    receipt_hash = "d" * 64
    receipt_body = _action_receipts_body(checkpoint_hash=receipt_hash)
    await link.send_from_godot("action_receipts", boundary_hash=receipt_hash, body=receipt_body)
    assert await bridge.next_action_receipts() == receipt_body
    assert bridge.checkpoint_hash == receipt_hash

    event_hash = "e" * 64
    event_body = _tick_events_body(checkpoint_hash=event_hash)
    await link.send_from_godot("tick_events", boundary_hash=event_hash, body=event_body)
    assert await bridge.next_tick_events() == event_body
    assert bridge.checkpoint_hash == event_hash


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("message_type", "boundary_hash", "body_factory", "expected_code"),
    [
        (
            "action_receipts",
            "d" * 64,
            lambda: _action_receipts_body(application_seq=1),
            "action_receipts_sequence_invalid",
        ),
        (
            "action_receipts",
            "d" * 64,
            lambda: _action_receipts_body(include_private_key=True),
            "action_receipts_private_data",
        ),
        (
            "tick_events",
            "e" * 64,
            lambda: _tick_events_body(first_event_seq=2),
            "tick_events_sequence_invalid",
        ),
    ],
)
async def test_replay_evidence_rejects_gaps_and_private_model_material(
    message_type: str,
    boundary_hash: str,
    body_factory,
    expected_code: str,
) -> None:
    bridge, link = await _authenticated_link()
    await _freeze_boundary(bridge, link)
    with pytest.raises(GodotBridgeInfrastructureError) as error:
        await link.send_from_godot(
            message_type,  # type: ignore[arg-type]
            boundary_hash=boundary_hash,
            body=body_factory(),
        )
    assert error.value.code == expected_code
    assert bridge.phase is GodotBridgePhase.FAILED


@pytest.mark.asyncio
async def test_terminal_drains_all_queued_evidence_after_final_checkpoint() -> None:
    bridge, link = await _authenticated_link()
    await _freeze_boundary(bridge, link)
    receipt_body = _action_receipts_body(checkpoint_hash="d" * 64)
    first_events = _tick_events_body(checkpoint_hash="e" * 64, tick=351)
    second_events = _tick_events_body(checkpoint_hash="a" * 64, first_event_seq=2, tick=352)
    await link.send_from_godot("action_receipts", boundary_hash="d" * 64, body=receipt_body)
    await link.send_from_godot("tick_events", boundary_hash="e" * 64, body=first_events)
    await link.send_from_godot("tick_events", boundary_hash="a" * 64, body=second_events)
    await _send_terminal_checkpoint(link, tick=353)
    await link.send_from_godot(
        "terminal",
        boundary_hash="f" * 64,
        body={
            "disposition": "draw",
            "reason": "time_limit",
            "result_hash": "f" * 64,
            "terminal_tick": 353,
            "winner_slot": None,
        },
    )

    assert await bridge.next_action_receipts() == receipt_body
    assert await bridge.next_tick_events() == first_events
    assert await bridge.next_tick_events() == second_events
    checkpoint = await bridge.next_checkpoint()
    assert checkpoint["tick"] == 353
    with pytest.raises(GodotBridgeInfrastructureError) as drained:
        await bridge.next_tick_events()
    assert drained.value.code == "match_terminal"


@pytest.mark.asyncio
async def test_terminal_without_immediate_final_checkpoint_fails_closed() -> None:
    bridge, link = await _authenticated_link()
    with pytest.raises(GodotBridgeInfrastructureError) as error:
        await link.send_from_godot(
            "terminal",
            boundary_hash="f" * 64,
            body={
                "disposition": "draw",
                "reason": "time_limit",
                "result_hash": "f" * 64,
                "terminal_tick": 1,
                "winner_slot": None,
            },
        )
    assert error.value.code == "terminal_checkpoint_missing"


async def _capture_fixed_commit(
    commits: Tuple[SlotCommit, SlotCommit],
) -> tuple[object, GatewayGodotBridge, InMemoryGodotTransport, asyncio.Task[None]]:
    bridge, link = await _authenticated_link()
    await _freeze_boundary(bridge, link)
    request = FixedCommitRequest(
        match_id=MATCH_ID,
        opportunity_id="fixed-7",
        observation_seq=7,
        boundary_tick=350,
        commits=commits,
    )
    task = asyncio.create_task(bridge.lock_batch_commits(request))
    frame = await link.receive_at_godot()
    return frame, bridge, link, task


@pytest.mark.asyncio
async def test_fixed_commit_serialization_is_arrival_order_invariant() -> None:
    commit_0 = SlotCommit(0, "a" * 64)
    commit_1 = SlotCommit(1, "b" * 64)
    frame_a, bridge_a, link_a, task_a = await _capture_fixed_commit((commit_0, commit_1))
    frame_b, bridge_b, link_b, task_b = await _capture_fixed_commit((commit_1, commit_0))

    assert frame_a.body == frame_b.body
    assert [item["player_slot"] for item in frame_a.body["commits"]] == [0, 1]
    assert canonical_json_bytes(frame_a) == canonical_json_bytes(frame_b)

    for _frame, link in ((frame_a, link_a), (frame_b, link_b)):
        await link.send_from_godot(
            "batch_commits_locked",
            boundary_hash=CHECKPOINT_HASH,
            body={
                "boundary_tick": 350,
                "locked": True,
                "observation_seq": 7,
                "opportunity_id": "fixed-7",
            },
        )
    await asyncio.gather(task_a, task_b)
    assert bridge_a.phase is bridge_b.phase is GodotBridgePhase.RUNNING


@pytest.mark.asyncio
async def test_fixed_reveal_crosses_as_one_atomic_pair() -> None:
    bridge, link = await _authenticated_link()
    await _freeze_boundary(bridge, link)
    await _lock_fixed_window(bridge, link)
    request = FixedRevealRequest(
        match_id=MATCH_ID,
        opportunity_id="fixed-7",
        observation_seq=7,
        boundary_tick=350,
        activation_tick=351,
        disposition=FixedOpportunityDisposition.CONTINUE,
        reveals=(
            SlotReveal(
                0,
                _batch(0, working_memory="fixed protected memory"),
                "10" * 32,
            ),
            SlotReveal(1, _batch(1), "20" * 32),
        ),
    )
    task = asyncio.create_task(bridge.reveal_batch_pair(request))
    reveal = await link.receive_at_godot()
    assert reveal.message_type == "batch_reveal"
    assert [value["player_slot"] for value in reveal.body["reveals"]] == [0, 1]
    assert reveal.body["activation_tick"] == 351
    evidence_task = asyncio.create_task(bridge.next_acknowledged_action_batches())
    await asyncio.sleep(0)
    assert not evidence_task.done()

    await link.send_from_godot(
        "action_pair",
        boundary_hash=CHECKPOINT_HASH,
        body={
            "accepted": True,
            "actions": [{"player_slot": 0}, {"player_slot": 1}],
            "activation_tick": 351,
            "mode": "fixed_simultaneous",
            "observation_seq": 7,
            "opportunity_id": "fixed-7",
        },
    )
    await task
    evidence = await evidence_task
    assert tuple(value.player_slot for value in evidence) == (0, 1)
    assert all(value.application_seq == 0 for value in evidence)
    assert all(value.application_tick == 351 for value in evidence)
    assert all(value.observation_tick == 350 for value in evidence)
    assert strict_json_loads(evidence[0].canonical_batch_bytes)["working_memory"] == (
        "fixed protected memory"
    )
    assert "fixed protected memory" not in repr(evidence[0])
    assert evidence[0].batch_digest == hashlib.sha256(evidence[0].canonical_batch_bytes).hexdigest()
    assert bridge.phase is GodotBridgePhase.RUNNING


def _timing(application_tick: int) -> ContinuousTimingRecord:
    return ContinuousTimingRecord(
        dispatch_monotonic_ns=1,
        deadline_monotonic_ns=10,
        first_token_monotonic_ns=2,
        completion_monotonic_ns=3,
        parse_started_monotonic_ns=4,
        parse_completed_monotonic_ns=5,
        ready_monotonic_ns=5,
        application_tick=application_tick,
        application_gate_monotonic_ns=6,
    )


@pytest.mark.asyncio
async def test_continuous_gate_uses_one_canonical_action_frame() -> None:
    bridge, link = await _authenticated_link("continuous_realtime")
    await _freeze_initial_boundary(bridge, link)
    await _start_continuous_clock(bridge, link)
    await _freeze_boundary(bridge, link)
    request = ContinuousApplyGateRequest(
        match_id=MATCH_ID,
        application_tick=351,
        applications=(
            ContinuousBatchApplication(0, "continuous-7-0", 7, 350, _batch(0), _timing(351)),
            ContinuousBatchApplication(
                1,
                "continuous-7-1",
                7,
                350,
                _batch(1, working_memory="continuous protected memory"),
                _timing(351),
            ),
        ),
    )
    task = asyncio.create_task(bridge.apply_continuous_gate(request))
    action = await link.receive_at_godot()
    assert action.message_type == "action"
    assert action.body["mode"] == "continuous_realtime"
    assert [value["player_slot"] for value in action.body["actions"]] == [0, 1]
    evidence_task = asyncio.create_task(bridge.next_acknowledged_action_batches())
    await asyncio.sleep(0)
    assert not evidence_task.done()

    await link.send_from_godot(
        "action_pair",
        boundary_hash=CHECKPOINT_HASH,
        body={
            "accepted": True,
            "actions": [{"player_slot": 0}, {"player_slot": 1}],
            "application_tick": 351,
            "mode": "continuous_realtime",
        },
    )
    await task
    evidence = await evidence_task
    assert tuple(value.player_slot for value in evidence) == (0, 1)
    assert all(value.decision_mode == "continuous_realtime" for value in evidence)
    assert strict_json_loads(evidence[1].canonical_batch_bytes)["working_memory"] == (
        "continuous protected memory"
    )


@pytest.mark.asyncio
async def test_continuous_clock_start_is_checkpoint_bound_exact_and_single_use() -> None:
    bridge, link = await _authenticated_link("continuous_realtime")
    await _freeze_initial_boundary(bridge, link)
    task = asyncio.create_task(bridge.start_continuous_clock())
    request = await link.receive_at_godot()
    assert request.message_type == "continuous_start"
    assert request.boundary_hash == CHECKPOINT_HASH
    assert set(request.body) == {"match_id", "observation_seq", "start_id", "tick"}
    assert request.body["match_id"] == MATCH_ID
    assert request.body["observation_seq"] == request.body["tick"] == 0
    identity = dict(request.body)
    start_id = identity.pop("start_id")
    assert start_id == hashlib.sha256(canonical_json_bytes(identity)).hexdigest()
    await link.send_from_godot(
        "continuous_start_accepted",
        boundary_hash=CHECKPOINT_HASH,
        body={"accepted": True, **request.body},
    )
    await task
    assert bridge.continuous_clock_started
    outbound_sequence = bridge._codec.outbound_sequence
    with pytest.raises(GodotBridgeInfrastructureError) as duplicate:
        await bridge.start_continuous_clock()
    assert duplicate.value.code == "continuous_clock_already_started"
    assert bridge._codec.outbound_sequence == outbound_sequence


@pytest.mark.asyncio
async def test_continuous_clock_start_rejects_wrong_mode_phase_and_boundary() -> None:
    fixed, _ = await _authenticated_link("fixed_simultaneous")
    with pytest.raises(GodotBridgeInfrastructureError) as wrong_mode:
        await fixed.start_continuous_clock()
    assert wrong_mode.value.code == "decision_mode_mismatch"

    continuous, _ = await _authenticated_link("continuous_realtime")
    with pytest.raises(GodotBridgeInfrastructureError) as missing_boundary:
        await continuous.start_continuous_clock()
    assert missing_boundary.value.code == "continuous_start_boundary_invalid"

    continuous, link = await _authenticated_link("continuous_realtime")
    await _freeze_initial_boundary(continuous, link)
    await _send_terminal_checkpoint(link, tick=0)
    await link.send_from_godot(
        "terminal",
        boundary_hash="f" * 64,
        body={
            "disposition": "draw",
            "reason": "time_limit",
            "result_hash": "f" * 64,
            "terminal_tick": 0,
            "winner_slot": None,
        },
    )
    with pytest.raises(GodotBridgeInfrastructureError) as wrong_phase:
        await continuous.start_continuous_clock()
    assert wrong_phase.value.code == "bridge_phase_invalid"


@pytest.mark.asyncio
async def test_continuous_clock_start_stale_or_duplicate_ack_fails_closed() -> None:
    bridge, link = await _authenticated_link("continuous_realtime")
    await _freeze_initial_boundary(bridge, link)
    task = asyncio.create_task(bridge.start_continuous_clock())
    request = await link.receive_at_godot()
    with pytest.raises(GodotBridgeInfrastructureError) as stale:
        await link.send_from_godot(
            "continuous_start_accepted",
            boundary_hash="e" * 64,
            body={"accepted": True, **request.body},
        )
    assert stale.value.code == "response_hash_mismatch"
    with pytest.raises(GodotBridgeInfrastructureError):
        await task
    assert bridge.phase is GodotBridgePhase.FAILED

    bridge, link = await _authenticated_link("continuous_realtime")
    await _freeze_initial_boundary(bridge, link)
    task = asyncio.create_task(bridge.start_continuous_clock())
    request = await link.receive_at_godot()
    accepted = {"accepted": True, **request.body}
    await link.send_from_godot(
        "continuous_start_accepted",
        boundary_hash=CHECKPOINT_HASH,
        body=accepted,
    )
    await task
    with pytest.raises(GodotBridgeInfrastructureError) as duplicate:
        await link.send_from_godot(
            "continuous_start_accepted",
            boundary_hash=CHECKPOINT_HASH,
            body=accepted,
        )
    assert duplicate.value.code == "unexpected_response"
    assert bridge.phase is GodotBridgePhase.FAILED


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("requested", "code", "terminal_disposition", "winner", "reason", "owner"),
    [
        (
            ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_0,
            "model_failure_threshold",
            "technical_forfeit",
            1,
            "model_failure",
            "model",
        ),
        (
            ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_1,
            "model_failure_threshold",
            "technical_forfeit",
            0,
            "model_failure",
            "model",
        ),
        (
            ContinuousOpportunityDisposition.DRAW_DOUBLE_TECHNICAL_FORFEIT,
            "model_failure_threshold",
            "draw",
            None,
            "double_technical_forfeit",
            None,
        ),
        (
            ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE,
            "dispatch_grid_drift",
            "infrastructure_void",
            None,
            "gateway_infrastructure_failure",
            "organizer_infrastructure",
        ),
    ],
)
async def test_continuous_disposition_is_authenticated_acknowledged_and_terminal(
    requested: ContinuousOpportunityDisposition,
    code: str,
    terminal_disposition: str,
    winner: int | None,
    reason: str,
    owner: str | None,
) -> None:
    bridge, link = await _authenticated_link("continuous_realtime")
    await _freeze_boundary(bridge, link)
    task = asyncio.create_task(bridge.declare_continuous_disposition(requested, code=code))
    request = await link.receive_at_godot()
    assert request.message_type == "gateway_disposition"
    assert request.boundary_hash == CHECKPOINT_HASH
    assert set(request.body) == {
        "code",
        "disposition",
        "match_id",
        "reason",
        "request_id",
    }
    assert request.body["code"] == code
    assert request.body["disposition"] == requested.value
    assert request.body["reason"] == reason
    identity = dict(request.body)
    request_id = identity.pop("request_id")
    assert request_id == hashlib.sha256(canonical_json_bytes(identity)).hexdigest()
    assert (
        "model" not in canonical_json_bytes(request.body).decode()
        or code == "model_failure_threshold"
    )

    await link.send_from_godot(
        "gateway_disposition_accepted",
        boundary_hash=CHECKPOINT_HASH,
        body={"accepted": True, **request.body},
    )
    await task
    outbound_sequence = bridge._codec.outbound_sequence
    await bridge.declare_continuous_disposition(requested, code=code)
    assert bridge._codec.outbound_sequence == outbound_sequence

    terminal_body: dict[str, object] = {
        "disposition": terminal_disposition,
        "reason": reason,
        "result_hash": "f" * 64,
        "terminal_tick": 350,
        "winner_slot": winner,
    }
    if owner is not None:
        terminal_body["failure"] = {
            "code": code,
            "hard_model_failure": owner == "model",
            "owner": owner,
        }
    await _send_terminal_checkpoint(link, tick=350)
    await link.send_from_godot("terminal", boundary_hash="f" * 64, body=terminal_body)
    report = await bridge.wait_terminal()
    assert report.disposition == terminal_disposition
    assert report.winner_slot == winner
    assert report.body["reason"] == reason


@pytest.mark.asyncio
async def test_continuous_disposition_rejects_wrong_mode_phase_and_public_code() -> None:
    fixed, _ = await _authenticated_link("fixed_simultaneous")
    with pytest.raises(GodotBridgeInfrastructureError) as wrong_mode:
        await fixed.declare_continuous_disposition(
            ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_0,
            code="model_failure_threshold",
        )
    assert wrong_mode.value.code == "decision_mode_mismatch"

    continuous, link = await _authenticated_link("continuous_realtime")
    for disposition, code, expected in [
        (
            ContinuousOpportunityDisposition.CONTINUE,
            "model_failure_threshold",
            "continuous_disposition_invalid",
        ),
        (
            ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_0,
            "raw-provider-error",
            "continuous_disposition_code_invalid",
        ),
        (
            ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE,
            "contains a secret",
            "continuous_disposition_code_invalid",
        ),
    ]:
        with pytest.raises(GodotBridgeInfrastructureError) as invalid:
            await continuous.declare_continuous_disposition(disposition, code=code)
        assert invalid.value.code == expected

    await _send_terminal_checkpoint(link, tick=18_000)
    await link.send_from_godot(
        "terminal",
        boundary_hash="f" * 64,
        body={
            "disposition": "draw",
            "reason": "time_limit",
            "result_hash": "f" * 64,
            "terminal_tick": 18_000,
            "winner_slot": None,
        },
    )
    with pytest.raises(GodotBridgeInfrastructureError) as wrong_phase:
        await continuous.declare_continuous_disposition(
            ContinuousOpportunityDisposition.VOID_INFRASTRUCTURE,
            code="host_clock_failure",
        )
    assert wrong_phase.value.code == "bridge_phase_invalid"


@pytest.mark.asyncio
async def test_continuous_disposition_conflict_and_bad_ack_fail_closed() -> None:
    bridge, link = await _authenticated_link("continuous_realtime")
    await _freeze_boundary(bridge, link)
    task = asyncio.create_task(
        bridge.declare_continuous_disposition(
            ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_0,
            code="model_failure_threshold",
        )
    )
    request = await link.receive_at_godot()
    with pytest.raises(GodotBridgeInfrastructureError) as stale:
        await link.send_from_godot(
            "gateway_disposition_accepted",
            boundary_hash="e" * 64,
            body={"accepted": True, **request.body},
        )
    assert stale.value.code == "response_hash_mismatch"
    with pytest.raises(GodotBridgeInfrastructureError):
        await task
    assert bridge.phase is GodotBridgePhase.FAILED

    bridge, link = await _authenticated_link("continuous_realtime")
    await _freeze_boundary(bridge, link)
    task = asyncio.create_task(
        bridge.declare_continuous_disposition(
            ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_0,
            code="model_failure_threshold",
        )
    )
    request = await link.receive_at_godot()
    await link.send_from_godot(
        "gateway_disposition_accepted",
        boundary_hash=CHECKPOINT_HASH,
        body={"accepted": True, **request.body},
    )
    await task
    with pytest.raises(GodotBridgeInfrastructureError) as conflict:
        await bridge.declare_continuous_disposition(
            ContinuousOpportunityDisposition.TECHNICAL_FORFEIT_SLOT_1,
            code="model_failure_threshold",
        )
    assert conflict.value.code == "continuous_disposition_conflict"
    assert bridge.phase is GodotBridgePhase.FAILED


@pytest.mark.asyncio
async def test_wrong_mode_is_an_infrastructure_failure_not_a_model_failure() -> None:
    bridge, link = await _authenticated_link("continuous_realtime")
    await _freeze_boundary(bridge, link)
    request = FixedCommitRequest(
        match_id=MATCH_ID,
        opportunity_id="fixed-7",
        observation_seq=7,
        boundary_tick=350,
        commits=(SlotCommit(0, "a" * 64), SlotCommit(1, "b" * 64)),
    )
    with pytest.raises(GodotBridgeInfrastructureError) as error:
        await bridge.lock_batch_commits(request)
    assert error.value.code == "decision_mode_mismatch"
    assert error.value.classification.owner is FailureOwner.ORGANIZER_INFRASTRUCTURE


@pytest.mark.asyncio
async def test_terminal_failure_owner_and_artifact_completion_are_explicit() -> None:
    bridge, link = await _authenticated_link()
    await _freeze_boundary(bridge, link)
    result_hash = "d" * 64
    await _send_terminal_checkpoint(link, tick=700)
    await link.send_from_godot(
        "terminal",
        boundary_hash=result_hash,
        body={
            "disposition": "technical_forfeit",
            "failure": {
                "code": "three_consecutive_invalid_batches",
                "hard_model_failure": True,
                "owner": "model",
            },
            "result_hash": result_hash,
            "terminal_tick": 700,
            "winner_slot": 1,
        },
    )
    report = await bridge.wait_terminal()
    assert report.failure is not None
    assert report.failure.owner is FailureOwner.MODEL
    assert bridge.remote_failures == (report.failure,)

    await bridge.mark_artifact_ready(
        artifact_hash="e" * 64,
        manifest={"replay_path": "artifacts/m_godot_bridge/replay.json"},
    )
    artifact = await link.receive_at_godot()
    assert artifact.message_type == "artifact_ready"
    assert bridge.phase is GodotBridgePhase.COMPLETE


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("disposition", "owner", "expected_owner"),
    [
        (
            "technical_forfeit",
            "participant_endpoint",
            FailureOwner.PARTICIPANT_ENDPOINT,
        ),
        (
            "infrastructure_void",
            "organizer_infrastructure",
            FailureOwner.ORGANIZER_INFRASTRUCTURE,
        ),
    ],
)
async def test_terminal_participant_and_infrastructure_ownership_remain_distinct(
    disposition: str, owner: str, expected_owner: FailureOwner
) -> None:
    bridge, link = await _authenticated_link()
    await _send_terminal_checkpoint(link, tick=1)
    await link.send_from_godot(
        "terminal",
        boundary_hash="f" * 64,
        body={
            "disposition": disposition,
            "failure": {
                "code": "classified_failure",
                "hard_model_failure": owner != "organizer_infrastructure",
                "owner": owner,
            },
            "result_hash": "f" * 64,
            "terminal_tick": 1,
            "winner_slot": 1 if disposition == "technical_forfeit" else None,
        },
    )
    report = await bridge.wait_terminal()
    assert report.failure is not None
    assert report.failure.owner is expected_owner


@pytest.mark.asyncio
async def test_remote_model_rejection_stays_distinct_from_transport_failure() -> None:
    bridge, link = await _authenticated_link()
    await _freeze_boundary(bridge, link)
    await _lock_fixed_window(bridge, link)
    request = FixedRevealRequest(
        match_id=MATCH_ID,
        opportunity_id="fixed-7",
        observation_seq=7,
        boundary_tick=350,
        activation_tick=351,
        disposition=FixedOpportunityDisposition.CONTINUE,
        reveals=(
            SlotReveal(0, _batch(0), "10" * 32),
            SlotReveal(1, _batch(1), "20" * 32),
        ),
    )
    task = asyncio.create_task(bridge.reveal_batch_pair(request))
    await link.receive_at_godot()
    evidence_task = asyncio.create_task(bridge.next_acknowledged_action_batches())
    with pytest.raises(GodotBridgeModelError) as inbound:
        await link.send_from_godot(
            "action_pair",
            boundary_hash=CHECKPOINT_HASH,
            body={
                "accepted": False,
                "activation_tick": 351,
                "failure": {
                    "code": "invalid_action_envelope",
                    "hard_model_failure": True,
                    "owner": "model",
                },
                "mode": "fixed_simultaneous",
                "observation_seq": 7,
                "opportunity_id": "fixed-7",
            },
        )
    assert inbound.value.classification.owner is FailureOwner.MODEL
    with pytest.raises(GodotBridgeModelError):
        await task
    with pytest.raises(GodotBridgeModelError):
        await evidence_task


def test_timing_fixture_remains_immutable_when_serialized() -> None:
    original = _timing(351)
    changed = replace(original, application_tick=352)
    assert original.application_tick == 351
    assert changed.application_tick == 352
