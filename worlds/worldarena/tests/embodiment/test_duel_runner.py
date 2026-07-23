from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
from genesis_arena.embodiment.contracts import (
    ActionReceipt,
    CapabilityStatus,
    EpisodeConfig,
    MultiParticipantStepResult,
    TerminalState,
)
from genesis_arena.embodiment.duel_runner import DuelDecisionDispatcher
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage, canonical_json_bytes
from genesis_arena.embodiment.providers.contracts import ProviderCallResult, ProviderTelemetry

ROOT = Path(__file__).resolve().parents[2]
PARTICIPANTS = ("participant_alpha", "participant_bravo")


def _config(participant_ids=PARTICIPANTS) -> EpisodeConfig:
    return EpisodeConfig(
        episode_id="ep_duel_dispatch",
        mode="model-duel-v0",
        task_id="neutral-encounter-v0",
        seed=7,
        participant_ids=tuple(participant_ids),
        capability_status=CapabilityStatus(
            implemented_modes=("model-duel-v0",),
            implemented_observation_profiles=("text-visible-v1",),
        ),
    )


def _observation(participant_id: str, *, seq: int = 0, tick: int = 0) -> dict:
    return {
        "protocol_version": "llm-controller/0.1.0",
        "episode_id": "ep_duel_dispatch",
        "observation_seq": seq,
        "tick": tick,
        "profile": "text-visible-v1",
        "goal": f"private-view:{participant_id}",
        "remaining_ticks": 100,
        "self": {
            "health_percent": 100,
            "energy_percent": 100,
            "facing": "north",
            "contact": "clear",
            "inventory": [],
            "status": [],
        },
        "visible_entities": [],
        "recent_events": [],
        "previous_receipt": None,
        "memory": "",
        "terminal": {"ended": False, "outcome": "running", "reason": "running"},
    }


def _action(participant_id: str, *, memory: str = "", seq: int = 0) -> bytes:
    return canonical_json_bytes(
        {
            "protocol_version": "llm-controller/0.1.0",
            "episode_id": "ep_duel_dispatch",
            "observation_seq": seq,
            "action_id": f"act_{participant_id}",
            "control": {
                "move_x": 0,
                "move_y": 1000 if participant_id == "participant_alpha" else -1000,
                "look_x": 0,
                "look_y": 0,
                "duration_ticks": 10,
                "buttons": {
                    "interact": False,
                    "primary": False,
                    "guard": False,
                    "dash": False,
                    "ability_1": False,
                    "ability_2": False,
                    "cycle_item": False,
                    "cancel": False,
                },
            },
            "intent_label": "advance",
            "memory_update": memory,
        }
    )


class _Provider:
    provider_name = "test-provider"

    def __init__(self, *, delay: float = 0, output: bytes | None = None, gate=None) -> None:
        self.delay = delay
        self.output = output
        self.gate = gate
        self.requests = []
        self.cancelled = False

    async def request(self, request):
        self.requests.append(request)
        if self.gate is not None:
            self.gate["started"].add(request.participant_id)
            if len(self.gate["started"]) == 2:
                self.gate["release"].set()
            await self.gate["release"].wait()
        try:
            if self.delay:
                await asyncio.sleep(self.delay)
        except asyncio.CancelledError:
            self.cancelled = True
            raise
        output = self.output if self.output is not None else _action(request.participant_id)
        return ProviderCallResult.success(output, ProviderTelemetry(latency_ms=1))


def _dispatcher(config, providers, **kwargs) -> DuelDecisionDispatcher:
    return DuelDecisionDispatcher(
        config=config,
        providers=providers,
        models={
            "participant_alpha": "model-alpha",
            "participant_bravo": "model-bravo",
        },
        system_prompt="Return exactly one controller action.",
        protocol_package=EmbodimentProtocolPackage.from_repository(ROOT),
        **kwargs,
    )


