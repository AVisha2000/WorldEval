from __future__ import annotations

from pathlib import Path
from typing import Any, Mapping, Sequence

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from worldarena.paths import WORLDARENA_GODOT_ROOT
from worldarena.primitive_sandbox.api import router as sandbox_router
from worldarena.primitive_sandbox.demo import PrimitiveSandboxDemoAgent
from worldarena.primitive_sandbox.godot import (
    GodotPrimitiveSandboxRunner,
    GodotSandboxError,
)
from worldarena.primitive_sandbox.service import (
    PrimitiveSandboxService,
    PrimitiveSandboxServiceError,
)
from worldarena.replay_api import ReplayCatalog
from worldarena.replay_api import router as replay_router
from worldeval.replay import INCOMPLETE_RUN_SCHEMA, load_incomplete_run

GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")
PROJECT = WORLDARENA_GODOT_ROOT


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
def test_interactive_session_requires_exact_ack_and_neutralizes_bad_input(
    tmp_path: Path,
) -> None:
    with _client(tmp_path) as client:
        created_response = client.post(
            "/api/worldeval/sandbox/sessions",
            json={"scenarioId": "tree-chop-interrupted-v0"},
        )
        assert created_response.status_code == 201, created_response.text
        created = created_response.json()
        session_id = created["sessionId"]
        assert created["status"] == "awaiting_acknowledgement"
        assert created["acknowledgement"]["required"] is True
        assert created["acknowledgement"]["acknowledged"] is False
        assert (
            created["onboarding"]["initialization_hash"]
            == created["acknowledgement"]["initializationHash"]
        )
        assert created["onboarding"]["authority"]["engine"] == "godot"
        assert (
            created["observation"]["session_id"]
            == created["onboarding"]["session_id"]
        )
        decisions_url = f"/api/worldeval/sandbox/sessions/{session_id}/decisions"
        acknowledge_url = (
            f"/api/worldeval/sandbox/sessions/{session_id}/acknowledge"
        )

        before_ack = client.post(decisions_url, json={})
        wrong_ack = client.post(
            acknowledge_url,
            json={"initializationHash": f"sha256:{'0' * 64}"},
        )
        unchanged = client.get(f"/api/worldeval/sandbox/sessions/{session_id}")

        assert before_ack.status_code == 409
        assert wrong_ack.status_code == 409
        assert unchanged.status_code == 200
        assert unchanged.json()["observation"]["observation_seq"] == 0
        assert unchanged.json()["decisionCount"] == 0

        acknowledged = client.post(
            acknowledge_url,
            json={
                "initializationHash": created["acknowledgement"][
                    "initializationHash"
                ]
            },
        )
        missing = client.post(decisions_url)
        invalid = client.post(
            decisions_url,
            json={"decision": {"type": "teleport", "target": {"x": 23, "y": 12}}},
        )

        assert acknowledged.status_code == 200
        assert acknowledged.json()["status"] == "decision_required"
        assert acknowledged.json()["acknowledgement"]["acknowledged"] is True
        assert missing.status_code == 200, missing.text
        assert missing.json()["receipt"]["fallback"] == "neutral"
        assert missing.json()["receipt"]["no_input_reason"] == "missing"
        assert missing.json()["receipt"]["applied_ticks"] == 0
        assert missing.json()["observation"]["tick"] == 0
        assert invalid.status_code == 200, invalid.text
        assert invalid.json()["receipt"]["fallback"] == "neutral"
        assert invalid.json()["receipt"]["no_input_reason"] == "invalid"
        assert invalid.json()["receipt"]["applied_ticks"] == 0
        assert invalid.json()["observation"]["tick"] == 0
        assert invalid.json()["observation"]["observation_seq"] == 2

        policy = PrimitiveSandboxDemoAgent()
        planned = client.post(
            decisions_url,
            json={"decision": policy.decide(invalid.json()["observation"])},
        )
        assert planned.status_code == 200, planned.text
        planned_value = planned.json()
        assert planned_value["receipt"]["accepted"] is True
        active_plan = planned_value["observation"]["active_plan"]
        tick_before_silence = planned_value["observation"]["tick"]

        silence_while_active = client.post(decisions_url)
        assert silence_while_active.status_code == 200, silence_while_active.text
        silent_value = silence_while_active.json()
        assert silent_value["receipt"]["no_input_reason"] == "missing"
        assert silent_value["receipt"]["fallback"] == "neutral"
        assert silent_value["observation"]["tick"] == tick_before_silence
        assert silent_value["observation"]["active_plan"] == active_plan


