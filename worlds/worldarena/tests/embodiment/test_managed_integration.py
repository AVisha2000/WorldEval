from __future__ import annotations

import asyncio
import json
import socket
from pathlib import Path

import pytest
import uvicorn
from fastapi import FastAPI, WebSocket
from genesis_arena.embodiment.contracts import (
    ControllerAction,
    ControllerButtons,
    ControllerState,
    DecisionWindow,
    EpisodeConfig,
    ParticipantDecision,
)
from genesis_arena.embodiment.golden import load_golden_transcript
from genesis_arena.embodiment.managed_process import (
    ManagedLaunchSpec,
    ManagedProcessLauncher,
)
from genesis_arena.embodiment.managed_session import ManagedWorldArenaSession
from genesis_arena.embodiment.protocol import EmbodimentProtocolPackage, canonical_sha256
from genesis_arena.embodiment.replay import verify_replay_bytes
from genesis_arena.embodiment.transport import ManagedWebSocketEndpoint
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
TICKET = "T" * 43


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
@pytest.mark.parametrize(
    "transcript_name",
    [
        "stage-a-orientation-forward-v1",
        "stage-b-interaction-v1",
        "stage-c-construction-v1",
        "stage-d-neutral-encounter-v1",
    ],
)
@pytest.mark.asyncio
async def test_real_managed_episode_and_offline_godot_replay(transcript_name: str) -> None:
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
    server = uvicorn.Server(
        uvicorn.Config(app, log_level="error", lifespan="off", loop="asyncio")
    )
    server_task = asyncio.create_task(server.serve(sockets=[listener]))
    while not server.started:
        if server_task.done():
            await server_task
        await asyncio.sleep(0)

    package = EmbodimentProtocolPackage.from_repository(ROOT)
    transcript = load_golden_transcript(
        ROOT / "game/embodiment_protocol/golden" / f"{transcript_name}.json",
        package=package,
    )
    config_wire = transcript["config"]
    config = EpisodeConfig(
        episode_id=config_wire["episode_id"],
        mode=config_wire["mode"],
        task_id=config_wire["task_id"],
        seed=config_wire["seed"],
        observation_profile=config_wire["observation_profile"],
        timing_track=config_wire["timing_track"],
        maximum_episode_ticks=config_wire["maximum_episode_ticks"],
        participant_ids=tuple(config_wire["participant_ids"]),
    )
    config_value = config.as_dict()
    secret = bytearray(range(32))
    socket_future = endpoint.register(
        ticket=TICKET,
        episode_id=config.episode_id,
        connection_id="connection_0",
        session_secret=bytearray(secret),
    )
    spec = ManagedLaunchSpec(
        episode_id=config.episode_id,
        attachment_ticket=TICKET,
        connection_id="connection_0",
        gateway_url=f"ws://127.0.0.1:{port}/ws/embodiment/{TICKET}",
        config=config_value,
        config_sha256=canonical_sha256(config_value),
        protocol_package_sha256=package.package_sha256,
        session_secret=bytearray(secret),
    )
    session = ManagedWorldArenaSession(
        config=config,
        launcher=ManagedProcessLauncher(executable=GODOT, project_path=ROOT / "godot"),
        launch_spec=spec,
        socket_future=socket_future,
        protocol_package=package,
    )

    try:
        observations = await session.reset()
        assert observations == transcript["initial_boundary"]["observations"]
        for expected_step in transcript["steps"]:
            window = _window_from_dict(expected_step["decision_window"])
            result = await session.step(window)
            assert result.as_dict() == expected_step["result"]
        assert result.terminal.as_dict() == transcript["terminal_boundary"]["terminal"]
        assert result.state_hash == transcript["terminal_boundary"]["state_hash"]
        final_state_hash = result.state_hash
        replay = session.replay_bytes
        verify_replay_bytes(replay, package=package)
    finally:
        await session.close()
        endpoint.cancel(TICKET)
        server.should_exit = True
        await asyncio.wait_for(server_task, 5)
        listener.close()

    verifier = await asyncio.create_subprocess_exec(
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
    output, _ = await asyncio.wait_for(verifier.communicate(replay), 10)
    assert verifier.returncode == 0, output.decode("utf-8", errors="replace")
    record = json.loads(output.decode("utf-8").strip().splitlines()[-1])
    assert record == {
        "episode_id": config.episode_id,
        "final_state_hash": final_state_hash,
        "kind": "embodiment_replay_verified",
        "schema_version": "llm-controller/episode-replay/1.0.0",
    }


def _window_from_dict(value: dict) -> DecisionWindow:
    decisions = {}
    for participant_id, decision_value in value["decisions"].items():
        action_value = decision_value["action"]
        if action_value is None:
            decisions[participant_id] = ParticipantDecision.no_input(
                decision_value["no_input_reason"]
            )
            continue
        control_value = action_value["control"]
        action = ControllerAction(
            episode_id=action_value["episode_id"],
            observation_seq=action_value["observation_seq"],
            action_id=action_value["action_id"],
            control=ControllerState(
                control_value["move_x"],
                control_value["move_y"],
                control_value["look_x"],
                control_value["look_y"],
                control_value["duration_ticks"],
                ControllerButtons(**control_value["buttons"]),
            ),
            intent_label=action_value["intent_label"],
            memory_update=action_value["memory_update"],
        )
        decisions[participant_id] = ParticipantDecision("accepted", action)
    return DecisionWindow(
        episode_id=value["episode_id"],
        observation_seq=value["observation_seq"],
        mode=value["mode"],
        start_tick=value["start_tick"],
        duration_ticks=value["duration_ticks"],
        decisions=decisions,
    )
