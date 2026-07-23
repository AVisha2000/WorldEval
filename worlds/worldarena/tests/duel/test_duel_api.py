from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from genesis_arena.duel.api import router
from genesis_arena.duel.match_service import default_duel_match_service

GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")


def _payload(*, launch_mode: str = "caller_owned") -> dict:
    return {
        "decision_mode": "fixed_simultaneous",
        "faction_preset_id": "grove-v1",
        "mirror_faction": True,
        "map_id": "crossroads-duel-v1",
        "seed": 202_607_19,
        "decision_period_ticks": 100,
        "response_deadline_ms": 45_000,
        "authority_launch_mode": launch_mode,
        "players": [
            {
                "slot": 0,
                "provider": "baseline.noop",
                "model": "baseline-noop-v1",
                "reasoning": "none",
            },
            {
                "slot": 1,
                "provider": "baseline.noop",
                "model": "baseline-noop-v1",
                "reasoning": "none",
            },
        ],
    }


def _app(*, godot_executable: Path | None = None) -> FastAPI:
    options = {"port": 8000}
    if godot_executable is not None:
        options["godot_executable"] = godot_executable
    service = default_duel_match_service(**options)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.duel_matches = service
        try:
            yield
        finally:
            await service.aclose()

    app = FastAPI(lifespan=lifespan)
    app.include_router(router)
    return app


def test_api_caller_owned_claim_status_cancel_and_result_are_secret_scoped() -> None:
    with TestClient(_app(), client=("127.0.0.1", 50_000)) as client:
        created_response = client.post("/api/duel/matches", json=_payload())
        assert created_response.status_code == 202
        assert created_response.headers["cache-control"] == "no-store"
        created = created_response.json()
        match_id = created["status"]["match_id"]
        claim_token = created["launch_claim_token"]
        assert claim_token
        assert created["status"]["state"] == "awaiting_godot"
        assert created["status"]["config"]["faction_preset_id"] == "grove-v1"
        assert created["status"]["config"]["mirror_faction"] is True

        status_response = client.get(f"/api/duel/matches/{match_id}")
        assert status_response.status_code == 200
        status_text = status_response.text
        for protected_key in (
            "claim_token",
            "gateway_url",
            "session_secret",
            "tie_key",
            "credential",
        ):
            assert protected_key not in status_text

        claim_response = client.post(
            "/api/duel/launch-claim", json={"claim_token": claim_token}
        )
        assert claim_response.status_code == 200
        assert claim_response.headers["cache-control"] == "no-store"
        controller = claim_response.json()
        assert set(controller) == {
            "authority",
            "connection_id",
            "gateway_url",
            "match_id",
            "match_init",
            "protocol_hash",
            "token",
        }
        assert controller["match_id"] == match_id
        assert controller["match_init"]["match_id"] == match_id
        assert len(controller["token"]) == 32
        assert len(controller["authority"]["tie_key"]) == 32
        assert controller["gateway_url"].startswith("ws://127.0.0.1:8000/ws/duel/")

        second_claim = client.post(
            "/api/duel/launch-claim", json={"claim_token": claim_token}
        )
        assert second_claim.status_code == 404

        not_ready = client.get(f"/api/duel/matches/{match_id}/result")
        assert not_ready.status_code == 409
        assert not_ready.json()["detail"]["code"] == "duel_result_not_ready"

        cancelled = client.post(f"/api/duel/matches/{match_id}/cancel")
        assert cancelled.status_code == 200
        assert cancelled.json()["state"] == "cancelled"
        result = client.get(f"/api/duel/matches/{match_id}/result")
        assert result.status_code == 200
        assert result.json()["state"] == "cancelled"
        assert "claim_token" not in result.text
        assert "token" not in result.text


def test_api_never_reflects_credentials_in_validation_errors() -> None:
    secret = "sk-malformed-request-must-not-be-reflected"
    payload = _payload()
    payload["mirror_faction"] = False
    payload["players"][0]["credential"] = secret
    payload["players"][1]["credential"] = secret

    with TestClient(_app(), client=("127.0.0.1", 50_000)) as client:
        response = client.post("/api/duel/matches", json=payload)
        assert response.status_code == 422
        assert response.json() == {"detail": {"code": "invalid_duel_match_request"}}
        assert secret not in response.text

        missing_model = _payload()
        del missing_model["players"][0]["model"]
        response = client.post("/api/duel/matches", json=missing_model)
        assert response.status_code == 422
        assert response.json() == {"detail": {"code": "invalid_duel_match_request"}}


def test_api_managed_mode_classifies_missing_executable_and_keeps_result_queryable() -> None:
    missing = Path("/definitely-missing/worldarena-godot")
    with TestClient(
        _app(godot_executable=missing), client=("127.0.0.1", 50_000)
    ) as client:
        response = client.post(
            "/api/duel/matches", json=_payload(launch_mode="managed_process")
        )
        assert response.status_code == 503
        detail = response.json()["detail"]
        assert detail["code"] == "duel_godot_executable_unavailable"
        match_id = detail["match_id"]

        status = client.get(f"/api/duel/matches/{match_id}")
        assert status.status_code == 200
        assert status.json()["state"] == "failed"
        assert status.json()["failure"] == {
            "code": "duel_godot_executable_unavailable",
            "owner": "organizer_infrastructure",
            "hard_model_failure": False,
        }
        result = client.get(f"/api/duel/matches/{match_id}/result")
        assert result.status_code == 200
        assert result.json()["state"] == "failed"


def test_api_default_managed_mode_starts_owned_godot_process() -> None:
    if not GODOT.is_file():
        pytest.skip("pinned Godot 4.5 binary is not installed")
    with TestClient(_app(), client=("127.0.0.1", 50_000)) as client:
        response = client.post(
            "/api/duel/matches", json=_payload(launch_mode="managed_process")
        )
        assert response.status_code == 202
        created = response.json()
        assert created["status"]["state"] == "awaiting_godot"
        assert created["launch_claim_token"] is None
        match_id = created["status"]["match_id"]

        cancelled = client.post(f"/api/duel/matches/{match_id}/cancel")
        assert cancelled.status_code == 200
        assert cancelled.json()["state"] == "cancelled"


def test_duel_router_is_additive_to_existing_main_routes() -> None:
    from genesis_arena.main import app

    paths = {getattr(route, "path", "") for route in app.routes}
    assert "/api/duel/matches" in paths
    assert "/api/simulations" in paths
    assert "/ws/arena" in paths
    assert "/ws/world" in paths


def test_application_runner_disables_capability_bearing_access_logs(monkeypatch) -> None:
    from genesis_arena import main

    captured = {}
    monkeypatch.setattr(main.uvicorn, "run", lambda *args, **kwargs: captured.update(kwargs))
    main.run()

    assert captured["access_log"] is False
