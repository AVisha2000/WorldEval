from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from worldarena.paths import WORLDARENA_GODOT_ROOT
from worldarena.primitive_sandbox.api import router as sandbox_router
from worldarena.primitive_sandbox.godot import (
    NATIVE_SCHEMA,
    NATIVE_VERIFIER,
    GodotPrimitiveSandboxRunner,
    GodotSandboxError,
    native_replay_verifier,
    network_isolation_available,
)
from worldarena.primitive_sandbox.service import PrimitiveSandboxService
from worldarena.replay_api import ReplayCatalog
from worldarena.replay_api import router as replay_router

GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
PROJECT = WORLDARENA_GODOT_ROOT
DEMO_REPLAY = (
    PROJECT.parent
    / "demos"
    / "primitive-sandbox-tree-chop-nominal"
    / "1.0.0"
    / "replays"
    / "primary.replay.json"
)


def _client(tmp_path: Path) -> TestClient:
    replay_root = tmp_path / "replays"
    app = FastAPI()
    app.state.primitive_sandbox = PrimitiveSandboxService(
        runner=GodotPrimitiveSandboxRunner(executable=GODOT, project_path=PROJECT),
        replay_root=replay_root,
    )
    app.state.worldeval_replays = ReplayCatalog((replay_root,))
    app.include_router(sandbox_router)
    app.include_router(replay_router)
    return TestClient(app)


@pytest.mark.skipif(not GODOT.is_file(), reason="Godot 4.5 is unavailable")
def test_interrupted_demo_is_authoritative_replay_first_and_publicly_downloadable(
    tmp_path: Path,
) -> None:
    with _client(tmp_path) as client:
        catalog = client.get("/api/worldeval/sandbox")
        response = client.post(
            "/api/worldeval/sandbox/runs",
            json={"scenarioId": "tree-chop-interrupted-v0"},
        )
        assert response.status_code == 200, response.text
        value = response.json()
        replay_summary = client.get(value["replay"]["bundleUrl"])
        replay_file = client.get(value["replay"]["primaryUrl"])

    assert catalog.status_code == 200
    assert catalog.json()["gameId"] == "worldarena-primitive-sandbox-v0"
    assert value["status"] == "ready"
    assert value["tick"] == 27
    assert value["grid"]["agent"] == value["grid"]["base"] == {"x": 2, "y": 12}
    assert value["grid"]["barrier"] == {"x": 12, "y": 12}
    assert value["grid"]["enemy"] == {"x": 23, "y": 12}
    assert value["evaluation"]["passed"] is True
    assert value["evaluation"]["correct_retreat"] is True
    assert value["evaluation"]["forbidden_autonomy_count"] == 0
    events = [event for row in value["timeline"] for event in row["events"]]
    assert "movement_blocked" in events
    assert "hostile_near_target" in events
    assert any(row["responseType"] == "plan.abort" for row in value["timeline"])
    assert value["replay"]["verified"] is True
    assert replay_summary.status_code == 200
    assert replay_summary.json()["offline_verification"]["provider_calls"] == 0
    assert replay_file.status_code == 200
    assert replay_file.json()["terminal_outcome"] == "safe_return"
    assert replay_file.json()["offline_verified"] is True


@pytest.mark.skipif(not GODOT.is_file(), reason="Godot 4.5 is unavailable")
def test_nominal_demo_equips_axe_and_destroys_the_tree(tmp_path: Path) -> None:
    with _client(tmp_path) as client:
        response = client.post(
            "/api/worldeval/sandbox/runs",
            json={"scenarioId": "tree-chop-nominal-v0"},
        )

    assert response.status_code == 200, response.text
    value = response.json()
    assert value["status"] == "ready"
    assert value["tick"] == 23
    assert value["evaluation"]["passed"] is True
    assert value["evaluation"]["correct_tool_selected"] is True
    assert value["evaluation"]["outcome"] == "tree_destroyed"


def test_unknown_sandbox_scenario_fails_closed(tmp_path: Path) -> None:
    with _client(tmp_path) as client:
        response = client.post(
            "/api/worldeval/sandbox/runs",
            json={"scenarioId": "unknown"},
        )

    assert response.status_code == 422


@pytest.mark.skipif(not GODOT.is_file(), reason="Godot 4.5 is unavailable")
def test_native_replay_acceptance_reexecutes_in_godot_and_rejects_tampering(
    tmp_path: Path,
) -> None:
    runner = GodotPrimitiveSandboxRunner(
        executable=GODOT,
        project_path=PROJECT,
    )
    service = PrimitiveSandboxService(
        runner=runner,
        replay_root=tmp_path / "replays",
    )
    result = service.run(
        "tree-chop-nominal-v0",
        run_id="godot-native-verifier-test-v1",
    )
    replay_path = result.bundle_path / "replays" / "primary.replay.json"
    descriptor = {
        "native_schema": NATIVE_SCHEMA,
        "verifier": NATIVE_VERIFIER,
    }

    verified = native_replay_verifier(
        replay_path.read_bytes(),
        descriptor,
        executable=GODOT,
        project_path=PROJECT,
        require_network_isolation=network_isolation_available(),
    )
    assert verified.provider_calls == 0

    tampered = json.loads(replay_path.read_text(encoding="utf-8"))
    tampered["terminal_tick"] += 1
    with pytest.raises(GodotSandboxError, match="failed closed"):
        native_replay_verifier(
            json.dumps(
                tampered,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8"),
            descriptor,
            executable=GODOT,
            project_path=PROJECT,
        )

    tampered = json.loads(replay_path.read_text(encoding="utf-8"))
    tampered["initialization_hash"] = f"sha256:{'0' * 64}"
    with pytest.raises(GodotSandboxError, match="authored inputs"):
        native_replay_verifier(
            json.dumps(
                tampered,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8"),
            descriptor,
            executable=GODOT,
            project_path=PROJECT,
        )


def test_native_replay_acceptance_fails_closed_without_godot(tmp_path: Path) -> None:
    with pytest.raises(GodotSandboxError, match="Godot executable is unavailable"):
        native_replay_verifier(
            DEMO_REPLAY.read_bytes(),
            {
                "native_schema": NATIVE_SCHEMA,
                "verifier": NATIVE_VERIFIER,
            },
            executable=tmp_path / "missing-godot",
            project_path=PROJECT,
        )
