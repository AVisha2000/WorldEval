from __future__ import annotations

import asyncio
import socket
from pathlib import Path

import pytest
import uvicorn
from fastapi import FastAPI, WebSocket
from genesis_arena.embodiment.contracts import (
    CapabilityStatus,
    DecisionWindow,
    EpisodeConfig,
    ParticipantDecision,
)
from genesis_arena.embodiment.managed_process import ManagedLaunchSpec, ManagedProcessLauncher
from genesis_arena.embodiment.managed_session import ManagedWorldArenaSession
from genesis_arena.embodiment.protocol import canonical_sha256
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.replay import verify_replay_bytes
from genesis_arena.embodiment.transport import ManagedWebSocketEndpoint
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
V3 = "llm-controller/0.3.0"
TICKET = "3" * 43
PARTICIPANTS = ("participant_0", "participant_1", "participant_2")


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
@pytest.mark.asyncio
async def test_real_python_to_godot_v3_managed_episode_and_replay(tmp_path: Path) -> None:
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

    registry = EmbodimentProtocolRegistry.from_repository(ROOT)
    package = registry.package(V3)
    capabilities = CapabilityStatus(
        implemented_modes=("trio-game-v0",),
        implemented_observation_profiles=("text-visible-v1",),
        implemented_tasks=("trio-relay-v0", "trio-free-for-all-v0"),
    )
    config = EpisodeConfig(
        episode_id="ep_v3_real_managed",
        mode="trio-game-v0",
        task_id="trio-relay-v0",
        seed=311,
        participant_ids=PARTICIPANTS,
        maximum_episode_ticks=1200,
        capability_status=capabilities,
        protocol_version=V3,
        seat_rotation=1,
    )
    config_value = config.as_dict()
    secret = bytearray(range(32))
    socket_future = endpoint.register(
        ticket=TICKET,
        episode_id=config.episode_id,
        connection_id="trio-v3-real",
        session_secret=bytearray(secret),
        protocol_version=V3,
    )
    launch = ManagedLaunchSpec(
        episode_id=config.episode_id,
        attachment_ticket=TICKET,
        connection_id="trio-v3-real",
        gateway_url=f"ws://127.0.0.1:{port}/ws/embodiment/{TICKET}",
        config=config_value,
        config_sha256=canonical_sha256(config_value),
        protocol_package_sha256=package.package_sha256,
        session_secret=bytearray(secret),
    )
    session = ManagedWorldArenaSession(
        config=config,
        launcher=ManagedProcessLauncher(
            executable=GODOT,
            project_path=ROOT / "godot",
            protocol_registry=registry,
        ),
        launch_spec=launch,
        socket_future=socket_future,
        protocol_package=package,
        step_timeout_s=5,
    )
    replay = b""
    try:
        observations = await session.reset()
        assert set(observations) == set(PARTICIPANTS)
        assert {value["tick"] for value in observations.values()} == {0}
        result = None
        for sequence in range(120):
            window = DecisionWindow(
                episode_id=config.episode_id,
                observation_seq=sequence,
                mode="trio-game-v0",
                start_tick=sequence * 10,
                duration_ticks=10,
                decisions={
                    participant_id: ParticipantDecision.no_input("missing")
                    for participant_id in PARTICIPANTS
                },
            )
            result = await session.step(window)
        assert result is not None and result.terminal.ended
        assert result.terminal.outcome == "draw"
        assert result.trio_result is not None
        assert result.trio_result.placements[0].participant_ids == PARTICIPANTS
        replay = session.replay_bytes
        verified = verify_replay_bytes(replay, registry=registry)
        assert verified["final_result"] == result.trio_result.as_dict()
    finally:
        await session.close()
        endpoint.cancel(TICKET)
        server.should_exit = True
        await asyncio.wait_for(server_task, 5)
        listener.close()

    replay_path = tmp_path / "trio-v3-managed.replay.json"
    replay_path.write_bytes(replay)
    verifier = await asyncio.create_subprocess_exec(
        str(GODOT), "--headless", "--path", str(ROOT / "godot"), "--script",
        "res://scripts/embodiment/v2/replay/embodiment_versioned_replay_cli.gd", "--",
        str(replay_path), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    output, _ = await asyncio.wait_for(verifier.communicate(), 20)
    assert verifier.returncode == 0, output.decode(errors="replace")
    assert b"EMBODIMENT_REPLAY_VERIFIED llm-controller/0.3.0" in output
