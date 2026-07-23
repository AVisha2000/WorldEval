from __future__ import annotations

import json
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator, Dict

import uvicorn
from fastapi import FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect
from pydantic import ValidationError
from worldarena.conversational_sandbox.api import router as conversational_sandbox_router
from worldarena.conversational_sandbox.godot import GodotConversationWarehouseRunner
from worldarena.conversational_sandbox.interpreter import (
    create_visible_action_planner,
    create_visible_referent_interpreter,
)
from worldarena.conversational_sandbox.service import ConversationSandboxService
from worldarena.paths import WORLDARENA_GAMES_ROOT
from worldarena.primitive_sandbox.api import router as primitive_sandbox_router
from worldarena.primitive_sandbox.godot import (
    GodotPrimitiveSandboxRunner,
    network_isolation_available,
)
from worldarena.primitive_sandbox.service import PrimitiveSandboxService
from worldarena.replay_api import ReplayCatalog
from worldarena.replay_api import router as worldeval_replay_router
from worldarena.replay_verifiers import default_native_verifiers

from .arena.simulation_jobs import (
    ReplayBundle,
    ReplaySummary,
    SimulationJob,
    SimulationJobManager,
    SimulationRequest,
)
from .arena_api import arena_socket
from .config import REPOSITORY_ROOT, WORKSPACE_ROOT, Settings
from .duel.api import router as duel_router
from .duel.match_service import default_duel_match_service
from .embodiment.api import router as embodiment_router
from .embodiment.crossroads_conquest import CachedCrossroadsShowcase, CrossroadsShowcaseError
from .embodiment.dashboard import mount_built_dashboard
from .embodiment.duel.live_runtime import default_duel_series_service
from .embodiment.labyrinth_run import CachedLabyrinthRun
from .embodiment.live_runtime import default_episode_service
from .embodiment.presentation.preview_ingress import (
    InternalParticipantPreviewIngress,
    internal_preview_router,
)
from .embodiment.readiness import PilotReadinessStore
from .embodiment.rts_showcase import CachedRtsShowcase
from .embodiment.solo_showcase import CachedSoloShowcase
from .embodiment.transport import ManagedWebSocketEndpoint
from .embodiment.trio_games.live_runtime import default_trio_series_service
from .models import Observation, SimulationConfig
from .orchestrator import Orchestrator

