from __future__ import annotations

import json
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator, Dict

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from pydantic import ValidationError

from .config import Settings
from .models import Observation
from .orchestrator import Orchestrator

settings = Settings()


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    app.state.orchestrator = Orchestrator(settings)
    yield


app = FastAPI(
    title="Genesis Arena Controller",
    version="0.1.0",
    description="Validated agent-brain bridge for the Godot simulation.",
    lifespan=lifespan,
)


@app.get("/health")
async def health() -> Dict[str, object]:
    orchestrator: Orchestrator = app.state.orchestrator
    return {
        "status": "ok",
        "brain": orchestrator.provider_name,
        "catalog_version": orchestrator.catalog.version,
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
                }
            )
            command = await orchestrator.decide(observation)
            await websocket.send_json(command.model_dump(mode="json"))
    except (WebSocketDisconnect, json.JSONDecodeError):
        return


def run() -> None:
    uvicorn.run(
        "genesis_arena.main:app",
        host=settings.host,
        port=settings.port,
        reload=False,
    )


if __name__ == "__main__":
    run()
