from __future__ import annotations

from fastapi.testclient import TestClient
from genesis_arena.main import app

from .helpers import observation


def test_world_websocket_returns_a_valid_action() -> None:
    with TestClient(app) as client:
        with client.websocket_connect("/ws/world") as websocket:
            assert websocket.receive_json()["type"] == "connected"
            websocket.send_json({"type": "hello", "client": "test"})
            assert websocket.receive_json()["type"] == "ready"

            websocket.send_json(observation().model_dump(mode="json"))
            assert websocket.receive_json()["type"] == "thinking"
            command = websocket.receive_json()

    assert command["type"] == "action_command"
    assert command["action"] == "collect"
    assert command["parameters"] == {"resource": "wood"}