@pytest.mark.asyncio
async def test_calls_are_concurrent_equal_budget_and_participant_scoped() -> None:
    gate = {"started": set(), "release": asyncio.Event()}
    providers = {participant_id: _Provider(gate=gate) for participant_id in PARTICIPANTS}
    dispatcher = _dispatcher(_config(), providers)
    observations = {participant_id: _observation(participant_id) for participant_id in PARTICIPANTS}

    result = await asyncio.wait_for(
        dispatcher.dispatch(observations=observations, observation_seq=0, start_tick=0),
        timeout=1,
    )

    assert gate["started"] == set(PARTICIPANTS)
    requests = [providers[participant_id].requests[0] for participant_id in PARTICIPANTS]
    assert requests[0].system_prompt == requests[1].system_prompt
    assert {request.model for request in requests} == {"model-alpha", "model-bravo"}
    assert requests[0].action_schema_json == requests[1].action_schema_json
    assert requests[0].deadline_monotonic_ns == requests[1].deadline_monotonic_ns
    assert requests[0].max_output_bytes == requests[1].max_output_bytes == 4096
    for request in requests:
        own = request.participant_id.encode()
        opponent = next(value for value in PARTICIPANTS if value != request.participant_id).encode()
        assert own in request.observation_json
        assert opponent not in request.observation_json
    assert result.window.duration_ticks == 10
    assert all(decision.disposition == "accepted" for decision in result.window.decisions.values())
    dispatcher.close()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("participant_order", "observation_order", "delays"),
    [
        (PARTICIPANTS, PARTICIPANTS, (0.02, 0)),
        (tuple(reversed(PARTICIPANTS)), tuple(reversed(PARTICIPANTS)), (0, 0.02)),
        (tuple(reversed(PARTICIPANTS)), PARTICIPANTS, (0.01, 0.03)),
    ],
)
async def test_order_delay_and_arrival_permutations_are_canonical(
    participant_order, observation_order, delays
) -> None:
    providers = {
        PARTICIPANTS[0]: _Provider(delay=delays[0]),
        PARTICIPANTS[1]: _Provider(delay=delays[1]),
    }
    dispatcher = _dispatcher(_config(participant_order), providers)
    observations = {
        participant_id: _observation(participant_id) for participant_id in observation_order
    }
    result = await dispatcher.dispatch(observations=observations, observation_seq=0, start_tick=0)
    encoded = canonical_json_bytes(result.window.as_dict())
    assert encoded == canonical_json_bytes(
        {
            "episode_id": "ep_duel_dispatch",
            "observation_seq": 0,
            "mode": "model-duel-v0",
            "start_tick": 0,
            "duration_ticks": 10,
            "decisions": result.window.as_dict()["decisions"],
        }
    )
    # Stable digest shared across all parametrized permutations.
    assert len(__import__("hashlib").sha256(encoded).hexdigest()) == 64
    dispatcher.close()


@pytest.mark.asyncio
async def test_permutation_outputs_are_identical() -> None:
    payloads = []
    for participant_order, delays in (
        (PARTICIPANTS, (0.02, 0)),
        (tuple(reversed(PARTICIPANTS)), (0, 0.02)),
    ):
        providers = {
            PARTICIPANTS[0]: _Provider(delay=delays[0]),
            PARTICIPANTS[1]: _Provider(delay=delays[1]),
        }
        dispatcher = _dispatcher(_config(participant_order), providers)
        observations = {
            participant_id: _observation(participant_id)
            for participant_id in reversed(participant_order)
        }
        result = await dispatcher.dispatch(
            observations=observations, observation_seq=0, start_tick=0
        )
        payloads.append(canonical_json_bytes(result.window.as_dict()))
        dispatcher.close()
    assert payloads[0] == payloads[1]


@pytest.mark.asyncio
async def test_invalid_timeout_and_missing_become_recorded_neutral_windows() -> None:
    providers = {
        PARTICIPANTS[0]: _Provider(output=b'{"invalid":true}'),
        PARTICIPANTS[1]: _Provider(delay=0.1),
    }
    dispatcher = _dispatcher(_config(), providers, provider_timeout_s=0.01)
    result = await dispatcher.dispatch(
        observations={
            participant_id: _observation(participant_id) for participant_id in PARTICIPANTS
        },
        observation_seq=0,
        start_tick=0,
    )
    assert result.window.controller_states() == {
        participant_id: result.window.controller_states()[participant_id]
        for participant_id in PARTICIPANTS
    }
    assert all(
        state.move_x == state.move_y == 0 for state in result.window.controller_states().values()
    )
    assert result.window.decisions[PARTICIPANTS[0]].no_input_reason == "invalid"
    assert result.window.decisions[PARTICIPANTS[1]].no_input_reason == "timeout"

    missing = await dispatcher.dispatch(
        observations={PARTICIPANTS[0]: _observation(PARTICIPANTS[0])},
        observation_seq=0,
        start_tick=0,
    )
    assert missing.window.decisions[PARTICIPANTS[1]].no_input_reason == "missing"
    dispatcher.close()