settings = Settings()


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    require_replay_network_isolation = network_isolation_available()
    app.state.orchestrator = Orchestrator(settings)
    app.state.simulation_jobs = SimulationJobManager(settings)
    app.state.worldeval_replays = ReplayCatalog(
        (settings.runs_dir / "replays", REPOSITORY_ROOT / "demos"),
        native_verifiers=default_native_verifiers(
            godot_executable=settings.godot_executable,
            godot_project_path=settings.godot_project_path,
            require_network_isolation=require_replay_network_isolation,
        ),
    )
    app.state.primitive_sandbox = PrimitiveSandboxService(
        runner=GodotPrimitiveSandboxRunner(
            executable=settings.godot_executable,
            project_path=settings.godot_project_path,
            require_network_isolation=require_replay_network_isolation,
        ),
        replay_root=settings.runs_dir / "replays",
    )
    app.state.conversation_sandbox = ConversationSandboxService(
        runner=GodotConversationWarehouseRunner(
            executable=settings.godot_executable,
            project_path=settings.godot_project_path,
            scenario_path=WORLDARENA_GAMES_ROOT / "conversational-warehouse" / "scenario.json",
        ),
        replay_root=settings.runs_dir / "replays",
        interpreter=create_visible_referent_interpreter(
            mode=settings.conversation_mode,
            model=settings.conversation_model,
        ),
        action_planner=create_visible_action_planner(
            mode=settings.conversation_mode,
            model=settings.conversation_model,
        ),
    )
    app.state.duel_matches = default_duel_match_service(
        port=settings.port,
        runs_dir=settings.runs_dir,
        godot_executable=settings.godot_executable,
        godot_project_path=settings.godot_project_path,
    )
    app.state.embodiment_gateway = ManagedWebSocketEndpoint()
    app.state.embodiment_preview_ingress = InternalParticipantPreviewIngress()
    app.state.embodiment_readiness = PilotReadinessStore(settings.embodiment_readiness_path)
    # A checked-in authority-verified replay/video is reused for the prominent judge path.
    # Starting a dashboard session therefore never spends time or resources re-running the demo.
    app.state.embodiment_rts_showcase = CachedRtsShowcase.load(REPOSITORY_ROOT)
    app.state.embodiment_labyrinth_showcase = CachedLabyrinthRun.load(REPOSITORY_ROOT)
    app.state.embodiment_solo_showcase = CachedSoloShowcase.load(REPOSITORY_ROOT)
    try:
        app.state.embodiment_crossroads_showcase = CachedCrossroadsShowcase.load(REPOSITORY_ROOT)
    except CrossroadsShowcaseError:
        # Crossroads is an optional future showcase. Its absent cache must never prevent the
        # checked-in Mini RTS golden path or the rest of the local dashboard from starting.
        app.state.embodiment_crossroads_showcase = None
    app.state.embodiment_episodes = default_episode_service(
        repository_root=REPOSITORY_ROOT,
        godot_executable=settings.godot_executable,
        godot_project_path=settings.godot_project_path,
        gateway_port=settings.port,
        endpoint=app.state.embodiment_gateway,
        preview_ingress=app.state.embodiment_preview_ingress,
        provider_timeout_s=settings.decision_timeout_seconds,
        runs_dir=settings.runs_dir,
        ffmpeg_executable=settings.ffmpeg_executable,
    )
    app.state.embodiment_series = default_duel_series_service(
        repository_root=REPOSITORY_ROOT,
        godot_executable=settings.godot_executable,
        godot_project_path=settings.godot_project_path,
        gateway_port=settings.port,
        endpoint=app.state.embodiment_gateway,
        provider_timeout_s=settings.decision_timeout_seconds,
        runs_dir=settings.runs_dir,
        ffmpeg_executable=settings.ffmpeg_executable,
        preview_ingress=app.state.embodiment_preview_ingress,
    )
    app.state.embodiment_trio_series = default_trio_series_service(
        repository_root=REPOSITORY_ROOT,
        godot_executable=settings.godot_executable,
        godot_project_path=settings.godot_project_path,
        gateway_port=settings.port,
        endpoint=app.state.embodiment_gateway,
        provider_timeout_s=settings.decision_timeout_seconds,
        runs_dir=settings.runs_dir,
        ffmpeg_executable=settings.ffmpeg_executable,
        preview_ingress=app.state.embodiment_preview_ingress,
    )
    # Live Labyrinth Run is intentionally a separate v1 lifecycle from the cached showcase
    # and the keyless trio demo service.
    from .embodiment.live_labyrinth import LiveLabyrinthService
    from .embodiment.live_labyrinth_media import LiveLabyrinthBroadcastRenderer

    app.state.embodiment_live_labyrinth = LiveLabyrinthService(
        render_video=LiveLabyrinthBroadcastRenderer(
            output_root=settings.runs_dir / "live-labyrinth",
            godot_executable=settings.godot_executable,
            godot_project_path=settings.godot_project_path,
            ffmpeg_executable=settings.ffmpeg_executable,
        )
    )
    try:
        yield
    finally:
        await app.state.embodiment_trio_series.aclose()
        await app.state.embodiment_series.aclose()
        await app.state.embodiment_episodes.aclose()
        app.state.embodiment_preview_ingress.close()
        await app.state.duel_matches.aclose()


app = FastAPI(
    title="WorldArena Controller",
    version="0.2.0",
    description=(
        "Validated model-planning bridge for survival_v1 and the simultaneous WorldArena."
    ),
    lifespan=lifespan,
)
app.include_router(duel_router)
app.include_router(embodiment_router)
app.include_router(internal_preview_router)
app.include_router(worldeval_replay_router)
app.include_router(primitive_sandbox_router)
app.include_router(conversational_sandbox_router)


@app.websocket("/ws/embodiment/{ticket}")
async def embodiment_socket(ticket: str, websocket: WebSocket) -> None:
    await app.state.embodiment_gateway.handle(ticket, websocket)


@app.get("/health")
async def health() -> Dict[str, object]:
    orchestrator: Orchestrator = app.state.orchestrator
    return {
        "status": "ok",
        "brain": orchestrator.provider_name,
        "catalog_version": orchestrator.catalog.version,
        "protocols": [
            "genesis-arena/0.1",
            "world-arena/0.2",
            "world-arena/0.3",
            "world-arena/0.4",
        ],
    }


@app.get("/api/catalog")
async def catalog() -> Dict[str, Any]:
    orchestrator: Orchestrator = app.state.orchestrator
    return {
        "version": orchestrator.catalog.version,
        "actions": orchestrator.catalog.actions,
    }


@app.get("/api/state")
async def state() -> Dict[str, object]:
    orchestrator: Orchestrator = app.state.orchestrator
    return orchestrator.state()


def _simulation_jobs() -> SimulationJobManager:
    return app.state.simulation_jobs


