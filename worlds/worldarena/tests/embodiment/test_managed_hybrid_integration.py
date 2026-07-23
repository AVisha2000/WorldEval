from __future__ import annotations

import asyncio
import hashlib
import socket
from pathlib import Path

import pytest
import uvicorn
from fastapi import FastAPI, WebSocket
from genesis_arena.embodiment.contracts import CapabilityStatus, DecisionWindow, EpisodeConfig
from genesis_arena.embodiment.managed_process import ManagedLaunchSpec, ManagedProcessLauncher
from genesis_arena.embodiment.managed_session import ManagedWorldArenaSession
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage, canonical_sha256
from genesis_arena.embodiment.transport import ManagedWebSocketEndpoint
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
@pytest.mark.asyncio
async def test_managed_hybrid_binds_reset_and_terminal_frames() -> None:
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
    config = EpisodeConfig(
        episode_id="ep_managed_hybrid",
        mode="solo-curriculum-v0",
        task_id="orientation-v0",
        seed=7,
        observation_profile="hybrid-visible-v1",
        maximum_episode_ticks=1,
        capability_status=CapabilityStatus(
            implemented_observation_profiles=("text-visible-v1", "hybrid-visible-v1")
        ),
    )
    ticket = "H" * 43
    secret = bytearray(range(32))
    config_value = config.as_dict()
    future = endpoint.register(
        ticket=ticket,
        episode_id=config.episode_id,
        connection_id="hybrid_connection",
        session_secret=bytearray(secret),
    )
    launch = ManagedLaunchSpec(
        episode_id=config.episode_id,
        attachment_ticket=ticket,
        connection_id="hybrid_connection",
        gateway_url=f"ws://127.0.0.1:{port}/ws/embodiment/{ticket}",
        config=config_value,
        config_sha256=canonical_sha256(config_value),
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
        initial = observations["participant_0"]
        package.validate("observation", initial)
        initial_png = await _frame(session, initial)
        window = DecisionWindow.finalize(
            episode_id=config.episode_id,
            observation_seq=0,
            mode=config.mode,
            start_tick=0,
            participant_ids=config.participant_ids,
            actions={},
            failure_reasons={"participant_0": "missing"},
            duration_ticks=1,
        )
        result = await session.step(window)
        terminal = result.observations["participant_0"]
        package.validate("observation", terminal)
        terminal_png = await _frame(session, terminal)
        assert result.terminal.ended
        assert initial_png != terminal_png
        assert session.replay_bytes
    finally:
        await session.close()
        endpoint.cancel(ticket)
        server.should_exit = True
        await asyncio.wait_for(server_task, 5)
        listener.close()


async def _frame(session: ManagedWorldArenaSession, observation: dict) -> bytes:
    metadata = observation["frame"]
    png = await session.render(
        "participant_0",
        metadata["sensor_id"],
        metadata["transport_ref"],
        observation["observation_seq"],
    )
    assert len(png) > 24
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    assert hashlib.sha256(png).hexdigest() == metadata["sha256"]
    return png
