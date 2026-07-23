from __future__ import annotations

import asyncio
import socket
from pathlib import Path

import pytest
import uvicorn
from fastapi import FastAPI, WebSocket
from genesis_arena.embodiment.artifacts import (
    verify_offline_replay,
    verify_offline_replay_with_godot,
)
from genesis_arena.embodiment.construction_task_provider import ConstructionTaskProvider
from genesis_arena.embodiment.contracts import CapabilityStatus, EpisodeConfig
from genesis_arena.embodiment.golden import load_golden_transcript
from genesis_arena.embodiment.live_solo import LiveSoloRunner
from genesis_arena.embodiment.managed_process import ManagedLaunchSpec, ManagedProcessLauncher
from genesis_arena.embodiment.managed_session import ManagedWorldArenaSession
from genesis_arena.embodiment.protocol import (
    EmbodimentProtocolPackage,
    canonical_json_bytes,
    canonical_sha256,
)
from genesis_arena.embodiment.providers.contracts import ProviderCallResult, ProviderTelemetry
from genesis_arena.embodiment.transport import ManagedWebSocketEndpoint
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


class _GoldenStageCProvider:
    provider_name = "scripted-stage-c"

    def __init__(self, transcript: dict) -> None:
        self._actions = {
            step["decision_window"]["observation_seq"]: step["decision_window"]["decisions"][
                "participant_0"
            ]["action"]
            for step in transcript["steps"]
        }

    async def request(self, request) -> ProviderCallResult:
        return ProviderCallResult.success(
            canonical_json_bytes(self._actions[request.observation_seq]),
            ProviderTelemetry(latency_ms=0),
        )


class _ConstructionPlanProvider:
    provider_name = "scripted-construction-plan"

    async def request(self, request) -> ProviderCallResult:
        observation = __import__("json").loads(request.observation_json)
        inventory = observation["self"]["inventory"]
        entities = {item["id"]: item["state"] for item in observation["visible_entities"]}
        task = (
            "deliver_materials" if inventory
            else "build_barricade" if entities.get("v_build_pad_1") == "ready"
            else "gather_materials"
        )
        return ProviderCallResult.success(
            canonical_json_bytes(
                {
                    "protocol_version": "llm-controller/0.1.0",
                    "episode_id": request.episode_id,
                    "observation_seq": request.observation_seq,
                    "task_id": task,
                    "intent_label": task,
                    "memory_update": "",
                }
            ),
            ProviderTelemetry(latency_ms=0),
        )


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
@pytest.mark.asyncio
async def test_actual_hybrid_stage_c_uses_live_runner_and_replays_from_genesis() -> None:
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
    transcript = load_golden_transcript(
        ROOT / "game/embodiment_protocol/golden/stage-c-construction-v1.json",
        package=package,
    )
    config = EpisodeConfig(
        episode_id=transcript["config"]["episode_id"],
        mode="solo-curriculum-v0",
        task_id="construction-v0",
        seed=0,
        observation_profile="hybrid-visible-v1",
        maximum_episode_ticks=600,
        capability_status=CapabilityStatus(
            implemented_observation_profiles=("text-visible-v1", "hybrid-visible-v1")
        ),
    )
    ticket = "S" * 43
    secret = bytearray(range(32))
    value = config.as_dict()
    future = endpoint.register(
        ticket=ticket,
        episode_id=config.episode_id,
        connection_id="stage_c_connection",
        session_secret=bytearray(secret),
    )
    launch = ManagedLaunchSpec(
        episode_id=config.episode_id,
        attachment_ticket=ticket,
        connection_id="stage_c_connection",
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
        outcome = await LiveSoloRunner(
            config=config,
            session=session,
            provider=_GoldenStageCProvider(transcript),
            model="scripted-stage-c",
            system_prompt="Return exactly one controller action matching the supplied schema.",
            protocol_package=package,
            provider_timeout_s=5,
        ).run()
        assert outcome.terminal["outcome"] == "success"
        assert outcome.windows == len(transcript["steps"])
        assert outcome.provider_failures == 0
        assert outcome.bundles is not None
        replay = verify_offline_replay(outcome.bundles.protected.bundle_bytes, package=package)
        assert replay["final_state_hash"] == outcome.final_state_hash
        seal = await verify_offline_replay_with_godot(
            outcome.bundles.protected.bundle_bytes,
            package=package,
            godot_executable=GODOT,
            project_path=ROOT / "godot",
        )
        assert seal["final_state_hash"] == outcome.final_state_hash
        assert outcome.bundles.protected.read("frames") != b"[]"
    finally:
        endpoint.cancel(ticket)
        server.should_exit = True
        await asyncio.wait_for(server_task, 5)
        listener.close()


@pytest.mark.skipif(not GODOT.is_file(), reason="pinned local Godot build is unavailable")
@pytest.mark.asyncio
async def test_actual_hybrid_stage_c_executes_task_plan_milestones() -> None:
    """The task-plan adapter must work through the real managed Godot boundary."""
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
        episode_id="ep_task_plan_stage_c",
        mode="solo-curriculum-v0",
        task_id="construction-v0",
        seed=0,
        observation_profile="hybrid-visible-v1",
        maximum_episode_ticks=600,
        capability_status=CapabilityStatus(implemented_observation_profiles=("hybrid-visible-v1",)),
    )
    ticket = "T" * 43
    secret = bytearray(range(32))
    value = config.as_dict()
    future = endpoint.register(
        ticket=ticket,
        episode_id=config.episode_id,
        connection_id="task_plan_connection",
        session_secret=bytearray(secret),
    )
    launch = ManagedLaunchSpec(
        episode_id=config.episode_id,
        attachment_ticket=ticket,
        connection_id="task_plan_connection",
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
        outcome = await LiveSoloRunner(
            config=config, session=session,
            provider=ConstructionTaskProvider(_ConstructionPlanProvider(), package),
            model="scripted-construction-plan", system_prompt="Choose one construction milestone.",
            protocol_package=package, provider_timeout_s=5,
        ).run()
        assert outcome.terminal["outcome"] == "success"
        assert outcome.provider_failures == 0
    finally:
        endpoint.cancel(ticket)
        server.should_exit = True
        await asyncio.wait_for(server_task, 5)
        listener.close()