@pytest.mark.skipif(not GODOT.is_file(), reason="Godot 4.5 is unavailable")
def test_interactive_demo_uses_decision_endpoint_and_is_ready_only_after_replay(
    tmp_path: Path,
) -> None:
    with _client(tmp_path) as client:
        created = client.post(
            "/api/worldeval/sandbox/sessions",
            json={"scenarioId": "tree-chop-interrupted-v0"},
        ).json()
        session_id = created["sessionId"]
        acknowledgement = client.post(
            f"/api/worldeval/sandbox/sessions/{session_id}/acknowledge",
            json={
                "initializationHash": created["acknowledgement"][
                    "initializationHash"
                ]
            },
        )
        assert acknowledgement.status_code == 200, acknowledgement.text
        invalid = client.post(
            f"/api/worldeval/sandbox/sessions/{session_id}/decisions",
            json={"decision": {"type": "opaque-skill", "name": "chop-tree"}},
        )
        assert invalid.status_code == 200, invalid.text
        assert invalid.json()["receipt"]["no_input_reason"] == "invalid"
        policy = PrimitiveSandboxDemoAgent()
        current = invalid.json()
        for _boundary in range(100):
            assert current["replay"]["status"] in {"pending", "ready"}
            if current["status"] == "ready":
                break
            decision = policy.decide(current["observation"])
            previous_count = current["decisionCount"]
            response = client.post(
                f"/api/worldeval/sandbox/sessions/{session_id}/decisions",
                json={"decision": decision},
            )
            assert response.status_code == 200, response.text
            current = response.json()
            assert current["decisionCount"] == previous_count + 1
        else:
            raise AssertionError("interactive demo did not reach a terminal boundary")

        fetched = client.get(f"/api/worldeval/sandbox/sessions/{session_id}")
        replay = client.get(current["replay"]["primaryUrl"])

    assert current["status"] == "ready"
    assert current["terminal"] is True
    assert current["outcome"] == "safe_return"
    assert current["observation"]["tick"] == 27
    assert current["observation"]["decision_required"]["allowed_responses"] == []
    assert current["replay"]["status"] == "ready"
    assert current["replay"]["verified"] is True
    assert current["evaluation"]["passed"] is True
    assert fetched.status_code == 200
    assert fetched.json() == current
    assert replay.status_code == 200
    assert replay.json()["terminal_outcome"] == "safe_return"
    assert replay.json()["offline_verified"] is True
    assert replay.json()["decisions"][0] is None
    assert replay.json()["receipts"][0]["no_input_reason"] == "invalid"


class _FailingRunner:
    sandbox_root = None

    def advance(
        self,
        scenario_id: str,
        *,
        run_id: str,
        history: Sequence[Mapping[str, Any]],
    ) -> Any:
        del scenario_id, run_id, history
        raise GodotSandboxError("simulated authority launch failure")


def test_preterminal_godot_failure_writes_only_atomic_incomplete_diagnostic(
    tmp_path: Path,
) -> None:
    replay_root = tmp_path / "replays"
    service = PrimitiveSandboxService(
        runner=_FailingRunner(),  # type: ignore[arg-type]
        replay_root=replay_root,
    )

    with pytest.raises(PrimitiveSandboxServiceError):
        service.run(
            "tree-chop-interrupted-v0",
            run_id="sandbox-launch-failure-v1",
        )

    destination = replay_root / "sandbox-launch-failure-v1"
    assert sorted(path.name for path in destination.iterdir()) == [
        "incomplete-run.json"
    ]
    diagnostic = load_incomplete_run(destination)
    assert diagnostic["schema"] == INCOMPLETE_RUN_SCHEMA
    assert diagnostic["phase"] == "authority_initialization"
    assert diagnostic["recoverable"] is False
    assert diagnostic["details"]["terminal_boundary_reached"] is False
    assert diagnostic["details"]["replay_saved"] is False
    assert not (destination / "manifest.json").exists()
    assert not (destination / "replays").exists()
