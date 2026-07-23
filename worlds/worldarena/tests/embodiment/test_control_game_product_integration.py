from __future__ import annotations

import asyncio
import socket
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
import pytest
import uvicorn
from fastapi import FastAPI, WebSocket
from genesis_arena.embodiment import live_runtime, live_solo
from genesis_arena.embodiment.api import router
from genesis_arena.embodiment.artifacts import verify_offline_replay_with_godot
from genesis_arena.embodiment.demo_provider import DemoProvider
from genesis_arena.embodiment.demo_scenarios import demo_scenario_fixture_bytes
from genesis_arena.embodiment.presentation.preview_ingress import (
    InternalParticipantPreviewIngress,
    internal_preview_router,
)
from genesis_arena.embodiment.protocol import strict_json_loads
from genesis_arena.embodiment.protocol_registry import EmbodimentProtocolRegistry
from genesis_arena.embodiment.transport import ManagedWebSocketEndpoint

ROOT = Path(__file__).resolve().parents[2]
GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
TASKS = (
    ("movement-maze-v0", "movement-maze-demo-v1"),
    ("operator-action-course-v0", "operator-action-course-demo-v1"),
)

pytestmark = pytest.mark.skipif(not GODOT.is_file(), reason="pinned Godot unavailable")


@asynccontextmanager
async def _product_app(monkeypatch: pytest.MonkeyPatch):
    # Product pacing is separately covered; an authority E2E test should not consume wall-clock
    # gameplay time merely to prove package selection, pixels, evidence, and replay verification.
    monkeypatch.setattr(live_solo, "_REALTIME_AUTHORITY_TICK_NS", 0)
    endpoint = ManagedWebSocketEndpoint()
    ingress = InternalParticipantPreviewIngress()
    app = FastAPI()
    app.state.embodiment_gateway = endpoint
    app.state.embodiment_preview_ingress = ingress
    app.include_router(router)
    app.include_router(internal_preview_router)

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(128)
    listener.setblocking(False)
    port = int(listener.getsockname()[1])
    app.state.embodiment_episodes = live_runtime.default_episode_service(
        repository_root=ROOT,
        godot_executable=GODOT,
        godot_project_path=ROOT / "godot",
        gateway_port=port,
        endpoint=endpoint,
        preview_ingress=ingress,
        provider_timeout_s=10,
    )

    @app.websocket("/ws/embodiment/{ticket}")
    async def attach(ticket: str, websocket: WebSocket) -> None:
        await endpoint.handle(ticket, websocket)

    server = uvicorn.Server(uvicorn.Config(app, log_level="error", lifespan="off"))
    task = asyncio.create_task(server.serve(sockets=[listener]))
    while not server.started:
        await asyncio.sleep(0)
    try:
        async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}", timeout=60) as client:
            yield app, client
    finally:
        await app.state.embodiment_episodes.aclose()
        ingress.close()
        server.should_exit = True
        try:
            await asyncio.wait_for(asyncio.shield(task), 2)
        except asyncio.TimeoutError:
            server.force_exit = True
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        listener.close()


async def _run(client: httpx.AsyncClient, task_id: str, model: str, seed: int = 77):
    response = await client.post(
        "/api/embodiment/episodes",
        json={
            "provider": "demo",
            "model": model,
            "task_id": task_id,
            "scenario_id": task_id,
            "seed": seed,
            "observation_profile": "hybrid-visible-v1",
        },
    )
    assert response.status_code == 202
    created = response.json()
    assert created["config"]["protocol_version"] == "llm-controller/0.2.0"
    assert created["config"]["certification_eligible"] is False
    episode_id = created["episode_id"]
    for _ in range(600):
        status = (await client.get(f"/api/embodiment/episodes/{episode_id}")).json()
        if status["state"] in {"completed", "failed", "cancelled"}:
            break
        await asyncio.sleep(0.05)
    assert status["state"] == "completed", status
    result = (await client.get(f"/api/embodiment/episodes/{episode_id}/result")).json()
    assert result["result"]["terminal"]["outcome"] == "success"
    frame = await client.get(f"/api/embodiment/episodes/{episode_id}/frame")
    assert frame.status_code == 200
    assert frame.headers["content-type"].startswith("image/png")
    assert frame.content.startswith(b"\x89PNG\r\n\x1a\n")
    public = await client.get(f"/api/embodiment/episodes/{episode_id}/replay")
    assert public.status_code == 200
    return episode_id, result


@pytest.mark.asyncio
@pytest.mark.parametrize(("task_id", "model"), TASKS)
async def test_api_demo_managed_v2_seals_and_verifies_control_game_replay(
    task_id: str, model: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    async with _product_app(monkeypatch) as (app, client):
        episode_id, first = await _run(client, task_id, model)
        protected = await app.state.embodiment_episodes.protected_bundle(episode_id)
        registry = EmbodimentProtocolRegistry.from_repository(ROOT)
        verified = await verify_offline_replay_with_godot(
            protected.bundle_bytes,
            package=registry.package("llm-controller/0.2.0"),
            godot_executable=GODOT,
            project_path=ROOT / "godot",
        )
        assert verified["protocol_version"] == "llm-controller/0.2.0"
        _, second = await _run(client, task_id, model)
        assert {
            "terminal": first["result"]["terminal"],
            "windows": first["result"]["windows"],
            "provider_failures": first["result"]["provider_failures"],
        } == {
            "terminal": second["result"]["terminal"],
            "windows": second["result"]["windows"],
            "provider_failures": second["result"]["provider_failures"],
        }


@pytest.mark.asyncio
async def test_api_invalid_demo_output_records_neutral_window_then_recovers(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    original_factory = live_runtime._demo_provider

    def invalid_first_factory(spec):
        original = original_factory(spec)
        valid_behavior = original._behavior  # noqa: SLF001 - deterministic fault injection

        def behavior(request, policy_lock, call_index):
            if call_index == 0:
                return b"{}"
            return valid_behavior(request, policy_lock, call_index)

        return DemoProvider(
            original.policy_lock,
            behavior=behavior,
            fixture_bytes=demo_scenario_fixture_bytes(spec.scenario_id),
        )

    monkeypatch.setattr(live_runtime, "_demo_provider", invalid_first_factory)
    async with _product_app(monkeypatch) as (app, client):
        episode_id, result = await _run(
            client, "movement-maze-v0", "movement-maze-demo-v1", seed=78
        )
        assert result["result"]["provider_failures"] == 1
        public = await app.state.embodiment_episodes.replay(episode_id)
        receipts = strict_json_loads(public.read("receipts"))
        first = receipts[0]["participants"]["participant_0"]
        last = receipts[-1]["participants"]["participant_0"]
        assert first["disposition"] == "no_input"
        assert first["no_input_reason"] == "invalid"
        assert first["applied_ticks"] == 10
        assert last["end_tick"] > first["end_tick"]
