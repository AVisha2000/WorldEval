from __future__ import annotations

import asyncio
import os
import shutil
import socket
from dataclasses import dataclass, field
from pathlib import Path

import pytest
import uvicorn
from fastapi import FastAPI, WebSocket
from genesis_arena.duel.canonical import canonical_json_bytes, strict_json_loads
from genesis_arena.duel.godot_bridge import (
    GatewayGodotBridge,
    GodotBridgePhase,
    LocalhostGodotWebSocketAdapter,
)
from genesis_arena.duel.live_match import (
    DuelLiveMatchRunner,
    LiveArtifactSeal,
    LiveMatchTrace,
)
from genesis_arena.duel.match_init import MatchInitAssembler
from genesis_arena.duel.models import MatchConfig
from genesis_arena.duel.protocol import ProtocolPackage
from genesis_arena.duel.provider_adapters import (
    EndpointOwnership,
    ProviderCallResult,
    ProviderFailureKind,
    ProviderRequest,
)
from worldarena.paths import WORLDARENA_ROOT

ROOT = WORLDARENA_ROOT
MATCH_ID = "m_websocket-integration"
TOKEN = bytes(range(32))
ENGINE_BUILD_ID = "godot-4.5.stable.official.876b29033"
ENGINE_BUILD_SHA256 = "39b904eb0014941330f6435796ae0a041979802047495eb6fb87d59f327de719"


def _godot_binary() -> str | None:
    macos = Path("/Applications/Godot.app/Contents/MacOS/Godot")
    if macos.is_file():
        return str(macos)
    return shutil.which("godot4") or shutil.which("godot")


def _config() -> MatchConfig:
    return MatchConfig(
        decision_mode="continuous_realtime",
        faction_preset_id="vanguard-v1",
        seed=91_339,
        decision_period_ticks=50,
        response_deadline_ms=8_000,
        players=[
            {
                "slot": 0,
                "model": "model-a",
                "reasoning": "medium",
                "provider_adapter": "integration-a",
            },
            {
                "slot": 1,
                "model": "model-b",
                "reasoning": "medium",
                "provider_adapter": "integration-b",
            },
        ],
    )


class ImmediateNoopAdapter:
    endpoint_ownership = EndpointOwnership.PARTICIPANT_HOSTED

    def __init__(self, slot: int) -> None:
        self.slot = slot
        self.requests: list[ProviderRequest] = []

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        self.requests.append(request)
        if self.slot == 1:
            return ProviderCallResult.failed(ProviderFailureKind.SHARED_PROVIDER_OUTAGE)
        observation = strict_json_loads(request.observation_json)
        assert isinstance(observation, dict)
        observation_hash = observation["observation_hash"]
        assert isinstance(observation_hash, str)
        return ProviderCallResult.success(
            canonical_json_bytes(
                {
                    "based_on_observation_hash": observation_hash,
                    "client_batch_id": f"websocket.batch.{request.observation_seq}.{self.slot}",
                    "commands": [],
                    "match_id": request.match_id,
                    "message_type": "action_batch",
                    "observation_seq": request.observation_seq,
                    "protocol_version": "worldeval-rts/1.0.0",
                    "valid_until_tick": request.boundary_tick + 100,
                    "working_memory": f"websocket-memory-{self.slot}",
                }
            )
        )


@dataclass
class IntegrationArtifactFinalizer:
    traces: list[LiveMatchTrace] = field(default_factory=list)

    async def seal(self, trace: LiveMatchTrace) -> LiveArtifactSeal:
        self.traces.append(trace)
        return LiveArtifactSeal(
            artifact_hash="d" * 64,
            manifest={
                "format": "worldeval-duel-replay-v1",
                "match_id": trace.match_id,
                "terminal_result_hash": trace.terminal.result_hash,
            },
        )


async def _wait_for_phase(bridge: GatewayGodotBridge, phase: GodotBridgePhase) -> None:
    for _ in range(1_000):
        if bridge.phase is phase:
            return
        if bridge.phase is GodotBridgePhase.FAILED:
            raise AssertionError("Godot bridge failed before reaching the expected phase")
        await asyncio.sleep(0.01)
    raise AssertionError(f"Godot bridge did not reach {phase.value}")