@app.post("/api/simulations", response_model=SimulationJob, status_code=202)
async def create_simulation(request: SimulationRequest) -> SimulationJob:
    return _simulation_jobs().create(request)


@app.get("/api/simulations", response_model=list[SimulationJob])
async def list_simulations(limit: int = Query(default=50, ge=1, le=100)) -> list[SimulationJob]:
    return _simulation_jobs().list_jobs(limit)


@app.get("/api/simulations/{job_id}", response_model=SimulationJob)
async def get_simulation(job_id: str) -> SimulationJob:
    try:
        job = _simulation_jobs().get(job_id)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail="simulation not found") from exc
    if job is None:
        raise HTTPException(status_code=404, detail="simulation not found")
    return job


@app.get("/api/replays", response_model=list[ReplaySummary])
async def list_replays(limit: int = Query(default=50, ge=1, le=100)) -> list[ReplaySummary]:
    return _simulation_jobs().list_replays(limit)


@app.get("/api/replays/{replay_id}", response_model=ReplaySummary)
async def get_replay(replay_id: str) -> ReplaySummary:
    try:
        replay = _simulation_jobs().get_replay(replay_id, full=False)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail="replay not found") from exc
    if replay is None:
        raise HTTPException(status_code=404, detail="replay not found")
    assert isinstance(replay, ReplaySummary)
    return replay


@app.get("/api/replays/{replay_id}/bundle", response_model=ReplayBundle)
async def get_replay_bundle(replay_id: str) -> ReplayBundle:
    try:
        replay = _simulation_jobs().get_replay(replay_id, full=True)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail="replay not found") from exc
    if replay is None:
        raise HTTPException(status_code=404, detail="replay not found")
    assert isinstance(replay, ReplayBundle)
    return replay


@app.websocket("/ws/world")
async def world_socket(websocket: WebSocket) -> None:
    await websocket.accept()
    orchestrator: Orchestrator = app.state.orchestrator
    await websocket.send_json(
        {
            "type": "connected",
            "protocol": "genesis-arena/0.1",
            "brain": orchestrator.provider_name,
        }
    )

    try:
        while True:
            message = json.loads(await websocket.receive_text())
            message_type = message.get("type")

            if message_type == "hello":
                await websocket.send_json(
                    {
                        "type": "ready",
                        "brain": orchestrator.provider_name,
                        "enabled_actions": orchestrator.catalog.enabled_names,
                    }
                )
                continue

            if message_type == "ping":
                await websocket.send_json({"type": "pong"})
                continue

            if message_type == "configure":
                try:
                    config = SimulationConfig.model_validate(message)
                    models = orchestrator.configure(config)
                except (ValidationError, ValueError) as exc:
                    details = exc.errors() if isinstance(exc, ValidationError) else str(exc)
                    await websocket.send_json(
                        {
                            "type": "error",
                            "error": "invalid simulation configuration",
                            "details": details,
                        }
                    )
                    continue
                await websocket.send_json(
                    {"type": "configured", "agents": models, "brain": orchestrator.provider_name}
                )
                continue

            if message_type != "observation":
                await websocket.send_json(
                    {"type": "error", "error": f"unsupported message type: {message_type!r}"}
                )
                continue

            try:
                observation = Observation.model_validate(message)
            except ValidationError as exc:
                await websocket.send_json(
                    {"type": "error", "error": "invalid observation", "details": exc.errors()}
                )
                continue

            await websocket.send_json(
                {
                    "type": "thinking",
                    "agent_id": observation.agent_id,
                    "turn": observation.turn,
                    "brain": orchestrator.provider_for(observation.agent_id),
                }
            )
            command = await orchestrator.decide(observation)
            await websocket.send_json(command.model_dump(mode="json"))
    except (WebSocketDisconnect, json.JSONDecodeError):
        return


@app.websocket("/ws/arena")
async def arena_v1_socket(websocket: WebSocket) -> None:
    """WorldArena v0.3 simultaneous three-faction protocol (with v0.2 support)."""

    await arena_socket(websocket, settings)


# Static presentation is mounted after every API and WebSocket route. A source checkout without a
# completed Vite build remains a valid API server; `pnpm build` makes the local dashboard available
# from the same origin without introducing a second credential-handling process.
mount_built_dashboard(app, WORKSPACE_ROOT / "apps" / "worldeval-web" / "dist")


def run() -> None:
    uvicorn.run(
        "genesis_arena.main:app",
        host=settings.host,
        port=settings.port,
        reload=False,
        # Duel's one-use Godot attachment capability is carried in a WebSocket path. Never allow
        # the server's generic request logger to persist that protected path.
        access_log=False,
    )


if __name__ == "__main__":
    run()