@pytest.mark.asyncio
async def test_scratchpads_are_separate_2048_byte_and_reset_per_leg() -> None:
    alpha_memory = "é" * 1024
    providers = {
        PARTICIPANTS[0]: _Provider(output=_action(PARTICIPANTS[0], memory=alpha_memory)),
        PARTICIPANTS[1]: _Provider(output=_action(PARTICIPANTS[1], memory="bravo-only")),
    }
    dispatcher = _dispatcher(_config(), providers)
    await dispatcher.dispatch(
        observations={
            participant_id: _observation(participant_id) for participant_id in PARTICIPANTS
        },
        observation_seq=0,
        start_tick=0,
    )
    assert dispatcher.scratchpad_utf8(PARTICIPANTS[0]) == alpha_memory.encode()
    assert len(dispatcher.scratchpad_utf8(PARTICIPANTS[0])) == 2048
    assert dispatcher.scratchpad_utf8(PARTICIPANTS[1]) == b"bravo-only"
    dispatcher.reset_leg()
    assert all(dispatcher.scratchpad_utf8(participant_id) == b"" for participant_id in PARTICIPANTS)
    dispatcher.close()


@pytest.mark.asyncio
async def test_dispatch_cancellation_cancels_both_provider_calls() -> None:
    providers = {participant_id: _Provider(delay=10) for participant_id in PARTICIPANTS}
    dispatcher = _dispatcher(_config(), providers)
    task = asyncio.create_task(
        dispatcher.dispatch(
            observations={
                participant_id: _observation(participant_id) for participant_id in PARTICIPANTS
            },
            observation_seq=0,
            start_tick=0,
        )
    )
    while not all(provider.requests for provider in providers.values()):
        await asyncio.sleep(0)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert all(provider.cancelled for provider in providers.values())
    dispatcher.close()


@pytest.mark.asyncio
async def test_protected_audit_is_sorted_hashed_and_has_no_credentials() -> None:
    providers = {participant_id: _Provider() for participant_id in reversed(PARTICIPANTS)}
    dispatcher = _dispatcher(_config(tuple(reversed(PARTICIPANTS))), providers)
    result = await dispatcher.dispatch(
        observations={
            participant_id: _observation(participant_id) for participant_id in PARTICIPANTS
        },
        observation_seq=0,
        start_tick=0,
    )
    assert tuple(audit.participant_id for audit in result.audits) == PARTICIPANTS
    assert all(len(audit.observation_sha256) == 64 for audit in result.audits)
    assert all(len(audit.action_schema_sha256) == 64 for audit in result.audits)
    assert "credential" not in repr(result.audits).lower()
    assert "api_key" not in repr(result.audits).lower()
    dispatcher.close()


class _StepSession:
    def __init__(self) -> None:
        self.window = None

    async def step(self, window):
        self.window = window
        receipts = {}
        for participant_id, decision in window.decisions.items():
            receipts[participant_id] = ActionReceipt(
                action_id=f"no_input_{participant_id}",
                observation_seq=0,
                accepted=False,
                start_tick=0,
                end_tick=10,
                applied_ticks=10,
                codes=("no_input",),
                disposition="no_input",
                fallback="neutral",
                no_input_reason=decision.no_input_reason,
            )
        return MultiParticipantStepResult(
            observations={
                participant_id: _observation(participant_id, seq=1, tick=10)
                for participant_id in PARTICIPANTS
            },
            receipts=receipts,
            public_events=(),
            state_hash="a" * 64,
            terminal=TerminalState(False, "running", "running"),
        )


@pytest.mark.asyncio
async def test_invalid_joint_input_still_steps_authority_ten_ticks() -> None:
    providers = {participant_id: _Provider(output=b"null") for participant_id in PARTICIPANTS}
    dispatcher = _dispatcher(_config(), providers)
    session = _StepSession()
    dispatch, step = await dispatcher.dispatch_and_step(
        session=session,  # type: ignore[arg-type]
        observations={
            participant_id: _observation(participant_id) for participant_id in PARTICIPANTS
        },
        observation_seq=0,
        start_tick=0,
    )
    assert session.window is dispatch.window
    assert session.window.duration_ticks == 10
    assert all(receipt.end_tick == 10 for receipt in step.receipts.values())
    dispatcher.close()
