from __future__ import annotations

import asyncio
import hashlib
import socket
from pathlib import Path

import pytest
import uvicorn
from fastapi import FastAPI, WebSocket
from genesis_arena.embodiment.contracts import (
    CapabilityStatus,
    ControllerAction,
    ControllerState,
    EpisodeConfig,
)
from genesis_arena.embodiment.duel_runner import DuelDecisionDispatcher
from genesis_arena.embodiment.managed_process import ManagedLaunchSpec, ManagedProcessLauncher
from genesis_arena.embodiment.managed_session import ManagedWorldArenaSession
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    canonical_sha256,
    strict_json_loads,
)
from genesis_arena.embodiment.providers.contracts import ProviderCallResult, ProviderTelemetry
from genesis_arena.embodiment.replay import verify_replay_bytes
from genesis_arena.embodiment.transport import ManagedWebSocketEndpoint

ROOT = Path(__file__).resolve().parents[2]
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


class _RelayProvider:
    provider_name = "scripted-model"

    async def request(self, request) -> ProviderCallResult:
        approaching = request.participant_id == "participant_0" and request.observation_seq < 3
        move_y = 1000 if approaching else 0
        action = ControllerAction(
            episode_id=request.episode_id,
            observation_seq=request.observation_seq,
            action_id=f"{request.participant_id}_{request.observation_seq}",
            control=ControllerState(
                move_x=0,
                move_y=move_y,
                look_x=0,
                look_y=0,
                duration_ticks=10,
            ),
            intent_label="Approach or hold the relay.",
            memory_update="holding relay",
        )
        return ProviderCallResult.success(
            canonical_json_bytes(action.as_dict()), ProviderTelemetry(latency_ms=0)
        )


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
@pytest.mark.asyncio
async def test_managed_hybrid_duel_binds_both_frames_and_replays_relay_win() -> None:
    endpoint = ManagedWebSocketEndpoint()
    app = FastAPI()

    @app.websocket("/ws/embodiment/{ticket}")
    async def attach(ticket: str, websocket: WebSocket) -> None:
        await endpoint.handle(ticket, websocket)

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(128)
    listener.setblocking(False)
    port = listener.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(app, log_level="error", lifespan="off"))
    server_task = asyncio.create_task(server.serve(sockets=[listener]))
    while not server.started:
        await asyncio.sleep(0)

    package = EmbodimentProtocolPackage.from_repository(ROOT)
    capabilities = CapabilityStatus(
        implemented_modes=("solo-curriculum-v0", "scripted-duel-v0", "model-duel-v0"),
        implemented_observation_profiles=("text-visible-v1", "hybrid-visible-v1"),
        implemented_tasks=(
            "orientation-v0",
            "interaction-v0",
            "construction-v0",
            "neutral-encounter-v0",
            "central-relay-v0",
        ),
    )
    config = EpisodeConfig(
        episode_id="ep_managed_model_duel",
        mode="model-duel-v0",
        task_id="central-relay-v0",
        seed=0,
        observation_profile="hybrid-visible-v1",
        maximum_episode_ticks=1800,
        participant_ids=("participant_0", "participant_1"),
        capability_status=capabilities,
    )
    ticket = "D" * 43
    secret = bytearray(range(32))
    value = config.as_dict()
    future = endpoint.register(
        ticket=ticket,
        episode_id=config.episode_id,
        connection_id="managed_duel_connection",
        session_secret=bytearray(secret),
    )
    launch = ManagedLaunchSpec(
        episode_id=config.episode_id,
        attachment_ticket=ticket,
        connection_id="managed_duel_connection",
        gateway_url=f"ws://127.0.0.1:{port}/ws/embodiment/{ticket}",
        config=value,
        config_sha256=canonical_sha256(value),
        protocol_package_sha256=package.package_sha256,
        session_secret=secret,
    )
    session = ManagedWorldArenaSession(
        config=config,
        launcher=ManagedProcessLauncher(executable=GODOT, project_path=ROOT / "godot"),
        launch_spec=launch,
        socket_future=future,
        protocol_package=package,
        attachment_timeout_s=20,
        step_timeout_s=20,
    )
    try:
        observations = await session.reset()
        assert set(observations) == {"participant_0", "participant_1"}
        dispatcher = DuelDecisionDispatcher(
            config=config,
            providers={"participant_0": _RelayProvider(), "participant_1": _RelayProvider()},
            models={"participant_0": "model-a", "participant_1": "model-b"},
            system_prompt="Return exactly one valid controller action.",
            protocol_package=package,
            provider_timeout_s=5,
        )
        result = None
        for observation_seq in range(13):
            dispatch, result = await dispatcher.dispatch_and_step(
                session=session,
                observations=observations,
                observation_seq=observation_seq,
                start_tick=observation_seq * 10,
            )
            assert len({audit.deadline_monotonic_ns for audit in dispatch.audits}) == 1
            observations = result.observations
            if result.terminal.ended:
                for participant_id, observation in result.observations.items():
                    metadata = observation["frame"]
                    png = await session.render(
                        participant_id,
                        metadata["sensor_id"],
                        metadata["transport_ref"],
                        observation["observation_seq"],
                    )
                    assert hashlib.sha256(png).hexdigest() == metadata["sha256"]
                    assert metadata["transport_ref"].startswith(f"frame:{participant_id}.")
                break
        assert result is not None
        assert result.terminal.outcome == "win"
        assert result.terminal.reason == "relay_hold"
        assert all(receipt.applied_ticks > 0 for receipt in result.receipts.values())
        replay = verify_replay_bytes(session.replay_bytes, package=package)
        assert replay["final_state_hash"] == result.state_hash
        seal = await _godot_replay_seal(session.replay_bytes)
        assert seal["episode_id"] == config.episode_id
        assert seal["final_state_hash"] == result.state_hash
        dispatcher.close()
    finally:
        await session.close()
        endpoint.cancel(ticket)
        server.should_exit = True
        try:
            await asyncio.wait_for(asyncio.shield(server_task), 10)
        except asyncio.TimeoutError:
            server.force_exit = True
            await asyncio.wait_for(server_task, 5)
        listener.close()


async def _godot_replay_seal(replay: bytes) -> dict:
    process = await asyncio.create_subprocess_exec(
        str(GODOT),
        "--no-header",
        "--headless",
        "--audio-driver",
        "Dummy",
        "--path",
        str(ROOT / "godot"),
        "--script",
        "res://scripts/embodiment/replay/embodiment_replay_cli.gd",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    output, _ = await asyncio.wait_for(process.communicate(replay), 20)
    assert process.returncode == 0, output.decode("utf-8", errors="replace")
    return strict_json_loads(output.strip().splitlines()[-1])