@pytest.mark.asyncio
async def test_real_loopback_websocket_runs_the_production_live_match(
    tmp_path: Path,
) -> None:
    godot = _godot_binary()
    if godot is None:
        pytest.skip("frozen Godot executable is unavailable")

    config = _config()
    assembly = MatchInitAssembler(
        ProtocolPackage(ROOT / "game" / "duel_protocol")
    ).assemble(
        config,
        match_id=MATCH_ID,
        engine_build_id=ENGINE_BUILD_ID,
        engine_build_sha256=ENGINE_BUILD_SHA256,
    )
    match_init_path = tmp_path / "match-init.canonical.json"
    match_init_path.write_bytes(assembly.canonical_bytes)
    decoded_match_init = strict_json_loads(assembly.canonical_bytes)
    assert isinstance(decoded_match_init, dict)
    protocol_hash = decoded_match_init["artifacts"]["protocol"]["sha256"]
    assert isinstance(protocol_hash, str)

    bridge = GatewayGodotBridge(match_id=MATCH_ID, token=TOKEN, response_timeout_s=30)
    adapter = LocalhostGodotWebSocketAdapter(bridge)
    app = FastAPI()

    @app.websocket("/ws/duel")
    async def duel_socket(websocket: WebSocket) -> None:
        await adapter.handle(websocket)

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(128)
    listener.setblocking(False)
    port = listener.getsockname()[1]
    server = uvicorn.Server(
        uvicorn.Config(app, host="127.0.0.1", port=port, log_level="critical", access_log=False)
    )
    server_task = asyncio.create_task(server.serve(sockets=[listener]))
    for _ in range(1_000):
        if server.started:
            break
        await asyncio.sleep(0.01)
    assert server.started

    environment = os.environ.copy()
    environment.update(
        {
            "WORLDEVAL_DUEL_TEST_MATCH_ID": MATCH_ID,
            "WORLDEVAL_DUEL_TEST_MATCH_INIT_PATH": str(match_init_path),
            "WORLDEVAL_DUEL_TEST_PROTOCOL_HASH": protocol_hash,
            "WORLDEVAL_DUEL_TEST_TOKEN_HEX": TOKEN.hex(),
            "WORLDEVAL_DUEL_TEST_URL": f"ws://127.0.0.1:{port}/ws/duel",
        }
    )
    process = await asyncio.create_subprocess_exec(
        godot,
        "--headless",
        "--path",
        str(ROOT / "godot"),
        "--script",
        "res://tests/duel/duel_gateway_websocket_integration_runner.gd",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        env=environment,
    )
    try:
        try:
            await _wait_for_phase(bridge, GodotBridgePhase.AUTHENTICATED)
        except BaseException as exc:
            if process.returncode is None:
                process.terminate()
            stdout, _ = await asyncio.wait_for(process.communicate(), 30)
            output = stdout.decode("utf-8", errors="replace")
            raise AssertionError(f"Godot authority did not authenticate; output:\n{output}") from exc
        providers = {slot: ImmediateNoopAdapter(slot) for slot in (0, 1)}
        finalizer = IntegrationArtifactFinalizer()
        runner = DuelLiveMatchRunner(
            config=config,
            match_init=assembly,
            adapters=providers,
            bridge=bridge,
            artifact_finalizer=finalizer,
        )
        try:
            result = await asyncio.wait_for(runner.run(), 60)
        except BaseException as exc:
            if process.returncode is None:
                process.terminate()
            stdout, _ = await asyncio.wait_for(process.communicate(), 30)
            output = stdout.decode("utf-8", errors="replace")
            raise AssertionError(f"production live runner failed; Godot output:\n{output}") from exc

        assert result.terminal.disposition == "infrastructure_void"
        assert result.terminal.winner_slot is None
        assert len(result.trace.observations) == 1
        assert len(result.trace.continuous_dispatches) == 1
        assert len(result.trace.continuous_gates) >= 1
        assert finalizer.traces == [result.trace]
        assert len(providers[0].requests) == len(providers[1].requests) == 1

        stdout, _ = await asyncio.wait_for(process.communicate(), 30)
        output = stdout.decode("utf-8", errors="replace")
        assert process.returncode == 0, output
        assert "DUEL_GATEWAY_WEBSOCKET_INTEGRATION_OK" in output
        assert TOKEN.hex() not in output
    finally:
        if process.returncode is None:
            process.terminate()
            await process.wait()
        server.should_exit = True
        await server_task
